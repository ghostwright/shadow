import XCTest
@testable import Shadow

final class ProcedureExecutorTests: XCTestCase {

    // MARK: - Initialization

    /// Executor starts in idle state.
    func testInitialState() async {
        let executor = ProcedureExecutor()
        let isExecuting = await executor.isExecuting
        XCTAssertFalse(isExecuting)
        let currentId = await executor.currentProcedureId
        XCTAssertNil(currentId)
        let currentStep = await executor.currentStepIndex
        XCTAssertNil(currentStep)
    }

    // MARK: - Cancellation

    /// Cancel when not executing does nothing.
    func testCancelWhenNotExecuting() async {
        let executor = ProcedureExecutor()
        await executor.cancel()
        // Should not throw or crash
        let isExecuting = await executor.isExecuting
        XCTAssertFalse(isExecuting)
    }

    // MARK: - Undo

    /// Undo when no steps have executed returns nil.
    func testUndoWhenEmpty() async {
        let executor = ProcedureExecutor()
        let strategy = await executor.undoLastStep()
        XCTAssertNil(strategy)
    }

    // MARK: - Safety Gate Blocking

    /// Procedure targeting blocked app fails immediately.
    func testBlockedAppProcedure() async {
        let executor = ProcedureExecutor()
        let procedure = makeTestProcedure(
            sourceApp: "Keychain Access",
            sourceBundleId: "com.apple.keychainaccess"
        )

        var events: [ExecutionEvent] = []
        let stream = await executor.execute(procedure)
        for await event in stream {
            events.append(event)
        }

        // Should have exactly one event: executionFailed
        XCTAssertFalse(events.isEmpty)
        if case .executionFailed(let atStep, let error) = events.last {
            XCTAssertEqual(atStep, 0)
            XCTAssertTrue(error.contains("Safety gate blocked"))
        } else {
            XCTFail("Expected executionFailed event, got \(events.last.map { "\($0)" } ?? "nil")")
        }
    }

    // MARK: - Execution Events

    /// Executing a procedure emits stepStarting events.
    func testExecutionEmitsStepStarting() async {
        let executor = ProcedureExecutor()
        let procedure = makeSimpleProcedure()

        var events: [ExecutionEvent] = []
        let stream = await executor.execute(procedure)
        for await event in stream {
            events.append(event)
        }

        // At minimum, should emit stepStarting for each step
        let startingEvents = events.filter {
            if case .stepStarting = $0 { return true }
            return false
        }
        XCTAssertGreaterThanOrEqual(startingEvents.count, 1)
    }

    /// Execution state callback is invoked on start and finish.
    func testExecutionStateCallback() async {
        let executor = ProcedureExecutor()
        let collector = ExecutionStateCollector()

        await executor.setOnExecutionStateChanged { state in
            Task { await collector.append(state) }
        }

        let procedure = makeSimpleProcedure()
        let stream = await executor.execute(procedure)
        for await _ in stream { /* consume events */ }

        // Small delay for the callback Tasks to complete
        try? await Task.sleep(nanoseconds: 200_000_000)

        let states = await collector.states
        XCTAssertEqual(states.count, 2, "Expected start (true) and finish (false)")
        if states.count == 2 {
            XCTAssertTrue(states[0])
            XCTAssertFalse(states[1])
        }
    }

    // MARK: - Parameter Resolution

    /// Parameters are substituted in typeText actions.
    func testParameterSubstitution() async {
        let executor = ProcedureExecutor()

        let procedure = ProcedureTemplate(
            id: "param-test",
            name: "Email Template",
            description: "Send an email",
            parameters: [
                ProcedureParameter(
                    name: "recipient",
                    paramType: "email",
                    description: "Email recipient",
                    stepIndices: [0],
                    defaultValue: "default@example.com"
                )
            ],
            steps: [
                ProcedureStep(
                    index: 0,
                    intent: "Enter recipient",
                    actionType: .typeText(text: "default@example.com"),
                    targetLocator: nil,
                    targetDescription: "To field",
                    parameterSubstitutions: ["recipient": "default@example.com"],
                    expectedPostCondition: nil,
                    maxRetries: 0,
                    timeoutSeconds: 1.0
                )
            ],
            createdAt: CaptureSessionClock.wallMicros(),
            updatedAt: CaptureSessionClock.wallMicros(),
            sourceApp: "Mail",
            sourceBundleId: "com.apple.mail",
            tags: ["email"],
            executionCount: 0,
            lastExecutedAt: nil
        )

        // Execute with parameter override
        var events: [ExecutionEvent] = []
        let stream = await executor.execute(
            procedure,
            parameters: ["recipient": "override@example.com"]
        )
        for await event in stream {
            events.append(event)
        }

        // Should have attempted execution (we can't verify the substituted text
        // in a unit test without mocking, but we verify the events were emitted)
        let startingEvents = events.filter {
            if case .stepStarting = $0 { return true }
            return false
        }
        XCTAssertEqual(startingEvents.count, 1)
    }

    // MARK: - Execution Completion

    /// A procedure with scroll-only steps completes successfully
    /// (scrolls are fire-and-forget, so they pass verification).
    func testScrollOnlyProcedureCompletes() async {
        let executor = ProcedureExecutor()
        let procedure = ProcedureTemplate(
            id: "scroll-test",
            name: "Scroll Down",
            description: "Just scroll down",
            parameters: [],
            steps: [
                ProcedureStep(
                    index: 0,
                    intent: "Scroll down",
                    actionType: .scroll(deltaX: 0, deltaY: -3, x: 400, y: 300),
                    targetLocator: nil,
                    targetDescription: nil,
                    parameterSubstitutions: [:],
                    expectedPostCondition: nil,
                    maxRetries: 0,
                    timeoutSeconds: 1.0
                )
            ],
            createdAt: CaptureSessionClock.wallMicros(),
            updatedAt: CaptureSessionClock.wallMicros(),
            sourceApp: "Safari",
            sourceBundleId: "com.apple.Safari",
            tags: [],
            executionCount: 0,
            lastExecutedAt: nil
        )

        var events: [ExecutionEvent] = []
        let stream = await executor.execute(procedure)
        for await event in stream {
            events.append(event)
        }

        // Should see stepStarting and either stepCompleted or stepFailed
        // (depends on whether we can actually scroll in the test env)
        XCTAssertFalse(events.isEmpty)
    }

    // MARK: - Tool Registration

    /// get_procedures tool has correct spec.
    func testGetProceduresToolSpec() {
        let tool = AgentTools.getProceduresTool()
        XCTAssertEqual(tool.spec.name, "get_procedures")
        XCTAssertTrue(tool.spec.description.contains("procedure"))
        XCTAssertNotNil(tool.handler)
    }

    /// replay_procedure tool has correct spec.
    func testReplayProcedureToolSpec() {
        let tool = AgentTools.replayProcedureTool()
        XCTAssertEqual(tool.spec.name, "replay_procedure")
        XCTAssertTrue(tool.spec.description.contains("Replay"))
        XCTAssertNotNil(tool.handler)
    }

    /// get_procedures with no procedures returns empty result.
    func testGetProceduresEmpty() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-exec-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ProcedureStore(directory: tempDir)
        let tool = AgentTools.getProceduresTool(store: store)
        let result = try await tool.handler!([:])
        XCTAssertTrue(result.contains("no_procedures_found"))
    }

    /// get_procedures returns saved procedures.
    func testGetProceduresReturnsSaved() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-exec-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ProcedureStore(directory: tempDir)
        try await store.save(makeTestProcedure(
            sourceApp: "Safari",
            sourceBundleId: "com.apple.Safari"
        ))

        let tool = AgentTools.getProceduresTool(store: store)
        let result = try await tool.handler!([:])
        XCTAssertTrue(result.contains("Test Procedure"))
        XCTAssertTrue(result.contains("Safari"))
    }

    /// replay_procedure with missing procedureId throws.
    func testReplayProcedureMissingId() async {
        let tool = AgentTools.replayProcedureTool()
        do {
            _ = try await tool.handler!([:])
            XCTFail("Should throw for missing procedureId")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("procedureId"))
        }
    }

    /// replay_procedure with non-existent procedure throws.
    func testReplayProcedureNotFound() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-exec-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ProcedureStore(directory: tempDir)
        let tool = AgentTools.replayProcedureTool(store: store)

        do {
            _ = try await tool.handler!(["procedureId": .string("nonexistent")])
            XCTFail("Should throw for non-existent procedure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not found"))
        }
    }

    // MARK: - Helpers

    private func makeTestProcedure(
        sourceApp: String,
        sourceBundleId: String
    ) -> ProcedureTemplate {
        ProcedureTemplate(
            id: "test-proc-\(UUID().uuidString.prefix(8))",
            name: "Test Procedure",
            description: "A test procedure for execution",
            parameters: [],
            steps: [
                ProcedureStep(
                    index: 0,
                    intent: "Click button",
                    actionType: .click(x: 100, y: 100, button: "left", count: 1),
                    targetLocator: nil,
                    targetDescription: "Test button",
                    parameterSubstitutions: [:],
                    expectedPostCondition: nil,
                    maxRetries: 0,
                    timeoutSeconds: 1.0
                )
            ],
            createdAt: CaptureSessionClock.wallMicros(),
            updatedAt: CaptureSessionClock.wallMicros(),
            sourceApp: sourceApp,
            sourceBundleId: sourceBundleId,
            tags: ["test"],
            executionCount: 0,
            lastExecutedAt: nil
        )
    }

    private func makeSimpleProcedure() -> ProcedureTemplate {
        ProcedureTemplate(
            id: "simple-proc",
            name: "Simple Procedure",
            description: "A simple test procedure",
            parameters: [],
            steps: [
                ProcedureStep(
                    index: 0,
                    intent: "App switch",
                    actionType: .appSwitch(toApp: "Finder", toBundleId: "com.apple.finder"),
                    targetLocator: nil,
                    targetDescription: nil,
                    parameterSubstitutions: [:],
                    expectedPostCondition: nil,
                    maxRetries: 0,
                    timeoutSeconds: 1.0
                )
            ],
            createdAt: CaptureSessionClock.wallMicros(),
            updatedAt: CaptureSessionClock.wallMicros(),
            sourceApp: "Finder",
            sourceBundleId: "com.apple.finder",
            tags: ["test"],
            executionCount: 0,
            lastExecutedAt: nil
        )
    }
}

// Helper to set the callback from async context
extension ProcedureExecutor {
    func setOnExecutionStateChanged(_ callback: @escaping @Sendable (Bool) -> Void) {
        self.onExecutionStateChanged = callback
    }
}

/// Thread-safe collector for execution state callback values.
private actor ExecutionStateCollector {
    var states: [Bool] = []

    func append(_ value: Bool) {
        states.append(value)
    }
}
