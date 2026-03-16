import XCTest
@testable import Shadow

final class TaskDecomposerTests: XCTestCase {

    // MARK: - AgentRole

    /// All agent roles exist.
    func testAllAgentRoles() {
        let roles = TaskDecomposer.AgentRole.allCases
        XCTAssertEqual(roles.count, 6)
        XCTAssertTrue(roles.contains(.observer))
        XCTAssertTrue(roles.contains(.executor))
        XCTAssertTrue(roles.contains(.memoryManager))
        XCTAssertTrue(roles.contains(.learningEngine))
        XCTAssertTrue(roles.contains(.safetyMonitor))
        XCTAssertTrue(roles.contains(.general))
    }

    /// AgentRole is Codable.
    func testAgentRoleCodable() throws {
        let role = TaskDecomposer.AgentRole.executor
        let data = try JSONEncoder().encode(role)
        let decoded = try JSONDecoder().decode(TaskDecomposer.AgentRole.self, from: data)
        XCTAssertEqual(role, decoded)
    }

    // MARK: - SubTask

    /// SubTask captures all fields.
    func testSubTaskFields() {
        let task = TaskDecomposer.SubTask(
            id: "test-1",
            agent: .observer,
            instruction: "Observe screen",
            parallelizable: true,
            timeoutSeconds: 15,
            dependsOn: "prev-task"
        )
        XCTAssertEqual(task.id, "test-1")
        XCTAssertEqual(task.agent, .observer)
        XCTAssertEqual(task.instruction, "Observe screen")
        XCTAssertTrue(task.parallelizable)
        XCTAssertEqual(task.timeoutSeconds, 15)
        XCTAssertEqual(task.dependsOn, "prev-task")
    }

    /// SubTask is Identifiable via id.
    func testSubTaskIdentifiable() {
        let task = TaskDecomposer.SubTask(id: "unique-id", agent: .general, instruction: "test")
        XCTAssertEqual(task.id, "unique-id")
    }

    /// SubTask defaults.
    func testSubTaskDefaults() {
        let task = TaskDecomposer.SubTask(agent: .general, instruction: "test")
        XCTAssertFalse(task.id.isEmpty)
        XCTAssertFalse(task.parallelizable)
        XCTAssertEqual(task.timeoutSeconds, 30)
        XCTAssertNil(task.dependsOn)
    }

    // MARK: - Decomposition by Intent

    /// Simple question decomposes into observer + general.
    func testDecomposeSimpleQuestion() async {
        let result = await TaskDecomposer.decompose(
            query: "What was I doing at 2pm?",
            intent: .simpleQuestion
        )
        XCTAssertEqual(result.intent, .simpleQuestion)
        XCTAssertEqual(result.subTasks.count, 2)
        XCTAssertEqual(result.subTasks[0].agent, .observer)
        XCTAssertEqual(result.subTasks[1].agent, .general)
        XCTAssertTrue(result.subTasks[0].parallelizable)
    }

    /// Memory search decomposes into memoryManager + observer + general.
    func testDecomposeMemorySearch() async {
        let result = await TaskDecomposer.decompose(
            query: "Find my budget meeting notes",
            intent: .memorySearch
        )
        XCTAssertEqual(result.subTasks.count, 3)
        XCTAssertEqual(result.subTasks[0].agent, .memoryManager)
        XCTAssertEqual(result.subTasks[1].agent, .observer)
        XCTAssertEqual(result.subTasks[2].agent, .general)
        XCTAssertTrue(result.subTasks[0].parallelizable)
        XCTAssertTrue(result.subTasks[1].parallelizable)
        XCTAssertNotNil(result.subTasks[2].dependsOn) // depends on memory result
    }

    /// Procedure replay decomposes into memory + observer + safety + executor.
    func testDecomposeProcedureReplay() async {
        let result = await TaskDecomposer.decompose(
            query: "File my expense report",
            intent: .procedureReplay
        )
        XCTAssertEqual(result.subTasks.count, 4)
        XCTAssertEqual(result.subTasks[0].agent, .memoryManager)
        XCTAssertEqual(result.subTasks[1].agent, .observer)
        XCTAssertEqual(result.subTasks[2].agent, .safetyMonitor)
        XCTAssertEqual(result.subTasks[3].agent, .executor)
        XCTAssertNotNil(result.subTasks[2].dependsOn) // safety depends on memory
        XCTAssertNotNil(result.subTasks[3].dependsOn) // executor depends on safety
        XCTAssertEqual(result.subTasks[3].timeoutSeconds, 300) // extended timeout
    }

    /// Procedure learning decomposes into observer + learningEngine.
    func testDecomposeProcedureLearning() async {
        let result = await TaskDecomposer.decompose(
            query: "Watch me create a Jira ticket",
            intent: .procedureLearning
        )
        XCTAssertEqual(result.subTasks.count, 2)
        XCTAssertEqual(result.subTasks[0].agent, .observer)
        XCTAssertEqual(result.subTasks[1].agent, .learningEngine)
        XCTAssertEqual(result.subTasks[1].timeoutSeconds, 600) // long timeout for learning
    }

    /// Complex reasoning decomposes into memory + observer + general.
    func testDecomposeComplexReasoning() async {
        let result = await TaskDecomposer.decompose(
            query: "Analyze my time allocation this week",
            intent: .complexReasoning
        )
        XCTAssertEqual(result.subTasks.count, 3)
        XCTAssertEqual(result.subTasks[0].agent, .memoryManager)
        XCTAssertEqual(result.subTasks[1].agent, .observer)
        XCTAssertEqual(result.subTasks[2].agent, .general)
        XCTAssertTrue(result.subTasks[0].parallelizable)
    }

    /// Directive creation decomposes into memory check + general.
    func testDecomposeDirectiveCreation() async {
        let result = await TaskDecomposer.decompose(
            query: "Remind me when I open Slack",
            intent: .directiveCreation
        )
        XCTAssertEqual(result.subTasks.count, 2)
        XCTAssertEqual(result.subTasks[0].agent, .memoryManager)
        XCTAssertEqual(result.subTasks[1].agent, .general)
    }

    /// Ambiguous intent produces single general task.
    func testDecomposeAmbiguous() async {
        let result = await TaskDecomposer.decompose(
            query: "something unclear",
            intent: .ambiguous
        )
        XCTAssertEqual(result.subTasks.count, 1)
        XCTAssertEqual(result.subTasks[0].agent, .general)
        XCTAssertEqual(result.subTasks[0].timeoutSeconds, 120)
    }

    // MARK: - DecompositionResult

    /// DecompositionResult captures all fields.
    func testDecompositionResult() async {
        let result = await TaskDecomposer.decompose(
            query: "test query",
            intent: .simpleQuestion
        )
        XCTAssertEqual(result.originalQuery, "test query")
        XCTAssertEqual(result.intent, .simpleQuestion)
        XCTAssertGreaterThan(result.estimatedTimeoutSeconds, 0)
    }

    /// Estimated timeout is sum of sub-task timeouts.
    func testEstimatedTimeout() async {
        let result = await TaskDecomposer.decompose(
            query: "test",
            intent: .simpleQuestion
        )
        let expectedTimeout = result.subTasks.reduce(0.0) { $0 + $1.timeoutSeconds }
        XCTAssertEqual(result.estimatedTimeoutSeconds, expectedTimeout)
    }

    // MARK: - Phase Grouping

    /// Single task produces single phase.
    func testGroupSingleTask() {
        let tasks = [
            TaskDecomposer.SubTask(agent: .general, instruction: "test"),
        ]
        let phases = TaskDecomposer.groupIntoPhases(tasks)
        XCTAssertEqual(phases.count, 1)
        XCTAssertEqual(phases[0].count, 1)
    }

    /// Parallel tasks are grouped into same phase.
    func testGroupParallelTasks() {
        let tasks = [
            TaskDecomposer.SubTask(agent: .memoryManager, instruction: "retrieve", parallelizable: true),
            TaskDecomposer.SubTask(agent: .observer, instruction: "observe", parallelizable: true),
        ]
        let phases = TaskDecomposer.groupIntoPhases(tasks)
        XCTAssertEqual(phases.count, 1)
        XCTAssertEqual(phases[0].count, 2)
    }

    /// Dependency breaks create new phase.
    func testGroupDependencyBreak() {
        let memId = "mem-1"
        let tasks = [
            TaskDecomposer.SubTask(id: memId, agent: .memoryManager, instruction: "retrieve", parallelizable: true),
            TaskDecomposer.SubTask(agent: .observer, instruction: "observe", parallelizable: true),
            TaskDecomposer.SubTask(agent: .general, instruction: "synthesize", dependsOn: memId),
        ]
        let phases = TaskDecomposer.groupIntoPhases(tasks)
        XCTAssertEqual(phases.count, 2)
        XCTAssertEqual(phases[0].count, 2) // memory + observer in parallel
        XCTAssertEqual(phases[1].count, 1) // general depends on memory
    }

    /// Sequential tasks get separate phases.
    func testGroupSequentialTasks() {
        let tasks = [
            TaskDecomposer.SubTask(agent: .observer, instruction: "step 1"),
            TaskDecomposer.SubTask(agent: .executor, instruction: "step 2"),
        ]
        let phases = TaskDecomposer.groupIntoPhases(tasks)
        XCTAssertEqual(phases.count, 2)
    }

    /// Empty task list produces no phases.
    func testGroupEmptyTasks() {
        let phases = TaskDecomposer.groupIntoPhases([])
        XCTAssertTrue(phases.isEmpty)
    }

    /// Complex pipeline groups correctly.
    func testGroupComplexPipeline() {
        let memId = "mem-1"
        let safetyId = "safety-1"
        let tasks = [
            TaskDecomposer.SubTask(id: memId, agent: .memoryManager, instruction: "find procedure"),
            TaskDecomposer.SubTask(agent: .observer, instruction: "capture state", parallelizable: true),
            TaskDecomposer.SubTask(id: safetyId, agent: .safetyMonitor, instruction: "check safety", dependsOn: memId),
            TaskDecomposer.SubTask(agent: .executor, instruction: "execute", dependsOn: safetyId),
        ]
        let phases = TaskDecomposer.groupIntoPhases(tasks)
        // Phase 0: memoryManager (sequential)
        // Phase 1: observer (parallel but alone since previous wasn't parallel)
        // Phase 2: safety (depends on mem)
        // Phase 3: executor (depends on safety)
        XCTAssertGreaterThanOrEqual(phases.count, 3)
    }
}
