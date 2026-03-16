// Apple Foundation Models structured output types.
//
// These types use the @Generable macro from the FoundationModels framework
// for constrained decoding (guided generation). This guarantees structural
// correctness — no JSON parsing failures.
//
// The entire file is wrapped in #if canImport(FoundationModels) because
// the framework is only available in Xcode 26+ SDK (macOS 26+).
// On the current build system (Xcode 16.4, macOS 15), this file compiles
// as an empty translation unit.
//
// These types are aspirational for Phase 5. The text-based
// AppleFoundationProvider works today (with graceful degradation).
// Structured output with @Generable will be enabled when the SDK ships.

#if canImport(FoundationModels)
import FoundationModels

// MARK: - Activity Classification

/// Activity classification for ContextHeartbeat.
/// Used to quickly categorize what the user is doing from recent context.
@available(macOS 26, *)
@Generable
struct ActivityClassification {
    @Guide(description: "Primary activity type: coding, writing, browsing, communication, meeting, design, reading, media, or other")
    var activityType: String

    @Guide(description: "Confidence from 0.0 to 1.0")
    var confidence: Double

    @Guide(description: "Key entities: app names, URLs, people, projects")
    var entities: [String]

    @Guide(description: "One-sentence summary of what the user is doing")
    var summary: String
}

// MARK: - Nudge Classification

/// Proactive nudge classification for ProactiveLiveAnalyzer.
/// Determines whether a proactive suggestion is warranted.
@available(macOS 26, *)
@Generable
struct NudgeClassification {
    @Guide(description: "Whether a proactive suggestion is warranted")
    var shouldNudge: Bool

    @Guide(description: "Category: reminder, insight, connection, summary, or none")
    var nudgeType: String

    @Guide(description: "Brief reason for the decision")
    var reasoning: String
}

// MARK: - Intent Classification

/// Intent classification for AgentRuntime tier routing.
/// Classifies user requests to determine which LLM tier should handle them.
@available(macOS 26, *)
@Generable
struct IntentClassification {
    @Guide(description: "Complexity: simple, moderate, or complex")
    var complexity: String

    @Guide(description: "Whether the request requires tool calls")
    var requiresTools: Bool

    @Guide(description: "Which tools might be needed")
    var likelyTools: [String]
}

#endif
