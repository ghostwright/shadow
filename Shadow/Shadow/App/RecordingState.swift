import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "RecordingState")

/// Shared observable state that bridges capture subsystems with the UI.
/// Owned by AppDelegate, observed by MenuBarView and other UI components.
@Observable
@MainActor
final class RecordingState {
    var isRecording: Bool = false
    var isPaused: Bool = false {
        didSet {
            onPauseChanged?(isPaused)
        }
    }

    /// Callback invoked when isPaused changes. Wired by AppDelegate to
    /// propagate pause/resume to all capture subsystems.
    var onPauseChanged: ((Bool) -> Void)?
    var todayStartTime: Date?
    var screenshotCount: Int = 0
    var appSwitchCount: Int = 0
    var inputEventCount: Int = 0

    /// Activity blocks for today's mini timeline.
    var todayBlocks: [ActivityBlock] = []

    /// Formatted elapsed time since recording started today.
    var elapsedTimeString: String {
        guard let start = todayStartTime, isRecording, !isPaused else {
            return isPaused ? "Paused" : "Not recording"
        }
        let elapsed = Date().timeIntervalSince(start)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Total events captured today.
    var totalEvents: Int {
        screenshotCount + appSwitchCount + inputEventCount
    }

    /// Refresh today's activity blocks and stats from the Rust storage.
    func refreshDaySummary() {
        let dateStr = Self.todayDateString()
        do {
            todayBlocks = try getDaySummary(dateStr: dateStr)
        } catch {
            logger.error("Failed to get day summary: \(error, privacy: .public)")
            todayBlocks = []
        }

        // Derive stats from timeline index
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let startUs = UInt64(startOfDay.timeIntervalSince1970 * 1_000_000)
        let endUs = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        do {
            let entries = try queryTimeRange(startUs: startUs, endUs: endUs)
            appSwitchCount = entries.filter { $0.track == 3 }.count
            inputEventCount = entries.filter { $0.track == 2 }.count
        } catch {
            logger.error("Failed to query today's events: \(error, privacy: .public)")
        }
    }

    /// Count distinct apps from today's blocks.
    var distinctAppCount: Int {
        Set(todayBlocks.map(\.appName)).count
    }

    /// Total events captured today.
    var todayEventCount: Int {
        appSwitchCount + inputEventCount
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func todayDateString() -> String {
        dateFormatter.string(from: Date())
    }
}
