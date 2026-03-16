import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "TrustTuner")

/// Tunable policy parameters for the proactive engine.
/// Updated from explicit user feedback with bounded step sizes.
struct TrustParameters: Codable, Sendable, Equatable {
    /// Minimum score to push a suggestion as an overlay nudge.
    var confidenceThreshold: Double
    /// Minimum score to store in inbox (below this → drop).
    var inboxThreshold: Double
    /// Global repetition penalty applied to scoring.
    var repetitionPenalty: Double
    /// Per-type cooldown in seconds before re-pushing same type.
    var cooldownByType: [SuggestionType: Double]
    /// Default cooldown when no type-specific override exists.
    var defaultCooldownSeconds: Double
    /// Per-type preference weights from feedback history.
    var preferredSuggestionTypes: [SuggestionType: Double]

    /// Factory defaults used when no feedback history exists or data is corrupt.
    static let defaults = TrustParameters(
        confidenceThreshold: 0.60,
        inboxThreshold: 0.35,
        repetitionPenalty: 0.0,
        cooldownByType: [:],
        defaultCooldownSeconds: 300,
        preferredSuggestionTypes: [:]
    )
}

/// Per-user trust parameter store with bounded feedback-driven updates.
/// Thread-safe via NSLock. Persists to JSON under `~/.shadow/data/proactive/`.
final class TrustTuner: @unchecked Sendable {

    private let lock = NSLock()
    private var parameters: TrustParameters
    private let filePath: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // Bounded step sizes — prevents runaway drift from noisy feedback.
    static let maxConfidenceStep: Double = 0.02
    static let maxRepetitionStep: Double = 0.01
    static let maxPreferenceStep: Double = 0.05
    static let maxCooldownStep: Double = 30

    // Hard bounds — parameters cannot leave these ranges.
    static let confidenceRange: ClosedRange<Double> = 0.40...0.95
    static let inboxRange: ClosedRange<Double> = 0.20...0.80
    static let repetitionRange: ClosedRange<Double> = 0.0...0.30
    static let preferenceRange: ClosedRange<Double> = -0.50...0.50
    static let cooldownRange: ClosedRange<Double> = 60...3600

    /// Minimum gap between confidenceThreshold and inboxThreshold.
    /// Prevents the push_now range from overlapping inbox_only.
    static let thresholdGap: Double = 0.05

    init(baseDir: String? = nil) {
        let base = baseDir ?? TrustTuner.defaultBaseDir()
        self.filePath = (base as NSString).appendingPathComponent("trust_parameters.json")

        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Ensure directory exists
        let dir = (filePath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // Load persisted parameters or use defaults
        if let data = FileManager.default.contents(atPath: filePath),
           let loaded = try? decoder.decode(TrustParameters.self, from: data) {
            self.parameters = loaded
        } else {
            self.parameters = .defaults
        }

        enforceThresholdInvariant()
    }

    /// Current effective parameters (thread-safe read).
    func effectiveParameters() -> TrustParameters {
        lock.lock()
        defer { lock.unlock() }
        return parameters
    }

    // MARK: - Feedback-Driven Updates

    /// Update parameters based on a feedback event.
    /// Bounded step sizes prevent runaway drift.
    func applyFeedback(_ feedback: ProactiveFeedback, suggestionType: SuggestionType) {
        lock.lock()
        defer { lock.unlock() }

        switch feedback.eventType {
        case .thumbsUp:
            // Lower confidence threshold slightly (more permissive)
            parameters.confidenceThreshold = clamp(
                parameters.confidenceThreshold - Self.maxConfidenceStep,
                range: Self.confidenceRange
            )
            // Boost preference for this type
            let current = parameters.preferredSuggestionTypes[suggestionType] ?? 0
            parameters.preferredSuggestionTypes[suggestionType] = clamp(
                current + Self.maxPreferenceStep,
                range: Self.preferenceRange
            )
            DiagnosticsStore.shared.increment("proactive_tuner_update_total")

        case .thumbsDown:
            // Raise confidence threshold (more selective)
            parameters.confidenceThreshold = clamp(
                parameters.confidenceThreshold + Self.maxConfidenceStep,
                range: Self.confidenceRange
            )
            // Penalize this type
            let current = parameters.preferredSuggestionTypes[suggestionType] ?? 0
            parameters.preferredSuggestionTypes[suggestionType] = clamp(
                current - Self.maxPreferenceStep,
                range: Self.preferenceRange
            )
            // Increase repetition penalty slightly
            parameters.repetitionPenalty = clamp(
                parameters.repetitionPenalty + Self.maxRepetitionStep,
                range: Self.repetitionRange
            )
            DiagnosticsStore.shared.increment("proactive_tuner_update_total")

        case .dismiss:
            // Mild signal — increase cooldown for this type
            let currentCooldown = parameters.cooldownByType[suggestionType]
                ?? parameters.defaultCooldownSeconds
            parameters.cooldownByType[suggestionType] = clamp(
                currentCooldown + Self.maxCooldownStep,
                range: Self.cooldownRange
            )
            DiagnosticsStore.shared.increment("proactive_tuner_update_total")

        case .snooze:
            // Mild signal — increase cooldown more aggressively
            let currentCooldown = parameters.cooldownByType[suggestionType]
                ?? parameters.defaultCooldownSeconds
            parameters.cooldownByType[suggestionType] = clamp(
                currentCooldown + Self.maxCooldownStep * 2,
                range: Self.cooldownRange
            )
            DiagnosticsStore.shared.increment("proactive_tuner_update_total")
        }

        enforceThresholdInvariant()
        persist()
    }

    /// Reset to factory defaults. Used when data is corrupt or for testing.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        parameters = .defaults
        enforceThresholdInvariant()
        persist()
        DiagnosticsStore.shared.increment("proactive_tuner_fallback_total")
    }

    // MARK: - Private

    /// Ensure confidenceThreshold stays above inboxThreshold + gap.
    /// Prevents push_now range from overlapping inbox_only range.
    /// Called under lock — must not acquire lock.
    private func enforceThresholdInvariant() {
        parameters.confidenceThreshold = max(
            parameters.confidenceThreshold,
            parameters.inboxThreshold + Self.thresholdGap
        )
    }

    private func clamp(_ value: Double, range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Persist current parameters to disk. Called under lock.
    private func persist() {
        do {
            let data = try encoder.encode(parameters)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch {
            logger.error("Failed to persist trust parameters: \(error, privacy: .public)")
        }
    }

    private static func defaultBaseDir() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".shadow/data/proactive").path
    }
}
