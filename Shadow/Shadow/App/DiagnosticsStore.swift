import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "Diagnostics")

/// Severity levels for diagnostic warnings.
enum DiagnosticSeverity: String, Sendable {
    case warning
    case error
    case critical
}

/// A single warning/error entry in the diagnostics feed.
struct DiagnosticWarning: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let severity: DiagnosticSeverity
    let subsystem: String
    let code: String
    let message: String
    let context: [String: String]
}

/// Thread-safe diagnostics store for capture health metrics.
/// All mutable state is protected by NSLock for safe cross-thread access.
///
/// This is the single source of truth for operational health. The diagnostics
/// panel reads from here; instrumented subsystems write to here.
final class DiagnosticsStore: @unchecked Sendable {
    static let shared = DiagnosticsStore()

    private let lock = NSLock()

    // MARK: - Counters

    private var counters: [String: Int64] = [:]

    /// Increment a named counter by delta (default 1).
    func increment(_ name: String, by delta: Int64 = 1) {
        lock.lock()
        counters[name, default: 0] += delta
        lock.unlock()
    }

    /// Read current value of a counter.
    func counter(_ name: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return counters[name, default: 0]
    }

    // MARK: - Gauges

    private var gauges: [String: Double] = [:]

    /// Set a gauge to an absolute value.
    func setGauge(_ name: String, value: Double) {
        lock.lock()
        gauges[name] = value
        lock.unlock()
    }

    /// Read current value of a gauge.
    func gauge(_ name: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return gauges[name, default: 0]
    }

    // MARK: - String Gauges

    private var stringGauges: [String: String] = [:]

    /// Set a string gauge (e.g. active provider profile name).
    func setStringGauge(_ name: String, value: String) {
        lock.lock()
        stringGauges[name] = value
        lock.unlock()
    }

    /// Read current value of a string gauge.
    func stringGauge(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stringGauges[name]
    }

    // MARK: - High-Water Marks

    private var highWaterMarks: [String: Int64] = [:]

    /// Update a high-water mark (only stores the maximum value seen).
    func updateHighWater(_ name: String, value: Int64) {
        lock.lock()
        let current = highWaterMarks[name, default: 0]
        if value > current {
            highWaterMarks[name] = value
        }
        lock.unlock()
    }

    /// Read current high-water mark.
    func highWater(_ name: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return highWaterMarks[name, default: 0]
    }

    // MARK: - Latency Tracking (P50/P95)

    /// Reservoir-based percentile estimator. Keeps last N samples
    /// and computes percentiles on read.
    private var latencySamples: [String: [Double]] = [:]
    private static let maxSamples = 200

    /// Record a latency sample (in milliseconds).
    func recordLatency(_ name: String, ms: Double) {
        lock.lock()
        var samples = latencySamples[name, default: []]
        if samples.count >= Self.maxSamples {
            samples.removeFirst()
        }
        samples.append(ms)
        latencySamples[name] = samples
        lock.unlock()
    }

    /// Get the p50 (median) for a latency metric.
    func latencyP50(_ name: String) -> Double {
        percentile(name, p: 0.5)
    }

    /// Get the p95 for a latency metric.
    func latencyP95(_ name: String) -> Double {
        percentile(name, p: 0.95)
    }

    private func percentile(_ name: String, p: Double) -> Double {
        lock.lock()
        let samples = latencySamples[name, default: []]
        lock.unlock()

        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = min(Int(Double(sorted.count) * p), sorted.count - 1)
        return sorted[index]
    }

    // MARK: - Warning Feed

    private var warnings: [DiagnosticWarning] = []
    private static let maxWarnings = 100
    /// Rate limiting: (code, contextHash) → last emission time
    private var warningDedup: [String: Date] = [:]
    private static let dedupIntervalSeconds: TimeInterval = 60

    /// Post a warning to the diagnostics feed. Rate-limited by (code, context).
    func postWarning(
        severity: DiagnosticSeverity,
        subsystem: String,
        code: String,
        message: String,
        context: [String: String] = [:]
    ) {
        let dedupKey = "\(code):\(context.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ","))"

        lock.lock()

        // Rate limit
        if let lastTime = warningDedup[dedupKey],
           Date().timeIntervalSince(lastTime) < Self.dedupIntervalSeconds
        {
            lock.unlock()
            return
        }

        warningDedup[dedupKey] = Date()

        let warning = DiagnosticWarning(
            timestamp: Date(),
            severity: severity,
            subsystem: subsystem,
            code: code,
            message: message,
            context: context
        )

        warnings.append(warning)
        if warnings.count > Self.maxWarnings {
            warnings.removeFirst(warnings.count - Self.maxWarnings)
        }

        lock.unlock()

        if severity == .critical || severity == .error {
            logger.error("[\(code)] \(message)")
        }
    }

    /// Get recent warnings (most recent first).
    func recentWarnings(limit: Int = 20) -> [DiagnosticWarning] {
        lock.lock()
        defer { lock.unlock() }
        return Array(warnings.suffix(limit).reversed())
    }

    // MARK: - Snapshot

    /// Create a snapshot of all metrics for export.
    func snapshot() -> DiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }

        return DiagnosticsSnapshot(
            counters: counters,
            gauges: gauges,
            stringGauges: stringGauges,
            highWaterMarks: highWaterMarks,
            latencyP50: latencySamples.mapValues { samples in
                guard !samples.isEmpty else { return 0 }
                let sorted = samples.sorted()
                return sorted[min(Int(Double(sorted.count) * 0.5), sorted.count - 1)]
            },
            latencyP95: latencySamples.mapValues { samples in
                guard !samples.isEmpty else { return 0 }
                let sorted = samples.sorted()
                return sorted[min(Int(Double(sorted.count) * 0.95), sorted.count - 1)]
            },
            warnings: Array(warnings.suffix(20).reversed())
        )
    }

    /// Reset all runtime counters (development only).
    func resetCounters() {
        lock.lock()
        counters.removeAll()
        gauges.removeAll()
        stringGauges.removeAll()
        highWaterMarks.removeAll()
        latencySamples.removeAll()
        lock.unlock()
    }
}

/// Immutable snapshot of diagnostics state for export/display.
struct DiagnosticsSnapshot {
    let counters: [String: Int64]
    let gauges: [String: Double]
    let stringGauges: [String: String]
    let highWaterMarks: [String: Int64]
    let latencyP50: [String: Double]
    let latencyP95: [String: Double]
    let warnings: [DiagnosticWarning]
}
