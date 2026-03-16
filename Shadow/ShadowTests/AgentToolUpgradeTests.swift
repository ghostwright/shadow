import XCTest
@testable import Shadow

/// Thread-safe box for capturing values in @Sendable closures.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Helper to build a SearchResult with audio fields.
private func makeSearchResult(
    ts: UInt64 = 1_000_000,
    app: String = "Safari",
    title: String = "Page",
    sourceKind: String = "transcript",
    matchReason: String = "text",
    snippet: String = "hello world",
    audioSource: String = "mic",
    audioSegmentId: Int64? = 42,
    tsEnd: UInt64 = 2_000_000,
    confidence: Float? = 0.9,
    displayId: UInt32? = 1
) -> SearchResult {
    SearchResult(
        ts: ts, appName: app, windowTitle: title, url: "",
        displayId: displayId, eventType: "transcript_chunk",
        score: 0.8, matchReason: matchReason, sourceKind: sourceKind,
        snippet: snippet, audioSegmentId: audioSegmentId,
        audioSource: audioSource, tsEnd: tsEnd, confidence: confidence
    )
}

/// Helper to build a MeetingSummary for testing.
private func makeSummary(
    id: String = "sum-1",
    title: String = "Weekly Standup",
    summary: String = "We discussed sprint progress and blockers.",
    keyPoints: [String] = ["Sprint on track", "Blocker: API latency"],
    actionItems: [ActionItem] = [
        ActionItem(description: "Fix API latency", owner: "John", dueDateText: "Friday", evidenceTimestamps: []),
        ActionItem(description: "Update docs", owner: nil, dueDateText: nil, evidenceTimestamps: []),
    ],
    decisions: [String] = ["Use caching for API calls"]
) -> MeetingSummary {
    MeetingSummary(
        id: id, title: title, summary: summary,
        keyPoints: keyPoints, decisions: decisions,
        actionItems: actionItems, openQuestions: [],
        highlights: [],
        metadata: SummaryMetadata(
            provider: "cloud_claude", modelId: "claude-sonnet-4-6",
            generatedAt: Date(), inputHash: "abc123",
            sourceWindow: SourceWindow(
                startUs: 1_000_000, endUs: 5_000_000,
                timezone: "America/New_York", sessionId: nil
            ),
            inputTokenEstimate: 1000
        )
    )
}

// MARK: - search_hybrid Upgrade Tests

final class SearchHybridUpgradeTests: XCTestCase {

    // 1. Time range params route to rangeSearcher
    func testSearchHybrid_timeRangeCallsRangeSearcher() async throws {
        let rangeSearcherCalled = Box(false)
        let capturedStart = Box<UInt64>(0)
        let capturedEnd = Box<UInt64>(0)

        let tool = AgentTools.searchHybridTool(
            searcher: { @Sendable _, _ in
                XCTFail("Default searcher should not be called when time range provided")
                return []
            },
            rangeSearcher: { @Sendable _, startUs, endUs, _ in
                rangeSearcherCalled.value = true
                capturedStart.value = startUs
                capturedEnd.value = endUs
                return [makeSearchResult()]
            },
            indexer: { 0 }
        )

        let _ = try await tool.handler!([
            "query": .string("meeting notes"),
            "startUs": .int(1_000_000),
            "endUs": .int(5_000_000),
        ])

        XCTAssertTrue(rangeSearcherCalled.value)
        XCTAssertEqual(capturedStart.value, 1_000_000)
        XCTAssertEqual(capturedEnd.value, 5_000_000)
    }

    // 2. No time range uses default searcher
    func testSearchHybrid_noTimeRangeCallsDefaultSearcher() async throws {
        let defaultSearcherCalled = Box(false)

        let tool = AgentTools.searchHybridTool(
            searcher: { @Sendable _, _ in
                defaultSearcherCalled.value = true
                return [makeSearchResult()]
            },
            rangeSearcher: { @Sendable _, _, _, _ in
                XCTFail("Range searcher should not be called without time range")
                return []
            },
            indexer: { 0 }
        )

        let _ = try await tool.handler!(["query": .string("hello")])
        XCTAssertTrue(defaultSearcherCalled.value)
    }

    // 3. Output includes audio fields
    func testSearchHybrid_outputIncludesAudioFields() async throws {
        let tool = AgentTools.searchHybridTool(
            searcher: { @Sendable _, _ in
                [makeSearchResult(
                    audioSource: "system",
                    audioSegmentId: 99,
                    tsEnd: 3_000_000,
                    confidence: 0.85
                )]
            },
            rangeSearcher: { @Sendable _, _, _, _ in [] },
            indexer: { 0 }
        )

        let output = try await tool.handler!(["query": .string("test")])
        XCTAssertTrue(output.contains("\"audioSource\":\"system\""))
        XCTAssertTrue(output.contains("\"audioSegmentId\":99"))
        XCTAssertTrue(output.contains("\"tsEnd\":3000000"))
        XCTAssertTrue(output.contains("\"confidence\""))
    }

    // 4. Partial time range throws
    func testSearchHybrid_partialTimeRangeThrows() async {
        let tool = AgentTools.searchHybridTool(
            searcher: { @Sendable _, _ in [] },
            rangeSearcher: { @Sendable _, _, _, _ in [] },
            indexer: { 0 }
        )

        do {
            let _ = try await tool.handler!([
                "query": .string("test"),
                "startUs": .int(1_000_000),
                // endUs missing
            ])
            XCTFail("Should throw for partial time range")
        } catch let error as ToolError {
            XCTAssertTrue(error.errorDescription?.contains("endUs") == true)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// MARK: - resolve_latest_meeting Upgrade Tests

final class ResolveLatestMeetingUpgradeTests: XCTestCase {

    // 5. Explicit startUs/endUs passed through to resolver
    func testResolveLatestMeeting_wiresStartUsEndUs() async throws {
        let capturedStart = Box<UInt64>(0)
        let capturedEnd = Box<UInt64>(0)

        let tool = AgentTools.resolveLatestMeetingTool(
            resolver: { @Sendable startUs, endUs in
                capturedStart.value = startUs
                capturedEnd.value = endUs
                return []
            }
        )

        let _ = try await tool.handler!([
            "startUs": .int(1_000_000),
            "endUs": .int(5_000_000),
        ])

        XCTAssertEqual(capturedStart.value, 1_000_000)
        XCTAssertEqual(capturedEnd.value, 5_000_000)
    }

    // 6. lookbackHours converted to startUs/endUs correctly
    func testResolveLatestMeeting_wiresLookbackHours() async throws {
        let capturedStart = Box<UInt64>(0)
        let capturedEnd = Box<UInt64>(0)

        let tool = AgentTools.resolveLatestMeetingTool(
            resolver: { @Sendable startUs, endUs in
                capturedStart.value = startUs
                capturedEnd.value = endUs
                return []
            }
        )

        let _ = try await tool.handler!(["lookbackHours": .int(6)])

        // endUs should be close to now
        let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let sixHoursUs: UInt64 = 6 * 3600 * 1_000_000

        // Allow 2 seconds of drift for test execution time
        XCTAssertTrue(capturedEnd.value > nowUs - 2_000_000)
        XCTAssertTrue(capturedEnd.value <= nowUs + 2_000_000)

        // startUs should be ~6 hours before endUs
        let expectedStart = capturedEnd.value - sixHoursUs
        XCTAssertTrue(capturedStart.value > expectedStart - 2_000_000)
        XCTAssertTrue(capturedStart.value <= expectedStart + 2_000_000)
    }

    // 7. Default lookback is 24h when no params provided
    func testResolveLatestMeeting_defaultLookback24h() async throws {
        let capturedStart = Box<UInt64>(0)
        let capturedEnd = Box<UInt64>(0)

        let tool = AgentTools.resolveLatestMeetingTool(
            resolver: { @Sendable startUs, endUs in
                capturedStart.value = startUs
                capturedEnd.value = endUs
                return []
            }
        )

        let _ = try await tool.handler!([:])

        let twentyFourHoursUs: UInt64 = 24 * 3600 * 1_000_000
        let span = capturedEnd.value - capturedStart.value

        // Allow 2 seconds of drift
        XCTAssertTrue(span > twentyFourHoursUs - 2_000_000)
        XCTAssertTrue(span <= twentyFourHoursUs + 2_000_000)
    }
}

// MARK: - search_summaries Enrichment Tests

final class SearchSummariesEnrichmentTests: XCTestCase {

    // 8. Output includes keyPoints and counts
    func testSearchSummaries_includesKeyPointsAndCounts() async throws {
        let tmpDir = NSTemporaryDirectory() + "shadow-test-summaries-\(UUID().uuidString)"
        let store = SummaryStore(directory: tmpDir)
        try store.save(makeSummary(title: "Sprint Review"))
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let tool = AgentTools.searchSummariesTool(store: store)
        let output = try await tool.handler!(["query": .string("Sprint")])

        XCTAssertTrue(output.contains("\"keyPoints\""))
        XCTAssertTrue(output.contains("Sprint on track"))
        XCTAssertTrue(output.contains("\"actionItemCount\":2"))
        XCTAssertTrue(output.contains("\"decisionCount\":1"))
    }

    // 9. Small summaries inline action items
    func testSearchSummaries_smallSummary_inlinesActionItems() async throws {
        let tmpDir = NSTemporaryDirectory() + "shadow-test-summaries-\(UUID().uuidString)"
        let store = SummaryStore(directory: tmpDir)
        try store.save(makeSummary(title: "Quick Sync"))
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let tool = AgentTools.searchSummariesTool(store: store)
        let output = try await tool.handler!(["query": .string("Quick")])

        // 2 action items (<=5) should be inlined
        XCTAssertTrue(output.contains("\"actionItems\""))
        XCTAssertTrue(output.contains("Fix API latency"))
        XCTAssertTrue(output.contains("\"owner\":\"John\""))
    }
}

// MARK: - MeetingResolver Tests

final class MeetingResolverAudioOverlapTests: XCTestCase {

    // 10. Audio overlap detection — overlapping mic+system segments produce a meeting window
    //     Overlap must be ≥2 minutes (120_000_000 µs) to pass the minimum duration filter.
    func testAudioOverlap_detectsMeeting() {
        let mic = [AudioSegment(
            segmentId: 1, source: "mic",
            startTs: 1_000_000, endTs: 600_000_000,  // 10 min mic segment
            filePath: "/tmp/mic.wav", displayId: nil,
            sampleRate: 16000, channels: 1
        )]
        let system = [AudioSegment(
            segmentId: 2, source: "system",
            startTs: 60_000_000, endTs: 480_000_000,  // 7 min system segment, starts 1 min in
            filePath: "/tmp/sys.wav", displayId: nil,
            sampleRate: 16000, channels: 1
        )]

        let windows = MeetingResolver.findAudioOverlaps(mic: mic, system: system)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].startUs, 60_000_000)   // max of starts
        XCTAssertEqual(windows[0].endUs, 480_000_000)    // min of ends
        XCTAssertTrue(windows[0].isAudioOverlap)
    }

    // 11. Short overlap (<2min) filtered out
    func testAudioOverlap_shortOverlap_filtered() {
        let mic = [AudioSegment(
            segmentId: 1, source: "mic",
            startTs: 1_000_000, endTs: 2_500_000,  // 1.5 seconds
            filePath: "/tmp/mic.wav", displayId: nil,
            sampleRate: 16000, channels: 1
        )]
        let system = [AudioSegment(
            segmentId: 2, source: "system",
            startTs: 1_000_000, endTs: 2_500_000,  // 1.5 seconds overlap
            filePath: "/tmp/sys.wav", displayId: nil,
            sampleRate: 16000, channels: 1
        )]

        let windows = MeetingResolver.findAudioOverlaps(mic: mic, system: system)
        XCTAssertTrue(windows.isEmpty, "Overlap < 2 minutes should be filtered")
    }

    // 12. No overlap when segments don't intersect
    func testAudioOverlap_noOverlap() {
        let mic = [AudioSegment(
            segmentId: 1, source: "mic",
            startTs: 1_000_000, endTs: 5_000_000,
            filePath: "/tmp/mic.wav", displayId: nil,
            sampleRate: 16000, channels: 1
        )]
        let system = [AudioSegment(
            segmentId: 2, source: "system",
            startTs: 10_000_000, endTs: 20_000_000,  // no overlap
            filePath: "/tmp/sys.wav", displayId: nil,
            sampleRate: 16000, channels: 1
        )]

        let windows = MeetingResolver.findAudioOverlaps(mic: mic, system: system)
        XCTAssertTrue(windows.isEmpty)
    }

    // 13. Audio overlap windows merge across different apps (meeting continuity)
    func testMergeNearbyWindows_audioOverlap_mergesFreely() {
        let windows: [MeetingResolver.MeetingWindow] = [
            .init(startUs: 100_000_000, endUs: 400_000_000, app: "Zoom", isAudioOverlap: true),
            .init(startUs: 410_000_000, endUs: 700_000_000, app: "Chrome", isAudioOverlap: true),
        ]
        // Gap is 10M µs (~10s) — well within 2-min merge gap
        let merged = MeetingResolver.mergeNearbyWindows(windows)

        XCTAssertEqual(merged.count, 1, "Audio overlap windows should merge freely regardless of app")
        XCTAssertEqual(merged[0].startUs, 100_000_000)
        XCTAssertEqual(merged[0].endUs, 700_000_000)
        XCTAssertTrue(merged[0].isAudioOverlap)
    }

    // 14. App-detected windows with same app merge (brief tab-out)
    func testMergeNearbyWindows_appDetected_sameApp_merges() {
        let windows: [MeetingResolver.MeetingWindow] = [
            .init(startUs: 100_000_000, endUs: 400_000_000, app: "zoom.us", isAudioOverlap: false),
            .init(startUs: 410_000_000, endUs: 700_000_000, app: "zoom.us", isAudioOverlap: false),
        ]
        let merged = MeetingResolver.mergeNearbyWindows(windows)

        XCTAssertEqual(merged.count, 1, "Same-app fallback windows should merge")
        XCTAssertEqual(merged[0].startUs, 100_000_000)
        XCTAssertEqual(merged[0].endUs, 700_000_000)
    }

    // 15. App-detected windows with different apps stay separate
    func testMergeNearbyWindows_appDetected_differentApps_noMerge() {
        let windows: [MeetingResolver.MeetingWindow] = [
            .init(startUs: 100_000_000, endUs: 400_000_000, app: "zoom.us", isAudioOverlap: false),
            .init(startUs: 410_000_000, endUs: 700_000_000, app: "Microsoft Teams", isAudioOverlap: false),
        ]
        let merged = MeetingResolver.mergeNearbyWindows(windows)

        XCTAssertEqual(merged.count, 2, "Different-app fallback windows should NOT merge")
        XCTAssertEqual(merged[0].app, "zoom.us")
        XCTAssertEqual(merged[1].app, "Microsoft Teams")
    }

    // 16. Mixed: audio overlap window merges with nearby app-detected window
    func testMergeNearbyWindows_audioAndApp_merges() {
        let windows: [MeetingResolver.MeetingWindow] = [
            .init(startUs: 100_000_000, endUs: 400_000_000, app: "audio_overlap", isAudioOverlap: true),
            .init(startUs: 410_000_000, endUs: 500_000_000, app: "zoom.us", isAudioOverlap: false),
        ]
        let merged = MeetingResolver.mergeNearbyWindows(windows)

        XCTAssertEqual(merged.count, 1, "Audio overlap window should absorb nearby app window")
        XCTAssertTrue(merged[0].isAudioOverlap)
        XCTAssertEqual(merged[0].endUs, 500_000_000)
    }
}
