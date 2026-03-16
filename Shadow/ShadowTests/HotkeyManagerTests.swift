import XCTest
@testable import Shadow

final class HotkeyManagerTests: XCTestCase {

    /// HotkeyManager initializes with nil kill switch action.
    @MainActor
    func testInitialKillSwitchIsNil() {
        let manager = HotkeyManager()
        XCTAssertNil(manager.killSwitchAction)
    }

    /// Kill switch callback can be set.
    @MainActor
    func testKillSwitchCanBeSet() {
        let manager = HotkeyManager()
        var called = false
        manager.killSwitchAction = { called = true }
        manager.killSwitchAction?()
        XCTAssertTrue(called)
    }

    /// Unregister clears kill switch action.
    @MainActor
    func testUnregisterClearsKillSwitch() {
        let manager = HotkeyManager()
        manager.killSwitchAction = { }
        manager.register(action: { })
        manager.unregister()
        XCTAssertNil(manager.killSwitchAction)
    }

    /// Register sets up monitors without crashing.
    @MainActor
    func testRegisterDoesNotCrash() {
        let manager = HotkeyManager()
        manager.register(action: { })
        // Should not crash — just verify it runs
        manager.unregister()
    }
}
