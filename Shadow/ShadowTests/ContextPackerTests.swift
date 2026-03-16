import XCTest
@testable import Shadow

final class ContextPackerTests: XCTestCase {

    private var tempDir: String!
    private var store: ContextStore!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "ContextPackerTests_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        store = ContextStore(baseDir: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeEpisode(
        id: UUID = UUID(),
        startUs: UInt64,
        endUs: UInt64,
        summary: String = "Test episode",
        topics: [String] = ["coding"],
        apps: [String] = ["Xcode"]
    ) -> EpisodeRecord {
        EpisodeRecord(
            id: id,
            startUs: startUs,
            endUs: endUs,
            summary: summary,
            topicTags: topics,
            apps: apps,
            keyArtifacts: [],
            evidence: [
                ContextEvidence(timestamp: startUs, app: apps.first, sourceKind: "timeline", displayId: nil, url: nil, snippet: "test evidence")
            ],
            provenance: RecordProvenance(provider: "test", modelId: "test-model", generatedAt: Date(), inputHash: "abc123")
        )
    }

    private func makeDaily(
        date: String,
        summary: String = "Test day",
        wins: [String] = ["shipped feature"],
        openLoops: [String] = []
    ) -> DailyRecord {
        DailyRecord(
            date: date,
            summary: summary,
            wins: wins,
            openLoops: openLoops,
            meetingHighlights: [],
            focusBlocks: [],
            evidence: [
                ContextEvidence(timestamp: 1000000, app: "Xcode", sourceKind: "episode", displayId: nil, url: nil, snippet: "day evidence")
            ],
            provenance: RecordProvenance(provider: "test", modelId: "test-model", generatedAt: Date(), inputHash: "def456")
        )
    }

    private func makeWeekly(
        weekId: String,
        summary: String = "Test week",
        themes: [String] = ["development"]
    ) -> WeeklyRecord {
        WeeklyRecord(
            weekId: weekId,
            summary: summary,
            majorThemes: themes,
            carryOverItems: [],
            behaviorPatterns: [],
            evidence: [
                ContextEvidence(timestamp: 2000000, app: nil, sourceKind: "daily", displayId: nil, url: nil, snippet: "week evidence")
            ],
            provenance: RecordProvenance(provider: "test", modelId: "test-model", generatedAt: Date(), inputHash: "ghi789")
        )
    }

    // MARK: - Empty Pack

    func test_emptyStore_producesEmptyPack() {
        let pack = ContextPacker.pack(contextStore: store)
        XCTAssertTrue(pack.packText.isEmpty)
        XCTAssertTrue(pack.includedRecords.isEmpty)
        XCTAssertTrue(pack.rawEvidenceRefs.isEmpty)
        XCTAssertEqual(pack.estimatedTokens, 0)
        XCTAssertNil(pack.truncationSummary)
    }

    // MARK: - Determinism

    func test_sameRecords_produceSamePack() {
        let ep1 = makeEpisode(startUs: 100_000_000, endUs: 200_000_000, summary: "Worked on feature A")
        let ep2 = makeEpisode(startUs: 300_000_000, endUs: 400_000_000, summary: "Reviewed PR")
        store.saveEpisode(ep1)
        store.saveEpisode(ep2)

        let pack1 = ContextPacker.pack(contextStore: store, nowUs: 500_000_000)
        let pack2 = ContextPacker.pack(contextStore: store, nowUs: 500_000_000)

        XCTAssertEqual(pack1.packText, pack2.packText)
        XCTAssertEqual(pack1.includedRecords, pack2.includedRecords)
        XCTAssertEqual(pack1.estimatedTokens, pack2.estimatedTokens)
        XCTAssertEqual(pack1.truncationSummary, pack2.truncationSummary)
    }

    // MARK: - Record Inclusion

    func test_episodesIncluded() {
        let ep = makeEpisode(startUs: 1_000_000, endUs: 2_000_000, summary: "Coding session")
        store.saveEpisode(ep)

        let pack = ContextPacker.pack(contextStore: store)
        XCTAssertTrue(pack.packText.contains("Coding session"))
        XCTAssertEqual(pack.includedRecords.count, 1)
        XCTAssertEqual(pack.includedRecords[0].layer, .episode)
        XCTAssertFalse(pack.rawEvidenceRefs.isEmpty)
    }

    func test_dailyIncluded() {
        let daily = makeDaily(date: "2026-02-21", summary: "Productive day on search features")
        store.saveDaily(daily)

        let pack = ContextPacker.pack(contextStore: store)
        XCTAssertTrue(pack.packText.contains("Productive day on search features"))
        XCTAssertEqual(pack.includedRecords.count, 1)
        XCTAssertEqual(pack.includedRecords[0].layer, .day)
    }

    func test_weeklyIncluded() {
        let weekly = makeWeekly(weekId: "2026-W08", summary: "Phase 4 development week")
        store.saveWeekly(weekly)

        let pack = ContextPacker.pack(contextStore: store)
        XCTAssertTrue(pack.packText.contains("Phase 4 development week"))
        XCTAssertEqual(pack.includedRecords.count, 1)
        XCTAssertEqual(pack.includedRecords[0].layer, .week)
    }

    func test_allLayersIncluded() {
        store.saveWeekly(makeWeekly(weekId: "2026-W08"))
        store.saveDaily(makeDaily(date: "2026-02-21"))
        store.saveEpisode(makeEpisode(startUs: 1_000_000, endUs: 2_000_000))

        let pack = ContextPacker.pack(contextStore: store)
        XCTAssertEqual(pack.includedRecords.count, 3)

        let layers = Set(pack.includedRecords.map(\.layer))
        XCTAssertTrue(layers.contains(.week))
        XCTAssertTrue(layers.contains(.day))
        XCTAssertTrue(layers.contains(.episode))
    }

    // MARK: - Budget Enforcement

    func test_budgetEnforcement_truncatesEpisodes() {
        // Create many episodes that exceed a small budget
        for i in 0..<20 {
            let ep = makeEpisode(
                startUs: UInt64(i) * 1_000_000,
                endUs: UInt64(i + 1) * 1_000_000,
                summary: "Episode \(i) with a moderately long summary that takes up space in the pack"
            )
            store.saveEpisode(ep)
        }

        let config = ContextPacker.Config(maxPackChars: 500, maxEpisodes: 20)
        let pack = ContextPacker.pack(contextStore: store, config: config)

        XCTAssertLessThanOrEqual(pack.packText.count, 500)
        XCTAssertNotNil(pack.truncationSummary)
        XCTAssertTrue(pack.includedRecords.count < 20, "Should not include all 20 episodes under tight budget")
    }

    func test_maxEpisodesRespected() {
        for i in 0..<10 {
            store.saveEpisode(makeEpisode(startUs: UInt64(i) * 1_000_000, endUs: UInt64(i + 1) * 1_000_000))
        }

        let config = ContextPacker.Config(maxEpisodes: 3)
        let pack = ContextPacker.pack(contextStore: store, config: config)

        let episodeRecords = pack.includedRecords.filter { $0.layer == .episode }
        XCTAssertLessThanOrEqual(episodeRecords.count, 3)
    }

    // MARK: - Evidence Refs

    func test_evidenceRefsCapped() {
        // Each episode contributes 1 evidence item; with many episodes, refs get capped
        for i in 0..<30 {
            store.saveEpisode(makeEpisode(startUs: UInt64(i) * 1_000_000, endUs: UInt64(i + 1) * 1_000_000))
        }

        let config = ContextPacker.Config(maxEpisodes: 30, maxEvidenceRefs: 5)
        let pack = ContextPacker.pack(contextStore: store, config: config)

        XCTAssertLessThanOrEqual(pack.rawEvidenceRefs.count, 5)
    }

    // MARK: - Truncation Summary

    func test_noTruncation_whenUnderBudget() {
        store.saveEpisode(makeEpisode(startUs: 1_000_000, endUs: 2_000_000, summary: "Short"))

        let pack = ContextPacker.pack(contextStore: store)
        XCTAssertNil(pack.truncationSummary)
    }

    func test_truncationSummary_containsDroppedInfo() {
        for i in 0..<10 {
            store.saveEpisode(makeEpisode(
                startUs: UInt64(i) * 1_000_000,
                endUs: UInt64(i + 1) * 1_000_000,
                summary: String(repeating: "x", count: 200)
            ))
        }

        let config = ContextPacker.Config(maxPackChars: 300, maxEpisodes: 10)
        let pack = ContextPacker.pack(contextStore: store, config: config)

        XCTAssertNotNil(pack.truncationSummary)
        XCTAssertTrue(pack.truncationSummary!.contains("Truncated"))
        XCTAssertTrue(pack.truncationSummary!.contains("episode:"))
    }

    // MARK: - Token Estimate

    func test_estimatedTokens_roughlyCorrect() {
        store.saveEpisode(makeEpisode(startUs: 1_000_000, endUs: 2_000_000, summary: String(repeating: "word ", count: 100)))

        let pack = ContextPacker.pack(contextStore: store)
        // 500 chars of "word " plus overhead ≈ ~150-200 tokens
        XCTAssertGreaterThan(pack.estimatedTokens, 0)
        XCTAssertEqual(pack.estimatedTokens, pack.packText.count / 4)
    }

    // MARK: - Pack Text Structure

    func test_packText_hasHeader() {
        store.saveEpisode(makeEpisode(startUs: 1_000_000, endUs: 2_000_000))

        let pack = ContextPacker.pack(contextStore: store)
        XCTAssertTrue(pack.packText.hasPrefix("--- User Context Memory ---"))
    }

    func test_packText_containsSectionLabels() {
        store.saveWeekly(makeWeekly(weekId: "2026-W08"))
        store.saveDaily(makeDaily(date: "2026-02-21"))
        store.saveEpisode(makeEpisode(startUs: 1_000_000, endUs: 2_000_000))

        let pack = ContextPacker.pack(contextStore: store)
        XCTAssertTrue(pack.packText.contains("[Week: 2026-W08]"))
        XCTAssertTrue(pack.packText.contains("[Day: 2026-02-21]"))
        XCTAssertTrue(pack.packText.contains("[Episode:"))
    }

    // MARK: - Hard Budget (header + separator overhead)

    func test_packText_neverExceedsMaxPackChars() {
        // Use a tight budget that leaves barely enough room for the header + one section.
        // Header = "--- User Context Memory ---\n" = 28 chars.
        // With budget 100, only ~72 chars available for section content + separators.
        for i in 0..<5 {
            store.saveEpisode(makeEpisode(
                startUs: UInt64(i) * 1_000_000,
                endUs: UInt64(i + 1) * 1_000_000,
                summary: "Summary episode \(i) padding text"
            ))
        }

        let config = ContextPacker.Config(maxPackChars: 100, maxEpisodes: 5)
        let pack = ContextPacker.pack(contextStore: store, config: config)

        XCTAssertLessThanOrEqual(pack.packText.count, 100,
            "packText.count (\(pack.packText.count)) must not exceed maxPackChars (100)")
        // Should have truncated some records
        XCTAssertNotNil(pack.truncationSummary)
    }

    // MARK: - Deterministic Ordering (timestamp tie-breaking)

    func test_tiedTimestamps_produceDeterministicOrder() {
        // Create episodes with identical startUs but different IDs.
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()

        let ep1 = makeEpisode(id: idA, startUs: 1_000_000, endUs: 2_000_000, summary: "Episode A")
        let ep2 = makeEpisode(id: idB, startUs: 1_000_000, endUs: 2_000_000, summary: "Episode B")
        let ep3 = makeEpisode(id: idC, startUs: 1_000_000, endUs: 2_000_000, summary: "Episode C")

        store.saveEpisode(ep1)
        store.saveEpisode(ep2)
        store.saveEpisode(ep3)

        // Pack multiple times — must be identical each time
        let pack1 = ContextPacker.pack(contextStore: store, nowUs: 5_000_000)
        let pack2 = ContextPacker.pack(contextStore: store, nowUs: 5_000_000)
        let pack3 = ContextPacker.pack(contextStore: store, nowUs: 5_000_000)

        XCTAssertEqual(pack1.packText, pack2.packText)
        XCTAssertEqual(pack2.packText, pack3.packText)
        XCTAssertEqual(pack1.includedRecords, pack2.includedRecords)
        XCTAssertEqual(pack2.includedRecords, pack3.includedRecords)

        // Verify all 3 episodes are included and in a consistent order
        let episodeRecords = pack1.includedRecords.filter { $0.layer == .episode }
        XCTAssertEqual(episodeRecords.count, 3)

        // Order should be ascending by UUID string (tie-breaker)
        let sortedIDs = [idA, idB, idC].map(\.uuidString).sorted()
        XCTAssertEqual(episodeRecords.map(\.id), sortedIDs)
    }
}
