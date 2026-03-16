import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "EventEnvelope")

/// Capture track identifiers matching the Rust index schema.
enum CaptureTrack: UInt8 {
    case lifecycle = 0  // Session lifecycle events
    case visual = 1     // Screen capture metadata
    case input = 2      // Keyboard/mouse input
    case windowApp = 3  // Window/app context
    case audio = 4      // Audio capture (future)
}

/// Identifies which capture subsystem produced an event.
enum EventSource: String {
    case inputMonitor = "input_monitor"
    case windowTracker = "window_tracker"
    case screenRecorder = "screen_recorder"
    case audioCapture = "audio_capture"
    case lifecycle = "lifecycle"
    case axEngine = "ax_engine"
}

/// Thread-safe session clock that generates monotonically increasing
/// sequence numbers and consistent session context for all events.
///
/// One instance per capture session. Created at capture start,
/// shared across all capture subsystems via EventWriter.
final class CaptureSessionClock: @unchecked Sendable {

    /// Unique session ID (generated at capture start).
    let sessionId: String

    private let lock = NSLock()
    private var _seq: UInt64 = 0

    private let timebaseInfo: mach_timebase_info_data_t

    /// Rolling baseline: delta between wall clock and monotonic clock (microseconds).
    /// Re-anchored after each detected jump so the same discontinuity is never
    /// reported twice. Protected by `lock`.
    private var baselineWallMonoDeltaUs: Int64

    /// Threshold for reporting a clock jump (5 seconds).
    private static let clockJumpThresholdUs: Int64 = 5_000_000

    init() {
        self.sessionId = UUID().uuidString

        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        self.timebaseInfo = info

        // Record initial relationship between wall and mono clocks
        let wallUs = Int64(bitPattern: Self.wallMicros())
        let monoTicks = mach_absolute_time()
        let monoUs = Int64(monoTicks * UInt64(info.numer) / UInt64(info.denom) / 1000)
        self.baselineWallMonoDeltaUs = wallUs - monoUs
    }

    /// Get next sequence number (strictly increasing by 1 within session).
    func nextSeq() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        _seq += 1
        return _seq
    }

    /// Current monotonic time in nanoseconds (mach_absolute_time converted).
    func monoNanos() -> UInt64 {
        let ticks = mach_absolute_time()
        return ticks * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
    }

    /// Wall clock timestamp in Unix microseconds.
    static func wallMicros() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }

    /// Check for clock drift between wall clock and monotonic clock.
    /// Returns the drift amount in microseconds if it exceeds the threshold,
    /// nil otherwise. A large drift indicates a clock jump (NTP correction,
    /// sleep/wake clock adjustment, etc.).
    ///
    /// After detecting a jump, the baseline is re-anchored to the current
    /// wall-mono delta. This ensures each real discontinuity is reported
    /// exactly once — subsequent checks see the new baseline and don't
    /// re-report the same jump.
    func checkClockDrift() -> Int64? {
        lock.lock()
        defer { lock.unlock() }

        let wallUs = Int64(bitPattern: Self.wallMicros())
        let monoUs = Int64(monoNanos() / 1000)
        let currentDelta = wallUs - monoUs
        let drift = currentDelta - baselineWallMonoDeltaUs

        if abs(drift) > Self.clockJumpThresholdUs {
            // Re-anchor baseline so this jump is not reported again
            baselineWallMonoDeltaUs = currentDelta
            return drift
        }
        return nil
    }
}
