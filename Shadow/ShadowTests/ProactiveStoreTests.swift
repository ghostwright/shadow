import XCTest
@testable import Shadow

final class ProactiveStoreTests: XCTestCase {

    private var tempDir: String!
    private var store: ProactiveStore!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "ProactiveStoreTests-\(UUID().uuidString)"
        store = ProactiveStore(baseDir: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Suggestions

    func testSaveSuggestionRoundTrip() {
        let suggestion = makeSuggestion(title: "Test Suggestion")
        store.saveSuggestion(suggestion)

        let loaded = store.findSuggestion(id: suggestion.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.title, "Test Suggestion")
        XCTAssertEqual(loaded?.confidence, 0.85)
        XCTAssertEqual(loaded?.decision, .pushNow)
    }

    func testListSuggestionsNewestFirst() {
        let s1 = makeSuggestion(title: "First", createdAt: Date(timeIntervalSince1970: 1000))
        let s2 = makeSuggestion(title: "Second", createdAt: Date(timeIntervalSince1970: 2000))
        let s3 = makeSuggestion(title: "Third", createdAt: Date(timeIntervalSince1970: 3000))

        store.saveSuggestion(s1)
        store.saveSuggestion(s2)
        store.saveSuggestion(s3)

        let list = store.listSuggestions()
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].title, "Third")
        XCTAssertEqual(list[1].title, "Second")
        XCTAssertEqual(list[2].title, "First")
    }

    func testUpdateSuggestionStatus() {
        let suggestion = makeSuggestion(title: "Updatable")
        store.saveSuggestion(suggestion)

        store.updateSuggestionStatus(id: suggestion.id, status: .dismissed)

        let loaded = store.findSuggestion(id: suggestion.id)
        XCTAssertEqual(loaded?.status, .dismissed)
    }

    func testOverwriteSameId() {
        var suggestion = makeSuggestion(title: "Original")
        store.saveSuggestion(suggestion)
        suggestion.status = .acted
        store.saveSuggestion(suggestion)

        let list = store.listSuggestions()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].status, .acted)
    }

    // MARK: - Feedback

    func testSaveFeedbackRoundTrip() {
        let fb = ProactiveFeedback(
            id: UUID(),
            suggestionId: UUID(),
            eventType: .thumbsUp,
            timestamp: Date(),
            foregroundApp: "Xcode",
            displayId: 1
        )
        store.saveFeedback(fb)

        let list = store.listFeedback()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].eventType, .thumbsUp)
        XCTAssertEqual(list[0].foregroundApp, "Xcode")
    }

    func testFeedbackForSuggestion() {
        let sId = UUID()
        let fb1 = ProactiveFeedback(id: UUID(), suggestionId: sId, eventType: .thumbsUp, timestamp: Date(), foregroundApp: nil, displayId: nil)
        let fb2 = ProactiveFeedback(id: UUID(), suggestionId: UUID(), eventType: .thumbsDown, timestamp: Date(), foregroundApp: nil, displayId: nil)
        store.saveFeedback(fb1)
        store.saveFeedback(fb2)

        let filtered = store.feedbackForSuggestion(id: sId)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].eventType, .thumbsUp)
    }

    // MARK: - Run Records

    func testSaveRunRecordRoundTrip() {
        var record = ProactiveRunRecord.start()
        record.complete(
            decision: .pushNow,
            confidence: 0.90,
            whyNow: "Meeting starts in 15 minutes",
            model: "claude-haiku-4-5-20251001"
        )
        store.saveRunRecord(record)

        let list = store.listRunRecords()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].status, .completed)
        XCTAssertEqual(list[0].decision, .pushNow)
        XCTAssertEqual(list[0].confidence, 0.90)
        XCTAssertNotNil(list[0].latencyMs)
    }

    func testRunRecordNewestFirst() {
        var r1 = ProactiveRunRecord(id: UUID(), startedAt: Date(timeIntervalSince1970: 1000), status: .completed, evidenceRefs: [], sourceRecordIds: [])
        r1.endedAt = Date(timeIntervalSince1970: 1001)
        var r2 = ProactiveRunRecord(id: UUID(), startedAt: Date(timeIntervalSince1970: 2000), status: .completed, evidenceRefs: [], sourceRecordIds: [])
        r2.endedAt = Date(timeIntervalSince1970: 2001)

        store.saveRunRecord(r1)
        store.saveRunRecord(r2)

        let list = store.listRunRecords()
        XCTAssertEqual(list.count, 2)
        XCTAssert(list[0].startedAt > list[1].startedAt, "Should be newest first")
    }

    func testRunRecordCapAt200() {
        for i in 0..<210 {
            var record = ProactiveRunRecord.start()
            // Override startedAt to ensure ordering
            record = ProactiveRunRecord(
                id: record.id,
                startedAt: Date(timeIntervalSince1970: Double(i)),
                status: .completed,
                evidenceRefs: [],
                sourceRecordIds: []
            )
            store.saveRunRecord(record)
        }

        let count = store.runRecordCount()
        XCTAssertEqual(count, 200, "Should cap at 200 records")
    }

    func testRunRecordOverwriteSameId() {
        var record = ProactiveRunRecord.start()
        store.saveRunRecord(record)

        record.complete(decision: .inboxOnly, confidence: 0.60, whyNow: "Updated", model: nil)
        store.saveRunRecord(record)

        let list = store.listRunRecords()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].status, .completed)
        XCTAssertEqual(list[0].decision, .inboxOnly)
    }

    func testRunRecordFailedState() {
        var record = ProactiveRunRecord.start()
        record.fail(error: "Provider unavailable")
        store.saveRunRecord(record)

        let loaded = store.listRunRecords().first
        XCTAssertEqual(loaded?.status, .failed)
        XCTAssertEqual(loaded?.errorSummary, "Provider unavailable")
        XCTAssertNotNil(loaded?.latencyMs)
    }

    func testRunRecordSkippedState() {
        var record = ProactiveRunRecord.start()
        record.skip(reason: "Change delta below threshold")
        store.saveRunRecord(record)

        let loaded = store.listRunRecords().first
        XCTAssertEqual(loaded?.status, .skipped)
        XCTAssertEqual(loaded?.errorSummary, "Change delta below threshold")
        XCTAssertEqual(loaded?.latencyMs, 0)
    }

    // MARK: - Persistence Across Instances

    func testPersistenceAcrossInstances() {
        let suggestion = makeSuggestion(title: "Persisted")
        store.saveSuggestion(suggestion)

        var record = ProactiveRunRecord.start()
        record.complete(decision: .drop, confidence: 0.40, whyNow: nil, model: nil)
        store.saveRunRecord(record)

        // Create a new store instance pointing to the same directory
        let store2 = ProactiveStore(baseDir: tempDir)
        let suggestions = store2.listSuggestions()
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].title, "Persisted")

        let records = store2.listRunRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].decision, .drop)
    }

    // MARK: - Helpers

    private func makeSuggestion(
        title: String,
        createdAt: Date = Date()
    ) -> ProactiveSuggestion {
        ProactiveSuggestion(
            id: UUID(),
            createdAt: createdAt,
            type: .followup,
            title: title,
            body: "Test body",
            whyNow: "You were just discussing this",
            confidence: 0.85,
            decision: .pushNow,
            evidence: [
                SuggestionEvidence(
                    timestamp: 1_700_000_000_000_000,
                    app: "Zoom",
                    sourceKind: "transcript",
                    displayId: 1,
                    url: nil,
                    snippet: "Discussed project timeline"
                ),
            ],
            sourceRecordIds: ["episode-1"],
            status: .active
        )
    }
}
