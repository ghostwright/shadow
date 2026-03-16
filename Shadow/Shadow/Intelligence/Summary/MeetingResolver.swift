import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "MeetingResolver")

/// A detected meeting candidate with confidence scoring.
struct MeetingCandidate: Sendable {
    /// Start of the meeting window (Unix microseconds).
    let startUs: UInt64
    /// End of the meeting window (Unix microseconds).
    let endUs: UInt64
    /// Dominant app during this window (e.g. "Zoom", "Google Meet", "Meeting").
    let app: String
    /// Number of transcript chunks found in this window.
    let transcriptChunkCount: Int
    /// Confidence score (0.0–1.0) based on duration, density, and recency.
    let confidence: Double
}

/// Resolves meeting queries into concrete time windows.
///
/// Detection hierarchy (deterministic, no LLM):
/// 1. **Primary: Audio overlap** — mic + system audio running simultaneously for ≥2 minutes.
///    This is app-agnostic and catches all meeting types (Zoom, Google Meet in browser,
///    Slack huddles, phone calls, new apps — anything with two-way audio).
/// 2. **Secondary: App/window-title hints** — fallback for edge cases where only system audio
///    exists (e.g., watching a webinar while muted). Uses known meeting app names and browser
///    window title keywords.
/// 3. **App context resolved after detection** — once a meeting window is found via audio overlap,
///    the focused app is looked up to provide labels like "Your Zoom meeting from 2-3pm".
///
/// Scoring: duration × transcript_density × recency_decay × audio_overlap_bonus
enum MeetingResolver {

    /// Known meeting application names (case-insensitive substring match).
    private static let meetingApps: Set<String> = [
        "zoom.us", "zoom", "google meet", "microsoft teams", "teams",
        "facetime", "webex", "cisco webex meetings",
        "slack", "discord",
    ]

    /// Window title keywords that indicate a browser-based meeting.
    private static let meetingWindowKeywords: [String] = [
        "google meet", "zoom meeting", "zoom webinar",
        "teams meeting", "slack huddle", "slack call",
        "facetime", "webex",
    ]

    /// Minimum duration (microseconds) to consider a window a meeting.
    private static let minDurationUs: UInt64 = 2 * 60 * 1_000_000  // 2 minutes

    /// Minimum transcript chunks to consider a window a meeting.
    private static let minTranscriptChunks = 3

    /// Recency decay half-life (microseconds). Recent meetings score higher.
    private static let recencyHalfLifeUs: Double = 4 * 3600 * 1_000_000  // 4 hours

    // MARK: - Public API

    /// Find the most likely recent meeting window.
    /// Returns single candidate if unambiguous, multiple if disambiguation needed, empty if none.
    static func resolveLatestMeeting(lookbackHours: Int = 24) throws -> [MeetingCandidate] {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let lookbackUs = UInt64(lookbackHours) * 3600 * 1_000_000
        let startUs = now - lookbackUs

        return try resolveMeetingsInRange(startUs: startUs, endUs: now)
    }

    /// Explicit time window (bypass auto-detection).
    static func resolveExplicit(startUs: UInt64, endUs: UInt64) -> MeetingCandidate {
        MeetingCandidate(
            startUs: startUs,
            endUs: endUs,
            app: "explicit",
            transcriptChunkCount: 0,
            confidence: 1.0
        )
    }

    // MARK: - Core Resolution

    static func resolveMeetingsInRange(
        startUs: UInt64,
        endUs: UInt64
    ) throws -> [MeetingCandidate] {
        // PRIMARY: Audio overlap detection (app-agnostic, future-proof)
        let audioSegments = try listAudioSegments(startUs: startUs, endUs: endUs)
        let micSegments = audioSegments.filter { $0.source == "mic" }
        let systemSegments = audioSegments.filter { $0.source == "system" }
        let audioWindows = findAudioOverlaps(mic: micSegments, system: systemSegments)

        // SECONDARY: App/window-title hints (fallback for muted-user edge cases)
        let entries = try queryTimeRange(startUs: startUs, endUs: endUs)
        let appWindows = buildMeetingWindows(from: entries, rangeEnd: endUs)

        // Combine — audio overlap windows take priority over app-detected windows
        let allWindows = deduplicateWindows(primary: audioWindows, secondary: appWindows)

        // Score each window using transcript density and recency
        var candidates: [MeetingCandidate] = []
        for window in allWindows {
            let duration = window.endUs - window.startUs
            guard duration >= minDurationUs else { continue }

            // Check transcript density
            let chunks = try listTranscriptChunksInRange(
                startUs: window.startUs,
                endUs: window.endUs,
                limit: 100,
                offset: 0
            )
            guard chunks.count >= minTranscriptChunks else { continue }

            // Score: duration_weight * density_weight * recency_weight * audio_bonus
            let durationMinutes = Double(duration) / (60 * 1_000_000)
            let durationWeight = min(durationMinutes / 10, 3.0)  // caps at 30-min

            let densityPerMinute = Double(chunks.count) / max(durationMinutes, 1)
            let densityWeight = min(densityPerMinute / 2, 2.0)  // caps at 4/min

            let age = Double(endUs - window.endUs)
            let recencyWeight = pow(0.5, age / recencyHalfLifeUs)

            // Audio overlap is the strongest meeting signal — boost confidence
            let audioBonus: Double = window.isAudioOverlap ? 1.5 : 1.0

            let score = durationWeight * densityWeight * recencyWeight * audioBonus
            let confidence = min(score / 3.0, 1.0)

            // Resolve app context for labeling
            let resolvedApp = resolveAppForWindow(window, entries: entries)

            candidates.append(MeetingCandidate(
                startUs: window.startUs,
                endUs: window.endUs,
                app: resolvedApp,
                transcriptChunkCount: chunks.count,
                confidence: confidence
            ))
        }

        // Sort by confidence descending
        candidates.sort { $0.confidence > $1.confidence }

        // Return top candidate if confident, multiple if ambiguous
        if let top = candidates.first {
            if top.confidence > 0.8 {
                return [top]
            }
            // Return candidates within 0.5 of top for disambiguation
            let threshold = top.confidence - 0.5
            return candidates.filter { $0.confidence >= max(threshold, 0) }
        }

        logger.info("No meeting candidates found in range")
        return []
    }

    // MARK: - Audio Overlap Detection (Primary)

    /// Find time ranges where both mic and system audio are active simultaneously.
    /// This is the definitive meeting signal — app-agnostic and future-proof.
    static func findAudioOverlaps(
        mic: [AudioSegment],
        system: [AudioSegment]
    ) -> [MeetingWindow] {
        var windows: [MeetingWindow] = []
        for sys in system {
            for m in mic {
                let overlapStart = max(sys.startTs, m.startTs)
                let overlapEnd = min(sys.endTs, m.endTs)
                guard overlapEnd > overlapStart else { continue }
                let duration = overlapEnd - overlapStart
                guard duration >= minDurationUs else { continue }
                windows.append(MeetingWindow(
                    startUs: overlapStart,
                    endUs: overlapEnd,
                    app: "audio_overlap",
                    isAudioOverlap: true
                ))
            }
        }
        return mergeNearbyWindows(windows)
    }

    // MARK: - App/Window-Title Detection (Secondary Fallback)

    struct MeetingWindow {
        let startUs: UInt64
        var endUs: UInt64
        var app: String
        var isAudioOverlap: Bool = false
    }

    /// Build contiguous meeting-app focus windows from timeline events.
    /// Secondary detection path — used as fallback for muted-user edge cases.
    private static func buildMeetingWindows(
        from entries: [TimelineEntry],
        rangeEnd: UInt64
    ) -> [MeetingWindow] {
        var windows: [MeetingWindow] = []
        var currentMeeting: MeetingWindow?

        let sorted = entries.sorted { $0.ts < $1.ts }

        for entry in sorted {
            guard entry.eventType == "app_switch",
                  let appName = entry.appName else { continue }

            let isMeeting = isMeetingContext(appName, windowTitle: entry.windowTitle)

            if isMeeting {
                if var meeting = currentMeeting, meeting.app.lowercased() == appName.lowercased() {
                    // Extend current meeting window
                    meeting.endUs = entry.ts
                    currentMeeting = meeting
                } else {
                    // Close previous meeting window if any
                    if var prev = currentMeeting {
                        prev.endUs = entry.ts
                        windows.append(prev)
                    }
                    // Start new meeting window
                    currentMeeting = MeetingWindow(
                        startUs: entry.ts,
                        endUs: entry.ts,
                        app: appName
                    )
                }
            } else {
                // Non-meeting app focused — close current meeting window
                if var meeting = currentMeeting {
                    meeting.endUs = entry.ts
                    windows.append(meeting)
                    currentMeeting = nil
                }
            }
        }

        // Close final open window
        if var meeting = currentMeeting {
            meeting.endUs = rangeEnd
            windows.append(meeting)
        }

        // Merge nearby windows for the same app (brief tab-outs during meetings)
        return mergeNearbyWindows(windows)
    }

    // MARK: - Window Merging & Deduplication

    /// Merge nearby meeting windows with source-aware policy:
    /// - **Audio overlap windows**: merge freely within gap (meeting continuity — user
    ///   switches apps during a call, that's still one meeting).
    /// - **App/title-detected windows**: merge only when same app context. Two different
    ///   meeting apps near each other are likely separate meetings (e.g., Zoom call ends,
    ///   Teams call starts).
    static func mergeNearbyWindows(_ windows: [MeetingWindow]) -> [MeetingWindow] {
        let mergeGapUs: UInt64 = 2 * 60 * 1_000_000  // 2 minutes
        var merged: [MeetingWindow] = []

        let sorted = windows.sorted { $0.startUs < $1.startUs }

        for window in sorted {
            if var last = merged.last,
               window.startUs <= last.endUs + mergeGapUs {
                // Both audio overlap, or at least one is audio overlap → merge freely
                // (audio is the definitive boundary, app changes don't matter)
                if last.isAudioOverlap || window.isAudioOverlap {
                    merged.removeLast()
                    last.endUs = max(last.endUs, window.endUs)
                    if window.isAudioOverlap { last.isAudioOverlap = true }
                    merged.append(last)
                } else if last.app.lowercased() == window.app.lowercased() {
                    // Both app-detected, same app → merge (brief tab-out during one meeting)
                    merged.removeLast()
                    last.endUs = max(last.endUs, window.endUs)
                    merged.append(last)
                } else {
                    // Both app-detected, different apps → keep separate
                    merged.append(window)
                }
            } else {
                merged.append(window)
            }
        }

        return merged
    }

    /// Deduplicate: if an audio overlap window fully covers an app-detected window,
    /// drop the app-detected one (audio overlap has more accurate boundaries).
    private static func deduplicateWindows(
        primary: [MeetingWindow],
        secondary: [MeetingWindow]
    ) -> [MeetingWindow] {
        var result = primary
        for appWindow in secondary {
            let dominated = primary.contains { overlap in
                overlap.startUs <= appWindow.startUs && overlap.endUs >= appWindow.endUs
            }
            if !dominated {
                result.append(appWindow)
            }
        }
        return mergeNearbyWindows(result)
    }

    // MARK: - App Context Resolution

    /// Look up what app was focused during a meeting window.
    /// For audio overlap windows, finds the dominant app from timeline entries.
    private static func resolveAppForWindow(
        _ window: MeetingWindow,
        entries: [TimelineEntry]
    ) -> String {
        guard window.isAudioOverlap else { return window.app }

        // Find app switches within the meeting window
        let windowSwitches = entries
            .filter { $0.eventType == "app_switch" && $0.ts >= window.startUs && $0.ts <= window.endUs }
            .sorted { $0.ts < $1.ts }

        guard !windowSwitches.isEmpty else {
            // No app switches during meeting — try point lookup
            if let ctx = try? findAppAtTimestamp(timestampUs: window.startUs) {
                return ctx.appName
            }
            return "Meeting"
        }

        // Find dominant app by time spent
        var appDurations: [String: UInt64] = [:]
        for (i, entry) in windowSwitches.enumerated() {
            let app = entry.appName ?? "Unknown"
            let nextTs = (i + 1 < windowSwitches.count) ? windowSwitches[i + 1].ts : window.endUs
            appDurations[app, default: 0] += nextTs - entry.ts
        }

        // Return the app with the most time, preferring known meeting apps
        let sorted = appDurations.sorted { $0.value > $1.value }
        for (app, _) in sorted {
            if isMeetingContext(app, windowTitle: nil) {
                return app
            }
        }

        return sorted.first?.key ?? "Meeting"
    }

    // MARK: - Meeting Context Detection

    /// Check if an app/window-title combination indicates a meeting context.
    /// Used by the secondary detection path and app resolution.
    private static func isMeetingContext(_ appName: String, windowTitle: String?) -> Bool {
        // Direct app name match
        let lower = appName.lowercased()
        if meetingApps.contains(where: { lower.contains($0) }) {
            return true
        }
        // Browser with meeting window title (e.g., Google Meet in Chrome)
        guard let title = windowTitle?.lowercased() else { return false }
        return meetingWindowKeywords.contains(where: { title.contains($0) })
    }
}
