import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "VisionAgent")

/// Vision-first computer use agent that operates in a see-think-act-verify loop.
///
/// Unlike the old plan-then-execute architecture (CloudPlanner + LocalExecutor), the VisionAgent:
/// 1. Takes a live screenshot at every step
/// 2. Sends the screenshot + task to Haiku for a single next-action decision
/// 3. Executes the action (click, type, hotkey, etc.)
/// 4. Verifies the result with OCR and a new screenshot
/// 5. Loops until done or max iterations reached
///
/// Key design decisions:
/// - **VLM grounding (ShowUI-2B) is the PRIMARY element finder** — not AX search.
///   When clicking by description, the VLM takes a screenshot and returns coordinates.
/// - **Haiku for per-step reasoning** — fast (~200ms) and cheap. No big cloud planning call.
/// - **OCR verification after every action** — no more blind "OK" reporting.
/// - **No hardcoded app recipes** — the agent figures out any app dynamically.
/// - **Max 20 iterations, 30s timeout** — fast failure, not silent 65s runs.
///
/// Mimicry V2: Vision-First Agent Loop.
actor VisionAgent {

    /// The LLM orchestrator for Haiku calls.
    private let orchestrator: LLMOrchestrator

    /// The local grounding model (ShowUI-2B) for element location.
    private let groundingModel: LocalGroundingModel?

    /// Maximum iterations before stopping.
    private let maxIterations: Int

    /// Timeout in seconds.
    private let timeoutSeconds: TimeInterval

    /// Fast model ID — auto-detected based on which cloud provider is available.
    /// Haiku for Anthropic, gpt-4.1-nano for OpenAI.
    private let fastModelId: String?

    // MARK: - Init

    init(
        orchestrator: LLMOrchestrator,
        groundingModel: LocalGroundingModel? = nil,
        maxIterations: Int = 50,
        timeoutSeconds: TimeInterval = 180,
        fastModelId: String? = nil
    ) {
        self.orchestrator = orchestrator
        self.groundingModel = groundingModel
        self.maxIterations = maxIterations
        self.timeoutSeconds = timeoutSeconds
        self.fastModelId = fastModelId
    }

    // MARK: - Main Loop

    /// Execute a task using the see-think-act-verify loop.
    ///
    /// Returns an AsyncStream of progress events for the UI layer to consume.
    ///
    /// - Parameters:
    ///   - task: Natural language task description (e.g., "Send an email to john@example.com saying hello").
    ///   - onProgress: Callback for each step's progress (for UI updates).
    /// - Returns: A `VisionAgentResult` with the outcome and step history.
    func execute(
        task: String,
        onProgress: (@Sendable (VisionAgentProgress) async -> Void)? = nil
    ) async -> VisionAgentResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        var steps: [VisionAgentStep] = []
        var iteration = 0

        // Remember which app was frontmost so we can return to it when done
        let startingAppPID: pid_t? = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }

        logger.notice("[MIMICRY-V2] Starting vision agent for: '\(task, privacy: .public)' (maxIter=\(self.maxIterations), timeout=\(self.timeoutSeconds)s, VLM=\(self.groundingModel != nil ? "available" : "nil", privacy: .public))")
        DiagnosticsStore.shared.increment("mimicry_v2_task_total")

        await onProgress?(VisionAgentProgress(
            phase: .starting,
            message: "Starting task...",
            iteration: 0,
            maxIterations: maxIterations
        ))

        // Build conversation history for the agent
        var messages: [LLMMessage] = []

        while iteration < maxIterations {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if elapsed > timeoutSeconds {
                logger.warning("[MIMICRY-V2] Timeout after \(String(format: "%.1f", elapsed))s at iteration \(iteration)")
                await onProgress?(VisionAgentProgress(
                    phase: .failed,
                    message: "Timeout after \(Int(elapsed))s",
                    iteration: iteration,
                    maxIterations: maxIterations
                ))
                return VisionAgentResult(
                    task: task,
                    status: .timeout,
                    steps: steps,
                    durationMs: elapsed * 1000,
                    summary: "Task timed out after \(Int(elapsed))s and \(iteration) iterations."
                )
            }

            iteration += 1
            let stepStart = CFAbsoluteTimeGetCurrent()

            // === SEE ===
            // Capture current screen state + frontmost app name (both require MainActor)
            let (screenshot, currentAppName) = await MainActor.run {
                let shot = ScreenshotCapture.captureScreen()
                let appName = AgentFocusManager.shared.targetAppInfo()?.name
                    ?? NSWorkspace.shared.frontmostApplication?.localizedName
                    ?? "unknown"
                return (shot, appName)
            }
            guard let screenshot else {
                logger.error("[MIMICRY-V2] Screenshot capture failed at iteration \(iteration)")
                return VisionAgentResult(
                    task: task,
                    status: .failed,
                    steps: steps,
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000,
                    summary: "Screenshot capture failed. Screen Recording permission may be missing."
                )
            }

            // Resize screenshot for Haiku API (must be <2000px per edge for multi-image requests)
            guard let resized = ScreenshotCapture.resize(screenshot, maxEdge: 1600),
                  let screenshotBase64 = ScreenshotCapture.encodeBase64JPEG(resized, quality: 0.6) else {
                logger.error("[MIMICRY-V2] Screenshot encoding failed at iteration \(iteration)")
                continue
            }

            // Run OCR on the screenshot for text context
            let ocrText = await ScreenshotCapture.extractText(from: screenshot)

            await onProgress?(VisionAgentProgress(
                phase: .thinking,
                message: "Analyzing screen (iteration \(iteration)/\(maxIterations))...",
                iteration: iteration,
                maxIterations: maxIterations
            ))

            // === THINK ===
            // Ask Haiku what to do next
            let userContent: [LLMMessageContent]
            if iteration == 1 {
                // First iteration: include the task + screenshot
                userContent = [
                    .image(mediaType: "image/jpeg", base64Data: screenshotBase64),
                    .text(buildFirstTurnPrompt(task: task, ocrText: ocrText, frontmostAppName: currentAppName))
                ]
            } else {
                // Subsequent iterations: include screenshot + what happened last
                let lastStep = steps.last
                let verificationSummary = lastStep.map { step in
                    "Previous action: \(step.action)\nResult: \(step.verification)"
                } ?? ""
                userContent = [
                    .image(mediaType: "image/jpeg", base64Data: screenshotBase64),
                    .text(buildFollowUpPrompt(
                        task: task,
                        iteration: iteration,
                        previousResult: verificationSummary,
                        ocrText: ocrText
                    ))
                ]
            }

            messages.append(LLMMessage(role: "user", content: userContent))

            // Sliding window: strip images from old messages to prevent request_too_large.
            // Keep images only in the last 6 user messages (= 6 screenshots).
            // Older user messages get their images replaced with "[screenshot omitted]".
            pruneOldImages(in: &messages, keepLastN: 6)

            // Call Haiku with tool-calling
            let response: LLMResponse
            do {
                let request = LLMRequest(
                    systemPrompt: buildSystemPrompt(),
                    userPrompt: "",
                    tools: buildToolSpecs(),
                    maxTokens: 1024,
                    temperature: 0.0,
                    responseFormat: .text,
                    messages: messages,
                    modelOverride: fastModelId
                )
                response = try await orchestrator.generate(request: request)
            } catch {
                logger.error("[MIMICRY-V2] Haiku call failed at iteration \(iteration): \(error.localizedDescription, privacy: .public)")
                steps.append(VisionAgentStep(
                    iteration: iteration,
                    action: "think",
                    detail: "LLM call failed: \(error.localizedDescription)",
                    verification: "error",
                    durationMs: (CFAbsoluteTimeGetCurrent() - stepStart) * 1000,
                    groundingStrategy: nil
                ))
                // Continue to next iteration with a fresh attempt
                messages.append(LLMMessage(role: "assistant", content: [.text("Error: \(error.localizedDescription)")]))
                continue
            }

            // Record the assistant message in conversation history
            if !response.toolCalls.isEmpty {
                var assistantContent: [LLMMessageContent] = []
                if !response.content.isEmpty {
                    assistantContent.append(.text(response.content))
                }
                for tc in response.toolCalls {
                    assistantContent.append(.toolUse(id: tc.id, name: tc.name, input: tc.arguments))
                }
                messages.append(LLMMessage(role: "assistant", content: assistantContent))
            } else {
                messages.append(LLMMessage(role: "assistant", content: [.text(response.content)]))
            }

            // === ACT ===
            // Process tool calls
            if response.toolCalls.isEmpty {
                // No tool calls — Haiku returned text only. Treat as "thinking out loud".
                // Check if the response indicates completion.
                let lowerContent = response.content.lowercased()
                if lowerContent.contains("task is complete") || lowerContent.contains("done") {
                    logger.notice("[MIMICRY-V2] Agent signaled completion via text at iteration \(iteration)")
                    steps.append(VisionAgentStep(
                        iteration: iteration,
                        action: "done",
                        detail: response.content,
                        verification: "completed",
                        durationMs: (CFAbsoluteTimeGetCurrent() - stepStart) * 1000,
                        groundingStrategy: nil
                    ))
                    break
                }
                logger.info("[MIMICRY-V2] No tool calls at iteration \(iteration), Haiku said: \(response.content.prefix(200), privacy: .public)")
                // Add a user message prompting Haiku to take action
                messages.append(LLMMessage(role: "user", content: [
                    .text("You must use a tool to proceed. Call one of the available tools to take the next action toward completing the task.")
                ]))
                continue
            }

            // Execute each tool call
            var toolResults: [LLMMessageContent] = []
            for toolCall in response.toolCalls {
                let actionResult = await executeToolCall(toolCall, screenshot: screenshot)

                await onProgress?(VisionAgentProgress(
                    phase: .acting,
                    message: "Step \(iteration): \(toolCall.name) — \(actionResult.detail.prefix(80))",
                    iteration: iteration,
                    maxIterations: maxIterations
                ))

                // Check for terminal tools
                if toolCall.name == "done" {
                    let summary = toolCall.arguments["summary"]?.stringValue ?? "Task completed"
                    logger.notice("[MIMICRY-V2] Agent called done(): \(summary, privacy: .public)")
                    steps.append(VisionAgentStep(
                        iteration: iteration,
                        action: "done",
                        detail: summary,
                        verification: "completed",
                        durationMs: (CFAbsoluteTimeGetCurrent() - stepStart) * 1000,
                        groundingStrategy: nil
                    ))

                    toolResults.append(.toolResult(
                        toolUseId: toolCall.id,
                        content: "Task marked as complete.",
                        isError: false
                    ))
                    // Add tool results to history before returning
                    messages.append(LLMMessage(role: "user", content: toolResults))

                    let totalElapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    DiagnosticsStore.shared.increment("mimicry_v2_task_success_total")
                    DiagnosticsStore.shared.recordLatency("mimicry_v2_task_duration_ms", ms: totalElapsed)

                    await onProgress?(VisionAgentProgress(
                        phase: .completed,
                        message: summary,
                        iteration: iteration,
                        maxIterations: maxIterations
                    ))

                    // Return to the app that was frontmost before Mimicry started
                    await refocusStartingApp(pid: startingAppPID)

                    return VisionAgentResult(
                        task: task,
                        status: .succeeded,
                        steps: steps,
                        durationMs: totalElapsed,
                        summary: summary
                    )
                }

                if toolCall.name == "fail" {
                    let reason = toolCall.arguments["reason"]?.stringValue ?? "Task failed"
                    logger.warning("[MIMICRY-V2] Agent called fail(): \(reason, privacy: .public)")
                    steps.append(VisionAgentStep(
                        iteration: iteration,
                        action: "fail",
                        detail: reason,
                        verification: "failed",
                        durationMs: (CFAbsoluteTimeGetCurrent() - stepStart) * 1000,
                        groundingStrategy: nil
                    ))

                    toolResults.append(.toolResult(
                        toolUseId: toolCall.id,
                        content: "Task marked as failed.",
                        isError: false
                    ))
                    messages.append(LLMMessage(role: "user", content: toolResults))

                    let totalElapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    DiagnosticsStore.shared.increment("mimicry_v2_task_fail_total")

                    await onProgress?(VisionAgentProgress(
                        phase: .failed,
                        message: reason,
                        iteration: iteration,
                        maxIterations: maxIterations
                    ))

                    return VisionAgentResult(
                        task: task,
                        status: .failed,
                        steps: steps,
                        durationMs: totalElapsed,
                        summary: reason
                    )
                }

                // === VERIFY ===
                // Wait for UI to settle, then capture verification
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

                let verificationText: String
                if toolCall.name == "type" || toolCall.name == "hotkey" || toolCall.name == "key_press" {
                    // For typing/key actions, do a quick OCR to verify text appeared
                    let verifyShot: CGImage? = await MainActor.run { ScreenshotCapture.captureScreen() }
                    if let verifyShot {
                        let afterOCR = await ScreenshotCapture.extractText(from: verifyShot)
                        let typedText = toolCall.arguments["text"]?.stringValue ?? ""
                        if typedText.isEmpty {
                            verificationText = "Key press executed"
                        } else {
                            // Try exact match first, then partial match (first word)
                            let searchPrefix = String(typedText.prefix(20))
                            let firstWord = typedText.split(separator: " ").first.map(String.init) ?? searchPrefix
                            if afterOCR.contains(searchPrefix) {
                                verificationText = "Verified: typed text visible in OCR"
                            } else if afterOCR.localizedCaseInsensitiveContains(firstWord) {
                                verificationText = "Likely verified: partial text match in OCR"
                            } else {
                                // Don't alarm the LLM — OCR misses text in web apps frequently
                                verificationText = "Text entered (OCR could not confirm — normal for web apps)"
                            }
                        }
                    } else {
                        verificationText = "Verification screenshot failed"
                    }
                } else {
                    verificationText = actionResult.verification
                }

                steps.append(VisionAgentStep(
                    iteration: iteration,
                    action: "\(toolCall.name)(\(actionResult.detail.prefix(100)))",
                    detail: actionResult.detail,
                    verification: verificationText,
                    durationMs: (CFAbsoluteTimeGetCurrent() - stepStart) * 1000,
                    groundingStrategy: actionResult.groundingStrategy
                ))

                toolResults.append(.toolResult(
                    toolUseId: toolCall.id,
                    content: "Action executed. \(verificationText)",
                    isError: actionResult.isError
                ))

                logger.notice("[MIMICRY-V2] Step \(iteration): \(toolCall.name, privacy: .public) -> \(verificationText, privacy: .public) (grounding: \(actionResult.groundingStrategy?.rawValue ?? "n/a", privacy: .public))")
            }

            // Add tool results to conversation
            messages.append(LLMMessage(role: "user", content: toolResults))
        }

        // Max iterations reached
        let totalElapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        DiagnosticsStore.shared.increment("mimicry_v2_task_maxiter_total")

        await onProgress?(VisionAgentProgress(
            phase: .failed,
            message: "Max iterations (\(maxIterations)) reached",
            iteration: maxIterations,
            maxIterations: maxIterations
        ))

        logger.warning("[MIMICRY-V2] Max iterations reached (\(self.maxIterations)). Steps completed: \(steps.count)")
        return VisionAgentResult(
            task: task,
            status: .maxIterations,
            steps: steps,
            durationMs: totalElapsed,
            summary: "Task did not complete within \(maxIterations) iterations. \(steps.count) actions were taken."
        )
    }

    // MARK: - Tool Execution

    /// Execute a single tool call and return the result.
    private func executeToolCall(
        _ toolCall: ToolCall,
        screenshot: CGImage
    ) async -> ToolActionResult {
        switch toolCall.name {
        case "click":
            return await executeClick(toolCall, screenshot: screenshot)
        case "type":
            return await executeType(toolCall)
        case "hotkey":
            return await executeHotkey(toolCall)
        case "key_press":
            return await executeKeyPress(toolCall)
        case "focus_app":
            return await executeFocusApp(toolCall)
        case "scroll":
            return await executeScroll(toolCall)
        case "wait":
            return await executeWait(toolCall)
        default:
            return ToolActionResult(
                detail: "Unknown tool: \(toolCall.name)",
                verification: "skipped",
                isError: true,
                groundingStrategy: nil
            )
        }
    }

    /// Execute a click action. Always uses element grounding (VLM primary, AX fallback).
    /// Direct x/y coordinates are not exposed to the LLM to prevent hallucinated coordinates.
    private func executeClick(_ toolCall: ToolCall, screenshot: CGImage) async -> ToolActionResult {
        let description = toolCall.arguments["description"]?.stringValue ?? ""

        var point: CGPoint
        var strategy: GroundingStrategy?

        if !description.isEmpty {
            // Use VLM grounding to find the element
            let screenSize = await MainActor.run { ScreenshotCapture.screenSize }

            if let model = groundingModel, model.isAvailable {
                // VLM path (primary)
                do {
                    let result = try await model.ground(
                        instruction: description,
                        screenshot: screenshot,
                        screenSize: screenSize
                    )
                    if result.confidence >= 0.3 {
                        point = result.point
                        strategy = .vlmGrounding
                        logger.notice("[MIMICRY-V2] VLM grounding for '\(description, privacy: .public)': (\(String(format: "%.0f", point.x)), \(String(format: "%.0f", point.y))) confidence=\(String(format: "%.2f", result.confidence))")
                    } else {
                        logger.warning("[MIMICRY-V2] VLM low confidence (\(String(format: "%.2f", result.confidence))) for '\(description, privacy: .public)', falling back to AX")
                        // Fall back to AX search
                        let axResult = await axFallbackClick(description: description)
                        if let axResult {
                            return axResult
                        }
                        return ToolActionResult(
                            detail: "Element '\(description)' not found (VLM confidence too low, AX fallback failed)",
                            verification: "failed",
                            isError: true,
                            groundingStrategy: .vlmGrounding
                        )
                    }
                } catch {
                    logger.warning("[MIMICRY-V2] VLM grounding failed: \(error.localizedDescription, privacy: .public), falling back to AX")
                    let axResult = await axFallbackClick(description: description)
                    if let axResult {
                        return axResult
                    }
                    return ToolActionResult(
                        detail: "Element '\(description)' not found (VLM error: \(error.localizedDescription), AX fallback failed)",
                        verification: "failed",
                        isError: true,
                        groundingStrategy: nil
                    )
                }
            } else {
                // No VLM available — use AX search as fallback
                logger.info("[MIMICRY-V2] No VLM available, using AX search for '\(description, privacy: .public)'")
                let axResult = await axFallbackClick(description: description)
                if let axResult {
                    return axResult
                }
                return ToolActionResult(
                    detail: "Element '\(description)' not found (no VLM, AX search failed)",
                    verification: "failed",
                    isError: true,
                    groundingStrategy: nil
                )
            }
        } else {
            return ToolActionResult(
                detail: "Click requires either 'description' or 'x'/'y' coordinates",
                verification: "failed",
                isError: true,
                groundingStrategy: nil
            )
        }

        // Execute the click
        do {
            try await MainActor.run {
                try InputSynthesizer.click(at: point)
            }
            return ToolActionResult(
                detail: description.isEmpty
                    ? "Clicked at (\(Int(point.x)), \(Int(point.y)))"
                    : "Clicked '\(description)' at (\(Int(point.x)), \(Int(point.y)))",
                verification: "click executed",
                isError: false,
                groundingStrategy: strategy
            )
        } catch {
            return ToolActionResult(
                detail: "Click failed: \(error.localizedDescription)",
                verification: "failed",
                isError: true,
                groundingStrategy: strategy
            )
        }
    }

    /// AX-based fallback for click when VLM is unavailable or low confidence.
    private func axFallbackClick(description: String) async -> ToolActionResult? {
        let cleanQuery = GroundingOracle.extractCleanLabel(from: description)

        let result: (point: CGPoint, strategy: String)? = await MainActor.run {
            guard let appInfo = AgentFocusManager.shared.targetAppInfo() else {
                return nil
            }
            let results = findElements(
                in: appInfo.element,
                role: nil,
                query: cleanQuery,
                maxResults: 5,
                maxDepth: 25,
                timeout: 3.0
            )
            guard let best = results.first else { return nil }
            guard let pos = best.element.position(), let size = best.element.size() else { return nil }
            let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
            return (point: center, strategy: best.matchStrategy)
        }

        guard let result else { return nil }

        do {
            try await MainActor.run {
                try InputSynthesizer.click(at: result.point)
            }
            return ToolActionResult(
                detail: "Clicked '\(cleanQuery)' at (\(Int(result.point.x)), \(Int(result.point.y))) via AX \(result.strategy)",
                verification: "click executed via AX fallback",
                isError: false,
                groundingStrategy: .axFuzzy
            )
        } catch {
            return nil
        }
    }

    /// Execute a type action.
    private func executeType(_ toolCall: ToolCall) async -> ToolActionResult {
        guard let text = toolCall.arguments["text"]?.stringValue, !text.isEmpty else {
            return ToolActionResult(
                detail: "Type requires 'text' argument",
                verification: "failed",
                isError: true,
                groundingStrategy: nil
            )
        }

        do {
            try await MainActor.run {
                try InputSynthesizer.typeText(text)
            }
            logger.notice("[MIMICRY-V2] Typed \(text.count) chars: '\(text.prefix(80), privacy: .public)'")
            return ToolActionResult(
                detail: "Typed \(text.count) chars: '\(text.prefix(80))'",
                verification: "text entered",
                isError: false,
                groundingStrategy: nil
            )
        } catch {
            return ToolActionResult(
                detail: "Type failed: \(error.localizedDescription)",
                verification: "failed",
                isError: true,
                groundingStrategy: nil
            )
        }
    }

    /// Execute a hotkey action.
    private func executeHotkey(_ toolCall: ToolCall) async -> ToolActionResult {
        guard let keysAny = toolCall.arguments["keys"],
              let keys = keysAny.arrayOfStrings, !keys.isEmpty else {
            return ToolActionResult(
                detail: "Hotkey requires 'keys' array argument",
                verification: "failed",
                isError: true,
                groundingStrategy: nil
            )
        }

        do {
            try await MainActor.run {
                try InputSynthesizer.hotkey(keys)
            }
            logger.notice("[MIMICRY-V2] Hotkey: \(keys.joined(separator: "+"), privacy: .public)")
            return ToolActionResult(
                detail: "Pressed \(keys.joined(separator: "+"))",
                verification: "hotkey executed",
                isError: false,
                groundingStrategy: nil
            )
        } catch {
            return ToolActionResult(
                detail: "Hotkey failed: \(error.localizedDescription)",
                verification: "failed",
                isError: true,
                groundingStrategy: nil
            )
        }
    }

    /// Execute a single key press.
    private func executeKeyPress(_ toolCall: ToolCall) async -> ToolActionResult {
        guard let key = toolCall.arguments["key"]?.stringValue, !key.isEmpty else {
            return ToolActionResult(
                detail: "key_press requires 'key' argument",
                verification: "failed",
                isError: true,
                groundingStrategy: nil
            )
        }

        do {
            try await MainActor.run {
                try InputSynthesizer.hotkey([key])
            }
            logger.notice("[MIMICRY-V2] Key press: \(key, privacy: .public)")
            return ToolActionResult(
                detail: "Pressed \(key)",
                verification: "key pressed",
                isError: false,
                groundingStrategy: nil
            )
        } catch {
            return ToolActionResult(
                detail: "Key press failed: \(error.localizedDescription)",
                verification: "failed",
                isError: true,
                groundingStrategy: nil
            )
        }
    }

    /// Execute a focus app action.
    private func executeFocusApp(_ toolCall: ToolCall) async -> ToolActionResult {
        guard let appName = toolCall.arguments["name"]?.stringValue, !appName.isEmpty else {
            return ToolActionResult(
                detail: "focus_app requires 'name' argument",
                verification: "failed",
                isError: true,
                groundingStrategy: nil
            )
        }

        let activated = await MainActor.run { () -> Bool in
            let apps = NSWorkspace.shared.runningApplications
            let target = apps.first(where: {
                $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame
            }) ?? apps.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            })

            guard let app = target else { return false }

            let success = app.activate()
            if success {
                AgentFocusManager.shared.setTarget(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? appName,
                    bundleId: app.bundleIdentifier ?? ""
                )
            }
            return success
        }

        if activated {
            try? await Task.sleep(nanoseconds: 500_000_000) // Wait for app to come to front
            return ToolActionResult(
                detail: "Focused app: \(appName)",
                verification: "app activated",
                isError: false,
                groundingStrategy: nil
            )
        } else {
            return ToolActionResult(
                detail: "App '\(appName)' not found or failed to activate",
                verification: "failed",
                isError: true,
                groundingStrategy: nil
            )
        }
    }

    /// Execute a scroll action.
    private func executeScroll(_ toolCall: ToolCall) async -> ToolActionResult {
        let direction = toolCall.arguments["direction"]?.stringValue ?? "down"
        let amount = toolCall.arguments["amount"]?.intValue ?? 3
        let deltaY: Int32 = direction.lowercased().contains("up") ? Int32(amount) : Int32(-amount)

        do {
            try await MainActor.run {
                try InputSynthesizer.scroll(deltaY: deltaY)
            }
            return ToolActionResult(
                detail: "Scrolled \(direction) by \(amount)",
                verification: "scrolled",
                isError: false,
                groundingStrategy: nil
            )
        } catch {
            return ToolActionResult(
                detail: "Scroll failed: \(error.localizedDescription)",
                verification: "failed",
                isError: true,
                groundingStrategy: nil
            )
        }
    }

    /// Execute a wait action.
    private func executeWait(_ toolCall: ToolCall) async -> ToolActionResult {
        let seconds = toolCall.arguments["seconds"]?.doubleValue ?? 1.0
        let clampedSeconds = min(seconds, 5.0) // Cap at 5 seconds

        try? await Task.sleep(nanoseconds: UInt64(clampedSeconds * 1_000_000_000))

        return ToolActionResult(
            detail: "Waited \(String(format: "%.1f", clampedSeconds))s",
            verification: "waited",
            isError: false,
            groundingStrategy: nil
        )
    }

    // MARK: - Conversation Management

    /// Remove images from older messages to prevent the request from growing unbounded.
    ///
    /// Anthropic rejects requests with many images exceeding 2000px, and the total payload
    /// hits HTTP 413 after ~15-20 screenshots. This keeps only the last `keepLastN` user
    /// messages with images intact; older images are replaced with "[screenshot omitted]".
    private func pruneOldImages(in messages: inout [LLMMessage], keepLastN: Int) {
        // Find indices of user messages that contain images
        var imageMessageIndices: [Int] = []
        for (i, msg) in messages.enumerated() {
            guard msg.role == "user" else { continue }
            let hasImage = msg.content.contains { item in
                if case .image = item { return true }
                return false
            }
            if hasImage {
                imageMessageIndices.append(i)
            }
        }

        // Only prune if we have more than keepLastN image messages
        guard imageMessageIndices.count > keepLastN else { return }

        let indicesToPrune = imageMessageIndices.dropLast(keepLastN)
        for idx in indicesToPrune {
            let msg = messages[idx]
            let prunedContent = msg.content.map { item -> LLMMessageContent in
                if case .image = item {
                    return .text("[screenshot omitted]")
                }
                return item
            }
            messages[idx] = LLMMessage(role: msg.role, content: prunedContent)
        }
    }

    // MARK: - App Focus Management

    /// Return focus to the app that was frontmost before Mimicry started.
    private func refocusStartingApp(pid: pid_t?) async {
        guard let pid else { return }
        let success = await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated else {
                return false
            }
            return app.activate()
        }
        if success {
            logger.notice("[MIMICRY-V2] Returned focus to starting app (pid=\(pid))")
        } else {
            logger.info("[MIMICRY-V2] Could not refocus starting app (pid=\(pid)) — may have quit")
        }
    }

    // MARK: - Prompts

    /// System prompt for the vision agent.
    private func buildSystemPrompt() -> String {
        """
        You are a computer use agent controlling a Mac. You see the screen via screenshots and \
        take one action at a time — look, decide, act, then look again.

        RULES:
        1. LOOK at the screenshot FIRST. What app is open? What state is it in?
        2. DO NOT open apps already visible. If Gmail is in Chrome, work with it directly.
        3. ONE action per step. You'll get a new screenshot after each action.
        4. For click(): describe the element using its VISIBLE TEXT. Examples: "Compose", "Send", \
           "To", "Subject". The system finds and clicks it automatically. NEVER guess coordinates.
        5. For web apps (Gmail, Slack): click the field first, then type(). Use Tab between fields.
        6. OCR verification may say "not found" — this is normal for web apps. Keep going.
        7. Call done(summary) when the task is complete. Call fail(reason) if impossible.
        8. DO NOT explain what you will do. Just call the tool.
        9. Never type passwords. Never use hotkey(["cmd","w"]) to close windows.
        10. If stuck, try a different approach (hotkeys, Tab navigation, scroll).

        WORKFLOW:
        1. FIRST, if the target app is not the frontmost window, use focus_app() to bring it to front.
        2. Then perform the task step by step.
        3. When done, call done() with a summary. The system will return to the previous app.

        APP PATTERNS:
        - Gmail: focus_app("Google Chrome") → click "Compose" → Tab to each field (To, Subject, Body) → type() → hotkey(["cmd","return"]) to send.
        - Slack: focus_app("Slack") → hotkey(["cmd","k"]) → type channel name → key_press("return") → type message → key_press("return").
        - General: Cmd+Tab switches apps. Cmd+L = browser address bar. Scroll if element not visible.
        """
    }

    /// First turn prompt with the task.
    private func buildFirstTurnPrompt(task: String, ocrText: String, frontmostAppName: String) -> String {
        var prompt = "Task: \(task)\n\n"
        prompt += "Currently visible app: \(frontmostAppName)\n"
        prompt += "This is the current screen."
        if !ocrText.isEmpty {
            let truncatedOCR = String(ocrText.prefix(2000))
            prompt += "\n\nVisible text (OCR):\n\(truncatedOCR)"
        }
        prompt += "\n\nLook at the screenshot. What is the FIRST action? Use a tool."
        return prompt
    }

    /// Follow-up turn prompt.
    private func buildFollowUpPrompt(
        task: String,
        iteration: Int,
        previousResult: String,
        ocrText: String
    ) -> String {
        var prompt = "Task: \(task)\nIteration: \(iteration)\n"
        if !previousResult.isEmpty {
            prompt += "\n\(previousResult)\n"
        }
        prompt += "\nThis is the current screen."
        if !ocrText.isEmpty {
            let truncatedOCR = String(ocrText.prefix(2000))
            prompt += "\n\nVisible text (OCR):\n\(truncatedOCR)"
        }
        prompt += "\n\nWhat is the next action? Use a tool, or call done() if the task is complete."
        return prompt
    }

    // MARK: - Tool Specs

    /// Build the tool specifications for the Haiku API call.
    private func buildToolSpecs() -> [ToolSpec] {
        [
            ToolSpec(
                name: "click",
                description: "Click a UI element by its visible label or description. The system locates it automatically. Do NOT guess coordinates — just describe what you see.",
                inputSchema: Self.makeSchema(properties: [
                    "description": Self.prop("string", "What to click — use the exact visible text or a short description (e.g., 'Compose', 'Send', 'To field', 'Search mail')")
                ], required: ["description"])
            ),
            ToolSpec(
                name: "type",
                description: "Type text at the currently focused element. Click a text field first if needed.",
                inputSchema: Self.makeSchema(properties: [
                    "text": Self.prop("string", "The text to type")
                ], required: ["text"])
            ),
            ToolSpec(
                name: "hotkey",
                description: "Press a keyboard shortcut. Modifiers: cmd, shift, option, ctrl. Keys: a-z, 0-9, return, tab, space, delete, escape, up, down, left, right.",
                inputSchema: Self.makeSchema(properties: [
                    "keys": .dictionary([
                        "type": .string("array"),
                        "items": .dictionary(["type": .string("string")]),
                        "description": .string("Array of keys, e.g. ['cmd', 'return']")
                    ])
                ], required: ["keys"])
            ),
            ToolSpec(
                name: "key_press",
                description: "Press a single key (tab, return, escape, delete, up, down, left, right, space).",
                inputSchema: Self.makeSchema(properties: [
                    "key": Self.prop("string", "Key name: tab, return, escape, delete, space, up, down, left, right")
                ], required: ["key"])
            ),
            ToolSpec(
                name: "focus_app",
                description: "Bring an application to the front. Use before interacting with a non-frontmost app.",
                inputSchema: Self.makeSchema(properties: [
                    "name": Self.prop("string", "Application name (case-insensitive, e.g., 'Google Chrome', 'Safari', 'Slack')")
                ], required: ["name"])
            ),
            ToolSpec(
                name: "scroll",
                description: "Scroll content in a direction.",
                inputSchema: Self.makeSchema(properties: [
                    "direction": Self.prop("string", "Scroll direction: up, down, left, or right"),
                    "amount": Self.prop("integer", "Number of lines to scroll (default 3)")
                ], required: ["direction"])
            ),
            ToolSpec(
                name: "wait",
                description: "Wait for a specified duration (max 5 seconds). Use after actions that trigger animations or page loads.",
                inputSchema: Self.makeSchema(properties: [
                    "seconds": Self.prop("number", "Seconds to wait (max 5.0)")
                ], required: ["seconds"])
            ),
            ToolSpec(
                name: "done",
                description: "Signal that the task is complete. Call this when you've verified the task was accomplished successfully.",
                inputSchema: Self.makeSchema(properties: [
                    "summary": Self.prop("string", "Brief summary of what was accomplished")
                ], required: ["summary"])
            ),
            ToolSpec(
                name: "fail",
                description: "Signal that the task cannot be completed. Use when you've exhausted options.",
                inputSchema: Self.makeSchema(properties: [
                    "reason": Self.prop("string", "Why the task cannot be completed")
                ], required: ["reason"])
            ),
        ]
    }

    // MARK: - Schema Helpers

    /// Build a JSON Schema object for a tool's input.
    private static func makeSchema(
        properties: [String: AnyCodable],
        required: [String]
    ) -> [String: AnyCodable] {
        [
            "type": .string("object"),
            "properties": .dictionary(properties),
            "required": .array(required.map { .string($0) })
        ]
    }

    /// Build a property descriptor for a JSON Schema.
    private static func prop(_ type: String, _ description: String) -> AnyCodable {
        .dictionary([
            "type": .string(type),
            "description": .string(description)
        ])
    }
}

// MARK: - Supporting Types

/// Result of a complete VisionAgent task execution.
struct VisionAgentResult: Sendable {
    let task: String
    let status: VisionAgentStatus
    let steps: [VisionAgentStep]
    let durationMs: Double
    let summary: String
}

/// Status of a VisionAgent task.
enum VisionAgentStatus: String, Sendable {
    case succeeded
    case failed
    case timeout
    case maxIterations
    case cancelled
}

/// A single step in the VisionAgent's execution history.
struct VisionAgentStep: Sendable {
    let iteration: Int
    let action: String
    let detail: String
    let verification: String
    let durationMs: Double
    let groundingStrategy: GroundingStrategy?
}

/// Progress update from the VisionAgent.
struct VisionAgentProgress: Sendable {
    let phase: VisionAgentPhase
    let message: String
    let iteration: Int
    let maxIterations: Int
}

/// Phases of the VisionAgent loop.
enum VisionAgentPhase: String, Sendable {
    case starting
    case thinking
    case acting
    case verifying
    case completed
    case failed
}

/// Internal result of executing a single tool action.
private struct ToolActionResult {
    let detail: String
    let verification: String
    let isError: Bool
    let groundingStrategy: GroundingStrategy?
}

// MARK: - AnyCodable Array Extension (VisionAgent-specific)

extension AnyCodable {
    /// Extract an array of strings from an AnyCodable array.
    var arrayOfStrings: [String]? {
        guard case .array(let arr) = self else { return nil }
        return arr.compactMap { $0.stringValue }
    }
}
