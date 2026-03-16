import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "WorkflowExtractor")

/// Extracts recurring workflow patterns from Shadow's passive recording data
/// and converts them into AX-anchored procedures.
///
/// This bridges the Rust workflow_extractor (which scans enriched events for
/// recurring patterns) with the Swift ProcedureStore (which stores and replays
/// procedures).
///
/// Mimicry Phase A4: Automatic Procedure Extraction from Passive Data.
enum WorkflowExtractor {

    /// Extract all recurring workflows from recent data and save as procedures.
    ///
    /// Scans the last `lookbackHours` of enriched events, finds recurring
    /// action sequences, and saves them as AX-anchored procedures in the
    /// ProcedureStore. Existing workflows with the same fingerprint are
    /// updated rather than duplicated.
    ///
    /// - Parameters:
    ///   - lookbackHours: How far back to scan (default: 168 = 1 week)
    ///   - maxResults: Maximum workflows to extract (default: 20)
    ///   - store: The procedure store to save into
    /// - Returns: Number of workflows extracted and saved
    @discardableResult
    static func extractAndSave(
        lookbackHours: UInt32 = 168,
        maxResults: UInt32 = 20,
        store: ProcedureStore
    ) async -> Int {
        do {
            let workflows = try extractWorkflows(
                lookbackHours: lookbackHours,
                maxResults: maxResults
            )

            guard !workflows.isEmpty else {
                logger.debug("No recurring workflows found in the last \(lookbackHours) hours")
                return 0
            }

            var savedCount = 0
            for workflow in workflows {
                let template = convertToProcedureTemplate(workflow)
                do {
                    try await store.save(template)
                    savedCount += 1
                    logger.info("Saved extracted workflow: '\(workflow.name)' (\(workflow.occurrenceCount) occurrences, \(String(format: "%.0f", workflow.confidence * 100))% confidence)")
                } catch {
                    logger.warning("Failed to save workflow '\(workflow.name)': \(error, privacy: .public)")
                }
            }

            DiagnosticsStore.shared.increment("workflows_extracted_total", by: Int64(savedCount))
            logger.info("Workflow extraction complete: \(savedCount)/\(workflows.count) saved")
            return savedCount
        } catch {
            logger.error("Workflow extraction failed: \(error, privacy: .public)")
            return 0
        }
    }

    /// Extract workflows for a specific app.
    @discardableResult
    static func extractAndSaveForApp(
        appName: String,
        lookbackHours: UInt32 = 168,
        maxResults: UInt32 = 10,
        store: ProcedureStore
    ) async -> Int {
        do {
            let workflows = try extractWorkflowsForApp(
                appName: appName,
                lookbackHours: lookbackHours,
                maxResults: maxResults
            )

            guard !workflows.isEmpty else { return 0 }

            var savedCount = 0
            for workflow in workflows {
                let template = convertToProcedureTemplate(workflow)
                do {
                    try await store.save(template)
                    savedCount += 1
                } catch {
                    logger.warning("Failed to save app workflow: \(error, privacy: .public)")
                }
            }

            return savedCount
        } catch {
            logger.error("App workflow extraction failed: \(error, privacy: .public)")
            return 0
        }
    }

    /// Raw extraction without saving. Returns the workflows from Rust.
    static func extract(
        lookbackHours: UInt32 = 168,
        maxResults: UInt32 = 20
    ) -> [ExtractedWorkflow] {
        do {
            return try extractWorkflows(
                lookbackHours: lookbackHours,
                maxResults: maxResults
            )
        } catch {
            logger.warning("Workflow extraction failed: \(error, privacy: .public)")
            return []
        }
    }

    // MARK: - Conversion

    /// Convert a Rust ExtractedWorkflow into a Swift ProcedureTemplate.
    ///
    /// Maps AX-anchored steps to ProcedureSteps with ElementLocators,
    /// preserving the AX element identity (role + title + identifier) as
    /// the primary resolution strategy.
    static func convertToProcedureTemplate(_ workflow: ExtractedWorkflow) -> ProcedureTemplate {
        let now = CaptureSessionClock.wallMicros()

        let steps: [ProcedureStep] = workflow.steps.map { axStep in
            // Build an ElementLocator from the AX-anchored step
            let locator: ElementLocator? = if let role = axStep.targetRole {
                ElementLocator(
                    role: role,
                    title: axStep.targetTitle,
                    identifier: axStep.targetIdentifier,
                    domId: nil,
                    domClass: nil,
                    value: nil,
                    pathHints: [],
                    positionFallback: fallbackPoint(x: axStep.fallbackX, y: axStep.fallbackY)
                )
            } else {
                nil
            }

            // Convert action type string to RecordedAction.ActionType
            let actionType = convertActionType(axStep)

            // Build description for the step
            let desc: String? = if let role = axStep.targetRole, let title = axStep.targetTitle {
                "\(role) \"\(title)\""
            } else if let role = axStep.targetRole {
                role
            } else {
                nil
            }

            return ProcedureStep(
                index: Int(axStep.index),
                intent: axStep.intent,
                actionType: actionType,
                targetLocator: locator,
                targetDescription: desc,
                parameterSubstitutions: [:],
                expectedPostCondition: nil,
                maxRetries: 2,
                timeoutSeconds: 5.0
            )
        }

        return ProcedureTemplate(
            id: workflow.id,
            name: workflow.name,
            description: "Automatically extracted from \(workflow.occurrenceCount) observations. Confidence: \(String(format: "%.0f", workflow.confidence * 100))%.",
            parameters: [],  // Parameters are extracted via LLM later if needed
            steps: steps,
            createdAt: workflow.firstSeenTs,
            updatedAt: now,
            sourceApp: workflow.appName,
            sourceBundleId: workflow.bundleId,
            tags: ["auto-extracted", "mimicry", workflow.appName.lowercased()],
            executionCount: 0,
            lastExecutedAt: nil
        )
    }

    // MARK: - Helpers

    /// Convert an AxAnchoredStep's action type string to RecordedAction.ActionType.
    private static func convertActionType(_ step: AxAnchoredStep) -> RecordedAction.ActionType {
        switch step.actionType {
        case "mouse_down":
            return .click(
                x: step.fallbackX ?? 0,
                y: step.fallbackY ?? 0,
                button: "left",
                count: 1
            )
        case "key_down":
            if let keyName = step.keyName {
                return .keyPress(
                    keyCode: 0,
                    keyName: keyName,
                    modifiers: step.modifiers
                )
            }
            if let text = step.text {
                return .typeText(text: text)
            }
            return .keyPress(keyCode: 0, keyName: "unknown", modifiers: [])
        case "scroll":
            return .scroll(
                deltaX: 0,
                deltaY: -3,  // Default scroll down
                x: step.fallbackX ?? 0,
                y: step.fallbackY ?? 0
            )
        default:
            return .click(
                x: step.fallbackX ?? 0,
                y: step.fallbackY ?? 0,
                button: "left",
                count: 1
            )
        }
    }

    /// Build a CGPoint from optional coordinates.
    private static func fallbackPoint(x: Double?, y: Double?) -> CGPoint? {
        guard let x, let y else { return nil }
        return CGPoint(x: x, y: y)
    }

    // MARK: - Formatting for Agent Prompt

    /// Format extracted workflows for injection into the agent system prompt.
    ///
    /// This gives the agent awareness of workflows that the user performs
    /// regularly, complementing the behavioral search context.
    static func formatForPrompt(_ workflows: [ExtractedWorkflow], limit: Int = 3) -> String {
        let capped = Array(workflows.prefix(limit))
        guard !capped.isEmpty else { return "" }

        var lines: [String] = [
            "# Learned Workflows (automatically extracted from your behavior)",
            "",
            "These workflows were observed recurring in your usage patterns.",
            "Use them as reliable guides for executing similar tasks.",
            ""
        ]

        for (i, wf) in capped.enumerated() {
            lines.append("WORKFLOW \(i + 1): \"\(wf.name)\" [seen \(wf.occurrenceCount)x, confidence: \(String(format: "%.0f", wf.confidence * 100))%]")
            lines.append("App: \(wf.appName) | Window: \(wf.windowTitlePattern)")

            for step in wf.steps {
                var desc = "  \(step.index + 1). [\(step.actionType)]"
                if let role = step.targetRole {
                    desc += " \(role)"
                }
                if let title = step.targetTitle {
                    desc += " \"\(title)\""
                }
                lines.append(desc)
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
