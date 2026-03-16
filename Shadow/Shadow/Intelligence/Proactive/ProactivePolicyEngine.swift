import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ProactivePolicy")

/// Deterministic policy engine for proactive suggestion delivery decisions.
///
/// Scoring formula:
/// `push_score = evidence_quality + intent_match + utility + urgency
///             + preference_affinity - interruption_cost - repetition_penalty`
///
/// Decision thresholds (configurable via TrustTuner):
/// - `push_now`   if score >= pushThreshold (default 0.82)
/// - `inbox_only` if score >= inboxThreshold (default 0.55)
/// - `drop`       if score < inboxThreshold
///
/// LLM proposes candidates and justifications.
/// This engine makes the final deterministic decision and can veto any proposal.
enum ProactivePolicyEngine {

    // MARK: - Scoring

    /// Compute the push score for a suggestion candidate.
    /// All inputs are in [0, 1]. Returns a score in [0, 1].
    static func computeScore(_ input: PolicyInput, tuner: TrustTuner) -> Double {
        let params = tuner.effectiveParameters()

        let rawScore = input.confidence * 0.40
            + input.evidenceQuality * 0.30
            + input.noveltyScore * 0.10
            + input.preferenceAffinity * 0.10
            - input.interruptionCost * 0.10

        // Apply repetition penalty from tuner
        let repetitionPenalty = params.repetitionPenalty
        let adjusted = rawScore - repetitionPenalty

        return max(0, min(1, adjusted))
    }

    /// Make a delivery decision from a computed score.
    static func decide(score: Double, tuner: TrustTuner) -> PolicyOutput {
        let params = tuner.effectiveParameters()

        let decision: SuggestionDecision
        let rationale: String

        if score >= params.confidenceThreshold {
            decision = .pushNow
            rationale = "Score \(String(format: "%.3f", score)) >= push threshold \(String(format: "%.3f", params.confidenceThreshold))"
        } else if score >= params.inboxThreshold {
            decision = .inboxOnly
            rationale = "Score \(String(format: "%.3f", score)) >= inbox threshold \(String(format: "%.3f", params.inboxThreshold))"
        } else {
            decision = .drop
            rationale = "Score \(String(format: "%.3f", score)) below inbox threshold \(String(format: "%.3f", params.inboxThreshold))"
        }

        return PolicyOutput(decision: decision, score: score, rationale: rationale)
    }

    /// Combined: score + decide.
    static func evaluate(_ input: PolicyInput, tuner: TrustTuner) -> PolicyOutput {
        let score = computeScore(input, tuner: tuner)
        return decide(score: score, tuner: tuner)
    }

    // MARK: - Safety Gates

    /// Check if a suggestion is suppressed by cooldown rules.
    /// Returns a reason string if suppressed, nil if allowed.
    static func checkCooldown(
        type: SuggestionType,
        lastPushTime: Date?,
        now: Date,
        tuner: TrustTuner
    ) -> String? {
        guard let lastPush = lastPushTime else { return nil }

        let params = tuner.effectiveParameters()
        let cooldown = params.cooldownByType[type] ?? params.defaultCooldownSeconds

        let elapsed = now.timeIntervalSince(lastPush)
        if elapsed < cooldown {
            let remaining = Int(cooldown - elapsed)
            return "Cooldown active: \(remaining)s remaining for type \(type.rawValue)"
        }

        return nil
    }

    /// Check if evidence anchors are present (hard safety gate).
    /// Returns nil if valid, error string if invalid.
    static func validateEvidence(_ evidence: [SuggestionEvidence]) -> String? {
        if evidence.isEmpty {
            return "No evidence anchors — suggestion must have at least one evidence reference"
        }
        return nil
    }

    /// Full gate check: cooldown + evidence + suppression context.
    /// Returns nil if all gates pass, first failure reason if any gate fails.
    static func checkGates(
        type: SuggestionType,
        evidence: [SuggestionEvidence],
        lastPushTime: Date?,
        isFullScreen: Bool,
        isActiveTyping: Bool,
        now: Date,
        tuner: TrustTuner
    ) -> String? {
        if let evidenceError = validateEvidence(evidence) {
            return evidenceError
        }

        if isFullScreen {
            return "Suppressed: full-screen app active"
        }

        if isActiveTyping {
            return "Suppressed: active typing burst detected"
        }

        if let cooldownError = checkCooldown(type: type, lastPushTime: lastPushTime, now: now, tuner: tuner) {
            return cooldownError
        }

        return nil
    }
}
