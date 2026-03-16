import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "MimicryCoordinator")

/// Coordinates the two-tier Mimicry architecture: CloudPlanner + LocalExecutor.
///
/// The coordinator is the entry point for task execution. It:
/// 1. Gathers context (behavioral history, procedures, AX tree state)
/// 2. Sends the task to the CloudPlanner to generate a plan
/// 3. Hands the plan to the LocalExecutor for step-by-step execution
/// 4. Handles escalations by routing them back to the planner
/// 5. Records execution results for learning and diagnostics
///
/// For routine tasks, the planner is called ONCE and the executor handles
/// everything locally. Cloud cost drops by 80-90% compared to the traditional
/// agent loop that sends full context on every tool call.
///
/// Mimicry Phase C: Planner-Executor Coordination.
actor MimicryCoordinator {

    /// The cloud planner for generating plans.
    private let planner: CloudPlanner

    /// The local executor for step-by-step execution.
    private let executor: LocalExecutor

    /// Number of tasks completed this session.
    private(set) var tasksCompleted: Int = 0

    /// Number of tasks failed this session.
    private(set) var tasksFailed: Int = 0

    /// Delegate for execution events (progress updates, completion).
    var onProgress: (@Sendable (MimicryProgress) async -> Void)?

    // MARK: - Init

    init(
        planner: CloudPlanner,
        executor: LocalExecutor
    ) {
        self.planner = planner
        self.executor = executor
    }

    /// Set the progress handler.
    func setProgress(_ handler: (@Sendable (MimicryProgress) async -> Void)?) {
        self.onProgress = handler
    }

    // MARK: - Task Execution

    /// Execute a task end-to-end: plan -> execute -> report.
    ///
    /// This is the main entry point for the Mimicry system.
    ///
    /// - Parameters:
    ///   - task: Natural language task description (e.g., "Send an email to John").
    ///   - context: Pre-gathered context for planning. If nil, context is gathered automatically.
    /// - Returns: A `MimicryResult` with the execution outcome.
    func executeTask(
        _ task: String,
        context: MimicryContext? = nil
    ) async -> MimicryResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        DiagnosticsStore.shared.increment("mimicry_task_total")

        if let progressHandler = onProgress {
            await progressHandler(MimicryProgress(
                phase: .planning,
                message: "Generating plan...",
                stepIndex: nil,
                totalSteps: nil
            ))
        }

        // 1. Gather context if not provided
        let resolvedContext: MimicryContext
        if let context {
            resolvedContext = context
        } else {
            resolvedContext = await gatherContext(for: task)
        }

        // 2. Generate plan via cloud planner
        logger.notice("[MIMICRY] Coordinator: generating plan for '\(task, privacy: .public)' with context: behavioral=\(resolvedContext.behavioralContext.count) chars, procedures=\(resolvedContext.procedures.count) chars, axTree=\(resolvedContext.axTreeSummary.count) chars, targetApp=\(resolvedContext.targetApp ?? "nil", privacy: .public)")
        let plan: TaskPlan
        do {
            plan = try await planner.generatePlan(
                task: task,
                behavioralContext: resolvedContext.behavioralContext,
                procedures: resolvedContext.procedures,
                axTreeSummary: resolvedContext.axTreeSummary,
                targetApp: resolvedContext.targetApp
            )
        } catch {
            tasksFailed += 1
            DiagnosticsStore.shared.increment("mimicry_plan_fail_total")
            logger.error("Task failed at planning: \(error, privacy: .public)")
            return MimicryResult(
                task: task,
                status: .planningFailed,
                plan: nil,
                executionState: nil,
                error: error.localizedDescription,
                durationMs: elapsedMs(since: startTime)
            )
        }

        if let progressHandler = onProgress {
            await progressHandler(MimicryProgress(
                phase: .executing,
                message: "Executing plan (\(plan.stepCount) steps)...",
                stepIndex: 0,
                totalSteps: plan.stepCount
            ))
        }

        // Capture the progress handler for use in closures
        let progressHandler = onProgress

        // 3. Execute plan locally
        let executionState = await executor.execute(
            plan: plan,
            onStepStart: { step in
                if let handler = progressHandler {
                    await handler(MimicryProgress(
                        phase: .executing,
                        message: step.description,
                        stepIndex: step.index,
                        totalSteps: plan.stepCount
                    ))
                }
            },
            onStepComplete: { result in
                if let handler = progressHandler {
                    await handler(MimicryProgress(
                        phase: .executing,
                        message: "Step \(result.stepIndex + 1) \(result.status.rawValue)",
                        stepIndex: result.stepIndex,
                        totalSteps: plan.stepCount
                    ))
                }
            },
            onEscalation: { [planner] request in
                if let handler = progressHandler {
                    await handler(MimicryProgress(
                        phase: .escalating,
                        message: "Escalating step \(request.failedStepIndex + 1) to planner...",
                        stepIndex: request.failedStepIndex,
                        totalSteps: plan.stepCount
                    ))
                }
                return try? await planner.handleEscalation(request)
            }
        )

        // 4. Record result
        let elapsed = elapsedMs(since: startTime)
        let status: MimicryTaskStatus = executionState.status == .succeeded ? .succeeded : .executionFailed

        if status == .succeeded {
            tasksCompleted += 1
            DiagnosticsStore.shared.increment("mimicry_task_success_total")
        } else {
            tasksFailed += 1
            DiagnosticsStore.shared.increment("mimicry_task_fail_total")
        }

        DiagnosticsStore.shared.recordLatency("mimicry_task_duration_ms", ms: elapsed)

        if let progressHandler = onProgress {
            await progressHandler(MimicryProgress(
                phase: status == .succeeded ? .completed : .failed,
                message: status == .succeeded
                    ? "Task completed (\(executionState.completedSteps)/\(plan.stepCount) steps)"
                    : "Task failed (\(executionState.completedSteps)/\(plan.stepCount) steps succeeded)",
                stepIndex: plan.stepCount,
                totalSteps: plan.stepCount
            ))
        }

        logger.notice("[MIMICRY] Coordinator DONE: '\(task, privacy: .public)' \(status.rawValue, privacy: .public): \(executionState.completedSteps)/\(plan.stepCount) steps in \(String(format: "%.0f", elapsed))ms")

        return MimicryResult(
            task: task,
            status: status,
            plan: plan,
            executionState: executionState,
            error: nil,
            durationMs: elapsed
        )
    }

    // MARK: - Context Gathering

    /// Gather context for planning from Shadow's data stores.
    private func gatherContext(for task: String) async -> MimicryContext {
        // Behavioral context from Rust index
        var behavioralContext = ""
        do {
            let sequences = try searchBehavioralContext(
                query: task,
                targetApp: "",
                maxResults: 5
            )
            if !sequences.isEmpty {
                behavioralContext = sequences.map { seq in
                    "App: \(seq.appName) | \(seq.actions.count) actions"
                }.joined(separator: "\n")
            }
        } catch {
            logger.debug("Behavioral context unavailable: \(error, privacy: .public)")
        }

        // Learned procedures
        let procedureStore = ProcedureStore()
        let allProcedures = await procedureStore.search(query: task)
        let procedures = Array(allProcedures.prefix(3))
        let procedureText = procedures.map { proc in
            "Procedure: \(proc.name) (\(proc.steps.count) steps, app: \(proc.sourceBundleId))"
        }.joined(separator: "\n")

        // Current AX tree state
        var axSummary = ""
        await MainActor.run {
            if let info = AgentFocusManager.shared.targetAppInfo() {
                let elements = collectInteractiveElements(
                    in: info.element,
                    maxDepth: 10,
                    maxCount: 50,
                    timeout: 2.0
                )
                axSummary = "App: \(info.name)\n" + elements.prefix(30).map { el -> String in
                    let role = el.role() ?? "?"
                    let title = el.title() ?? ""
                    return "  \(role): \(title)"
                }.joined(separator: "\n")
            }
        }

        return MimicryContext(
            behavioralContext: behavioralContext,
            procedures: procedureText,
            axTreeSummary: axSummary,
            targetApp: nil
        )
    }

    // MARK: - Helpers

    private func elapsedMs(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
}

// MARK: - Supporting Types

/// Context gathered for the planner.
struct MimicryContext: Sendable {
    let behavioralContext: String
    let procedures: String
    let axTreeSummary: String
    let targetApp: String?
}

/// Result of a complete Mimicry task execution.
struct MimicryResult: Sendable {
    let task: String
    let status: MimicryTaskStatus
    let plan: TaskPlan?
    let executionState: PlanExecutionState?
    let error: String?
    let durationMs: Double
}

/// Overall task status.
enum MimicryTaskStatus: String, Sendable {
    case succeeded
    case planningFailed
    case executionFailed
    case cancelled
}

/// Progress update from the Mimicry coordinator.
struct MimicryProgress: Sendable {
    let phase: MimicryPhase
    let message: String
    let stepIndex: Int?
    let totalSteps: Int?
}

/// Execution phases.
enum MimicryPhase: String, Sendable {
    case planning
    case executing
    case escalating
    case completed
    case failed
}
