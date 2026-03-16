import XCTest
@preconcurrency import ApplicationServices
@testable import Shadow

final class ShadowElementTests: XCTestCase {

    // MARK: - Factory Methods

    /// application(pid:) creates a valid element for the current process.
    func testApplicationFactory() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let el = ShadowElement.application(pid: pid)
        // AXUIElementCreateApplication always succeeds (no AX call yet)
        XCTAssertNotNil(el.ref)
    }

    /// systemWide() creates the system-wide element.
    func testSystemWideFactory() {
        let el = ShadowElement.systemWide()
        XCTAssertNotNil(el.ref)
    }

    // MARK: - Equality

    /// Two elements for the same PID are equal (CFEqual).
    func testEqualityForSamePid() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let a = ShadowElement.application(pid: pid)
        let b = ShadowElement.application(pid: pid)
        XCTAssertEqual(a, b)
    }

    /// Two elements for different PIDs are not equal.
    func testInequalityForDifferentPids() {
        let a = ShadowElement.application(pid: 1)
        let b = ShadowElement.application(pid: 2)
        // PID 1 (launchd) and PID 2 are different applications
        XCTAssertNotEqual(a, b)
    }

    /// System-wide element is not equal to an application element.
    func testSystemWideNotEqualToApp() {
        let sysWide = ShadowElement.systemWide()
        let app = ShadowElement.application(pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotEqual(sysWide, app)
    }

    // MARK: - Hashing

    /// Same PID produces the same hash.
    func testHashConsistency() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let a = ShadowElement.application(pid: pid)
        let b = ShadowElement.application(pid: pid)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    /// cfHash is consistent with hashValue (both use CFHash).
    func testCfHashConsistency() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let a = ShadowElement.application(pid: pid)
        let b = ShadowElement.application(pid: pid)
        XCTAssertEqual(a.cfHash, b.cfHash)
    }

    /// Elements can be stored in a Set (Hashable conformance).
    func testSetStorage() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let a = ShadowElement.application(pid: pid)
        let b = ShadowElement.application(pid: pid)
        let c = ShadowElement.application(pid: 1)

        var set = Set<ShadowElement>()
        set.insert(a)
        set.insert(b)  // duplicate
        set.insert(c)

        // a and b are equal, so set should have 2 elements
        XCTAssertEqual(set.count, 2)
        XCTAssertTrue(set.contains(a))
        XCTAssertTrue(set.contains(c))
    }

    /// Elements can be used as Dictionary keys.
    func testDictionaryKey() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let el = ShadowElement.application(pid: pid)

        var dict: [ShadowElement: String] = [:]
        dict[el] = "test_app"
        XCTAssertEqual(dict[el], "test_app")
    }

    // MARK: - Sendable

    /// ShadowElement can be passed across concurrency boundaries.
    func testSendable() async {
        let pid = ProcessInfo.processInfo.processIdentifier
        let el = ShadowElement.application(pid: pid)

        // Pass to a Task and get it back (verifies Sendable)
        let returned = await Task.detached {
            return el
        }.value

        XCTAssertEqual(returned, el)
    }

    // MARK: - AXSearchResult

    /// AXSearchResult stores all its fields correctly.
    func testSearchResultFields() {
        let el = ShadowElement.application(pid: ProcessInfo.processInfo.processIdentifier)
        let result = AXSearchResult(
            element: el,
            confidence: 0.85,
            matchStrategy: "role+title",
            semanticDepth: 3,
            realDepth: 7
        )

        XCTAssertEqual(result.confidence, 0.85)
        XCTAssertEqual(result.matchStrategy, "role+title")
        XCTAssertEqual(result.semanticDepth, 3)
        XCTAssertEqual(result.realDepth, 7)
        XCTAssertEqual(result.element, el)
    }

    // MARK: - TreeWalkAction

    /// TreeWalkAction enum has all expected cases.
    func testTreeWalkActionCases() {
        let actions: [TreeWalkAction] = [.continue, .skipChildren, .stop]
        XCTAssertEqual(actions.count, 3)
    }
}
