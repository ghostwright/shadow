import XCTest
@testable import Shadow

final class BackgroundTaskManagerTests: XCTestCase {

    override func tearDown() async throws {
        await MainActor.run {
            BackgroundTaskManager.shared.exitBackground()
        }
        try await super.tearDown()
    }

    // MARK: - Initial State

    /// Manager starts inactive.
    @MainActor
    func testInitialState() {
        BackgroundTaskManager.shared.exitBackground()
        XCTAssertFalse(BackgroundTaskManager.shared.isBackgroundTaskActive)
        XCTAssertNil(BackgroundTaskManager.shared.statusIndicator)
    }

    // MARK: - Enter/Exit Background

    /// Enter background activates the manager and creates a status indicator.
    @MainActor
    func testEnterBackground() {
        BackgroundTaskManager.shared.enterBackground(task: "Compose email")

        XCTAssertTrue(BackgroundTaskManager.shared.isBackgroundTaskActive)
        XCTAssertNotNil(BackgroundTaskManager.shared.statusIndicator)
    }

    /// Exit background deactivates the manager and clears the indicator.
    @MainActor
    func testExitBackground() {
        BackgroundTaskManager.shared.enterBackground(task: "Test task")
        BackgroundTaskManager.shared.exitBackground()

        XCTAssertFalse(BackgroundTaskManager.shared.isBackgroundTaskActive)
    }

    /// Double enter is idempotent.
    @MainActor
    func testDoubleEnter() {
        BackgroundTaskManager.shared.enterBackground(task: "Task 1")
        BackgroundTaskManager.shared.enterBackground(task: "Task 2")

        // Should still be active (not error)
        XCTAssertTrue(BackgroundTaskManager.shared.isBackgroundTaskActive)
    }

    /// Double exit is safe.
    @MainActor
    func testDoubleExit() {
        BackgroundTaskManager.shared.enterBackground(task: "Test")
        BackgroundTaskManager.shared.exitBackground()
        BackgroundTaskManager.shared.exitBackground()

        XCTAssertFalse(BackgroundTaskManager.shared.isBackgroundTaskActive)
    }

    // MARK: - Complete/Fail

    /// Complete marks the task as done.
    @MainActor
    func testComplete() {
        BackgroundTaskManager.shared.enterBackground(task: "Test")
        BackgroundTaskManager.shared.complete(summary: "Done!")

        // After complete, no longer active
        XCTAssertFalse(BackgroundTaskManager.shared.isBackgroundTaskActive)
    }

    /// Fail marks the task as failed.
    @MainActor
    func testFail() {
        BackgroundTaskManager.shared.enterBackground(task: "Test")
        BackgroundTaskManager.shared.fail(error: "Network error")

        // After fail, no longer active
        XCTAssertFalse(BackgroundTaskManager.shared.isBackgroundTaskActive)
    }

    // MARK: - Callbacks

    /// onDismissPanel is called when entering background.
    @MainActor
    func testDismissPanelCallback() {
        var dismissCalled = false
        BackgroundTaskManager.shared.onDismissPanel = { dismissCalled = true }

        BackgroundTaskManager.shared.enterBackground(task: "Test")

        XCTAssertTrue(dismissCalled)

        // Cleanup
        BackgroundTaskManager.shared.onDismissPanel = nil
    }

    // MARK: - Unviewed Results

    /// No unviewed results initially.
    @MainActor
    func testNoUnviewedResultsInitially() {
        BackgroundTaskManager.shared.exitBackground()
        XCTAssertFalse(BackgroundTaskManager.shared.hasUnviewedResults)
    }

    /// Complete sets hasUnviewedResults.
    @MainActor
    func testCompleteMarksUnviewedResults() {
        BackgroundTaskManager.shared.enterBackground(task: "Test")
        BackgroundTaskManager.shared.complete(summary: "Done!")

        XCTAssertTrue(BackgroundTaskManager.shared.hasUnviewedResults)
    }

    /// Fail sets hasUnviewedResults.
    @MainActor
    func testFailMarksUnviewedResults() {
        BackgroundTaskManager.shared.enterBackground(task: "Test")
        BackgroundTaskManager.shared.fail(error: "Oops")

        XCTAssertTrue(BackgroundTaskManager.shared.hasUnviewedResults)
    }

    /// exitBackground clears hasUnviewedResults.
    @MainActor
    func testExitClearsUnviewedResults() {
        BackgroundTaskManager.shared.enterBackground(task: "Test")
        BackgroundTaskManager.shared.complete(summary: "Done!")
        XCTAssertTrue(BackgroundTaskManager.shared.hasUnviewedResults)

        BackgroundTaskManager.shared.exitBackground()
        XCTAssertFalse(BackgroundTaskManager.shared.hasUnviewedResults)
    }
}
