import XCTest
import os
@testable import Shadow

final class ContextHeartbeatTests: XCTestCase {

    private var tempDir: String!
    private var contextStore: ContextStore!
    private var proactiveStore: ProactiveStore!
    private var trustTuner: TrustTuner!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "ContextHeartbeatTests-\(UUID().uuidString)"
        contextStore = ContextStore(baseDir: tempDir + "/context")
        proactiveStore = ProactiveStore(baseDir: tempDir + "/proactive")
        trustTuner = TrustTuner(baseDir: tempDir + "/trust")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - ContextSynthesizer Tests

    func testComputeHashIsDeterministic() {
        let hash1 = ContextSynthesizer.computeHash("hello world")
        let hash2 = ContextSynthesizer.computeHash("hello world")
        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1.count, 64)  // SHA256 hex
    }

    func testComputeHashDiffersForDifferentInput() {
        let hash1 = ContextSynthesizer.computeHash("hello world")
        let hash2 = ContextSynthesizer.computeHash("goodbye world")
        XCTAssertNotEqual(hash1, hash2)
    }

    func testFormatEpisodeContextWithEvents() {
        let events = [
            Self.makeTimelineEntry(ts: 1000000, app: "Xcode", title: "MyProject"),
            Self.makeTimelineEntry(ts: 2000000, app: "Safari", title: "Docs"),
        ]
        let context = ContextSynthesizer.formatEpisodeContext(
            events: events,
            chunks: [],
            startUs: 1000000
        )
        XCTAssertTrue(context.contains("Timeline Events"))
        XCTAssertTrue(context.contains("Xcode"))
        XCTAssertTrue(context.contains("Safari"))
    }

    func testFormatEpisodeContextWithTranscripts() {
        let chunks = [Self.makeTranscriptChunk(ts: 5000000, text: "Hello everyone", source: "mic")]
        let context = ContextSynthesizer.formatEpisodeContext(
            events: [],
            chunks: chunks,
            startUs: 5000000
        )
        XCTAssertTrue(context.contains("Transcript"))
        XCTAssertTrue(context.contains("Hello everyone"))
        XCTAssertTrue(context.contains("(mic)"))
    }

    func testFormatEpisodeContextEmpty() {
        let context = ContextSynthesizer.formatEpisodeContext(events: [], chunks: [], startUs: 0)
        XCTAssertTrue(context.isEmpty)
    }

    func testFormatDailyContext() {
        let blocks = Self.makeActivityBlocks(eventCount: 150, apps: ["Xcode", "Safari"])
        let episodes = [Self.makeEpisode(summary: "Code review session", tags: ["code review"])]
        let context = ContextSynthesizer.formatDailyContext(
            date: "2026-02-22",
            activityBlocks: blocks,
            episodes: episodes
        )
        XCTAssertTrue(context.contains("Xcode"))
        XCTAssertTrue(context.contains("Code review session"))
    }

    func testParseEpisodeResponseValid() throws {
        let json = """
        {
          "summary": "User worked on code review in Xcode",
          "topicTags": ["code review", "swift"],
          "apps": ["Xcode", "Safari"],
          "keyArtifacts": ["MyProject.swift"],
          "evidence": [
            {"timestamp": 1000000, "app": "Xcode", "sourceKind": "timeline", "snippet": "Opened file"}
          ]
        }
        """
        let response = LLMResponse(
            content: json,
            toolCalls: [],
            provider: "cloud_claude",
            modelId: "claude-sonnet-4-6",
            inputTokens: 100,
            outputTokens: 50,
            latencyMs: 500
        )

        let episode = try ContextSynthesizer.parseEpisodeResponse(
            response,
            startUs: 1000000,
            endUs: 2000000,
            inputHash: "abc123"
        )

        XCTAssertEqual(episode.summary, "User worked on code review in Xcode")
        XCTAssertEqual(episode.topicTags, ["code review", "swift"])
        XCTAssertEqual(episode.apps, ["Xcode", "Safari"])
        XCTAssertEqual(episode.keyArtifacts, ["MyProject.swift"])
        XCTAssertEqual(episode.evidence.count, 1)
        XCTAssertEqual(episode.provenance.provider, "cloud_claude")
        XCTAssertEqual(episode.provenance.inputHash, "abc123")
    }

    func testParseEpisodeResponseEmptySummaryThrows() {
        let json = """
        {"summary": "", "topicTags": [], "apps": [], "keyArtifacts": [], "evidence": []}
        """
        let response = LLMResponse(
            content: json, toolCalls: [], provider: "test", modelId: "test",
            inputTokens: nil, outputTokens: nil, latencyMs: 0
        )

        XCTAssertThrowsError(try ContextSynthesizer.parseEpisodeResponse(
            response, startUs: 0, endUs: 0, inputHash: ""
        ))
    }

    func testParseEpisodeResponseStripsMarkdown() throws {
        let json = """
        ```json
        {"summary": "Test episode", "topicTags": [], "apps": [], "keyArtifacts": [], "evidence": []}
        ```
        """
        let response = LLMResponse(
            content: json, toolCalls: [], provider: "test", modelId: "test",
            inputTokens: nil, outputTokens: nil, latencyMs: 0
        )

        let episode = try ContextSynthesizer.parseEpisodeResponse(
            response, startUs: 0, endUs: 0, inputHash: ""
        )
        XCTAssertEqual(episode.summary, "Test episode")
    }

    func testParseDailyResponseValid() throws {
        let json = """
        {
          "summary": "Productive day focused on Shadow development",
          "wins": ["Completed Phase 4 Slice 2"],
          "openLoops": ["Audio sync issue"],
          "meetingHighlights": [],
          "focusBlocks": [],
          "evidence": []
        }
        """
        let response = LLMResponse(
            content: json, toolCalls: [], provider: "cloud_claude", modelId: "test",
            inputTokens: nil, outputTokens: nil, latencyMs: 0
        )

        let daily = try ContextSynthesizer.parseDailyResponse(
            response, date: "2026-02-22", inputHash: "xyz"
        )

        XCTAssertEqual(daily.date, "2026-02-22")
        XCTAssertEqual(daily.summary, "Productive day focused on Shadow development")
        XCTAssertEqual(daily.wins, ["Completed Phase 4 Slice 2"])
        XCTAssertEqual(daily.openLoops, ["Audio sync issue"])
    }

    func testParseDailyResponseEmptySummaryThrows() {
        let json = """
        {"summary": "", "wins": [], "openLoops": [], "meetingHighlights": [], "focusBlocks": [], "evidence": []}
        """
        let response = LLMResponse(
            content: json, toolCalls: [], provider: "test", modelId: "test",
            inputTokens: nil, outputTokens: nil, latencyMs: 0
        )

        XCTAssertThrowsError(try ContextSynthesizer.parseDailyResponse(
            response, date: "2026-02-22", inputHash: ""
        ))
    }

    // MARK: - ContextHeartbeat Trigger Tests

    func testShouldSkipWhenNoEvents() async {
        // Pre-seed daily so only episode gate matters
        var cp0 = HeartbeatCheckpoint.empty
        cp0.lastDailyDate = Self.yesterdayString()
        contextStore.saveCheckpoint(cp0)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: Self.failingGenerate,
            queryTimeRangeFn: { _, _ in [] },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        await heartbeat.tickForTest()

        let checkpoint = contextStore.loadCheckpoint()
        XCTAssertNil(checkpoint.lastEpisodeEndUs, "Should not advance checkpoint when skipped")
    }

    func testShouldSynthesizeEpisodeWhenEnoughEvents() async {
        var cp0 = HeartbeatCheckpoint.empty
        cp0.lastDailyDate = Self.yesterdayString()
        contextStore.saveCheckpoint(cp0)

        let events = Self.make20Events()
        let synthesizeCalled = OSAllocatedUnfairLock(initialState: false)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { request in
                synthesizeCalled.withLock { $0 = true }
                return LLMResponse(
                    content: """
                    {"summary":"Test episode","topicTags":["test"],"apps":["Xcode"],"keyArtifacts":[],"evidence":[]}
                    """,
                    toolCalls: [],
                    provider: "test",
                    modelId: "test",
                    inputTokens: nil,
                    outputTokens: nil,
                    latencyMs: 100
                )
            },
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        await heartbeat.tickForTest()

        XCTAssertTrue(synthesizeCalled.withLock { $0 }, "Should call LLM when enough events")

        let episodes = contextStore.listEpisodes()
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes.first?.summary, "Test episode")

        let records = proactiveStore.listRunRecords()
        XCTAssertEqual(records.first?.status, .completed)
    }

    func testBackoffOnFailure() async {
        var cp0 = HeartbeatCheckpoint.empty
        cp0.lastDailyDate = Self.yesterdayString()
        contextStore.saveCheckpoint(cp0)

        let events = Self.make20Events()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { _ in
                callCount.withLock { $0 += 1 }
                throw LLMProviderError.transientFailure(underlying: "test error")
            },
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        await heartbeat.tickForTest()
        let checkpoint = contextStore.loadCheckpoint()
        XCTAssertEqual(checkpoint.consecutiveFailures, 1, "Should increment failure count")

        let records = proactiveStore.listRunRecords()
        XCTAssertEqual(records.first?.status, .failed)
    }

    func testCheckpointAdvancesOnSuccess() async {
        var cp0 = HeartbeatCheckpoint.empty
        cp0.lastDailyDate = Self.yesterdayString()
        contextStore.saveCheckpoint(cp0)

        let events = Self.make20Events()

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { _ in
                LLMResponse(
                    content: """
                    {"summary":"Test","topicTags":[],"apps":[],"keyArtifacts":[],"evidence":[]}
                    """,
                    toolCalls: [],
                    provider: "test",
                    modelId: "test",
                    inputTokens: nil,
                    outputTokens: nil,
                    latencyMs: 0
                )
            },
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        await heartbeat.tickForTest()

        let checkpoint = contextStore.loadCheckpoint()
        XCTAssertNotNil(checkpoint.lastEpisodeEndUs, "Checkpoint should advance after success")
        XCTAssertEqual(checkpoint.consecutiveFailures, 0)
    }

    func testConsecutiveFailuresResetOnSuccess() async {
        var cp = HeartbeatCheckpoint.empty
        cp.consecutiveFailures = 3
        cp.lastDailyDate = Self.yesterdayString()
        contextStore.saveCheckpoint(cp)

        let events = Self.make20Events()

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { _ in
                LLMResponse(
                    content: """
                    {"summary":"Success","topicTags":[],"apps":[],"keyArtifacts":[],"evidence":[]}
                    """,
                    toolCalls: [],
                    provider: "test",
                    modelId: "test",
                    inputTokens: nil,
                    outputTokens: nil,
                    latencyMs: 0
                )
            },
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        await heartbeat.tickForTest()

        let updatedCp = contextStore.loadCheckpoint()
        XCTAssertEqual(updatedCp.consecutiveFailures, 0, "Failures should reset on success")
    }

    func testEpisodesForDateExtension() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let todayStr = formatter.string(from: now)

        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        let noonUs = UInt64(noon.timeIntervalSince1970 * 1_000_000)

        let episode = EpisodeRecord(
            id: UUID(),
            startUs: noonUs,
            endUs: noonUs + 3600_000_000,
            summary: "Test episode",
            topicTags: ["test"],
            apps: ["Xcode"],
            keyArtifacts: [],
            evidence: [],
            provenance: RecordProvenance(
                provider: "test",
                modelId: "test",
                generatedAt: now,
                inputHash: "abc"
            )
        )
        contextStore.saveEpisode(episode)

        let todayEpisodes = contextStore.episodesForDate(todayStr)
        XCTAssertEqual(todayEpisodes.count, 1)
        XCTAssertEqual(todayEpisodes.first?.summary, "Test episode")

        let yesterdayStr = formatter.string(from: Calendar.current.date(byAdding: .day, value: -1, to: now)!)
        let yesterdayEpisodes = contextStore.episodesForDate(yesterdayStr)
        XCTAssertTrue(yesterdayEpisodes.isEmpty)
    }

    func testRunRecordLifecycleComplete() {
        var record = ProactiveRunRecord.start()
        XCTAssertEqual(record.status, .running)
        XCTAssertNil(record.endedAt)

        record.complete(
            decision: .inboxOnly,
            confidence: 0.9,
            whyNow: "Episode",
            model: "test"
        )
        XCTAssertEqual(record.status, .completed)
        XCTAssertNotNil(record.endedAt)
        XCTAssertNotNil(record.latencyMs)
    }

    func testRunRecordLifecycleFail() {
        var record = ProactiveRunRecord.start()
        record.fail(error: "LLM unavailable")
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.errorSummary, "LLM unavailable")
    }

    func testRunRecordLifecycleSkip() {
        var record = ProactiveRunRecord.start()
        record.skip(reason: "Not enough events")
        XCTAssertEqual(record.status, .skipped)
        XCTAssertEqual(record.latencyMs, 0)
    }

    // MARK: - Stabilization Tests (Fix 7)

    /// Fix 1: Cooldown does not permanently block subsequent ticks.
    /// Two ticks with enough events and sufficient gap should both produce episodes.
    func testCooldownAllowsSecondTickAfterInterval() async {
        let events = Self.make20Events()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        // Pre-seed lastDailyDate so daily synthesis doesn't fire (isolate episode behavior)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let yesterday = formatter.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        var cp0 = HeartbeatCheckpoint.empty
        cp0.lastDailyDate = yesterday
        cp0.lastAnalyzerRunAt = Date()  // Suppress analyzer (isolate episode behavior)
        contextStore.saveCheckpoint(cp0)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { _ in
                callCount.withLock { $0 += 1 }
                return Self.successResponse(summary: "Episode")
            },
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        // First tick
        await heartbeat.tickForTest()
        XCTAssertEqual(callCount.withLock { $0 }, 1, "First tick should synthesize")

        // Simulate cooldown elapsed by backdating lastEpisodeSynthesisAt
        var cp = contextStore.loadCheckpoint()
        cp.lastEpisodeSynthesisAt = Date().addingTimeInterval(-ContextHeartbeat.episodeCooldownSeconds - 1)
        cp.lastEpisodeEndUs = nil  // Reset so delta gate passes again
        cp.lastAnalyzerRunAt = Date()  // Keep analyzer suppressed
        contextStore.saveCheckpoint(cp)

        // Second tick
        await heartbeat.tickForTest()
        XCTAssertEqual(callCount.withLock { $0 }, 2, "Second tick after cooldown should also synthesize")
    }

    /// Fix 1: Episode cooldown suppresses synthesis within the window.
    func testEpisodeCooldownSuppressesSynthesis() async {
        let events = Self.make20Events()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        // Pre-seed checkpoint as if episode just completed + daily already done + analyzer just ran
        var cp = HeartbeatCheckpoint.empty
        cp.lastEpisodeSynthesisAt = Date()  // Just now
        cp.lastEpisodeEndUs = 100           // Has a prior episode
        cp.lastDailyDate = Self.yesterdayString()  // Suppress daily synthesis
        cp.lastAnalyzerRunAt = Date()       // Suppress fallback analyzer
        cp.lastDeepAnalyzerRunAt = Date()   // Suppress deep tick
        contextStore.saveCheckpoint(cp)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { _ in
                callCount.withLock { $0 += 1 }
                return Self.successResponse(summary: "Should not run")
            },
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        await heartbeat.tickForTest()
        XCTAssertEqual(callCount.withLock { $0 }, 0, "Should not synthesize during cooldown")

        // Run record should be skipped
        let records = proactiveStore.listRunRecords()
        XCTAssertEqual(records.first?.status, .skipped)
    }

    /// Fix 5: Backoff skip path emits a skipped run record.
    func testBackoffSkipEmitsRunRecord() async {
        // Pre-seed checkpoint with failure + recent failure timestamp
        var cp = HeartbeatCheckpoint.empty
        cp.consecutiveFailures = 2
        cp.lastFailureAt = Date()  // Just now — within backoff window
        contextStore.saveCheckpoint(cp)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: Self.failingGenerate,
            queryTimeRangeFn: { _, _ in [] },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        await heartbeat.tickForTest()

        let records = proactiveStore.listRunRecords()
        XCTAssertEqual(records.count, 1, "Backoff tick should produce a run record")
        XCTAssertEqual(records.first?.status, .skipped)
        XCTAssertTrue(records.first?.errorSummary?.contains("Backoff") == true)
    }

    /// Fix 6: Provider unavailability produces skipped run, not failed run.
    func testProviderUnavailableSkipsNotFails() async {
        let events = Self.make20Events()

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: Self.failingGenerate,  // Should never be called
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] },
            isProviderAvailable: { false }
        )

        await heartbeat.tickForTest()

        let checkpoint = contextStore.loadCheckpoint()
        XCTAssertEqual(checkpoint.consecutiveFailures, 0, "Provider skip should not count as failure")

        let records = proactiveStore.listRunRecords()
        XCTAssertEqual(records.first?.status, .skipped)
        XCTAssertTrue(records.first?.errorSummary?.contains("provider") == true)
    }

    /// Fix 2: Negative timestamp in evidence JSON is rejected.
    func testNegativeTimestampEvidenceRejected() throws {
        let json = """
        {
          "summary": "Test episode",
          "topicTags": [],
          "apps": [],
          "keyArtifacts": [],
          "evidence": [
            {"timestamp": -1, "app": "Xcode", "sourceKind": "timeline", "snippet": "Bad"}
          ]
        }
        """
        let response = LLMResponse(
            content: json, toolCalls: [], provider: "test", modelId: "test",
            inputTokens: nil, outputTokens: nil, latencyMs: 0
        )

        let episode = try ContextSynthesizer.parseEpisodeResponse(
            response, startUs: 0, endUs: 0, inputHash: ""
        )
        XCTAssertTrue(episode.evidence.isEmpty, "Negative timestamp evidence should be rejected")
    }

    /// Fix 2: Negative displayId in FocusBlock is rejected.
    func testNegativeDisplayIdFocusBlockRejected() throws {
        let json = """
        {
          "summary": "Test daily",
          "wins": [],
          "openLoops": [],
          "meetingHighlights": [],
          "focusBlocks": [
            {"app": "Xcode", "startUs": -5, "endUs": 200, "durationMinutes": 10}
          ],
          "evidence": []
        }
        """
        let response = LLMResponse(
            content: json, toolCalls: [], provider: "test", modelId: "test",
            inputTokens: nil, outputTokens: nil, latencyMs: 0
        )

        let daily = try ContextSynthesizer.parseDailyResponse(
            response, date: "2026-02-22", inputHash: ""
        )
        XCTAssertTrue(daily.focusBlocks.isEmpty, "FocusBlock with negative startUs should be rejected")
    }

    /// Fix 2: Safe UInt64/UInt32 helpers.
    func testSafeNumericParsing() {
        // Positive values work
        XCTAssertEqual(ContextSynthesizer.safeUInt64(NSNumber(value: 1000)), 1000)
        XCTAssertEqual(ContextSynthesizer.safeUInt32(NSNumber(value: 42)), 42)
        XCTAssertEqual(ContextSynthesizer.safeUInt64(NSNumber(value: 0)), 0)

        // Negative values rejected
        XCTAssertNil(ContextSynthesizer.safeUInt64(NSNumber(value: -1)))
        XCTAssertNil(ContextSynthesizer.safeUInt32(NSNumber(value: -100)))

        // Large values within range work
        XCTAssertEqual(ContextSynthesizer.safeUInt32(NSNumber(value: UInt32.max)), UInt32.max)
    }

    /// Fix 3: Transcript pagination is bounded.
    func testTranscriptPaginationBounded() async {
        var cp0 = HeartbeatCheckpoint.empty
        cp0.lastDailyDate = Self.yesterdayString()
        contextStore.saveCheckpoint(cp0)

        let events = Self.make20Events()
        let pagesRequested = OSAllocatedUnfairLock(initialState: 0)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { _ in
                Self.successResponse(summary: "Bounded episode")
            },
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in
                pagesRequested.withLock { $0 += 1 }
                // Return full pages to simulate many chunks — pagination should still stop
                return (0..<500).map { i in
                    Self.makeTranscriptChunk(ts: UInt64(i) * 1000, text: "chunk \(i)", source: "mic")
                }
            },
            getActivityBlocksFn: { _ in [] }
        )

        await heartbeat.tickForTest()

        let pages = pagesRequested.withLock { $0 }
        XCTAssertLessThanOrEqual(pages, ContextSynthesizer.maxTranscriptChunks / 500 + 1,
            "Should not fetch unlimited transcript pages")

        // Should still produce an episode despite truncation
        let episodes = contextStore.listEpisodes()
        XCTAssertEqual(episodes.count, 1)
    }

    /// Fix 5: Skip-no-synthesis path emits skipped run record.
    func testNoSynthesisNeededEmitsSkippedRecord() async {
        // Pre-seed daily so only episode gate matters + suppress analyzer/deep tick
        var cp = HeartbeatCheckpoint.empty
        cp.lastDailyDate = Self.yesterdayString()
        cp.lastAnalyzerRunAt = Date()       // Suppress fallback analyzer
        cp.lastDeepAnalyzerRunAt = Date()   // Suppress deep tick
        contextStore.saveCheckpoint(cp)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: Self.failingGenerate,
            queryTimeRangeFn: { _, _ in [] },  // No events
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        await heartbeat.tickForTest()

        let records = proactiveStore.listRunRecords()
        XCTAssertEqual(records.count, 1, "Even skip ticks should produce a run record")
        XCTAssertEqual(records.first?.status, .skipped)
    }

    // MARK: - Fix 1: Backoff Baseline Tests

    /// Repeated skip ticks do NOT extend the backoff window.
    /// The backoff anchor (lastFailureAt) stays fixed at the original failure time.
    func testRepeatedSkipTicksDoNotExtendBackoff() async {
        let failureTime = Date()
        var cp = HeartbeatCheckpoint.empty
        cp.consecutiveFailures = 1  // 30s backoff from failureTime
        cp.lastFailureAt = failureTime
        contextStore.saveCheckpoint(cp)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: Self.failingGenerate,
            queryTimeRangeFn: { _, _ in [] },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        // Tick several times while in backoff
        for _ in 0..<5 {
            await heartbeat.tickForTest()
        }

        let checkpoint = contextStore.loadCheckpoint()
        // lastFailureAt must remain exactly as set — skip ticks never update it
        XCTAssertEqual(
            checkpoint.lastFailureAt!.timeIntervalSince1970,
            failureTime.timeIntervalSince1970,
            accuracy: 0.001,
            "Skip ticks must not move lastFailureAt"
        )
        XCTAssertEqual(checkpoint.consecutiveFailures, 1, "Skip ticks must not change failure count")
    }

    /// Heartbeat resumes synthesis once backoff window elapses (lastFailureAt + backoff < now).
    func testHeartbeatResumesAfterBackoffExpires() async {
        var cp = HeartbeatCheckpoint.empty
        cp.consecutiveFailures = 1  // 30s backoff
        cp.lastFailureAt = Date().addingTimeInterval(-60)  // 60s ago — well past 30s backoff
        cp.lastDailyDate = Self.yesterdayString()
        cp.lastAnalyzerRunAt = Date()  // Suppress analyzer (isolate synthesis behavior)
        contextStore.saveCheckpoint(cp)

        let events = Self.make20Events()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { _ in
                callCount.withLock { $0 += 1 }
                return Self.successResponse(summary: "Resumed after backoff")
            },
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        await heartbeat.tickForTest()

        XCTAssertEqual(callCount.withLock { $0 }, 1, "Should synthesize once backoff window elapses")
        let checkpoint = contextStore.loadCheckpoint()
        XCTAssertEqual(checkpoint.consecutiveFailures, 0, "Successful synthesis resets failure count")
        XCTAssertNil(checkpoint.lastFailureAt, "Successful synthesis clears lastFailureAt")
    }

    /// Failure sets lastFailureAt; success clears it.
    func testLastFailureAtLifecycle() async {
        var cp = HeartbeatCheckpoint.empty
        cp.lastDailyDate = Self.yesterdayString()
        contextStore.saveCheckpoint(cp)

        let events = Self.make20Events()
        let shouldFail = OSAllocatedUnfairLock(initialState: true)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { _ in
                if shouldFail.withLock({ $0 }) {
                    throw LLMProviderError.transientFailure(underlying: "test")
                }
                return Self.successResponse(summary: "OK")
            },
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        // Tick 1: failure
        await heartbeat.tickForTest()
        var checkpoint = contextStore.loadCheckpoint()
        XCTAssertNotNil(checkpoint.lastFailureAt, "Failure should set lastFailureAt")
        XCTAssertEqual(checkpoint.consecutiveFailures, 1)

        // Backdate failure so backoff passes, then succeed
        checkpoint.lastFailureAt = Date().addingTimeInterval(-120)
        contextStore.saveCheckpoint(checkpoint)
        shouldFail.withLock { $0 = false }

        // Tick 2: success
        await heartbeat.tickForTest()
        checkpoint = contextStore.loadCheckpoint()
        XCTAssertNil(checkpoint.lastFailureAt, "Success should clear lastFailureAt")
        XCTAssertEqual(checkpoint.consecutiveFailures, 0)
    }

    // MARK: - Fix 2: Provider Gate Tests

    /// cloudOnly + key present + consent false => skip, no failure increment.
    func testProviderGateAsyncSkipsNotFails() async {
        var cp = HeartbeatCheckpoint.empty
        cp.lastDailyDate = Self.yesterdayString()
        contextStore.saveCheckpoint(cp)

        let events = Self.make20Events()

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: Self.failingGenerate,  // Should never be called
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] },
            isProviderAvailable: { false }  // Simulates: no eligible provider
        )

        await heartbeat.tickForTest()

        let checkpoint = contextStore.loadCheckpoint()
        XCTAssertEqual(checkpoint.consecutiveFailures, 0, "Provider gate skip must not increment failures")
        XCTAssertNil(checkpoint.lastFailureAt, "Provider gate skip must not set lastFailureAt")

        let records = proactiveStore.listRunRecords()
        XCTAssertEqual(records.first?.status, .skipped)
    }

    /// auto + eligible provider => proceed to synthesis.
    func testProviderGateAllowsSynthesisWhenEligible() async {
        var cp = HeartbeatCheckpoint.empty
        cp.lastDailyDate = Self.yesterdayString()
        cp.lastAnalyzerRunAt = Date()  // Suppress analyzer (isolate synthesis behavior)
        contextStore.saveCheckpoint(cp)

        let events = Self.make20Events()
        let callCount = OSAllocatedUnfairLock(initialState: 0)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { _ in
                callCount.withLock { $0 += 1 }
                return Self.successResponse(summary: "Gate passed")
            },
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] },
            isProviderAvailable: { true }
        )

        await heartbeat.tickForTest()

        XCTAssertEqual(callCount.withLock { $0 }, 1, "Should synthesize when provider gate passes")
    }

    // MARK: - Helpers

    /// Create 20 timeline entries (meets minEventDelta threshold).
    private static func make20Events() -> [TimelineEntry] {
        (0..<20).map { i in
            makeTimelineEntry(ts: UInt64(i) * 1_000_000 + 1_000_000_000, app: "Xcode", title: "File\(i)")
        }
    }

    private static func makeTimelineEntry(ts: UInt64, app: String, title: String) -> TimelineEntry {
        TimelineEntry(
            ts: ts,
            track: 3,
            eventType: "app_switch",
            appName: app,
            windowTitle: title,
            url: nil,
            displayId: 1,
            segmentFile: ""
        )
    }

    private static func makeTranscriptChunk(ts: UInt64, text: String, source: String) -> TranscriptChunkResult {
        TranscriptChunkResult(
            tsStart: ts,
            tsEnd: ts + 30_000_000,
            text: text,
            audioSource: source,
            confidence: 0.95,
            appName: "Zoom",
            windowTitle: "Meeting",
            audioSegmentId: 1
        )
    }

    private static func makeActivityBlocks(eventCount: UInt32, apps: [String]) -> [ActivityBlock] {
        apps.map { app in
            ActivityBlock(
                startTs: 1_000_000_000,
                endTs: 2_000_000_000,
                appName: app,
                eventCount: eventCount / UInt32(max(apps.count, 1))
            )
        }
    }

    private static func makeEpisode(summary: String, tags: [String]) -> EpisodeRecord {
        EpisodeRecord(
            id: UUID(),
            startUs: 1_000_000_000,
            endUs: 2_000_000_000,
            summary: summary,
            topicTags: tags,
            apps: ["Xcode"],
            keyArtifacts: [],
            evidence: [],
            provenance: RecordProvenance(
                provider: "test",
                modelId: "test",
                generatedAt: Date(),
                inputHash: "abc"
            )
        )
    }

    private static func successResponse(summary: String) -> LLMResponse {
        LLMResponse(
            content: """
            {"summary":"\(summary)","topicTags":[],"apps":[],"keyArtifacts":[],"evidence":[]}
            """,
            toolCalls: [],
            provider: "test",
            modelId: "test",
            inputTokens: nil,
            outputTokens: nil,
            latencyMs: 0
        )
    }

    /// Yesterday's date string in local timezone. Used to suppress daily synthesis in episode-focused tests.
    private static func yesterdayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
    }

    private static var failingGenerate: LLMGenerateFunction {
        { _ in throw LLMProviderError.unavailable(reason: "test") }
    }

    // MARK: - Analyzer Integration Tests

    /// After successful episode synthesis, the analyzer should run if cooldown allows.
    func testHeartbeatTriggersAnalyzerAfterSynthesis() async {
        let events = Self.make20Events()
        let generateCount = OSAllocatedUnfairLock(initialState: 0)

        // Pre-seed daily so only episode synthesis fires
        var cp0 = HeartbeatCheckpoint.empty
        cp0.lastDailyDate = Self.yesterdayString()
        contextStore.saveCheckpoint(cp0)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { _ in
                generateCount.withLock { $0 += 1 }
                // Return valid JSON for both synthesizer and analyzer
                return Self.successResponse(summary: "Test episode")
            },
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        let beforeRuns = DiagnosticsStore.shared.counter("proactive_analyze_runs_total")
        await heartbeat.tickForTest()

        // Generate should be called at least twice: once for episode synthesis, once for analyzer
        let count = generateCount.withLock { $0 }
        XCTAssertGreaterThanOrEqual(count, 2, "Should call generate for both synthesis and analysis")

        let afterRuns = DiagnosticsStore.shared.counter("proactive_analyze_runs_total")
        XCTAssertGreaterThan(afterRuns, beforeRuns, "Analyzer run counter should increment")
    }

    /// Analyzer should be skipped when lastAnalyzerRunAt is within cooldown window.
    func testHeartbeatSkipsAnalyzerDuringCooldown() async {
        let events = Self.make20Events()
        let generateCount = OSAllocatedUnfairLock(initialState: 0)

        // Pre-seed checkpoint: daily done, analyzer just ran
        var cp0 = HeartbeatCheckpoint.empty
        cp0.lastDailyDate = Self.yesterdayString()
        cp0.lastAnalyzerRunAt = Date()  // Just now — within 10 min cooldown
        contextStore.saveCheckpoint(cp0)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { _ in
                generateCount.withLock { $0 += 1 }
                return Self.successResponse(summary: "Episode")
            },
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        await heartbeat.tickForTest()

        // Should only call generate once (for episode synthesis) — analyzer skipped
        let count = generateCount.withLock { $0 }
        XCTAssertEqual(count, 1, "Analyzer should be skipped during cooldown")
    }

    /// Analyzer failure should NOT increment heartbeat's consecutiveFailures or set lastFailureAt.
    func testHeartbeatAnalyzerFailureDoesNotBackoffHeartbeat() async {
        let events = Self.make20Events()
        let generateCount = OSAllocatedUnfairLock(initialState: 0)

        // Pre-seed daily done
        var cp0 = HeartbeatCheckpoint.empty
        cp0.lastDailyDate = Self.yesterdayString()
        contextStore.saveCheckpoint(cp0)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { _ in
                let count = generateCount.withLock { val -> Int in
                    val += 1
                    return val
                }
                if count == 1 {
                    // First call: episode synthesis succeeds
                    return Self.successResponse(summary: "Episode OK")
                } else {
                    // Second call: analyzer fails
                    throw LLMProviderError.unavailable(reason: "analyzer fail")
                }
            },
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        let beforeFails = DiagnosticsStore.shared.counter("proactive_analyze_fail_total")
        await heartbeat.tickForTest()
        let afterFails = DiagnosticsStore.shared.counter("proactive_analyze_fail_total")

        // Analyzer failure should be recorded
        XCTAssertGreaterThan(afterFails, beforeFails, "Analyzer failure should be counted")

        // But heartbeat should NOT be in backoff state
        let cp = contextStore.loadCheckpoint()
        XCTAssertEqual(cp.consecutiveFailures, 0, "Heartbeat failures should be 0 — analyzer fail is independent")
        XCTAssertNil(cp.lastFailureAt, "lastFailureAt should be nil — analyzer fail doesn't set it")

        // The synthesis record should still be completed (not failed)
        let records = proactiveStore.listRunRecords()
        let latestCompleted = records.first { $0.status == .completed }
        XCTAssertNotNil(latestCompleted, "Synthesis run record should be completed despite analyzer failure")

        // lastAnalyzerRunAt should be stamped even on failure (cooldown applies to attempts)
        XCTAssertNotNil(cp.lastAnalyzerRunAt, "lastAnalyzerRunAt should be set even on failure")
    }

    /// Analyzer failure should still apply cooldown — next tick should skip analyzer.
    func testHeartbeatAnalyzerCooldownAppliesOnFailure() async {
        let events = Self.make20Events()
        let generateCount = OSAllocatedUnfairLock(initialState: 0)

        var cp0 = HeartbeatCheckpoint.empty
        cp0.lastDailyDate = Self.yesterdayString()
        contextStore.saveCheckpoint(cp0)

        let heartbeat = ContextHeartbeat(
            contextStore: contextStore,
            proactiveStore: proactiveStore,
            trustTuner: trustTuner,
            generate: { _ in
                let count = generateCount.withLock { val -> Int in
                    val += 1
                    return val
                }
                if count == 1 {
                    return Self.successResponse(summary: "Episode OK")
                } else {
                    throw LLMProviderError.unavailable(reason: "analyzer fail")
                }
            },
            queryTimeRangeFn: { _, _ in events },
            listTranscriptsFn: { _, _, _, _ in [] },
            getActivityBlocksFn: { _ in [] }
        )

        // First tick: synthesis (1) + analyzer attempt fails (2) = 2 generate calls
        await heartbeat.tickForTest()
        XCTAssertEqual(generateCount.withLock { $0 }, 2, "First tick: synthesis + analyzer attempt")

        // Backdate episode cooldown so second tick synthesizes again
        var cp = contextStore.loadCheckpoint()
        cp.lastEpisodeSynthesisAt = Date().addingTimeInterval(-ContextHeartbeat.episodeCooldownSeconds - 1)
        cp.lastEpisodeEndUs = nil
        // NOTE: lastAnalyzerRunAt should already be set from the failed attempt
        XCTAssertNotNil(cp.lastAnalyzerRunAt, "lastAnalyzerRunAt should be set from failed attempt")
        contextStore.saveCheckpoint(cp)

        // Second tick: synthesis (3) + analyzer SKIPPED (cooldown) = 3 generate calls total
        await heartbeat.tickForTest()
        XCTAssertEqual(generateCount.withLock { $0 }, 3, "Second tick: synthesis only — analyzer cooldown from failed attempt")
    }
}

// MARK: - Test-Only Extension

extension ContextHeartbeat {
    /// Expose tick() for testing without needing the timer.
    /// Temporarily marks as not-stopped so the guard passes.
    func tickForTest() async {
        guardedState.withLock { $0.isStopped = false }
        await tick()
    }
}
