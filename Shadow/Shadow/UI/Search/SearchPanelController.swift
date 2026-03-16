import Cocoa
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "SearchPanel")

// MARK: - Search Panel

/// Borderless NSPanel for the search overlay.
///
/// A borderless NSPanel returns true from canBecomeKey by default (when
/// becomesKeyOnlyIfNeeded is false, which is the NSPanel default). We override
/// it explicitly to guarantee keyboard focus regardless of future style mask changes.
/// canBecomeMain returns false because this is a transient overlay, not the main window.
private class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Search Panel Controller

/// Manages a floating NSPanel for Spotlight-like search overlay.
/// The panel floats above all windows, receives keyboard focus immediately,
/// and dismisses on Esc or when it loses key window status.
///
/// Supports adaptive panel height based on command state (search vs running vs result vs error).
@MainActor
final class SearchPanelController {
    private var panel: NSPanel?
    private var viewModel: SearchViewModel?
    private var resignObserver: NSObjectProtocol?

    /// Injected by AppDelegate after LLM subsystem initialization.
    var summaryJobQueue: SummaryJobQueue? {
        didSet {
            viewModel?.summaryJobQueue = summaryJobQueue
        }
    }

    /// Injected by AppDelegate. When set, ⌘↩ uses the agent path.
    var llmOrchestrator: LLMOrchestrator? {
        didSet {
            updateAgentRunFunction()
        }
    }

    /// Injected by AppDelegate for context-aware agent runs.
    var contextStore: ContextStore? {
        didSet {
            updateAgentRunFunction()
        }
    }

    /// Tool registry, injected by AppDelegate or built lazily.
    /// When injected, includes the shared ProcedureExecutor for kill switch + progress UI.
    var agentToolRegistry: AgentToolRegistry? {
        didSet {
            updateAgentRunFunction()
        }
    }

    /// Pattern store for self-learning agent patterns.
    /// Created lazily on first agent run; persists patterns to ~/.shadow/data/patterns/.
    private(set) lazy var patternStore: PatternStore = PatternStore()

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func toggle() {
        if isVisible {
            dismiss()
        } else if hasBackgroundResults {
            // Background agent completed — re-show the panel with results intact
            showWithResults()
            BackgroundTaskManager.shared.exitBackground()
        } else {
            show()
        }
    }

    /// Whether the viewModel holds results from a background agent run.
    ///
    /// Returns true when:
    /// - A background task is actively running (agent streaming in background)
    /// - A background task completed/failed with results not yet viewed
    ///
    /// Does NOT return true for non-background agent results (e.g., simple Q&A
    /// that completed while the panel was visible).
    private var hasBackgroundResults: Bool {
        let bgMgr = BackgroundTaskManager.shared
        // Active background run or unviewed background results
        return bgMgr.isBackgroundTaskActive || bgMgr.hasUnviewedResults
    }

    func show() {
        if panel == nil {
            createPanel()
        }

        guard let panel else { return }

        // Snapshot the current frontmost app BEFORE Shadow activates.
        // This is critical: after NSApp.activate(), the frontmost app is Shadow.
        // The snapshot lets AX tools target the app the user was working in.
        AgentFocusManager.shared.snapshotFrontmostApp()

        // Position panel centered horizontally, ~25% from top
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelWidth: CGFloat = CommandState.panelWidth
            let panelHeight = viewModel?.commandState.panelHeight ?? CommandState.idle.panelHeight
            let x = screenFrame.origin.x + (screenFrame.width - panelWidth) / 2
            let y = screenFrame.origin.y + screenFrame.height - panelHeight - screenFrame.height * 0.2
            panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Clear previous query on show
        viewModel?.clear()

        logger.debug("Search panel shown")
    }

    func dismiss() {
        AudioPlayer.shared.stop()
        viewModel?.cancelCommand()

        // Clear focus target when dismissing without an active background agent run
        if !AgentFocusManager.shared.isAgentRunning {
            AgentFocusManager.shared.clearTarget()
        }

        panel?.orderOut(nil)
        logger.debug("Search panel dismissed")
    }

    /// Cancel the active agent run without dismissing the panel.
    /// Called by the kill switch (Option+Escape) and the background status indicator cancel button.
    /// Cancels both the agent command task and any active procedure execution.
    func cancelAgentRun() {
        viewModel?.cancelCommand()
        logger.debug("Agent run cancelled via kill switch")
    }

    /// Hide the panel without cancelling the agent run.
    /// Used when transitioning to background execution mode.
    /// The agent continues running; the panel can be re-shown later with results.
    func hideForBackground() {
        panel?.orderOut(nil)
        logger.debug("Search panel hidden for background execution")
    }

    /// Re-show the panel after background execution completes, preserving agent results.
    ///
    /// Unlike `show()`, this does NOT clear the viewModel state. The user sees the
    /// agent result (or error) that was produced during background execution.
    /// Called when the user taps the status indicator's "Show results" button,
    /// or presses Option+Space while a background result is available.
    func showWithResults() {
        if panel == nil {
            createPanel()
        }

        guard let panel else { return }

        // Position panel — use the current commandState height so it fits the result
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelWidth: CGFloat = CommandState.panelWidth
            let panelHeight = viewModel?.commandState.panelHeight ?? CommandState.idle.panelHeight
            let x = screenFrame.origin.x + (screenFrame.width - panelWidth) / 2
            let y = screenFrame.origin.y + screenFrame.height - panelHeight - screenFrame.height * 0.2
            panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Do NOT clear viewModel state — we want to show the background results
        logger.debug("Search panel re-shown with results")
    }

    private func createPanel() {
        let vm = SearchViewModel()
        vm.onDismiss = { [weak self] in self?.dismiss() }
        vm.onOpenTimeline = { [weak self] ts, displayID in
            self?.dismiss()
            self?.openTimeline(at: ts, displayID: displayID)
        }
        vm.summaryJobQueue = summaryJobQueue
        vm.onCommandStateChanged = { [weak self] state in
            self?.updatePanelHeight(for: state)
        }
        self.viewModel = vm

        // Wire agent path if orchestrator is already available
        updateAgentRunFunction()

        let overlayView = SearchOverlayView(viewModel: vm)
        let hosting = NSHostingController(rootView: overlayView)

        let p = SearchPanel(contentViewController: hosting)
        p.styleMask = [.borderless, .nonactivatingPanel]
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.animationBehavior = .utilityWindow
        p.minSize = NSSize(width: CommandState.panelWidth, height: CommandState.idle.panelHeight)

        // Dismiss when panel loses key window status (user clicked elsewhere).
        // Suppressed during agent runs so the agent can focus other apps without
        // the panel vanishing and killing the agent run.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: p,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // During agent execution, the agent may focus other apps.
                // Don't dismiss — the agent needs the panel (or status indicator) alive.
                guard !AgentFocusManager.shared.isAgentRunning else {
                    logger.debug("Panel resignKey suppressed — agent is running")
                    return
                }
                self?.dismiss()
            }
        }

        self.panel = p
    }

    // MARK: - Adaptive Panel Height

    /// Animate the panel height when commandState changes.
    /// Keeps the panel's top edge fixed (macOS coordinates: origin is bottom-left).
    private func updatePanelHeight(for state: CommandState) {
        guard let panel else { return }

        let currentFrame = panel.frame
        let newHeight = state.panelHeight

        // Skip if height hasn't changed
        guard abs(newHeight - currentFrame.height) > 1 else { return }

        // Keep top edge fixed: adjust Y origin
        let heightDelta = newHeight - currentFrame.height
        var newY = currentFrame.origin.y - heightDelta

        // Clamp to screen bounds
        if let screen = panel.screen ?? NSScreen.main {
            newY = max(newY, screen.visibleFrame.origin.y)
        }

        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: newY,
            width: currentFrame.width,
            height: newHeight
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    // MARK: - Timeline Deep-Link

    func openTimeline(at timestamp: UInt64, displayID: UInt32?) {
        // Always store pending jump — consumed by TimelineViewModel on window open,
        // or cleared by the notification handler if the window is already observing.
        TimelineViewModel.pendingJump = (timestamp: timestamp, displayID: displayID)

        var userInfo: [String: Any] = ["timestamp": timestamp]
        if let displayID { userInfo["displayID"] = displayID }

        if let window = NSApp.windows.first(where: { $0.title == "Shadow Timeline" }) {
            // Window exists (visible or hidden) — bring it front and post notification
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            NotificationCenter.default.post(
                name: .shadowJumpToTimestamp,
                object: nil,
                userInfo: userInfo
            )
        } else {
            // No timeline window at all — create via bridged OpenWindowAction.
            // pendingJump handles observer-not-ready; delayed notification
            // handles observer-ready-by-next-tick.
            if let action = (NSApp.delegate as? AppDelegate)?.openTimelineAction {
                action(id: "timeline")
            } else {
                logger.warning("openTimelineAction not bridged — cannot open timeline window")
            }
            NSApp.activate(ignoringOtherApps: true)

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .shadowJumpToTimestamp,
                    object: nil,
                    userInfo: userInfo
                )
            }
        }
    }

    // MARK: - Agent Wiring

    /// Build the agent run closure from the orchestrator + registry and inject into the view model.
    /// Called on `llmOrchestrator` didSet and during `createPanel()` (if orchestrator arrived first).
    ///
    /// Routes through AgentOrchestrator which classifies intent and either:
    /// - Fast-paths simple questions directly to AgentRuntime (same behavior as before)
    /// - Decomposes complex requests into parallel sub-tasks for multi-agent orchestration
    ///
    /// The OrchestratorEvent stream is adapted to AgentRunEvent so the existing UI works unchanged.
    private func updateAgentRunFunction() {
        guard let orchestrator = llmOrchestrator else {
            viewModel?.agentRunFunction = nil
            return
        }

        if agentToolRegistry == nil {
            agentToolRegistry = AgentTools.buildDefaultRegistry()
        }
        guard let registry = agentToolRegistry else { return }

        let ctxStore = contextStore
        let patterns = patternStore
        viewModel?.agentRunFunction = { @Sendable request in
            Self.adaptOrchestratorStream(
                query: request.task,
                config: request.config,
                orchestrator: orchestrator,
                registry: registry,
                contextStore: ctxStore,
                patternStore: patterns
            )
        }

        logger.debug("Agent run function wired via AgentOrchestrator")
    }

    /// Adapt the AgentOrchestrator event stream to the AgentRunEvent stream expected by SearchViewModel.
    ///
    /// Routes through two paths based on intent classification:
    /// - **Mimicry path** (uiAction + cloud available): Classify intent, then run MimicryCoordinator
    ///   (plan-then-execute). Progress events are mapped to AgentRunEvents for the existing UI.
    /// - **Agent path** (all other intents): Forward through AgentOrchestrator as before.
    ///
    /// On the fast path (simple questions), orchestrator events wrap AgentRunEvents directly via
    /// `.agentEvent()` — these are forwarded as-is. On the orchestrated path (complex intents),
    /// the orchestration result is synthesized into a `.finalAnswer` event.
    private nonisolated static func adaptOrchestratorStream(
        query: String,
        config: AgentRunConfig,
        orchestrator: LLMOrchestrator,
        registry: AgentToolRegistry,
        contextStore: ContextStore?,
        patternStore: PatternStore?
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            let task = Task {
                // Step 1: Classify intent first (fast Haiku call or heuristic)
                let classification = await IntentClassifier.classify(
                    query: query,
                    orchestrator: orchestrator
                )

                // Forward classification to UI
                continuation.yield(.intentClassified(
                    intent: classification.intent.rawValue,
                    confidence: classification.confidence,
                    method: classification.method.rawValue
                ))

                // Step 2: Route based on intent
                if classification.intent == .uiAction || classification.intent == .procedureReplay {
                    // Check if cloud LLM is available for Mimicry planning
                    let cloudAvailable = await orchestrator.canGenerateNow

                    if cloudAvailable {
                        // Mimicry path: plan-then-execute
                        await executeMimicryPath(
                            query: query,
                            orchestrator: orchestrator,
                            continuation: continuation
                        )
                        continuation.finish()
                        return
                    }
                }

                // Standard agent path: run through AgentOrchestrator
                await executeAgentPath(
                    query: query,
                    config: config,
                    orchestrator: orchestrator,
                    registry: registry,
                    contextStore: contextStore,
                    patternStore: patternStore,
                    continuation: continuation
                )

                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Mimicry Execution Path (V2 — Vision-First Agent Loop)

    /// Execute a task through the Mimicry V2 vision-first agent loop (VisionAgent).
    ///
    /// Replaces the old plan-then-execute pipeline (CloudPlanner + LocalExecutor) with a
    /// reactive see-think-act-verify loop:
    /// 1. Take live screenshot
    /// 2. Send to Haiku for single next-action decision
    /// 3. Execute action (with VLM grounding for clicks)
    /// 4. Verify with OCR
    /// 5. Loop until done or max iterations
    ///
    /// Handles overlay-dismiss lifecycle:
    /// 1. Immediately enter background mode (no planning phase to show)
    /// 2. Focus the target app so screenshots capture the right app
    /// 3. Execute vision loop, showing floating status indicator
    /// 4. On completion, update status indicator
    private nonisolated static func executeMimicryPath(
        query: String,
        orchestrator: LLMOrchestrator,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async {
        let startTime = CFAbsoluteTimeGetCurrent()
        let mimicryLogger = Logger(subsystem: "com.shadow.app", category: "MimicryV2")

        continuation.yield(.runStarted(task: query))

        // Build the VisionAgent with ShowUI-2B grounding model
        let groundingModel: LocalGroundingModel? = {
            let spec = LocalModelRegistry.groundingDefault
            guard LocalModelRegistry.isDownloaded(spec) else { return nil }
            let lifecycle = LocalModelLifecycle()
            return LocalGroundingModel(lifecycle: lifecycle, spec: spec)
        }()

        let vlmStatus = groundingModel != nil ? "ShowUI-2B available" : "nil (model not downloaded, using AX fallback)"
        mimicryLogger.notice("[MIMICRY-V2] Starting vision agent for: '\(query, privacy: .public)' | VLM: \(vlmStatus, privacy: .public)")

        // Auto-detect the fast model based on which cloud provider has an API key.
        // Anthropic → claude-haiku-4-5-20251001 (fast, vision-capable)
        // OpenAI → gpt-4.1-nano (fast, vision-capable)
        // Both providers check synchronously via resolveAPIKey() — no actor hop needed.
        let fastModelId: String? = {
            let anthropic = CloudLLMProvider()
            if anthropic.isAvailable {
                return "claude-haiku-4-5-20251001"
            }
            let openai = OpenAILLMProvider()
            if openai.isAvailable {
                return "gpt-4.1-nano"
            }
            return nil
        }()

        mimicryLogger.notice("[MIMICRY-V2] Fast model: \(fastModelId ?? "none", privacy: .public)")

        let visionAgent = VisionAgent(
            orchestrator: orchestrator,
            groundingModel: groundingModel,
            fastModelId: fastModelId
        )

        // Enter background mode immediately — vision loop needs the target app visible
        await MainActor.run {
            AgentFocusManager.shared.agentRunStarted()
            BackgroundTaskManager.shared.enterBackground(task: query)

            // Focus the target app
            if let target = AgentFocusManager.shared.targetApp {
                if let app = NSRunningApplication(processIdentifier: target.pid),
                   !app.isTerminated {
                    app.activate()
                }
            }
        }

        // Brief delay for the target app to become frontmost
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Emit initial progress
        continuation.yield(.toolCallStarted(name: "mimicry_v2_vision_loop", step: 0))

        // Execute the vision agent loop
        let result = await visionAgent.execute(task: query) { progress in
            // Map VisionAgentProgress to streaming events
            continuation.yield(.llmDelta(text: progress.message + "\n"))

            // Update background status indicator
            await MainActor.run {
                let bgMgr = BackgroundTaskManager.shared
                if bgMgr.isBackgroundTaskActive {
                    bgMgr.updateProgress(
                        currentTool: progress.message,
                        step: progress.iteration,
                        totalSteps: progress.maxIterations
                    )
                }
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        // Complete the vision loop tool call
        continuation.yield(.toolCallCompleted(
            name: "mimicry_v2_vision_loop",
            durationMs: elapsed,
            outputPreview: "\(result.steps.count) actions, \(result.status.rawValue)"
        ))

        // Clean up background mode
        await MainActor.run {
            let bgMgr = BackgroundTaskManager.shared
            switch result.status {
            case .succeeded:
                bgMgr.complete(summary: result.summary)
            case .failed, .timeout, .maxIterations:
                bgMgr.fail(error: result.summary)
            case .cancelled:
                bgMgr.exitBackground()
            }
            AgentFocusManager.shared.agentRunEnded()
        }

        // Build the terminal event
        let answer = buildVisionAgentAnswer(result)
        let metrics = AgentRunMetrics(
            totalMs: elapsed,
            stepCount: result.steps.count,
            toolCallCount: result.steps.count,
            inputTokensTotal: 0,
            outputTokensTotal: 0,
            provider: "mimicry_v2",
            modelId: "\(result.steps.isEmpty ? "unknown" : "vision-agent")+showui-2b"
        )

        switch result.status {
        case .succeeded:
            let agentResult = AgentRunResult(
                answer: answer,
                evidence: [],
                toolCalls: [],
                metrics: metrics
            )
            continuation.yield(.finalAnswer(agentResult))

        case .failed:
            let agentResult = AgentRunResult(
                answer: answer,
                evidence: [],
                toolCalls: [],
                metrics: metrics
            )
            continuation.yield(.finalAnswer(agentResult))

        case .timeout, .maxIterations:
            let agentResult = AgentRunResult(
                answer: answer,
                evidence: [],
                toolCalls: [],
                metrics: metrics
            )
            continuation.yield(.finalAnswer(agentResult))

        case .cancelled:
            continuation.yield(.runCancelled)
        }
    }

    /// Build a human-readable answer from a VisionAgentResult.
    private nonisolated static func buildVisionAgentAnswer(_ result: VisionAgentResult) -> String {
        var lines: [String] = []

        switch result.status {
        case .succeeded:
            lines.append("Task completed: \(result.task)")
            lines.append(result.summary)
        case .failed:
            lines.append("Task failed: \(result.task)")
            lines.append(result.summary)
        case .timeout:
            lines.append("Task timed out: \(result.task)")
            lines.append(result.summary)
        case .maxIterations:
            lines.append("Task exceeded max iterations: \(result.task)")
            lines.append(result.summary)
        case .cancelled:
            lines.append("Task cancelled: \(result.task)")
        }

        // Add step details
        for step in result.steps {
            let statusIcon: String
            if step.verification.contains("failed") || step.verification.contains("error") {
                statusIcon = "[FAIL]"
            } else {
                statusIcon = "[OK]"
            }
            let grounding = step.groundingStrategy.map { " (\($0.rawValue))" } ?? ""
            lines.append("  \(statusIcon) \(step.action)\(grounding)")
        }

        lines.append("\nCompleted in \(String(format: "%.1f", result.durationMs / 1000))s")

        return lines.joined(separator: "\n")
    }

    // MARK: - Standard Agent Execution Path

    /// Run through the standard AgentOrchestrator pipeline.
    /// This is the original path that handles all non-Mimicry intents.
    private nonisolated static func executeAgentPath(
        query: String,
        config: AgentRunConfig,
        orchestrator: LLMOrchestrator,
        registry: AgentToolRegistry,
        contextStore: ContextStore?,
        patternStore: PatternStore?,
        continuation: AsyncStream<AgentRunEvent>.Continuation
    ) async {
        let orchStream = AgentOrchestrator.run(
            query: query,
            orchestrator: orchestrator,
            registry: registry,
            contextStore: contextStore,
            patternStore: patternStore,
            config: config
        )

        var receivedFinalAnswer = false

        for await event in orchStream {
            switch event {
            case .agentEvent(let agentEvent):
                // Fast-path: forward AgentRunEvents directly
                continuation.yield(agentEvent)
                if case .finalAnswer = agentEvent { receivedFinalAnswer = true }
                if case .runFailed = agentEvent { receivedFinalAnswer = true }
                if case .runCancelled = agentEvent { receivedFinalAnswer = true }

            case .orchestrationComplete(let result):
                // Orchestrated path completed — synthesize into a final answer
                if !receivedFinalAnswer {
                    let metrics = result.metrics ?? AgentRunMetrics(
                        totalMs: result.totalMs,
                        stepCount: result.subTaskResults.count,
                        toolCallCount: 0,
                        inputTokensTotal: 0,
                        outputTokensTotal: 0,
                        provider: "orchestrator",
                        modelId: "multi-agent"
                    )
                    let agentResult = AgentRunResult(
                        answer: result.answer,
                        evidence: [],
                        toolCalls: [],
                        metrics: metrics
                    )
                    continuation.yield(.finalAnswer(agentResult))
                    receivedFinalAnswer = true
                }

            case .orchestrationFailed(let message):
                if !receivedFinalAnswer {
                    continuation.yield(.runFailed(.internalError(message)))
                    receivedFinalAnswer = true
                }

            case .intentClassified:
                // Already forwarded before routing decision — skip duplicate
                break

            case .taskDecomposed, .phaseStarted,
                 .subTaskStarted, .subTaskCompleted:
                // Decomposition events — not used since all intents use fast path
                break
            }
        }

        // If stream ended without a terminal event, emit an error
        if !receivedFinalAnswer {
            continuation.yield(.runFailed(.internalError("Orchestration ended without result")))
        }
    }

    // No deinit needed — SearchPanelController lives for the app's lifetime
    // (stored in AppDelegate). The NotificationCenter observer is retained
    // via resignObserver and cleaned up automatically.
}

// MARK: - Mimicry Background Tracker

/// Sendable-safe flag for tracking whether the Mimicry path has entered background mode.
///
/// Used inside the `@Sendable` progress callback to avoid capturing a mutable local variable
/// (which Swift 6 strict concurrency forbids). The actor provides thread-safe mutation.
private actor MimicryBackgroundTracker {
    private(set) var isActive: Bool = false

    func markActive() {
        isActive = true
    }
}

extension Notification.Name {
    static let shadowJumpToTimestamp = Notification.Name("shadowJumpToTimestamp")
}

// MARK: - Array Safe Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}
