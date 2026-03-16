import XCTest
@testable import Shadow

// MARK: - Summary Schema Validation Tests

final class MeetingSummaryTests: XCTestCase {

    private func makeMetadata(windowStart: UInt64 = 0, windowEnd: UInt64 = 100_000_000) -> SummaryMetadata {
        SummaryMetadata(
            provider: "test",
            modelId: "test-model",
            generatedAt: Date(),
            inputHash: "abc123",
            sourceWindow: SourceWindow(
                startUs: windowStart,
                endUs: windowEnd,
                timezone: "UTC",
                sessionId: nil
            ),
            inputTokenEstimate: 500
        )
    }

    private func makeValidSummary(
        title: String = "Weekly Standup",
        summary: String = "The team discussed Q3 progress and identified blockers.",
        keyPoints: [String] = ["Q3 progress review"],
        highlights: [TimestampedHighlight] = [],
        metadata: SummaryMetadata? = nil
    ) -> MeetingSummary {
        MeetingSummary(
            id: UUID().uuidString,
            title: title,
            summary: summary,
            keyPoints: keyPoints,
            decisions: ["Ship by Friday"],
            actionItems: [
                ActionItem(
                    description: "Update documentation",
                    owner: "Alice",
                    dueDateText: "by Friday",
                    evidenceTimestamps: [50_000_000]
                )
            ],
            openQuestions: ["What about the budget?"],
            highlights: highlights,
            metadata: metadata ?? makeMetadata()
        )
    }

    // MARK: - 1. Valid summary passes validation

    func testValidSummary_passesValidation() {
        let summary = makeValidSummary()
        let errors = summary.validate()
        XCTAssertTrue(errors.isEmpty, "Valid summary should have no errors, got: \(errors)")
    }

    // MARK: - 2. Empty title rejected

    func testEmptyTitle_rejected() {
        let summary = makeValidSummary(title: "")
        let errors = summary.validate()
        XCTAssertTrue(errors.contains(.emptyTitle))
    }

    func testWhitespaceTitle_rejected() {
        let summary = makeValidSummary(title: "   \n  ")
        let errors = summary.validate()
        XCTAssertTrue(errors.contains(.emptyTitle))
    }

    func testTitleTooLong_rejected() {
        let longTitle = String(repeating: "A", count: 201)
        let summary = makeValidSummary(title: longTitle)
        let errors = summary.validate()
        XCTAssertTrue(errors.contains(.titleTooLong(maxLength: 200)))
    }

    // MARK: - 3. Missing key points rejected

    func testMissingKeyPoints_rejected() {
        let summary = makeValidSummary(keyPoints: [])
        let errors = summary.validate()
        XCTAssertTrue(errors.contains(.noKeyPoints))
    }

    // MARK: - 4. Highlight outside window rejected

    func testHighlightOutsideWindow_rejected() {
        let meta = makeMetadata(windowStart: 100_000, windowEnd: 200_000)
        let highlights = [
            TimestampedHighlight(text: "Notable moment", tsStart: 50_000, tsEnd: 60_000)
        ]
        let summary = makeValidSummary(highlights: highlights, metadata: meta)
        let errors = summary.validate()
        XCTAssertTrue(errors.contains(where: {
            if case .highlightOutsideWindow(let index, _, _, _) = $0, index == 0 { return true }
            return false
        }))
    }

    func testHighlightInsideWindow_accepted() {
        let meta = makeMetadata(windowStart: 100_000, windowEnd: 200_000)
        let highlights = [
            TimestampedHighlight(text: "Notable moment", tsStart: 150_000, tsEnd: 160_000)
        ]
        let summary = makeValidSummary(highlights: highlights, metadata: meta)
        let errors = summary.validate()
        // Should not contain any highlight errors
        XCTAssertFalse(errors.contains(where: {
            if case .highlightOutsideWindow = $0 { return true }
            return false
        }))
    }

    // MARK: - 5. Empty action item description rejected

    func testEmptyActionItemDescription_rejected() {
        let summary = MeetingSummary(
            id: UUID().uuidString,
            title: "Test",
            summary: "Test summary",
            keyPoints: ["Point"],
            decisions: [],
            actionItems: [
                ActionItem(description: "", owner: nil, dueDateText: nil, evidenceTimestamps: []),
                ActionItem(description: "Valid task", owner: nil, dueDateText: nil, evidenceTimestamps: [])
            ],
            openQuestions: [],
            highlights: [],
            metadata: makeMetadata()
        )
        let errors = summary.validate()
        XCTAssertTrue(errors.contains(.emptyActionItemDescription(index: 0)))
    }

    // MARK: - 6. Input hash computation

    func testInputHash_deterministic() {
        let text = "Hello, world! This is a test transcript."
        let hash1 = computeInputHash(text)
        let hash2 = computeInputHash(text)
        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1.count, 64) // SHA256 hex = 64 chars
    }

    func testInputHash_differentForDifferentInput() {
        let hash1 = computeInputHash("Meeting transcript A")
        let hash2 = computeInputHash("Meeting transcript B")
        XCTAssertNotEqual(hash1, hash2)
    }

    // MARK: - 7. Summary Codable roundtrip

    func testSummary_codableRoundtrip() throws {
        let original = makeValidSummary()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingSummary.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.summary, original.summary)
        XCTAssertEqual(decoded.keyPoints, original.keyPoints)
        XCTAssertEqual(decoded.decisions, original.decisions)
        XCTAssertEqual(decoded.actionItems.count, original.actionItems.count)
        XCTAssertEqual(decoded.metadata.provider, original.metadata.provider)
        XCTAssertEqual(decoded.metadata.sourceWindow.startUs, original.metadata.sourceWindow.startUs)
    }

    // MARK: - 8. Summary store persistence

    func testSummaryStore_saveAndLoad() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-summaries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = SummaryStore(directory: tmpDir.path)
        let summary = makeValidSummary()

        try store.save(summary)

        let loaded = store.load(id: summary.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, summary.id)
        XCTAssertEqual(loaded?.title, summary.title)
    }

    func testSummaryStore_listAll() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-summaries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = SummaryStore(directory: tmpDir.path)

        let s1 = makeValidSummary(title: "Meeting 1")
        let s2 = makeValidSummary(title: "Meeting 2")
        try store.save(s1)
        try store.save(s2)

        let all = store.listAll()
        XCTAssertEqual(all.count, 2)
    }

    func testSummaryStore_delete() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-test-summaries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = SummaryStore(directory: tmpDir.path)
        let summary = makeValidSummary()
        try store.save(summary)

        XCTAssertNotNil(store.load(id: summary.id))
        XCTAssertTrue(store.delete(id: summary.id))
        XCTAssertNil(store.load(id: summary.id))
    }

    // MARK: - 9. Timestamp format includes absolute microseconds (Fix 4)

    func testTimestampFormat_includesAbsoluteMicroseconds() {
        let baseTs: UInt64 = 1_708_300_000_000_000  // some Unix microsecond timestamp
        let chunk = TranscriptChunkResult(
            tsStart: baseTs + 5_000_000,  // +5 seconds
            tsEnd: baseTs + 10_000_000,
            text: "Hello everyone",
            audioSource: "mic",
            confidence: 0.95,
            appName: "Zoom",
            windowTitle: "Meeting",
            audioSegmentId: 1
        )
        let formatted = MeetingInputAssembler.formatTranscript([chunk], baseTimestamp: baseTs)

        // Should contain the relative timestamp [00:00:05]
        XCTAssertTrue(formatted.contains("[00:00:05"), "Missing relative timestamp")
        // Should contain the absolute microsecond value after @
        XCTAssertTrue(formatted.contains("@\(baseTs + 5_000_000)"), "Missing absolute microsecond timestamp")
        // Should contain the source
        XCTAssertTrue(formatted.contains("(mic)"), "Missing source label")
        // Should contain the text
        XCTAssertTrue(formatted.contains("Hello everyone"), "Missing transcript text")
    }

    // MARK: - 10. Deduplication

    func testDeduplication() {
        let baseTs: UInt64 = 1_708_300_000_000_000
        let chunks = [
            TranscriptChunkResult(
                tsStart: baseTs,
                tsEnd: baseTs + 2_000_000,
                text: "Hello everyone",
                audioSource: "mic",
                confidence: 0.9,
                appName: "Zoom",
                windowTitle: "Meeting",
                audioSegmentId: 1
            ),
            // Duplicate — same text within 1s
            TranscriptChunkResult(
                tsStart: baseTs + 500_000,  // 0.5s later
                tsEnd: baseTs + 2_500_000,
                text: "Hello everyone",
                audioSource: "mic",
                confidence: 0.85,
                appName: "Zoom",
                windowTitle: "Meeting",
                audioSegmentId: 1
            ),
            // Different text — should be kept
            TranscriptChunkResult(
                tsStart: baseTs + 3_000_000,
                tsEnd: baseTs + 5_000_000,
                text: "Let's get started",
                audioSource: "mic",
                confidence: 0.9,
                appName: "Zoom",
                windowTitle: "Meeting",
                audioSegmentId: 1
            ),
        ]
        let deduped = MeetingInputAssembler.deduplicateChunks(chunks)
        XCTAssertEqual(deduped.count, 2, "Duplicate chunk should be removed")
        XCTAssertEqual(deduped[0].text, "Hello everyone")
        XCTAssertEqual(deduped[1].text, "Let's get started")
    }

    // MARK: - 11. Single pass for short transcript

    func testSinglePass_shortTranscript() {
        // Short transcript: well under 5000 tokens (~20k chars)
        let transcript = "[00:00:05 @1708300005000000] (mic) Hello everyone\n[00:00:30 @1708300030000000] (mic) Let's discuss the roadmap"
        let window = SourceWindow(startUs: 1708300000000000, endUs: 1708300060000000, timezone: "UTC", sessionId: nil)

        let plan = SummaryPromptBuilder.buildRequest(transcript: transcript, sourceWindow: window)
        switch plan {
        case .singlePass:
            break  // expected
        case .mapReduce:
            XCTFail("Short transcript should produce a single-pass plan")
        }
    }

    // MARK: - 12. Map-reduce for long transcript

    func testMapReduce_longTranscript() {
        // Generate a long transcript that exceeds 5000 tokens (~20k chars)
        var lines: [String] = []
        let baseTs: UInt64 = 1_708_300_000_000_000
        for i in 0..<500 {
            let ts = baseTs + UInt64(i) * 5_000_000
            lines.append("[00:\(String(format: "%02d", i / 60)):\(String(format: "%02d", i % 60)) @\(ts)] (mic) This is line number \(i) of the meeting transcript with some extra text to make it longer and more realistic")
        }
        let transcript = lines.joined(separator: "\n")
        let window = SourceWindow(startUs: baseTs, endUs: baseTs + 2500_000_000, timezone: "UTC", sessionId: nil)

        let plan = SummaryPromptBuilder.buildRequest(transcript: transcript, sourceWindow: window)
        switch plan {
        case .singlePass:
            XCTFail("Long transcript should produce a map-reduce plan")
        case .mapReduce(let mapRequests, _):
            XCTAssertTrue(mapRequests.count > 1, "Map-reduce should have more than 1 map request, got \(mapRequests.count)")
        }
    }
}
