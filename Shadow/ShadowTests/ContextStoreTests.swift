import XCTest
@testable import Shadow

final class ContextStoreTests: XCTestCase {

    private var tempDir: String!
    private var store: ContextStore!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "ContextStoreTests-\(UUID().uuidString)"
        store = ContextStore(baseDir: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Episodes

    func testSaveEpisodeRoundTrip() {
        let episode = makeEpisode(summary: "Built search feature")
        store.saveEpisode(episode)

        let loaded = store.findEpisode(id: episode.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.summary, "Built search feature")
        XCTAssertEqual(loaded?.topicTags, ["search", "ui"])
    }

    func testListEpisodesNewestFirst() {
        let e1 = makeEpisode(summary: "First", startUs: 1_000_000, endUs: 2_000_000)
        let e2 = makeEpisode(summary: "Second", startUs: 3_000_000, endUs: 4_000_000)

        store.saveEpisode(e1)
        store.saveEpisode(e2)

        let list = store.listEpisodes()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].summary, "Second")
        XCTAssertEqual(list[1].summary, "First")
    }

    func testEpisodesInRange() {
        let e1 = makeEpisode(summary: "A", startUs: 100, endUs: 200)
        let e2 = makeEpisode(summary: "B", startUs: 300, endUs: 400)
        let e3 = makeEpisode(summary: "C", startUs: 500, endUs: 600)

        store.saveEpisode(e1)
        store.saveEpisode(e2)
        store.saveEpisode(e3)

        let inRange = store.episodesInRange(startUs: 250, endUs: 450)
        XCTAssertEqual(inRange.count, 1)
        XCTAssertEqual(inRange[0].summary, "B")
    }

    // MARK: - Daily Records

    func testSaveDailyRoundTrip() {
        let daily = makeDaily(date: "2026-02-22")
        store.saveDaily(daily)

        let loaded = store.findDaily(date: "2026-02-22")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.summary, "Productive day")
    }

    func testListDailiesDescending() {
        store.saveDaily(makeDaily(date: "2026-02-20"))
        store.saveDaily(makeDaily(date: "2026-02-22"))
        store.saveDaily(makeDaily(date: "2026-02-21"))

        let list = store.listDailies()
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].date, "2026-02-22")
        XCTAssertEqual(list[1].date, "2026-02-21")
        XCTAssertEqual(list[2].date, "2026-02-20")
    }

    // MARK: - Weekly Records

    func testSaveWeeklyRoundTrip() {
        let weekly = makeWeekly(weekId: "2026-W08")
        store.saveWeekly(weekly)

        let loaded = store.findWeekly(weekId: "2026-W08")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.summary, "Focused on search features")
    }

    func testListWeekliesDescending() {
        store.saveWeekly(makeWeekly(weekId: "2026-W06"))
        store.saveWeekly(makeWeekly(weekId: "2026-W08"))
        store.saveWeekly(makeWeekly(weekId: "2026-W07"))

        let list = store.listWeeklies()
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].weekId, "2026-W08")
    }

    // MARK: - Checkpoint

    func testCheckpointRoundTrip() {
        var cp = HeartbeatCheckpoint.empty
        cp.lastEpisodeEndUs = 5_000_000
        cp.lastDailyDate = "2026-02-22"
        cp.lastHeartbeatAt = Date(timeIntervalSince1970: 1_700_000_000)
        cp.consecutiveFailures = 2

        store.saveCheckpoint(cp)

        let loaded = store.loadCheckpoint()
        XCTAssertEqual(loaded.lastEpisodeEndUs, 5_000_000)
        XCTAssertEqual(loaded.lastDailyDate, "2026-02-22")
        XCTAssertEqual(loaded.consecutiveFailures, 2)
    }

    func testCheckpointDefaultsWhenMissing() {
        let cp = store.loadCheckpoint()
        XCTAssertNil(cp.lastEpisodeEndUs)
        XCTAssertNil(cp.lastDailyDate)
        XCTAssertEqual(cp.consecutiveFailures, 0)
    }

    func testCheckpointPersistenceAcrossInstances() {
        var cp = HeartbeatCheckpoint.empty
        cp.lastEpisodeEndUs = 123_456
        store.saveCheckpoint(cp)

        let store2 = ContextStore(baseDir: tempDir)
        let loaded = store2.loadCheckpoint()
        XCTAssertEqual(loaded.lastEpisodeEndUs, 123_456)
    }

    // MARK: - Persistence Across Instances

    func testEpisodePersistenceAcrossInstances() {
        let episode = makeEpisode(summary: "Persisted episode")
        store.saveEpisode(episode)

        let store2 = ContextStore(baseDir: tempDir)
        let loaded = store2.findEpisode(id: episode.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.summary, "Persisted episode")
    }

    // MARK: - Helpers

    private func makeEpisode(
        summary: String,
        startUs: UInt64 = 1_000_000,
        endUs: UInt64 = 2_000_000
    ) -> EpisodeRecord {
        EpisodeRecord(
            id: UUID(),
            startUs: startUs,
            endUs: endUs,
            summary: summary,
            topicTags: ["search", "ui"],
            apps: ["Xcode", "Chrome"],
            keyArtifacts: ["SearchViewModel.swift"],
            evidence: [
                ContextEvidence(
                    timestamp: startUs,
                    app: "Xcode",
                    sourceKind: "app_switch",
                    displayId: 1,
                    url: nil,
                    snippet: "Opened search file"
                ),
            ],
            provenance: RecordProvenance(
                provider: "anthropic",
                modelId: "claude-haiku-4-5-20251001",
                generatedAt: Date(),
                inputHash: "abc123"
            )
        )
    }

    private func makeDaily(date: String) -> DailyRecord {
        DailyRecord(
            date: date,
            summary: "Productive day",
            wins: ["Shipped feature"],
            openLoops: ["Fix test"],
            meetingHighlights: ["Design review"],
            focusBlocks: [
                FocusBlock(app: "Xcode", startUs: 1_000_000, endUs: 5_000_000, durationMinutes: 66),
            ],
            evidence: [],
            provenance: RecordProvenance(
                provider: "anthropic",
                modelId: "claude-haiku-4-5-20251001",
                generatedAt: Date(),
                inputHash: "daily123"
            )
        )
    }

    private func makeWeekly(weekId: String) -> WeeklyRecord {
        WeeklyRecord(
            weekId: weekId,
            summary: "Focused on search features",
            majorThemes: ["search", "performance"],
            carryOverItems: ["Audio playback"],
            behaviorPatterns: ["Deep focus mornings"],
            evidence: [],
            provenance: RecordProvenance(
                provider: "anthropic",
                modelId: "claude-haiku-4-5-20251001",
                generatedAt: Date(),
                inputHash: "week123"
            )
        )
    }
}
