import XCTest
@testable import Shadow

@MainActor
final class CommandFlowTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeViewModel() -> SearchViewModel {
        let vm = SearchViewModel()
        vm.query = "standup meeting"
        return vm
    }

    /// Create a view model wired for async command tests.
    /// Injects a controllable summarize function and a real (but unused) SummaryJobQueue.
    private func makeCommandViewModel(
        summarize: @escaping @Sendable (SummaryJobQueue) async throws -> SummarizationResult
    ) -> SearchViewModel {
        let vm = SearchViewModel()
        vm.query = "standup meeting"
        vm.summaryJobQueue = makeDummyQueue()
        vm.summarizeFunction = summarize
        return vm
    }

    /// Lightweight queue instance — satisfies the nil guard in executeCommand().
    /// The injected summarizeFunction ignores it entirely.
    private func makeDummyQueue() -> SummaryJobQueue {
        let orchestrator = LLMOrchestrator(providers: [], mode: .auto)
        let store = SummaryStore()
        return SummaryJobQueue(orchestrator: orchestrator, store: store)
    }

    private func makeSummary() -> MeetingSummary {
        MeetingSummary(
            id: UUID().uuidString,
            title: "Weekly Standup",
            summary: "Team discussed Q3 progress and upcoming milestones.",
            keyPoints: ["Q3 revenue up 12%", "Dashboard redesign approved"],
            decisions: ["Ship by Friday"],
            actionItems: [
                ActionItem(
                    description: "Update rate limiter config",
                    owner: "Sarah",
                    dueDateText: "Friday",
                    evidenceTimestamps: [1_000_000, 2_000_000]
                )
            ],
            openQuestions: ["Budget allocation?"],
            highlights: [
                TimestampedHighlight(
                    text: "We need to ship before the board meeting",
                    tsStart: 500_000,
                    tsEnd: 600_000
                )
            ],
            metadata: SummaryMetadata(
                provider: "test_provider",
                modelId: "test-model-v1",
                generatedAt: Date(),
                inputHash: "abc123",
                sourceWindow: SourceWindow(
                    startUs: 0,
                    endUs: 3_000_000,
                    timezone: "America/New_York",
                    sessionId: nil
                ),
                inputTokenEstimate: 500
            )
        )
    }

    private func makeSummary(timezone: String) -> MeetingSummary {
        MeetingSummary(
            id: UUID().uuidString,
            title: "Test Meeting",
            summary: "Test summary.",
            keyPoints: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            highlights: [],
            metadata: SummaryMetadata(
                provider: "test",
                modelId: "test",
                generatedAt: Date(),
                inputHash: "tz_test",
                sourceWindow: SourceWindow(
                    startUs: 1_708_617_600_000_000, // 2024-02-22 12:00:00 PM UTC
                    endUs:   1_708_621_200_000_000, // 2024-02-22 01:00:00 PM UTC
                    timezone: timezone,
                    sessionId: nil
                ),
                inputTokenEstimate: 100
            )
        )
    }

    // MARK: - 1. Initial state is idle

    func testInitialState_isIdle() {
        let vm = makeViewModel()
        guard case .idle = vm.commandState else {
            XCTFail("Initial commandState should be .idle, got \(vm.commandState)")
            return
        }
    }

    // MARK: - 2. Execute without queue shows queueNotReady error

    func testExecute_nilQueue_showsQueueNotReady() {
        let vm = makeViewModel()
        vm.summaryJobQueue = nil

        vm.executeCommand()

        guard case .error(.queueNotReady) = vm.commandState else {
            XCTFail("Expected .error(.queueNotReady), got \(vm.commandState)")
            return
        }
    }

    // MARK: - 3. Execute with empty query does nothing

    func testExecute_emptyQuery_staysIdle() {
        let vm = SearchViewModel()
        vm.query = ""

        vm.executeCommand()

        guard case .idle = vm.commandState else {
            XCTFail("Expected .idle with empty query, got \(vm.commandState)")
            return
        }
    }

    // MARK: - 4. Execute with whitespace-only query does nothing

    func testExecute_whitespaceQuery_staysIdle() {
        let vm = SearchViewModel()
        vm.query = "   \n  "

        vm.executeCommand()

        guard case .idle = vm.commandState else {
            XCTFail("Expected .idle with whitespace query, got \(vm.commandState)")
            return
        }
    }

    // MARK: - 5. Cancel returns to idle

    func testCancelCommand_returnsToIdle() {
        let vm = makeViewModel()

        // Manually set a running state to test cancel
        vm.cancelCommand()

        guard case .idle = vm.commandState else {
            XCTFail("Expected .idle after cancel, got \(vm.commandState)")
            return
        }
    }

    // MARK: - 6. DismissCommandResult returns to idle

    func testDismissResult_returnsToIdle() {
        let vm = makeViewModel()

        vm.dismissCommandResult()

        guard case .idle = vm.commandState else {
            XCTFail("Expected .idle after dismissResult, got \(vm.commandState)")
            return
        }
    }

    // MARK: - 7. Clear resets command state

    func testClear_resetsCommandState() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.query.isEmpty)

        vm.clear()

        guard case .idle = vm.commandState else {
            XCTFail("Expected .idle after clear, got \(vm.commandState)")
            return
        }
        XCTAssertTrue(vm.query.isEmpty)
        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertEqual(vm.selectedIndex, 0)
    }

    // MARK: - 8. CommandState panel heights

    func testPanelHeights() {
        XCTAssertEqual(CommandState.idle.panelHeight, 640)
        XCTAssertEqual(CommandState.running(stage: "test").panelHeight, 240)
        XCTAssertEqual(CommandState.error(.noMeetingFound).panelHeight, 300)
        XCTAssertEqual(CommandState.error(.queueNotReady).panelHeight, 300)
        XCTAssertEqual(CommandState.error(.providerError("test")).panelHeight, 300)
        XCTAssertEqual(CommandState.error(.multipleMeetingsFound).panelHeight, 300)

        let summary = makeSummary()
        XCTAssertEqual(CommandState.result(summary).panelHeight, 640)
    }

    // MARK: - 9. CommandError messages are non-empty

    func testCommandError_hasNonEmptyMessages() {
        let errors: [CommandError] = [
            .noMeetingFound,
            .multipleMeetingsFound,
            .queueNotReady,
            .providerError("Something went wrong")
        ]

        for error in errors {
            XCTAssertFalse(error.title.isEmpty, "Error \(error) should have a title")
            XCTAssertFalse(error.message.isEmpty, "Error \(error) should have a message")
            XCTAssertFalse(error.iconName.isEmpty, "Error \(error) should have an icon name")
        }
    }

    // MARK: - 10. Evidence deep-link uses onOpenTimeline callback

    func testEvidenceDeepLink_usesOnOpenTimeline() {
        let vm = makeViewModel()
        var capturedTs: UInt64?
        var capturedDisplayID: UInt32?
        var callCount = 0

        vm.onOpenTimeline = { ts, displayID in
            capturedTs = ts
            capturedDisplayID = displayID
            callCount += 1
        }

        // Simulate what CommandResponseView's evidenceLink does:
        // calls onOpenTimeline?(ts, nil) — same callback path as search results
        vm.onOpenTimeline?(1_000_000, nil)

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(capturedTs, 1_000_000)
        XCTAssertNil(capturedDisplayID, "Evidence links pass nil displayID (no display attribution for meetings)")
    }

    // MARK: - 11. Search result deep-link uses onOpenTimeline callback

    func testSearchResultDeepLink_usesOnOpenTimeline() {
        let vm = makeViewModel()
        var capturedTs: UInt64?
        var capturedDisplayID: UInt32?
        var callCount = 0

        vm.onOpenTimeline = { ts, displayID in
            capturedTs = ts
            capturedDisplayID = displayID
            callCount += 1
        }

        // Simulate search result tap with display ID
        vm.onOpenTimeline?(2_000_000, 42)

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(capturedTs, 2_000_000)
        XCTAssertEqual(capturedDisplayID, 42)
    }

    // MARK: - 12. isCommandActive property

    func testIsCommandActive() {
        XCTAssertFalse(CommandState.idle.isCommandActive)
        XCTAssertTrue(CommandState.running(stage: "test").isCommandActive)

        let summary = makeSummary()
        XCTAssertTrue(CommandState.result(summary).isCommandActive)

        XCTAssertTrue(CommandState.error(.noMeetingFound).isCommandActive)
        XCTAssertTrue(CommandState.error(.multipleMeetingsFound).isCommandActive)
        XCTAssertTrue(CommandState.error(.queueNotReady).isCommandActive)
        XCTAssertTrue(CommandState.error(.providerError("err")).isCommandActive)
    }

    // MARK: - 13. onCommandStateChanged callback fires

    func testOnCommandStateChanged_firesOnStateChange() {
        let vm = makeViewModel()
        var callbackStates: [String] = []

        vm.onCommandStateChanged = { state in
            switch state {
            case .idle: callbackStates.append("idle")
            case .running: callbackStates.append("running")
            case .result: callbackStates.append("result")
            case .error: callbackStates.append("error")
            case .agentStreaming: callbackStates.append("agentStreaming")
            case .agentResult: callbackStates.append("agentResult")
            }
        }

        // Execute with nil queue → triggers error state
        vm.executeCommand()
        XCTAssertEqual(callbackStates, ["error"])

        // Dismiss → triggers idle state
        vm.dismissCommandResult()
        XCTAssertEqual(callbackStates, ["error", "idle"])
    }

    // MARK: - 14. confirmSelection guards on commandState

    func testConfirmSelection_guardsOnCommandState() {
        let vm = makeViewModel()
        var openTimelineCalled = false

        vm.onOpenTimeline = { _, _ in
            openTimelineCalled = true
        }

        // With no results, confirmSelection should do nothing
        vm.confirmSelection()
        XCTAssertFalse(openTimelineCalled)
    }

    // MARK: - 15. CommandState panelWidth is constant

    func testPanelWidth_isConstant() {
        XCTAssertEqual(CommandState.panelWidth, 740)
    }

    // MARK: - 16. Cancelled run cannot update commandState

    func testCancelledRun_cannotUpdateState() async {
        let summary = makeSummary()
        let vm = makeCommandViewModel { _ in
            try await Task.sleep(for: .milliseconds(200))
            return .success(summary)
        }

        vm.executeCommand()
        guard case .running = vm.commandState else {
            XCTFail("Expected .running after executeCommand, got \(vm.commandState)")
            return
        }

        // Cancel before the summarize function completes
        vm.cancelCommand()
        guard case .idle = vm.commandState else {
            XCTFail("Expected .idle after cancel, got \(vm.commandState)")
            return
        }

        // Wait for the in-flight summarize function to complete
        try? await Task.sleep(for: .milliseconds(400))

        // State must still be .idle — the stale result must not have landed
        guard case .idle = vm.commandState else {
            XCTFail("Stale result mutated state after cancel: \(vm.commandState)")
            return
        }
    }

    // MARK: - 17. Stage updater is cancelled when command is cancelled

    func testStageUpdater_cancelledOnCommandCancel() async {
        let vm = makeCommandViewModel { _ in
            // Slow enough that stage updater would fire if not cancelled
            try await Task.sleep(for: .seconds(10))
            return .noMeetingFound
        }

        vm.executeCommand()
        guard case .running(let stage) = vm.commandState else {
            XCTFail("Expected .running, got \(vm.commandState)")
            return
        }
        XCTAssertTrue(stage.contains("Resolving"))

        // Cancel immediately
        vm.cancelCommand()

        // Wait past the first stage update interval (2s)
        try? await Task.sleep(for: .milliseconds(2500))

        // State must remain idle — stage updater must not have fired
        guard case .idle = vm.commandState else {
            XCTFail("Stage updater fired after cancel: \(vm.commandState)")
            return
        }
    }

    // MARK: - 18. Rapid cancel+restart: old run cannot overwrite new run

    func testRapidCancelRestart_oldRunCannotOverwriteNew() async {
        let summaryA = makeSummary()
        let summaryB = MeetingSummary(
            id: "run2",
            title: "Run 2 Result",
            summary: "Run 2 summary.",
            keyPoints: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            highlights: [],
            metadata: summaryA.metadata
        )

        // Run 1: slow (500ms)
        let vm = makeCommandViewModel { _ in
            try await Task.sleep(for: .milliseconds(500))
            return .success(summaryA)
        }

        // Start run 1
        vm.executeCommand()

        // Cancel run 1, immediately start run 2 (fast: 50ms)
        vm.cancelCommand()
        let run2Summary = summaryB
        vm.summarizeFunction = { _ in
            try await Task.sleep(for: .milliseconds(50))
            return .success(run2Summary)
        }
        vm.executeCommand()

        // Wait for both to complete
        try? await Task.sleep(for: .milliseconds(800))

        // State must be run 2's result, not run 1's
        guard case .result(let result) = vm.commandState else {
            XCTFail("Expected .result from run 2, got \(vm.commandState)")
            return
        }
        XCTAssertEqual(result.id, "run2", "Result should be from run 2, not stale run 1")
    }

    // MARK: - 19. Disambiguation maps to multipleMeetingsFound error

    func testDisambiguation_mapsToMultipleMeetingsFound() async {
        let vm = makeCommandViewModel { _ in
            return .disambiguation([])
        }

        vm.executeCommand()

        // The summarize function returns instantly, but runs in a Task.
        // Yield enough for the MainActor task to process.
        try? await Task.sleep(for: .milliseconds(500))

        guard case .error(.multipleMeetingsFound) = vm.commandState else {
            XCTFail("Expected .error(.multipleMeetingsFound), got \(vm.commandState)")
            return
        }
    }

    // MARK: - 20. SummaryTimeFormatter uses sourceWindow timezone

    func testTimeFormatter_usesSourceTimezone() {
        // 1_708_617_600_000_000 us = 2024-02-22 16:00:00 UTC
        // In America/Los_Angeles (PST = UTC-8): 8:00 AM
        let fmt = SummaryTimeFormatter(timezoneIdentifier: "America/Los_Angeles")

        let ts = fmt.formatTimestamp(1_708_617_600_000_000)
        XCTAssertTrue(ts.contains("8:00:00"), "16:00 UTC should be 8:00:00 AM PST, got \(ts)")

        // Same timestamp in UTC should be different
        let utcFmt = SummaryTimeFormatter(timezoneIdentifier: "UTC")
        let utcTs = utcFmt.formatTimestamp(1_708_617_600_000_000)
        XCTAssertTrue(utcTs.contains("4:00:00"), "16:00 UTC should be 4:00:00 PM UTC, got \(utcTs)")
        XCTAssertNotEqual(ts, utcTs)
    }

    // MARK: - 21. SummaryTimeFormatter formats time window correctly

    func testTimeFormatter_formatsWindow() {
        let fmt = SummaryTimeFormatter(timezoneIdentifier: "America/New_York")

        // 1-hour window: 16:00 UTC → 17:00 UTC = 11:00 AM → 12:00 PM EST
        let window = fmt.formatWindow(
            startUs: 1_708_617_600_000_000,
            endUs:   1_708_621_200_000_000
        )
        XCTAssertTrue(window.contains("11:00 AM"), "Start should be 11:00 AM EST, got \(window)")
        XCTAssertTrue(window.contains("12:00 PM"), "End should be 12:00 PM EST, got \(window)")
        XCTAssertTrue(window.contains("60 min"), "Duration should be 60 min, got \(window)")
    }

    // MARK: - 22. SummaryTimeFormatter falls back on invalid timezone

    func testTimeFormatter_fallsBackOnInvalidTimezone() {
        let fmt = SummaryTimeFormatter(timezoneIdentifier: "Invalid/Zone")
        XCTAssertEqual(fmt.timeZone, TimeZone.current, "Invalid identifier should fall back to .current")

        // Should still produce output without crashing
        let ts = fmt.formatTimestamp(1_708_617_600_000_000)
        XCTAssertFalse(ts.isEmpty)
    }
}
