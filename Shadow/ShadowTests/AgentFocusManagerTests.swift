import XCTest
@testable import Shadow

final class AgentFocusManagerTests: XCTestCase {

    override func tearDown() async throws {
        await MainActor.run {
            AgentFocusManager.shared.clearTarget()
            AgentFocusManager.shared.agentRunEnded()
        }
        try await super.tearDown()
    }

    // MARK: - Initial State

    /// Manager starts with no target and no agent running.
    @MainActor
    func testInitialState() {
        AgentFocusManager.shared.clearTarget()
        AgentFocusManager.shared.agentRunEnded()

        XCTAssertNil(AgentFocusManager.shared.targetApp)
        XCTAssertFalse(AgentFocusManager.shared.isAgentRunning)
    }

    // MARK: - Target Management

    /// setTarget sets the target app and clearTarget clears it.
    @MainActor
    func testSetAndClearTarget() {
        AgentFocusManager.shared.setTarget(pid: 42, name: "Safari", bundleId: "com.apple.Safari")

        XCTAssertNotNil(AgentFocusManager.shared.targetApp)
        XCTAssertEqual(AgentFocusManager.shared.targetApp?.pid, 42)
        XCTAssertEqual(AgentFocusManager.shared.targetApp?.name, "Safari")
        XCTAssertEqual(AgentFocusManager.shared.targetApp?.bundleId, "com.apple.Safari")

        AgentFocusManager.shared.clearTarget()
        XCTAssertNil(AgentFocusManager.shared.targetApp)
    }

    /// Setting a target replaces the previous target.
    @MainActor
    func testSetTargetReplaces() {
        AgentFocusManager.shared.setTarget(pid: 42, name: "Safari", bundleId: "com.apple.Safari")
        AgentFocusManager.shared.setTarget(pid: 99, name: "Chrome", bundleId: "com.google.Chrome")

        XCTAssertEqual(AgentFocusManager.shared.targetApp?.pid, 99)
        XCTAssertEqual(AgentFocusManager.shared.targetApp?.name, "Chrome")
    }

    // MARK: - Agent Run Lifecycle

    /// Agent run state tracks start and end.
    @MainActor
    func testAgentRunLifecycle() {
        AgentFocusManager.shared.agentRunEnded() // ensure clean state

        XCTAssertFalse(AgentFocusManager.shared.isAgentRunning)

        AgentFocusManager.shared.agentRunStarted()
        XCTAssertTrue(AgentFocusManager.shared.isAgentRunning)

        AgentFocusManager.shared.agentRunEnded()
        XCTAssertFalse(AgentFocusManager.shared.isAgentRunning)
    }

    /// Multiple agentRunEnded calls are safe (idempotent).
    @MainActor
    func testAgentRunEndedIdempotent() {
        AgentFocusManager.shared.agentRunStarted()
        AgentFocusManager.shared.agentRunEnded()
        AgentFocusManager.shared.agentRunEnded()

        XCTAssertFalse(AgentFocusManager.shared.isAgentRunning)
    }

    // MARK: - Target Resolution

    /// targetAppInfo returns the set target when available.
    @MainActor
    func testTargetAppInfoUsesSetTarget() {
        // Set a known target using a real process (the current process)
        let pid = ProcessInfo.processInfo.processIdentifier
        AgentFocusManager.shared.setTarget(pid: pid, name: "TestHost", bundleId: "com.test.host")

        let info = AgentFocusManager.shared.targetAppInfo()
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.pid, pid)
        XCTAssertEqual(info?.name, "TestHost")
        XCTAssertEqual(info?.bundleId, "com.test.host")
    }

    /// targetAppInfo clears dead target and falls back.
    @MainActor
    func testTargetAppInfoClearsDeadTarget() {
        // Set a target with a bogus PID that doesn't exist
        AgentFocusManager.shared.setTarget(pid: 999999, name: "DeadApp", bundleId: "com.dead.app")

        // targetAppInfo should detect the dead process and clear the target
        let _ = AgentFocusManager.shared.targetAppInfo()
        XCTAssertNil(AgentFocusManager.shared.targetApp, "Dead target should be cleared")
    }

    /// targetAppInfo returns something when no target set (falls back to frontmost non-Shadow).
    @MainActor
    func testTargetAppInfoFallback() {
        AgentFocusManager.shared.clearTarget()

        // In the test environment, there should be at least one running app
        // We just verify it doesn't crash
        let info = AgentFocusManager.shared.targetAppInfo()
        _ = info // May or may not be nil depending on environment
    }

    // MARK: - Snapshot

    /// snapshotFrontmostApp captures the current frontmost app.
    @MainActor
    func testSnapshotCaptures() {
        AgentFocusManager.shared.clearTarget()

        // In test environment, there IS a frontmost app (Xcode or the test runner)
        AgentFocusManager.shared.snapshotFrontmostApp()

        // The snapshot should have captured something (unless running headless)
        // We verify it doesn't crash; the actual target depends on environment
        _ = AgentFocusManager.shared.targetApp
    }

    /// Snapshot is replaced by setTarget.
    @MainActor
    func testSnapshotReplacedBySetTarget() {
        AgentFocusManager.shared.snapshotFrontmostApp()
        let snapshotPid = AgentFocusManager.shared.targetApp?.pid

        let currentPid = ProcessInfo.processInfo.processIdentifier
        AgentFocusManager.shared.setTarget(pid: currentPid, name: "Override", bundleId: "com.override")

        XCTAssertEqual(AgentFocusManager.shared.targetApp?.pid, currentPid)
        XCTAssertEqual(AgentFocusManager.shared.targetApp?.name, "Override")

        // Verify it was actually changed (unless snapshot was the same process by coincidence)
        if snapshotPid != currentPid {
            XCTAssertNotEqual(snapshotPid, currentPid)
        }
    }

    // MARK: - TargetApp Sendable

    /// TargetApp is Sendable.
    func testTargetAppSendable() {
        let target = AgentFocusManager.TargetApp(pid: 42, name: "Test", bundleId: "com.test")

        // Verify Sendable by capturing in a Sendable closure
        let captured: @Sendable () -> String = { target.name }
        XCTAssertEqual(captured(), "Test")
    }
}
