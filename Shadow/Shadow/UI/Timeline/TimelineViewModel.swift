import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "Timeline")

/// View model for the timeline — loads data, manages playhead, extracts frames.
@Observable
@MainActor
final class TimelineViewModel {
    /// Pending jump from search deep-link, consumed on window open.
    /// Both producer (SearchPanelController) and consumer run on @MainActor.
    static var pendingJump: (timestamp: UInt64, displayID: UInt32?)?

    var currentDate: Date = Date()
    var playheadPosition: Double = 1.0 // 0.0 = visible start, 1.0 = visible end
    var currentFrame: CGImage?
    var appEntries: [TimelineEntry] = []
    var inputEntries: [TimelineEntry] = []
    var allEntries: [TimelineEntry] = []
    var audioSegments: [AudioSegment] = []

    /// Mic-only segments for the dedicated Mic timeline row.
    var micSegments: [AudioSegment] { audioSegments.filter { $0.source == "mic" } }

    /// System-only segments for the dedicated System timeline row.
    var systemSegments: [AudioSegment] { audioSegments.filter { $0.source == "system" } }

    /// Display IDs with video data for the current day. Derived from video_segments.
    var availableDisplayIDs: [CGDirectDisplayID] = []

    /// User-selected display for frame extraction. Set by display picker or deep-link.
    /// Reconciled with availableDisplayIDs on each loadDay() call.
    /// Fallback chain: selectedDisplayID → availableDisplayIDs.first → CGMainDisplayID().
    var selectedDisplayID: CGDirectDisplayID?

    /// Whether the display picker should be visible (>1 display with data).
    var showDisplayPicker: Bool { availableDisplayIDs.count > 1 }

    private var lastFrameExtractionTime: TimeInterval = 0

    /// When true, loadDay() skips default playhead positioning.
    /// Set by jumpToTimestamp() before its internal loadDay() call,
    /// cleared by loadDay() after honoring the flag.
    private var suppressDefaultPlayhead: Bool = false

    private var jumpObserver: NSObjectProtocol?

    init() {}

    /// Start listening for search deep-link notifications.
    /// Called from TimelineView.onAppear — not from init — so the observer
    /// lifecycle is tied to the view's presence, not object allocation.
    ///
    /// Returns true if a pending jump was consumed (caller should skip loadDay).
    @discardableResult
    func startObserving() -> Bool {
        guard jumpObserver == nil else { return false }
        jumpObserver = NotificationCenter.default.addObserver(
            forName: .shadowJumpToTimestamp,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let ts = notification.userInfo?["timestamp"] as? UInt64 else { return }
            let displayID = notification.userInfo?["displayID"] as? UInt32
            Task { @MainActor in
                Self.pendingJump = nil
                self.jumpToTimestamp(ts, displayID: displayID)
            }
        }

        // Consume any pending jump stored before the window opened.
        // This handles the case where SearchPanelController opened the window
        // via OpenWindowAction and the notification was not yet dispatched.
        if let jump = Self.pendingJump {
            Self.pendingJump = nil
            DiagnosticsStore.shared.increment("timeline_deeplink_pending_consumed_total")
            jumpToTimestamp(jump.timestamp, displayID: jump.displayID)
            return true
        }
        return false
    }

    /// Stop listening for search deep-link notifications.
    /// Called from TimelineView.onDisappear to prevent dangling observers.
    func stopObserving() {
        if let observer = jumpObserver {
            NotificationCenter.default.removeObserver(observer)
            jumpObserver = nil
        }
    }


    // MARK: - Display

    var displayDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d, yyyy"
        return formatter.string(from: currentDate)
    }

    var canGoNext: Bool {
        !Calendar.current.isDateInToday(currentDate)
    }

    // MARK: - Query Range (full day, used for loading data)

    private var queryStartUs: UInt64 {
        let start = Calendar.current.startOfDay(for: currentDate)
        return UInt64(start.timeIntervalSince1970 * 1_000_000)
    }

    private var queryEndUs: UInt64 {
        if Calendar.current.isDateInToday(currentDate) {
            return UInt64(Date().timeIntervalSince1970 * 1_000_000)
        }
        let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: currentDate)!
        return UInt64(end.timeIntervalSince1970 * 1_000_000)
    }

    // MARK: - Visible Range (zoomed to data, used by views)

    /// Start of the visible range — first event's hour boundary.
    var visibleStartUs: UInt64 {
        guard let first = allEntries.first else { return queryStartUs }
        let date = Date(timeIntervalSince1970: Double(first.ts) / 1_000_000)
        guard let interval = Calendar.current.dateInterval(of: .hour, for: date) else {
            return queryStartUs
        }
        return UInt64(interval.start.timeIntervalSince1970 * 1_000_000)
    }

    /// End of the visible range — current time's (or last event's) next hour boundary.
    var visibleEndUs: UInt64 {
        let endDate: Date
        if Calendar.current.isDateInToday(currentDate) {
            endDate = Date()
        } else if let last = allEntries.last {
            endDate = Date(timeIntervalSince1970: Double(last.ts) / 1_000_000)
        } else {
            return queryEndUs
        }
        guard let interval = Calendar.current.dateInterval(of: .hour, for: endDate) else {
            return queryEndUs
        }
        let endUs = UInt64(interval.end.timeIntervalSince1970 * 1_000_000)

        // Ensure minimum 2-hour visible range for readability
        let startUs = visibleStartUs
        let minRange: UInt64 = 2 * 3600 * 1_000_000
        return max(endUs, startUs + minRange)
    }

    // MARK: - Playhead

    var playheadTimestamp: UInt64 {
        let start = visibleStartUs
        let end = visibleEndUs
        guard end > start else { return start }
        let range = end - start
        return start + UInt64(Double(range) * playheadPosition)
    }

    var playheadDate: Date {
        Date(timeIntervalSince1970: Double(playheadTimestamp) / 1_000_000)
    }

    var currentAppName: String? {
        let ts = playheadTimestamp
        return appEntries.last(where: { $0.ts <= ts })?.appName
    }

    var currentWindowTitle: String? {
        let ts = playheadTimestamp
        return appEntries.last(where: { $0.ts <= ts })?.windowTitle
    }

    // MARK: - Actions

    func loadDay() {
        let startUs = queryStartUs
        let endUs = queryEndUs

        do {
            allEntries = try queryTimeRange(startUs: startUs, endUs: endUs)
            appEntries = allEntries.filter { $0.track == 3 }
            inputEntries = allEntries.filter { $0.track == 2 }
        } catch {
            logger.error("Failed to load timeline: \(error, privacy: .public)")
            allEntries = []
            appEntries = []
            inputEntries = []
        }

        // Enumerate displays with video data for this day
        do {
            let segments = try listVideoSegments(startUs: startUs, endUs: endUs)
            let uniqueIDs = Set(segments.map { CGDirectDisplayID($0.displayId) })
            availableDisplayIDs = uniqueIDs.sorted()
        } catch {
            availableDisplayIDs = []
        }

        // Reconcile selectedDisplayID with available displays for this day.
        // If the current selection is stale (not in today's data), reset it.
        if let selected = selectedDisplayID, !availableDisplayIDs.contains(selected) {
            selectedDisplayID = availableDisplayIDs.first
        }

        // Load audio segments for the day range (off-main via detached task)
        Task.detached(priority: .userInitiated) {
            let segments: [AudioSegment]
            do {
                segments = try listAudioSegments(startUs: startUs, endUs: endUs)
            } catch {
                logger.error("Failed to load audio segments: \(error, privacy: .public)")
                await MainActor.run { self.audioSegments = [] }
                return
            }
            await MainActor.run { self.audioSegments = segments }
        }

        // Position playhead — skip if a deep-link jump will set it instead
        if suppressDefaultPlayhead {
            suppressDefaultPlayhead = false
        } else if Calendar.current.isDateInToday(currentDate) {
            let nowUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            let start = visibleStartUs
            let end = visibleEndUs
            guard end > start else {
                playheadPosition = 1.0
                extractFrameAtPlayhead()
                return
            }
            let range = end - start
            let offset = nowUs >= start ? nowUs - start : 0
            playheadPosition = max(0, min(1, Double(offset) / Double(range)))
        } else {
            playheadPosition = 0.5
        }

        extractFrameAtPlayhead()
    }

    func previousDay() {
        currentDate = Calendar.current.date(byAdding: .day, value: -1, to: currentDate)!
        loadDay()
    }

    func nextDay() {
        guard canGoNext else { return }
        currentDate = Calendar.current.date(byAdding: .day, value: 1, to: currentDate)!
        loadDay()
    }

    /// Jump to a specific timestamp (from search result deep-link).
    /// Navigates to the correct day, positions the playhead, and uses the
    /// provided display ID for frame extraction (falling back to main display).
    func jumpToTimestamp(_ ts: UInt64, displayID: UInt32? = nil) {
        DiagnosticsStore.shared.increment("timeline_deeplink_attempt_total")

        // Set display context for frame extraction
        selectedDisplayID = displayID.map { CGDirectDisplayID($0) }

        let targetDate = Date(timeIntervalSince1970: Double(ts) / 1_000_000)
        let targetDay = Calendar.current.startOfDay(for: targetDate)
        let currentDay = Calendar.current.startOfDay(for: currentDate)

        // Switch days if needed — suppress default playhead so loadDay() doesn't overwrite
        if targetDay != currentDay {
            currentDate = targetDate
            suppressDefaultPlayhead = true
            loadDay()
        }

        // Position playhead at the target timestamp
        let start = visibleStartUs
        let end = visibleEndUs
        let range = end - start
        guard range > 0 else { return }

        let offset = ts >= start ? ts - start : 0
        let position = Double(offset) / Double(range)
        playheadPosition = max(0, min(1, position))
        extractFrameAtPlayhead()

        DiagnosticsStore.shared.increment("timeline_deeplink_success_total")
        logger.info("Timeline jump to \(ts)")
    }

    /// Switch display for frame extraction (from display picker).
    func selectDisplay(_ id: CGDirectDisplayID) {
        selectedDisplayID = id
        extractFrameAtPlayhead()
    }

    func scrubTo(position: Double) {
        playheadPosition = max(0, min(1, position))

        // Throttle frame extraction during fast scrubbing
        let now = Date().timeIntervalSince1970
        guard now - lastFrameExtractionTime > 0.2 else { return }
        lastFrameExtractionTime = now

        extractFrameAtPlayhead()
    }

    private func extractFrameAtPlayhead() {
        let timestamp = Double(playheadTimestamp) / 1_000_000
        let displayID: CGDirectDisplayID = selectedDisplayID ?? availableDisplayIDs.first ?? CGMainDisplayID()

        Task {
            do {
                let frame = try await FrameExtractor.extractFrame(
                    at: timestamp,
                    displayID: displayID
                )
                self.currentFrame = frame
            } catch {
                logger.debug("Frame extraction failed: \(error, privacy: .public)")
                self.currentFrame = nil
            }
        }
    }
}
