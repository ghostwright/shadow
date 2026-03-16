import Foundation
import CryptoKit

// MARK: - Meeting Summary Schema

/// Structured output from LLM meeting summarization.
/// Codable for JSON persistence, Sendable for actor isolation.
struct MeetingSummary: Codable, Sendable {
    /// Unique summary identifier (UUID string).
    let id: String
    /// Short title for the meeting.
    let title: String
    /// 2-4 sentence overview.
    let summary: String
    /// Bullet points of key topics discussed.
    let keyPoints: [String]
    /// Decisions made during the meeting.
    let decisions: [String]
    /// Action items with optional owners and deadlines.
    let actionItems: [ActionItem]
    /// Open questions that were raised but not resolved.
    let openQuestions: [String]
    /// Timestamped highlights — notable moments with source references.
    let highlights: [TimestampedHighlight]
    /// Metadata about how this summary was generated.
    let metadata: SummaryMetadata
}

/// An action item extracted from the meeting.
struct ActionItem: Codable, Sendable {
    /// What needs to be done.
    let description: String
    /// Who is responsible (if mentioned).
    let owner: String?
    /// Due date text as mentioned (e.g. "by Friday", "next sprint").
    let dueDateText: String?
    /// Source transcript timestamps supporting this action item (Unix microseconds).
    let evidenceTimestamps: [UInt64]
}

/// A notable moment with timestamp references back to the source transcript.
struct TimestampedHighlight: Codable, Sendable {
    /// Brief description of the highlight.
    let text: String
    /// Start of the relevant transcript window (Unix microseconds).
    let tsStart: UInt64
    /// End of the relevant transcript window (Unix microseconds).
    let tsEnd: UInt64
}

/// Metadata about how and when a summary was generated.
struct SummaryMetadata: Codable, Sendable {
    /// Provider that generated this summary (e.g. "local_mlx", "cloud_claude").
    let provider: String
    /// Model identifier (e.g. "Qwen2.5-7B-Instruct-4bit").
    let modelId: String
    /// When this summary was generated.
    let generatedAt: Date
    /// SHA256 hash of the input transcript text (for dedup/coalescing).
    let inputHash: String
    /// The time window this summary covers.
    let sourceWindow: SourceWindow
    /// Estimated input token count.
    let inputTokenEstimate: Int
}

/// The time window a summary covers.
struct SourceWindow: Codable, Sendable {
    /// Start of the window (Unix microseconds).
    let startUs: UInt64
    /// End of the window (Unix microseconds).
    let endUs: UInt64
    /// IANA timezone identifier (e.g. "America/New_York").
    let timezone: String
    /// Session identifier if available.
    let sessionId: String?
}

// MARK: - Validation

/// Typed validation errors for summary schema.
enum SummaryValidationError: Error, Sendable, Equatable {
    case emptyTitle
    case titleTooLong(maxLength: Int)
    case emptySummary
    case summaryTooLong(maxLength: Int)
    case noKeyPoints
    case emptyActionItemDescription(index: Int)
    case highlightOutsideWindow(index: Int, tsStart: UInt64, windowStart: UInt64, windowEnd: UInt64)
}

extension MeetingSummary {
    /// Validate this summary against schema constraints.
    /// Returns all validation errors found (empty = valid).
    func validate() -> [SummaryValidationError] {
        var errors: [SummaryValidationError] = []

        // Title validation
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.emptyTitle)
        } else if title.count > 200 {
            errors.append(.titleTooLong(maxLength: 200))
        }

        // Summary validation
        if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.emptySummary)
        } else if summary.count > 2000 {
            errors.append(.summaryTooLong(maxLength: 2000))
        }

        // Key points
        if keyPoints.isEmpty {
            errors.append(.noKeyPoints)
        }

        // Action items
        for (i, item) in actionItems.enumerated() {
            if item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyActionItemDescription(index: i))
            }
        }

        // Highlights: timestamps must fall within source window
        let windowStart = metadata.sourceWindow.startUs
        let windowEnd = metadata.sourceWindow.endUs
        for (i, highlight) in highlights.enumerated() {
            if highlight.tsStart < windowStart || highlight.tsStart > windowEnd {
                errors.append(.highlightOutsideWindow(
                    index: i,
                    tsStart: highlight.tsStart,
                    windowStart: windowStart,
                    windowEnd: windowEnd
                ))
            }
        }

        return errors
    }
}

// MARK: - Input Hash Computation

/// Compute SHA256 hash of transcript text for dedup/coalescing.
func computeInputHash(_ text: String) -> String {
    let data = Data(text.utf8)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}
