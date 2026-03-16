import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "AgentOrchestrator")

/// Central coordinator for the multi-agent system.
///
/// Receives user requests, classifies intent, decomposes into sub-tasks,
/// routes to specialized agents, and manages the conversation context.
///
/// Uses stateless enum pattern — all orchestration state is local to `run()`.
enum AgentOrchestrator {

    // MARK: - Orchestration Events

    /// Events emitted during orchestrated agent runs.
    /// Extends the base AgentRunEvent with orchestration-specific events.
    enum OrchestratorEvent: Sendable {
        /// Intent classification completed.
        case intentClassified(intent: IntentClassifier.UserIntent, confidence: Double, method: String)
        /// Task decomposition completed.
        case taskDecomposed(subTaskCount: Int, intent: IntentClassifier.UserIntent)
        /// A sub-task phase started (may contain parallel tasks).
        case phaseStarted(phaseIndex: Int, taskCount: Int)
        /// A sub-task started execution.
        case subTaskStarted(taskId: String, role: TaskDecomposer.AgentRole, instruction: String)
        /// A sub-task completed.
        case subTaskCompleted(taskId: String, role: TaskDecomposer.AgentRole, durationMs: Double, success: Bool)
        /// Forwarded event from the underlying agent runtime.
        case agentEvent(AgentRunEvent)
        /// Orchestration completed with final result.
        case orchestrationComplete(OrchestratorResult)
        /// Orchestration failed.
        case orchestrationFailed(String)
    }

    /// Final result of an orchestrated run.
    struct OrchestratorResult: Sendable {
        /// The final answer text.
        let answer: String
        /// Sub-task results from each phase.
        let subTaskResults: [SubTaskResult]
        /// Classified intent.
        let intent: IntentClassifier.UserIntent
        /// Total orchestration time in milliseconds.
        let totalMs: Double
        /// Performance metrics from the final agent run.
        let metrics: AgentRunMetrics?
    }

    // MARK: - Orchestrated Run

    /// Run the full orchestration pipeline: classify -> decompose -> route -> synthesize.
    ///
    /// For simple intents, this delegates directly to the standard AgentRuntime
    /// with minimal overhead. For complex intents, it executes sub-tasks in phases,
    /// injecting results from earlier phases as context for later ones.
    ///
    /// - Parameters:
    ///   - query: The user's natural language request.
    ///   - orchestrator: LLM orchestrator for model routing.
    ///   - registry: Tool registry for agent execution.
    ///   - contextStore: Optional context store for memory injection.
    ///   - config: Run configuration (budgets, timeouts).
    ///   - classifyFn: Injectable classifier for testing.
    ///   - subTaskRunner: Injectable sub-task runner for testing.
    /// - Returns: AsyncStream of OrchestratorEvents.
    static func run(
        query: String,
        orchestrator: LLMOrchestrator,
        registry: AgentToolRegistry,
        contextStore: ContextStore? = nil,
        patternStore: PatternStore? = nil,
        config: AgentRunConfig = AgentRunConfig(),
        classifyFn: (@Sendable (String) async throws -> String)? = nil,
        subTaskRunner: SubTaskRunnerFn? = nil
    ) -> AsyncStream<OrchestratorEvent> {
        AsyncStream { continuation in
            let task = Task {
                await executeOrchestration(
                    query: query,
                    orchestrator: orchestrator,
                    registry: registry,
                    contextStore: contextStore,
                    patternStore: patternStore,
                    config: config,
                    classifyFn: classifyFn,
                    subTaskRunner: subTaskRunner,
                    continuation: continuation
                )
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Injectable function type for running sub-tasks.
    typealias SubTaskRunnerFn = @Sendable (
        _ subTask: TaskDecomposer.SubTask,
        _ context: ContextBudgetManager.AgentContext,
        _ query: String
    ) async -> SubTaskResult

    // MARK: - Orchestration Loop

    private static func executeOrchestration(
        query: String,
        orchestrator: LLMOrchestrator,
        registry: AgentToolRegistry,
        contextStore: ContextStore?,
        patternStore: PatternStore?,
        config: AgentRunConfig,
        classifyFn: (@Sendable (String) async throws -> String)?,
        subTaskRunner: SubTaskRunnerFn?,
        continuation: AsyncStream<OrchestratorEvent>.Continuation
    ) async {
        let startTime = CFAbsoluteTimeGetCurrent()
        DiagnosticsStore.shared.increment("orchestrator_run_total")

        // Phase 1: Intent Classification
        let classification = await IntentClassifier.classify(
            query: query,
            orchestrator: orchestrator,
            classifyFn: classifyFn
        )

        continuation.yield(.intentClassified(
            intent: classification.intent,
            confidence: classification.confidence,
            method: classification.method.rawValue
        ))

        // Check cancellation
        if Task.isCancelled {
            continuation.yield(.orchestrationFailed("Cancelled"))
            return
        }

        // Fast path: for simple questions and ambiguous intents, skip decomposition
        // and run directly via the standard agent runtime.
        if shouldUseFastPath(classification) {
            logger.info("Using fast path for intent: \(classification.intent.rawValue)")
            DiagnosticsStore.shared.increment("orchestrator_fast_path_total")

            await runFastPath(
                query: query,
                orchestrator: orchestrator,
                registry: registry,
                contextStore: contextStore,
                patternStore: patternStore,
                config: config,
                intent: classification.intent,
                startTime: startTime,
                continuation: continuation
            )
            return
        }

        // Phase 2: Task Decomposition
        let decomposition = await TaskDecomposer.decompose(
            query: query,
            intent: classification.intent
        )

        continuation.yield(.taskDecomposed(
            subTaskCount: decomposition.subTasks.count,
            intent: classification.intent
        ))

        // Phase 3: Execute sub-tasks in phases
        let phases = TaskDecomposer.groupIntoPhases(decomposition.subTasks)
        var allResults: [SubTaskResult] = []

        // Build memory pack once
        let memoryPack: String
        if let ctxStore = contextStore {
            let pack = ContextPacker.pack(contextStore: ctxStore)
            memoryPack = pack.packText
        } else {
            memoryPack = ""
        }

        for (phaseIndex, phase) in phases.enumerated() {
            if Task.isCancelled {
                continuation.yield(.orchestrationFailed("Cancelled during phase \(phaseIndex)"))
                return
            }

            continuation.yield(.phaseStarted(phaseIndex: phaseIndex, taskCount: phase.count))

            let phaseResults: [SubTaskResult]
            if phase.count == 1 || !phase.allSatisfy(\.parallelizable) {
                // Sequential execution
                var sequentialResults: [SubTaskResult] = []
                for subTask in phase {
                    let context = ContextBudgetManager.buildContext(
                        role: subTask.agent,
                        query: query,
                        priorResults: allResults,
                        memoryPack: memoryPack
                    )

                    continuation.yield(.subTaskStarted(
                        taskId: subTask.id,
                        role: subTask.agent,
                        instruction: subTask.instruction
                    ))

                    let result: SubTaskResult
                    if let runner = subTaskRunner {
                        result = await runner(subTask, context, query)
                    } else {
                        result = await executeSubTask(
                            subTask: subTask,
                            context: context,
                            query: query,
                            orchestrator: orchestrator,
                            registry: registry,
                            config: config
                        )
                    }

                    continuation.yield(.subTaskCompleted(
                        taskId: subTask.id,
                        role: subTask.agent,
                        durationMs: result.durationMs,
                        success: result.success
                    ))

                    sequentialResults.append(result)
                }
                phaseResults = sequentialResults
            } else {
                // Parallel execution via TaskGroup
                phaseResults = await withTaskGroup(of: SubTaskResult.self) { group in
                    for subTask in phase {
                        let context = ContextBudgetManager.buildContext(
                            role: subTask.agent,
                            query: query,
                            priorResults: allResults,
                            memoryPack: memoryPack
                        )

                        group.addTask {
                            continuation.yield(.subTaskStarted(
                                taskId: subTask.id,
                                role: subTask.agent,
                                instruction: subTask.instruction
                            ))

                            let result: SubTaskResult
                            if let runner = subTaskRunner {
                                result = await runner(subTask, context, query)
                            } else {
                                result = await executeSubTask(
                                    subTask: subTask,
                                    context: context,
                                    query: query,
                                    orchestrator: orchestrator,
                                    registry: registry,
                                    config: config
                                )
                            }

                            continuation.yield(.subTaskCompleted(
                                taskId: subTask.id,
                                role: subTask.agent,
                                durationMs: result.durationMs,
                                success: result.success
                            ))

                            return result
                        }
                    }

                    var results: [SubTaskResult] = []
                    for await result in group {
                        results.append(result)
                    }
                    return results
                }
            }

            allResults.append(contentsOf: phaseResults)
        }

        // Phase 4: Synthesize final answer from sub-task results
        let totalMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        // If the last sub-task was a general agent run, use its answer directly
        let finalAnswer: String
        if let lastGeneral = allResults.last(where: { $0.role == .general && $0.success }) {
            finalAnswer = lastGeneral.output
        } else {
            // Combine all successful results
            finalAnswer = allResults
                .filter(\.success)
                .map { "[\($0.role.rawValue)] \($0.output)" }
                .joined(separator: "\n\n")
        }

        let result = OrchestratorResult(
            answer: finalAnswer,
            subTaskResults: allResults,
            intent: classification.intent,
            totalMs: totalMs,
            metrics: nil
        )

        continuation.yield(.orchestrationComplete(result))
        DiagnosticsStore.shared.increment("orchestrator_run_success_total")
        DiagnosticsStore.shared.recordLatency("orchestrator_run_ms", ms: totalMs)
        logger.info("Orchestration complete: intent=\(classification.intent.rawValue) subTasks=\(allResults.count) ms=\(String(format: "%.0f", totalMs))")
    }

    // MARK: - Fast Path

    /// ALL intents use the fast path (direct AgentRuntime with full tool access).
    ///
    /// The general agent's system prompt is comprehensive enough to handle every intent:
    /// - UI actions: ax_tree_query -> ax_click/ax_type -> ax_wait -> verify
    /// - Memory search: search_hybrid -> get_transcript_window -> synthesize
    /// - Procedure replay: get_procedures -> replay_procedure (with built-in safety)
    /// - Learning: handled by the agent's conversational loop
    /// - Complex reasoning: agent chains tools with full context
    ///
    /// The decomposition path was removed because sub-agents without tool access
    /// produced hallucinated tool calls as text. The single general agent with all
    /// tools is strictly better than multiple specialized agents without tools.
    static func shouldUseFastPath(_ classification: IntentClassifier.ClassificationResult) -> Bool {
        return true
    }

    /// Run the standard AgentRuntime directly, forwarding events.
    private static func runFastPath(
        query: String,
        orchestrator: LLMOrchestrator,
        registry: AgentToolRegistry,
        contextStore: ContextStore?,
        patternStore: PatternStore?,
        config: AgentRunConfig,
        intent: IntentClassifier.UserIntent,
        startTime: Double,
        continuation: AsyncStream<OrchestratorEvent>.Continuation
    ) async {
        let request = AgentRunRequest(task: query, config: config)
        let stream = AgentRuntime.run(
            request: request,
            orchestrator: orchestrator,
            registry: registry,
            contextStore: contextStore,
            patternStore: patternStore
        )

        var finalResult: AgentRunResult?

        for await event in stream {
            continuation.yield(.agentEvent(event))

            if case .finalAnswer(let result) = event {
                finalResult = result
            }
        }

        let totalMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        if let result = finalResult {
            let orchestratorResult = OrchestratorResult(
                answer: result.answer,
                subTaskResults: [],
                intent: intent,
                totalMs: totalMs,
                metrics: result.metrics
            )
            continuation.yield(.orchestrationComplete(orchestratorResult))
        }
    }

    // MARK: - Sub-Task Execution

    /// Execute a single sub-task using the appropriate agent.
    private static func executeSubTask(
        subTask: TaskDecomposer.SubTask,
        context: ContextBudgetManager.AgentContext,
        query: String,
        orchestrator: LLMOrchestrator,
        registry: AgentToolRegistry,
        config: AgentRunConfig
    ) async -> SubTaskResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Build a sub-config with the sub-task's timeout
        var subConfig = config
        subConfig.timeoutSeconds = subTask.timeoutSeconds
        subConfig.maxSteps = min(config.maxSteps, subTask.agent == .executor ? 50 : 10)

        // Build the task instruction with injected context
        var fullInstruction = subTask.instruction
        if !context.injectedContext.isEmpty {
            fullInstruction += "\n\n--- Context from prior steps ---\n" + context.injectedContext
        }

        // For the general agent, run the full AgentRuntime
        if subTask.agent == .general {
            return await runGeneralAgent(
                taskId: subTask.id,
                instruction: fullInstruction,
                orchestrator: orchestrator,
                registry: registry,
                config: subConfig,
                startTime: startTime
            )
        }

        // For specialized agents, use a focused LLM call
        do {
            let request = LLMRequest(
                systemPrompt: context.systemPrompt,
                userPrompt: fullInstruction,
                maxTokens: 2048,
                temperature: 0.2,
                responseFormat: .text
            )

            let response = try await orchestrator.generate(request: request)
            let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

            return SubTaskResult(
                taskId: subTask.id,
                role: subTask.agent,
                output: response.content,
                success: true,
                durationMs: durationMs
            )
        } catch {
            let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.warning("Sub-task \(subTask.id) (\(subTask.agent.rawValue)) failed: \(error, privacy: .public)")

            return SubTaskResult(
                taskId: subTask.id,
                role: subTask.agent,
                output: "",
                success: false,
                durationMs: durationMs,
                error: error.localizedDescription
            )
        }
    }

    /// Run the general agent via AgentRuntime and collect the result.
    private static func runGeneralAgent(
        taskId: String,
        instruction: String,
        orchestrator: LLMOrchestrator,
        registry: AgentToolRegistry,
        config: AgentRunConfig,
        startTime: Double
    ) async -> SubTaskResult {
        let request = AgentRunRequest(task: instruction, config: config)
        let stream = AgentRuntime.run(
            request: request,
            orchestrator: orchestrator,
            registry: registry
        )

        var finalAnswer = ""
        var success = false

        for await event in stream {
            switch event {
            case .finalAnswer(let result):
                finalAnswer = result.answer
                success = true
            case .runFailed(let error):
                finalAnswer = "Agent failed: \(error)"
                success = false
            case .runCancelled:
                finalAnswer = "Agent cancelled"
                success = false
            default:
                break
            }
        }

        let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        return SubTaskResult(
            taskId: taskId,
            role: .general,
            output: finalAnswer,
            success: success,
            durationMs: durationMs
        )
    }
}
