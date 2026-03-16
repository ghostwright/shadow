import CoreGraphics
import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ContextHeartbeat")

/// Periodic worker that drives context synthesis (episodes + daily records)
/// and two-tier proactive analysis (fast tick + deep tick).
///
/// Follows the OCRWorker pattern: Timer + DispatchQueue + OSAllocatedUnfairLock guarded state.
///
/// Trigger logic (all deterministic, no LLM):
/// - Timer fires every 5 minutes
/// - Episode: skip if <10 new timeline events since last checkpoint (change-delta gate)
/// - Episode cooldown: min 3 minutes between episode syntheses
/// - Daily: synthesize yesterday when date rolls over
/// - Daily cooldown: 1 hour between daily syntheses
/// - Backoff: consecutive failures -> 2^n * 30s, max 30 minutes
/// - Consent gate: skip if LLM orchestrator unavailable
/// - Fast tick: ~10 min, live context + tools + screenshot → push_now
/// - Deep tick: ~30 min, episodes + patterns + tools → inbox_only
final class ContextHeartbeat: @unchecked Sendable {

    /// How often the heartbeat timer fires (seconds).
    static let heartbeatInterval: TimeInterval = 300  // 5 minutes

    /// Minimum new timeline events before triggering episode synthesis.
    static let minEventDelta: Int = 10

    /// Minimum seconds between episode syntheses.
    static let episodeCooldownSeconds: TimeInterval = 180  // 3 minutes

    /// Minimum seconds between daily syntheses.
    static let dailyCooldownSeconds: TimeInterval = 3600  // 1 hour

    /// Base backoff interval (seconds). Doubles per consecutive failure.
    static let backoffBaseSeconds: TimeInterval = 30

    /// Maximum backoff interval (seconds).
    static let maxBackoffSeconds: TimeInterval = 1800  // 30 minutes

    /// Default episode window size (microseconds). 30 minutes.
    static let defaultEpisodeWindowUs: UInt64 = 30 * 60 * 1_000_000

    /// Minimum seconds between fast proactive analyzer runs.
    static let analyzerCooldownSeconds: TimeInterval = 600  // 10 minutes

    /// Minimum seconds between deep proactive analyzer runs.
    static let deepAnalyzerCooldownSeconds: TimeInterval = 1800  // 30 minutes

    /// Recent activity window for live context gathering (microseconds). 10 minutes.
    static let liveContextWindowUs: UInt64 = 10 * 60 * 1_000_000

    private let workQueue = DispatchQueue(label: "com.shadow.context-heartbeat", qos: .utility)

    // MARK: - Dependencies (injected at init, immutable)

    private let contextStore: ContextStore
    private let proactiveStore: ProactiveStore
    private let trustTuner: TrustTuner
    private let generate: LLMGenerateFunction
    private let queryTimeRangeFn: (@Sendable (UInt64, UInt64) throws -> [TimelineEntry])?
    private let listTranscriptsFn: (@Sendable (UInt64, UInt64, UInt32, UInt32) throws -> [TranscriptChunkResult])?
    private let getActivityBlocksFn: (@Sendable (String) throws -> [ActivityBlock])?

    /// Tool registry for proactive analyzer tool-calling loops. Nil = fallback to old analyzer.
    private let toolRegistry: AgentToolRegistry?

    /// Frame extractor for proactive screenshot capture. (timestampUs, displayId) → CGImage?.
    /// Returns nil on failure (non-fatal).
    private let frameExtractFn: (@Sendable (UInt64, UInt32) async throws -> CGImage?)?

    /// Injectable provider-availability check. Returns true if at least one LLM provider
    /// can accept work right now (mode + consent + availability).
    /// Default: always available (for testing). Wired to LLMOrchestrator in production.
    let isProviderAvailable: @Sendable () async -> Bool

    /// Callback when proactive analyzer generates suggestions. Fires on @MainActor
    /// so delivery manager can safely route to overlay/inbox.
    var onSuggestionsGenerated: (@Sendable @MainActor ([ProactiveSuggestion]) -> Void)?

    // MARK: - Synchronized state

    struct GuardedState: Sendable {
        var isProcessing = false
        var isStopped = true
    }

    let guardedState = OSAllocatedUnfairLock(initialState: GuardedState())

    // MARK: - Main-thread-only state

    private nonisolated(unsafe) var heartbeatTimer: Timer?

    // MARK: - Pre-filter state (workQueue-only, single-flight guarantees exclusive access)

    private nonisolated(unsafe) var lastFastTickApp: String?
    private nonisolated(unsafe) var lastFastTickWindowTitle: String?
    private nonisolated(unsafe) var lastPushState: ProactiveLiveAnalyzer.LastPushState?

    // MARK: - Init

    init(
        contextStore: ContextStore,
        proactiveStore: ProactiveStore,
        trustTuner: TrustTuner,
        generate: @escaping LLMGenerateFunction,
        queryTimeRangeFn: (@Sendable (UInt64, UInt64) throws -> [TimelineEntry])? = nil,
        listTranscriptsFn: (@Sendable (UInt64, UInt64, UInt32, UInt32) throws -> [TranscriptChunkResult])? = nil,
        getActivityBlocksFn: (@Sendable (String) throws -> [ActivityBlock])? = nil,
        toolRegistry: AgentToolRegistry? = nil,
        frameExtractFn: (@Sendable (UInt64, UInt32) async throws -> CGImage?)? = nil,
        isProviderAvailable: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.contextStore = contextStore
        self.proactiveStore = proactiveStore
        self.trustTuner = trustTuner
        self.generate = generate
        self.queryTimeRangeFn = queryTimeRangeFn
        self.listTranscriptsFn = listTranscriptsFn
        self.getActivityBlocksFn = getActivityBlocksFn
        self.toolRegistry = toolRegistry
        self.frameExtractFn = frameExtractFn
        self.isProviderAvailable = isProviderAvailable
    }

    // MARK: - Lifecycle

    @MainActor
    func start() {
        guardedState.withLock { $0.isStopped = false }

        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: Self.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            self?.triggerTick()
        }

        // Initial tick after a short delay (let other subsystems stabilize)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.triggerTick()
        }

        logger.info("Context heartbeat started (interval: \(Self.heartbeatInterval)s)")
    }

    @MainActor
    func stop() {
        guardedState.withLock { $0.isStopped = true }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        logger.info("Context heartbeat stopped")
    }

    private func triggerTick() {
        workQueue.async { [weak self] in
            guard let self else { return }
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached(priority: .utility) {
                await self.tick()
                semaphore.signal()
            }
            semaphore.wait()
        }
    }

    // MARK: - Tick Logic

    /// Execute one heartbeat tick. Determines what (if anything) needs synthesizing,
    /// creates a ProactiveRunRecord for observability, and runs synthesis.
    ///
    /// Every tick produces a run record with lifecycle: running → completed/failed/skipped.
    func tick() async {
        // Ensure single-flight
        let canProceed = guardedState.withLock { state -> Bool in
            guard !state.isProcessing, !state.isStopped else { return false }
            state.isProcessing = true
            return true
        }
        guard canProceed else { return }
        defer { guardedState.withLock { $0.isProcessing = false } }

        DiagnosticsStore.shared.increment("context_heartbeat_run_total")

        var checkpoint = contextStore.loadCheckpoint()
        let now = Date()
        let nowUs = UInt64(now.timeIntervalSince1970 * 1_000_000)

        // Every tick gets a run record for observability (Fix 5)
        var record = ProactiveRunRecord.start()
        proactiveStore.saveRunRecord(record)

        // Check backoff — anchored to lastFailureAt (stable, never updated on skip)
        if checkpoint.consecutiveFailures > 0, let failedAt = checkpoint.lastFailureAt {
            let backoffSeconds = min(
                Self.backoffBaseSeconds * pow(2.0, Double(checkpoint.consecutiveFailures - 1)),
                Self.maxBackoffSeconds
            )
            let eligibleAt = failedAt.addingTimeInterval(backoffSeconds)
            if now < eligibleAt {
                DiagnosticsStore.shared.increment("context_heartbeat_skip_total")
                DiagnosticsStore.shared.setGauge("context_backoff_active", value: 1)
                logger.debug("Heartbeat in backoff until \(eligibleAt)")

                record.skip(reason: "Backoff: \(Int(eligibleAt.timeIntervalSince(now)))s remaining")
                proactiveStore.saveRunRecord(record)
                // Do NOT update lastHeartbeatAt here — keep backoff anchor stable
                contextStore.saveCheckpoint(checkpoint)
                return
            }
        }

        DiagnosticsStore.shared.setGauge("context_backoff_active", value: 0)
        checkpoint.lastHeartbeatAt = now

        // Provider availability gate (Fix 6) — skip, don't fail/backoff
        if !(await isProviderAvailable()) {
            DiagnosticsStore.shared.increment("context_heartbeat_skip_total")
            logger.debug("Heartbeat skipped: no LLM provider available")

            record.skip(reason: "No LLM provider available")
            proactiveStore.saveRunRecord(record)
            contextStore.saveCheckpoint(checkpoint)
            return
        }

        // Determine what to synthesize (Fix 1: uses dedicated synthesis timestamps)
        let needsDaily = shouldSynthesizeDaily(checkpoint: checkpoint, now: now)
        let needsEpisode = shouldSynthesizeEpisode(checkpoint: checkpoint, nowUs: nowUs, now: now)

        if !needsDaily && !needsEpisode {
            DiagnosticsStore.shared.increment("context_heartbeat_skip_total")
        }

        // Episode synthesis
        if needsEpisode {
            let episodeStartUs = checkpoint.lastEpisodeEndUs.map { $0 + 1 } ?? (nowUs - Self.defaultEpisodeWindowUs)
            let episodeEndUs = nowUs

            do {
                let episode = try await ContextSynthesizer.synthesizeEpisode(
                    startUs: episodeStartUs,
                    endUs: episodeEndUs,
                    generate: generate,
                    queryTimeRangeFn: queryTimeRangeFn,
                    listTranscriptsFn: listTranscriptsFn
                )

                contextStore.saveEpisode(episode)
                checkpoint.lastEpisodeEndUs = episodeEndUs
                checkpoint.lastEpisodeSynthesisAt = now
                checkpoint.consecutiveFailures = 0
                checkpoint.lastFailureAt = nil
                DiagnosticsStore.shared.increment("context_episode_generated_total")

                logger.info("Episode generated: \(episode.topicTags.joined(separator: ", "))")
            } catch {
                checkpoint.consecutiveFailures += 1
                checkpoint.lastFailureAt = now
                DiagnosticsStore.shared.increment("context_heartbeat_fail_total")
                logger.error("Episode synthesis failed: \(error, privacy: .public)")

                record.fail(error: "Episode: \(error.localizedDescription)")
                proactiveStore.saveRunRecord(record)
                contextStore.saveCheckpoint(checkpoint)
                return
            }
        }

        // Daily synthesis
        if needsDaily {
            let yesterday = yesterdayDateString(from: now)

            do {
                let episodes = contextStore.episodesForDate(yesterday)
                let daily = try await ContextSynthesizer.synthesizeDaily(
                    date: yesterday,
                    episodes: episodes,
                    generate: generate,
                    getActivityBlocksFn: getActivityBlocksFn
                )

                contextStore.saveDaily(daily)
                checkpoint.lastDailyDate = yesterday
                checkpoint.lastDailySynthesisAt = now
                checkpoint.consecutiveFailures = 0
                checkpoint.lastFailureAt = nil
                DiagnosticsStore.shared.increment("context_day_generated_total")

                logger.info("Daily record generated for \(yesterday)")

                // Semantic consolidation: extract durable knowledge from today's episodes.
                // Runs after daily synthesis to consolidate the day's learnings.
                // Non-fatal — consolidation failure does not affect the heartbeat.
                do {
                    let recentEpisodes = Array(episodes.suffix(5))
                    if !recentEpisodes.isEmpty {
                        let existing = try SemanticMemoryStore.query()
                        let result = try await SemanticConsolidator.consolidate(
                            episodes: recentEpisodes,
                            existingKnowledge: existing,
                            generate: generate
                        )
                        logger.info("Semantic consolidation: \(result.newKnowledge) new, \(result.updatedKnowledge) updated")
                    }
                } catch {
                    logger.warning("Semantic consolidation failed: \(error, privacy: .public)")
                }
            } catch {
                checkpoint.consecutiveFailures += 1
                checkpoint.lastFailureAt = now
                DiagnosticsStore.shared.increment("context_heartbeat_fail_total")
                logger.error("Daily synthesis failed: \(error, privacy: .public)")

                record.fail(error: "Daily: \(error.localizedDescription)")
                proactiveStore.saveRunRecord(record)
                contextStore.saveCheckpoint(checkpoint)
                return
            }
        }

        // --- Directive checking (every tick) ---
        // Check if any active directives match the current app context.
        // Matched directives generate proactive suggestions that flow through
        // the existing delivery pipeline (overlay for push_now, inbox otherwise).
        do {
            let liveCtx = gatherLiveContext(nowUs: nowUs)
            let matched = try DirectiveMemoryStore.matchingDirectives(
                app: liveCtx.currentApp,
                windowTitle: liveCtx.windowTitle.isEmpty ? nil : liveCtx.windowTitle,
                url: liveCtx.url,
                nowUs: nowUs
            )

            if !matched.isEmpty {
                var directiveSuggestions: [ProactiveSuggestion] = []
                for directive in matched {
                    // Record the trigger
                    try? DirectiveMemoryStore.recordTrigger(id: directive.id, nowUs: nowUs)

                    // Create a proactive suggestion for this directive
                    let suggestion = ProactiveSuggestion(
                        id: UUID(),
                        createdAt: Date(),
                        type: .reminder,
                        title: "Reminder: \(directive.actionDescription)",
                        body: "Triggered by: \(directive.triggerPattern)",
                        whyNow: "You opened \(liveCtx.currentApp) which matches your directive",
                        confidence: 0.9,
                        decision: .pushNow,
                        evidence: [],
                        sourceRecordIds: [],
                        status: .active
                    )
                    directiveSuggestions.append(suggestion)
                    proactiveStore.saveSuggestion(suggestion)
                }

                if !directiveSuggestions.isEmpty, let callback = onSuggestionsGenerated {
                    await callback(directiveSuggestions)
                }

                DiagnosticsStore.shared.increment("directive_trigger_match_total", by: Int64(matched.count))
                logger.info("Directive check: \(matched.count) directive(s) triggered for \(liveCtx.currentApp)")
            }
        } catch {
            // Non-fatal — directive checking should not block the heartbeat
            logger.warning("Directive check failed: \(error, privacy: .public)")
        }

        // --- Fast tick (live context analysis, ~10 min cooldown) ---
        let fastCooldownOk: Bool
        if let lastRun = checkpoint.lastAnalyzerRunAt {
            fastCooldownOk = now.timeIntervalSince(lastRun) >= Self.analyzerCooldownSeconds
        } else {
            fastCooldownOk = true
        }

        if fastCooldownOk {
            if let registry = toolRegistry {
                // Tool-augmented fast tick
                do {
                    let liveContext = gatherLiveContext(nowUs: nowUs)
                    if ProactiveLiveAnalyzer.shouldRunFastTick(
                        liveContext: liveContext,
                        lastApp: lastFastTickApp,
                        lastWindowTitle: lastFastTickWindowTitle
                    ) {
                        // Stamp cooldown only when we actually run (not when prefilter skips)
                        checkpoint.lastAnalyzerRunAt = now

                        let screenshot = await captureScreenshot(
                            displayId: liveContext.displayId,
                            nowUs: nowUs
                        )
                        let suggestions = try await ProactiveLiveAnalyzer.fastTick(
                            toolRegistry: registry,
                            proactiveStore: proactiveStore,
                            trustTuner: trustTuner,
                            generate: generate,
                            liveContext: liveContext,
                            screenshot: screenshot,
                            lastPushState: lastPushState
                        )
                        updateLastFastTickState(liveContext: liveContext, suggestions: suggestions)

                        if !suggestions.isEmpty, let callback = onSuggestionsGenerated {
                            await callback(suggestions)
                        }

                        DiagnosticsStore.shared.increment("proactive_fast_tick_total")
                    } else {
                        DiagnosticsStore.shared.increment("proactive_fast_tick_skip_total")
                    }
                } catch {
                    // Still stamp cooldown on failure to avoid retry storm
                    checkpoint.lastAnalyzerRunAt = now
                    DiagnosticsStore.shared.increment("proactive_analyze_fail_total")
                    logger.error("Fast tick failed: \(error, privacy: .public)")
                }
            } else {
                // Fallback: old episode-based analyzer (when no tool registry)
                checkpoint.lastAnalyzerRunAt = now
                do {
                    let suggestions = try await ProactiveAnalyzer.analyze(
                        contextStore: contextStore,
                        proactiveStore: proactiveStore,
                        trustTuner: trustTuner,
                        generate: generate
                    )
                    DiagnosticsStore.shared.increment("proactive_analyze_runs_total")

                    if !suggestions.isEmpty, let callback = onSuggestionsGenerated {
                        await callback(suggestions)
                    }
                } catch {
                    DiagnosticsStore.shared.increment("proactive_analyze_fail_total")
                    logger.error("Proactive analysis (fallback) failed: \(error, privacy: .public)")
                }
            }
        }

        // --- Deep tick (pattern analysis, ~30 min cooldown) ---
        let deepCooldownOk: Bool
        if let lastRun = checkpoint.lastDeepAnalyzerRunAt {
            deepCooldownOk = now.timeIntervalSince(lastRun) >= Self.deepAnalyzerCooldownSeconds
        } else {
            deepCooldownOk = true
        }

        if deepCooldownOk, let registry = toolRegistry {
            checkpoint.lastDeepAnalyzerRunAt = now

            do {
                let liveContext = gatherLiveContext(nowUs: nowUs)
                let suggestions = try await ProactiveLiveAnalyzer.deepTick(
                    toolRegistry: registry,
                    contextStore: contextStore,
                    proactiveStore: proactiveStore,
                    trustTuner: trustTuner,
                    generate: generate,
                    liveContext: liveContext
                )

                if !suggestions.isEmpty, let callback = onSuggestionsGenerated {
                    await callback(suggestions)
                }

                DiagnosticsStore.shared.increment("proactive_deep_tick_total")
            } catch {
                DiagnosticsStore.shared.increment("proactive_analyze_fail_total")
                logger.error("Deep tick failed: \(error, privacy: .public)")
            }
        }

        // Record outcome — skip if nothing ran at all, complete otherwise
        if !needsEpisode && !needsDaily && !fastCooldownOk && !deepCooldownOk {
            record.skip(reason: "No synthesis needed, all cooldowns active")
        } else {
            var whyParts: [String] = []
            if needsEpisode { whyParts.append("Episode") }
            if needsDaily { whyParts.append("Daily") }
            if fastCooldownOk { whyParts.append("FastTick") }
            if deepCooldownOk { whyParts.append("DeepTick") }
            record.complete(
                decision: .inboxOnly,
                confidence: 1.0,
                whyNow: whyParts.joined(separator: " + "),
                model: nil,
                sourceRecordIds: []
            )
        }
        proactiveStore.saveRunRecord(record)
        contextStore.saveCheckpoint(checkpoint)
    }

    // MARK: - Trigger Decisions

    /// Check if we should synthesize an episode.
    /// Fix 1: Uses `lastEpisodeSynthesisAt` for cooldown, not `lastHeartbeatAt`.
    private func shouldSynthesizeEpisode(checkpoint: HeartbeatCheckpoint, nowUs: UInt64, now: Date) -> Bool {
        // Cooldown check — based on when episode synthesis last succeeded
        if let lastSynthesis = checkpoint.lastEpisodeSynthesisAt,
           checkpoint.lastEpisodeEndUs != nil {
            let age = now.timeIntervalSince(lastSynthesis)
            if age < Self.episodeCooldownSeconds {
                return false
            }
        }

        // Change-delta gate: check if enough new events exist
        let fromUs = checkpoint.lastEpisodeEndUs.map { $0 + 1 } ?? (nowUs - Self.defaultEpisodeWindowUs)
        do {
            let events: [TimelineEntry]
            if let fn = queryTimeRangeFn {
                events = try fn(fromUs, nowUs)
            } else {
                events = try queryTimeRange(startUs: fromUs, endUs: nowUs)
            }
            return events.count >= Self.minEventDelta
        } catch {
            logger.warning("Failed to check event delta: \(error, privacy: .public)")
            return false
        }
    }

    /// Check if we should synthesize a daily record.
    /// Fix 1: Uses `lastDailySynthesisAt` for cooldown, not `lastHeartbeatAt`.
    private func shouldSynthesizeDaily(checkpoint: HeartbeatCheckpoint, now: Date) -> Bool {
        let todayStr = todayDateString(from: now)

        guard let lastDaily = checkpoint.lastDailyDate else {
            let yesterday = yesterdayDateString(from: now)
            return yesterday != todayStr
        }

        let yesterday = yesterdayDateString(from: now)
        if lastDaily >= yesterday {
            return false
        }

        // Cooldown check — based on when daily synthesis last succeeded
        if let lastSynthesis = checkpoint.lastDailySynthesisAt {
            if now.timeIntervalSince(lastSynthesis) < Self.dailyCooldownSeconds {
                return false
            }
        }

        return true
    }

    // MARK: - Live Context Gathering

    /// Gather a snapshot of the user's current activity from the timeline.
    private func gatherLiveContext(nowUs: UInt64) -> ProactiveLiveAnalyzer.LiveContextSnapshot {
        let fromUs = nowUs > Self.liveContextWindowUs ? nowUs - Self.liveContextWindowUs : 0

        let events: [TimelineEntry]
        do {
            if let fn = queryTimeRangeFn {
                events = try fn(fromUs, nowUs)
            } else {
                events = try queryTimeRange(startUs: fromUs, endUs: nowUs)
            }
        } catch {
            logger.warning("Failed to gather live context: \(error, privacy: .public)")
            return ProactiveLiveAnalyzer.LiveContextSnapshot(
                currentApp: "unknown",
                windowTitle: "",
                url: nil,
                displayId: nil,
                activeSeconds: 0,
                recentApps: []
            )
        }

        // Find most recent app_switch or window_title_changed for current state
        var currentApp = "unknown"
        var windowTitle = ""
        var url: String? = nil
        var displayId: UInt32? = nil
        var lastAppSwitchTs: UInt64 = 0

        // Build recent app sequence (newest first)
        var recentApps: [ProactiveLiveAnalyzer.RecentAppEntry] = []

        for event in events.reversed() {
            let app = event.appName ?? "unknown"
            let title = event.windowTitle ?? ""

            if event.eventType == "app_switch" || event.eventType == "window_title_changed" {
                if currentApp == "unknown" || event.ts > lastAppSwitchTs {
                    currentApp = app
                    windowTitle = title
                    url = event.url
                    displayId = event.displayId
                    lastAppSwitchTs = event.ts
                }

                if recentApps.count < 10 {
                    recentApps.append(ProactiveLiveAnalyzer.RecentAppEntry(
                        app: app, title: title, ts: event.ts
                    ))
                }
            }
        }

        let activeSeconds: Int
        if lastAppSwitchTs > 0 {
            activeSeconds = Int((nowUs - lastAppSwitchTs) / 1_000_000)
        } else {
            activeSeconds = 0
        }

        return ProactiveLiveAnalyzer.LiveContextSnapshot(
            currentApp: currentApp,
            windowTitle: windowTitle,
            url: url,
            displayId: displayId,
            activeSeconds: activeSeconds,
            recentApps: recentApps
        )
    }

    /// Capture the current screen as a JPEG ImageData for the LLM.
    private func captureScreenshot(displayId: UInt32?, nowUs: UInt64) async -> ImageData? {
        guard let extractFn = frameExtractFn,
              let dispId = displayId else { return nil }

        do {
            guard let cgImage = try await extractFn(nowUs, dispId),
                  let jpegData = AgentTools.encodeFrameAsJPEG(cgImage, maxWidth: 768, quality: 0.5) else {
                return nil
            }
            return ImageData(mediaType: "image/jpeg", base64Data: jpegData.base64EncodedString())
        } catch {
            logger.debug("Screenshot capture failed: \(error, privacy: .public)")
            return nil
        }
    }

    /// Update pre-filter state after a fast tick run.
    private func updateLastFastTickState(
        liveContext: ProactiveLiveAnalyzer.LiveContextSnapshot,
        suggestions: [ProactiveSuggestion]
    ) {
        lastFastTickApp = liveContext.currentApp
        lastFastTickWindowTitle = liveContext.windowTitle

        if let first = suggestions.first, first.decision == .pushNow {
            lastPushState = ProactiveLiveAnalyzer.LastPushState(
                title: first.title,
                app: liveContext.currentApp,
                timestamp: Date()
            )
        }
    }

    // MARK: - Date Helpers

    private func todayDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func yesterdayDateString(from date: Date) -> String {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: date)!
        return todayDateString(from: yesterday)
    }
}

// MARK: - ContextStore Extension for Date-Based Episode Lookup

extension ContextStore {
    /// List episodes that fall within a given date (YYYY-MM-DD) in the local timezone.
    func episodesForDate(_ dateStr: String) -> [EpisodeRecord] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current

        guard let dayStart = formatter.date(from: dateStr) else { return [] }
        guard let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        let startUs = UInt64(dayStart.timeIntervalSince1970 * 1_000_000)
        let endUs = UInt64(dayEnd.timeIntervalSince1970 * 1_000_000)

        return episodesInRange(startUs: startUs, endUs: endUs)
    }
}
