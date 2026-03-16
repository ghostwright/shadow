import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "TaskDecomposer")

/// Decomposes complex user requests into ordered sub-tasks for agent routing.
///
/// Two strategies:
/// 1. **Template decomposition** — Intent-based templates for known patterns.
/// 2. **LLM decomposition** — For ambiguous or complex multi-step requests.
///
/// Sub-tasks execute sequentially by default. Independent lookups (memory retrieval)
/// can run in parallel via TaskGroup at the orchestrator level.
enum TaskDecomposer {

    // MARK: - Sub-Task Types

    /// A single unit of work to be routed to a specialized agent.
    struct SubTask: Sendable, Equatable, Identifiable {
        let id: String
        /// Which agent handles this sub-task.
        let agent: AgentRole
        /// Natural language description of what to do.
        let instruction: String
        /// Whether this sub-task can run in parallel with the next one.
        let parallelizable: Bool
        /// Timeout for this sub-task in seconds.
        let timeoutSeconds: Double
        /// Whether this sub-task requires the result of a previous one.
        let dependsOn: String?

        init(
            id: String = UUID().uuidString,
            agent: AgentRole,
            instruction: String,
            parallelizable: Bool = false,
            timeoutSeconds: Double = 30,
            dependsOn: String? = nil
        ) {
            self.id = id
            self.agent = agent
            self.instruction = instruction
            self.parallelizable = parallelizable
            self.timeoutSeconds = timeoutSeconds
            self.dependsOn = dependsOn
        }
    }

    /// Specialized agent roles for sub-task routing.
    enum AgentRole: String, Sendable, CaseIterable, Codable {
        /// Reads screen state, AX trees, current context.
        case observer
        /// Executes UI actions, replays procedures.
        case executor
        /// Retrieves and manages memories, knowledge, directives.
        case memoryManager
        /// Records and generalizes procedures from demonstrations.
        case learningEngine
        /// Evaluates safety, applies approval gates.
        case safetyMonitor
        /// General purpose — the full agent runtime.
        case general
    }

    /// Result of task decomposition.
    struct DecompositionResult: Sendable, Equatable {
        /// Ordered list of sub-tasks.
        let subTasks: [SubTask]
        /// The original user query.
        let originalQuery: String
        /// The classified intent that drove decomposition.
        let intent: IntentClassifier.UserIntent
        /// Total estimated time budget in seconds.
        let estimatedTimeoutSeconds: Double
    }

    // MARK: - Decomposition

    /// Decompose a user request into sub-tasks based on classified intent.
    ///
    /// - Parameters:
    ///   - query: The user's natural language input.
    ///   - intent: Pre-classified intent from IntentClassifier.
    ///   - decomposeFn: Injectable LLM function for complex decomposition.
    /// - Returns: DecompositionResult with ordered sub-tasks.
    static func decompose(
        query: String,
        intent: IntentClassifier.UserIntent,
        decomposeFn: (@Sendable (String) async throws -> String)? = nil
    ) async -> DecompositionResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        let subTasks: [SubTask]
        switch intent {
        case .simpleQuestion:
            subTasks = decomposeSimpleQuestion(query)
        case .memorySearch:
            subTasks = decomposeMemorySearch(query)
        case .procedureReplay:
            subTasks = decomposeProcedureReplay(query)
        case .procedureLearning:
            subTasks = decomposeProcedureLearning(query)
        case .complexReasoning:
            subTasks = decomposeComplexReasoning(query)
        case .directiveCreation:
            subTasks = decomposeDirectiveCreation(query)
        case .uiAction:
            // UI actions go directly to the general agent which has all AX tools
            subTasks = [SubTask(agent: .general, instruction: query, timeoutSeconds: 120)]
        case .ambiguous:
            // Ambiguous → run via general agent with no decomposition
            subTasks = [SubTask(agent: .general, instruction: query, timeoutSeconds: 120)]
        }

        let totalTimeout = subTasks.reduce(0.0) { $0 + $1.timeoutSeconds }
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000

        logger.info("Decomposed '\(query.prefix(50))' into \(subTasks.count) sub-tasks (\(String(format: "%.0f", elapsed))ms)")
        DiagnosticsStore.shared.increment("task_decompose_total")
        DiagnosticsStore.shared.setGauge("task_subtask_count", value: Double(subTasks.count))

        return DecompositionResult(
            subTasks: subTasks,
            originalQuery: query,
            intent: intent,
            estimatedTimeoutSeconds: totalTimeout
        )
    }

    // MARK: - Template Decompositions

    /// Simple question → observe + general agent.
    private static func decomposeSimpleQuestion(_ query: String) -> [SubTask] {
        let observeId = UUID().uuidString
        return [
            SubTask(
                id: observeId,
                agent: .observer,
                instruction: "Capture current screen context and app state",
                parallelizable: true,
                timeoutSeconds: 10
            ),
            SubTask(
                agent: .general,
                instruction: query,
                timeoutSeconds: 60
            ),
        ]
    }

    /// Memory search → parallel memory retrieval + general synthesis.
    private static func decomposeMemorySearch(_ query: String) -> [SubTask] {
        let memId = UUID().uuidString
        return [
            SubTask(
                id: memId,
                agent: .memoryManager,
                instruction: "Retrieve relevant memories for: \(query)",
                parallelizable: true,
                timeoutSeconds: 15
            ),
            SubTask(
                agent: .observer,
                instruction: "Capture current screen context",
                parallelizable: true,
                timeoutSeconds: 10
            ),
            SubTask(
                agent: .general,
                instruction: query,
                timeoutSeconds: 60,
                dependsOn: memId
            ),
        ]
    }

    /// Procedure replay → memory lookup + safety check + execution.
    private static func decomposeProcedureReplay(_ query: String) -> [SubTask] {
        let memId = UUID().uuidString
        let safetyId = UUID().uuidString
        return [
            SubTask(
                id: memId,
                agent: .memoryManager,
                instruction: "Find matching procedures for: \(query)",
                timeoutSeconds: 15
            ),
            SubTask(
                agent: .observer,
                instruction: "Capture current screen state for procedure execution",
                parallelizable: true,
                timeoutSeconds: 10
            ),
            SubTask(
                id: safetyId,
                agent: .safetyMonitor,
                instruction: "Assess safety of procedure execution for: \(query)",
                timeoutSeconds: 10,
                dependsOn: memId
            ),
            SubTask(
                agent: .executor,
                instruction: "Execute procedure for: \(query)",
                timeoutSeconds: 300,
                dependsOn: safetyId
            ),
        ]
    }

    /// Procedure learning → start recording.
    private static func decomposeProcedureLearning(_ query: String) -> [SubTask] {
        return [
            SubTask(
                agent: .observer,
                instruction: "Capture initial screen state before learning",
                timeoutSeconds: 10
            ),
            SubTask(
                agent: .learningEngine,
                instruction: "Start recording procedure: \(query)",
                timeoutSeconds: 600
            ),
        ]
    }

    /// Complex reasoning → memory retrieval + observation + deep analysis.
    private static func decomposeComplexReasoning(_ query: String) -> [SubTask] {
        let memId = UUID().uuidString
        return [
            SubTask(
                id: memId,
                agent: .memoryManager,
                instruction: "Retrieve all relevant context for analysis: \(query)",
                parallelizable: true,
                timeoutSeconds: 20
            ),
            SubTask(
                agent: .observer,
                instruction: "Capture current context",
                parallelizable: true,
                timeoutSeconds: 10
            ),
            SubTask(
                agent: .general,
                instruction: query,
                timeoutSeconds: 120,
                dependsOn: memId
            ),
        ]
    }

    /// Directive creation → create via memory manager.
    private static func decomposeDirectiveCreation(_ query: String) -> [SubTask] {
        return [
            SubTask(
                agent: .memoryManager,
                instruction: "Check existing directives for conflicts",
                parallelizable: true,
                timeoutSeconds: 10
            ),
            SubTask(
                agent: .general,
                instruction: "Create directive from user request: \(query)",
                timeoutSeconds: 60
            ),
        ]
    }

    // MARK: - Parallel Grouping

    /// Group sub-tasks into execution phases. Tasks within the same phase
    /// can run in parallel if marked parallelizable.
    static func groupIntoPhases(_ subTasks: [SubTask]) -> [[SubTask]] {
        var phases: [[SubTask]] = []
        var currentPhase: [SubTask] = []

        for task in subTasks {
            if task.dependsOn != nil && !currentPhase.isEmpty {
                // Dependency break — flush current phase, start new one
                phases.append(currentPhase)
                currentPhase = [task]
            } else if task.parallelizable && (currentPhase.isEmpty || currentPhase.allSatisfy(\.parallelizable)) {
                // Can run in parallel with current phase
                currentPhase.append(task)
            } else if currentPhase.isEmpty {
                currentPhase.append(task)
            } else {
                // Sequential — flush and start new phase
                phases.append(currentPhase)
                currentPhase = [task]
            }
        }

        if !currentPhase.isEmpty {
            phases.append(currentPhase)
        }

        return phases
    }
}
