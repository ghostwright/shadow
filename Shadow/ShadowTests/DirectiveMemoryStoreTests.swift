import XCTest
@testable import Shadow

/// Thread-safe box for capturing values in @Sendable closures during tests.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class DirectiveMemoryStoreTests: XCTestCase {

    // MARK: - Directive Type

    /// Directive is Identifiable via its id.
    func testIdentifiable() {
        let d = makeDirective(id: "dir-1")
        XCTAssertEqual(d.id, "dir-1")
    }

    /// Directive is Equatable.
    func testEquatable() {
        let d1 = makeDirective(id: "dir-1", trigger: "opens Slack")
        let d2 = makeDirective(id: "dir-1", trigger: "opens Slack")
        XCTAssertEqual(d1, d2)
    }

    /// Directive round-trips through Codable.
    func testCodableRoundTrip() throws {
        let d = makeDirective(id: "dir-test", trigger: "after 2h focus", action: "Suggest break")
        let data = try JSONEncoder().encode(d)
        let decoded = try JSONDecoder().decode(Directive.self, from: data)
        XCTAssertEqual(d, decoded)
    }

    // MARK: - Save

    /// Save calls the upsert function with correct parameters.
    func testSaveCallsUpsert() throws {
        let captured = Box<(String, String, String, String, Int32, UInt64, UInt64?, String)?>(nil)

        let upsertFn: DirectiveMemoryStore.UpsertFn = { id, dirType, trigger, action, priority, created, expires, ctx in
            captured.value = (id, dirType, trigger, action, priority, created, expires, ctx)
        }

        let d = makeDirective(
            id: "dir-1", directiveType: "reminder",
            trigger: "opens Slack", action: "Check standup",
            priority: 7, expiresAt: 9000000, sourceContext: "user asked"
        )
        try DirectiveMemoryStore.save(d, upsertFn: upsertFn)

        XCTAssertNotNil(captured.value)
        XCTAssertEqual(captured.value?.0, "dir-1")
        XCTAssertEqual(captured.value?.1, "reminder")
        XCTAssertEqual(captured.value?.2, "opens Slack")
        XCTAssertEqual(captured.value?.3, "Check standup")
        XCTAssertEqual(captured.value?.4, 7)
        XCTAssertEqual(captured.value?.6, 9000000)
        XCTAssertEqual(captured.value?.7, "user asked")
    }

    /// Save propagates errors from the upsert function.
    func testSavePropagatesError() {
        let upsertFn: DirectiveMemoryStore.UpsertFn = { _, _, _, _, _, _, _, _ in
            throw TestError.simulated
        }

        let d = makeDirective(id: "dir-test")
        XCTAssertThrowsError(try DirectiveMemoryStore.save(d, upsertFn: upsertFn))
    }

    // MARK: - Query Active

    /// Query returns mapped records.
    func testQueryActiveReturns() throws {
        let queryFn: DirectiveMemoryStore.QueryActiveFn = { _, _ in
            [
                DirectiveRecord(
                    id: "dir-1", directiveType: "reminder",
                    triggerPattern: "opens Slack", actionDescription: "Check standup",
                    priority: 5, createdAt: 1000000, expiresAt: nil,
                    isActive: true, executionCount: 2, lastTriggeredAt: 1500000,
                    sourceContext: "test"
                )
            ]
        }

        let results = try DirectiveMemoryStore.queryActive(queryFn: queryFn)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "dir-1")
        XCTAssertEqual(results[0].directiveType, "reminder")
        XCTAssertEqual(results[0].triggerPattern, "opens Slack")
        XCTAssertEqual(results[0].actionDescription, "Check standup")
        XCTAssertTrue(results[0].isActive)
        XCTAssertEqual(results[0].executionCount, 2)
        XCTAssertEqual(results[0].lastTriggeredAt, 1500000)
    }

    /// Query passes nowUs and limit correctly.
    func testQueryActivePassesParameters() throws {
        let capturedNowUs = Box<UInt64?>(nil)
        let capturedLimit = Box<UInt32?>(nil)

        let queryFn: DirectiveMemoryStore.QueryActiveFn = { nowUs, lim in
            capturedNowUs.value = nowUs
            capturedLimit.value = lim
            return []
        }

        _ = try DirectiveMemoryStore.queryActive(nowUs: 5000000, limit: 15, queryFn: queryFn)
        XCTAssertEqual(capturedNowUs.value, 5000000)
        XCTAssertEqual(capturedLimit.value, 15)
    }

    // MARK: - Record Trigger

    /// RecordTrigger calls function with correct ID and timestamp.
    func testRecordTriggerCallsFunction() throws {
        let capturedId = Box<String?>(nil)
        let capturedNowUs = Box<UInt64?>(nil)

        let triggerFn: DirectiveMemoryStore.RecordTriggerFn = { id, nowUs in
            capturedId.value = id
            capturedNowUs.value = nowUs
        }

        try DirectiveMemoryStore.recordTrigger(id: "dir-1", nowUs: 3000000, triggerFn: triggerFn)
        XCTAssertEqual(capturedId.value, "dir-1")
        XCTAssertEqual(capturedNowUs.value, 3000000)
    }

    // MARK: - Deactivate

    /// Deactivate calls function with correct ID.
    func testDeactivateCallsFunction() throws {
        let capturedId = Box<String?>(nil)

        let deactivateFn: DirectiveMemoryStore.DeactivateFn = { id in
            capturedId.value = id
        }

        try DirectiveMemoryStore.deactivate(id: "dir-1", deactivateFn: deactivateFn)
        XCTAssertEqual(capturedId.value, "dir-1")
    }

    // MARK: - Delete

    /// Delete calls function with correct ID.
    func testDeleteCallsFunction() throws {
        let capturedId = Box<String?>(nil)

        let deleteFn: DirectiveMemoryStore.DeleteFn = { id in
            capturedId.value = id
        }

        try DirectiveMemoryStore.delete(id: "dir-1", deleteFn: deleteFn)
        XCTAssertEqual(capturedId.value, "dir-1")
    }

    // MARK: - Trigger Matching

    /// Matching finds directive when app name matches trigger pattern.
    func testMatchingByAppName() throws {
        let queryFn: DirectiveMemoryStore.QueryActiveFn = { _, _ in
            [
                DirectiveRecord(
                    id: "dir-1", directiveType: "reminder",
                    triggerPattern: "slack", actionDescription: "Check standup",
                    priority: 5, createdAt: 1000000, expiresAt: nil,
                    isActive: true, executionCount: 0, lastTriggeredAt: nil,
                    sourceContext: "test"
                )
            ]
        }

        let matches = try DirectiveMemoryStore.matchingDirectives(
            app: "Slack",
            windowTitle: nil,
            url: nil,
            queryFn: queryFn
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].id, "dir-1")
    }

    /// Matching finds directive when window title matches trigger.
    func testMatchingByWindowTitle() throws {
        let queryFn: DirectiveMemoryStore.QueryActiveFn = { _, _ in
            [
                DirectiveRecord(
                    id: "dir-1", directiveType: "watch",
                    triggerPattern: "pull request", actionDescription: "Review PR",
                    priority: 5, createdAt: 1000000, expiresAt: nil,
                    isActive: true, executionCount: 0, lastTriggeredAt: nil,
                    sourceContext: "test"
                )
            ]
        }

        let matches = try DirectiveMemoryStore.matchingDirectives(
            app: "Chrome",
            windowTitle: "Pull Request #42",
            url: nil,
            queryFn: queryFn
        )
        XCTAssertEqual(matches.count, 1)
    }

    /// No match when trigger pattern doesn't match.
    func testMatchingNoMatch() throws {
        let queryFn: DirectiveMemoryStore.QueryActiveFn = { _, _ in
            [
                DirectiveRecord(
                    id: "dir-1", directiveType: "reminder",
                    triggerPattern: "opens figma", actionDescription: "Check designs",
                    priority: 5, createdAt: 1000000, expiresAt: nil,
                    isActive: true, executionCount: 0, lastTriggeredAt: nil,
                    sourceContext: "test"
                )
            ]
        }

        let matches = try DirectiveMemoryStore.matchingDirectives(
            app: "VS Code",
            windowTitle: "main.swift",
            url: nil,
            queryFn: queryFn
        )
        XCTAssertTrue(matches.isEmpty)
    }

    /// Matching is case-insensitive.
    func testMatchingCaseInsensitive() throws {
        let queryFn: DirectiveMemoryStore.QueryActiveFn = { _, _ in
            [
                DirectiveRecord(
                    id: "dir-1", directiveType: "reminder",
                    triggerPattern: "SAFARI", actionDescription: "Check email",
                    priority: 5, createdAt: 1000000, expiresAt: nil,
                    isActive: true, executionCount: 0, lastTriggeredAt: nil,
                    sourceContext: "test"
                )
            ]
        }

        let matches = try DirectiveMemoryStore.matchingDirectives(
            app: "safari",
            windowTitle: nil,
            url: nil,
            queryFn: queryFn
        )
        XCTAssertEqual(matches.count, 1)
    }

    // MARK: - Helpers

    private func makeDirective(
        id: String = "dir-test",
        directiveType: String = "reminder",
        trigger: String = "test trigger",
        action: String = "test action",
        priority: Int32 = 5,
        expiresAt: UInt64? = nil,
        sourceContext: String = "test"
    ) -> Directive {
        Directive(
            id: id,
            directiveType: directiveType,
            triggerPattern: trigger,
            actionDescription: action,
            priority: priority,
            createdAt: 1000000,
            expiresAt: expiresAt,
            isActive: true,
            executionCount: 0,
            lastTriggeredAt: nil,
            sourceContext: sourceContext
        )
    }

    private enum TestError: Error {
        case simulated
    }
}
