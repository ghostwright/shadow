import Foundation

// MARK: - Memory Layers

/// Provenance metadata for any synthesized record.
struct RecordProvenance: Codable, Sendable, Equatable {
    let provider: String
    let modelId: String
    let generatedAt: Date
    let inputHash: String
}

/// A coherent work-session summary.
struct EpisodeRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let startUs: UInt64
    let endUs: UInt64
    let summary: String
    let topicTags: [String]
    let apps: [String]
    let keyArtifacts: [String]
    let evidence: [ContextEvidence]
    let provenance: RecordProvenance
}

/// Day-level synthesis.
struct DailyRecord: Codable, Identifiable, Sendable, Equatable {
    var id: String { date }
    let date: String  // YYYY-MM-DD
    let summary: String
    let wins: [String]
    let openLoops: [String]
    let meetingHighlights: [String]
    let focusBlocks: [FocusBlock]
    let evidence: [ContextEvidence]
    let provenance: RecordProvenance
}

/// A focused work block within a day.
struct FocusBlock: Codable, Sendable, Equatable {
    let app: String
    let startUs: UInt64
    let endUs: UInt64
    let durationMinutes: Int
}

/// Week-level trend synthesis.
struct WeeklyRecord: Codable, Identifiable, Sendable, Equatable {
    var id: String { weekId }
    let weekId: String  // YYYY-Www
    let summary: String
    let majorThemes: [String]
    let carryOverItems: [String]
    let behaviorPatterns: [String]
    let evidence: [ContextEvidence]
    let provenance: RecordProvenance
}

/// Evidence anchor for context records.
struct ContextEvidence: Codable, Sendable, Equatable {
    let timestamp: UInt64
    let app: String?
    let sourceKind: String
    let displayId: UInt32?
    let url: String?
    let snippet: String
}

// MARK: - Heartbeat Checkpoint

/// Persisted checkpoint for resumable heartbeat generation.
struct HeartbeatCheckpoint: Codable, Sendable, Equatable {
    var lastEpisodeEndUs: UInt64?
    var lastDailyDate: String?
    var lastWeeklyWeekId: String?
    var lastHeartbeatAt: Date?
    var consecutiveFailures: Int

    /// When episode synthesis last completed successfully. Used for cooldown decisions.
    var lastEpisodeSynthesisAt: Date?

    /// When daily synthesis last completed successfully. Used for cooldown decisions.
    var lastDailySynthesisAt: Date?

    /// Stable backoff anchor — set only on synthesis failure, cleared on success.
    /// Unlike `lastHeartbeatAt`, this is never updated on skip ticks, so the backoff
    /// window expires correctly relative to the actual failure time.
    var lastFailureAt: Date?

    /// When proactive analysis last ran (fast tick). Used for analyzer cooldown (10 min).
    var lastAnalyzerRunAt: Date?

    /// When deep proactive analysis last ran. Used for deep tick cooldown (30 min).
    var lastDeepAnalyzerRunAt: Date?

    static let empty = HeartbeatCheckpoint(
        lastEpisodeEndUs: nil,
        lastDailyDate: nil,
        lastWeeklyWeekId: nil,
        lastHeartbeatAt: nil,
        consecutiveFailures: 0,
        lastEpisodeSynthesisAt: nil,
        lastDailySynthesisAt: nil,
        lastFailureAt: nil,
        lastAnalyzerRunAt: nil,
        lastDeepAnalyzerRunAt: nil
    )
}

// MARK: - Context Pack

/// Output of the context packer, consumed by agent runtime.
struct ContextPack: Sendable, Equatable {
    let packText: String
    let includedRecords: [IncludedRecord]
    let rawEvidenceRefs: [ContextEvidence]
    let estimatedTokens: Int
    let truncationSummary: String?
}

/// Reference to a record included in a context pack.
struct IncludedRecord: Sendable, Equatable {
    let id: String
    let layer: MemoryLayer
}

/// Memory layer classification.
enum MemoryLayer: String, Codable, Sendable {
    case episode
    case day
    case week
}
