import Foundation
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "ProactiveDeliveryManager")

/// Coordinates delivery of proactive suggestions to UI surfaces.
///
/// Receives persisted suggestions from the analyzer, checks delivery controls
/// (UserDefaults-backed toggles), shows the floating overlay for push_now items
/// when enabled, and records user feedback back to ProactiveStore + TrustTuner.
///
/// @MainActor because all UI operations (overlay, inbox) must run on main thread.
@MainActor
final class ProactiveDeliveryManager {

    // MARK: - UserDefaults Keys

    static let overlayEnabledKey = "proactiveOverlayEnabled"
    static let pushEnabledKey = "proactivePushEnabled"

    // MARK: - Dependencies

    private let proactiveStore: ProactiveStore
    private let trustTuner: TrustTuner

    /// Overlay controller for push_now nudges. Weak to avoid retain cycle.
    weak var overlayController: ProactiveOverlayController?

    /// Callback to open inbox, optionally focused on a specific suggestion.
    var onShowInbox: ((UUID?) -> Void)?

    // MARK: - Delivery Controls

    /// Whether the floating overlay is enabled. Defaults to true.
    var isOverlayEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.overlayEnabledKey) as? Bool ?? true
    }

    /// Whether push suggestions are enabled at all. Defaults to true.
    var isPushEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.pushEnabledKey) as? Bool ?? true
    }

    // MARK: - Init

    init(proactiveStore: ProactiveStore, trustTuner: TrustTuner) {
        self.proactiveStore = proactiveStore
        self.trustTuner = trustTuner
    }

    // MARK: - Delivery

    /// Process newly-persisted suggestions from the analyzer.
    ///
    /// Suggestions are already persisted by ProactiveAnalyzer. This method only
    /// controls whether the overlay fires. No double-writes.
    ///
    /// - Parameter suggestions: Suggestions persisted by the latest analyzer pass.
    func deliverSuggestions(_ suggestions: [ProactiveSuggestion]) {
        for suggestion in suggestions {
            switch suggestion.decision {
            case .pushNow:
                if isPushEnabled && isOverlayEnabled {
                    overlayController?.show(suggestion)
                    logger.info("Overlay shown for suggestion: \(suggestion.id)")
                } else {
                    logger.debug("Overlay suppressed (push=\(self.isPushEnabled), overlay=\(self.isOverlayEnabled)) for: \(suggestion.id)")
                }

            case .inboxOnly:
                // Already in store — nothing to do for delivery
                DiagnosticsStore.shared.increment("proactive_inbox_created_total")

            case .drop:
                // Should never arrive here (analyzer doesn't persist drops)
                break
            }
        }
    }

    // MARK: - Feedback

    /// Record user feedback on a suggestion.
    ///
    /// Persists the feedback event, updates suggestion status, and applies
    /// adaptive feedback to the TrustTuner.
    func recordFeedback(
        suggestionId: UUID,
        eventType: FeedbackEventType,
        foregroundApp: String? = nil,
        displayId: UInt32? = nil
    ) {
        // 1. Persist feedback
        let feedback = ProactiveFeedback(
            id: UUID(),
            suggestionId: suggestionId,
            eventType: eventType,
            timestamp: Date(),
            foregroundApp: foregroundApp,
            displayId: displayId
        )
        proactiveStore.saveFeedback(feedback)

        // 2. Update suggestion status
        let newStatus: SuggestionStatus
        switch eventType {
        case .thumbsUp:
            newStatus = .acted
        case .thumbsDown, .dismiss:
            newStatus = .dismissed
        case .snooze:
            newStatus = .snoozed
        }
        proactiveStore.updateSuggestionStatus(id: suggestionId, status: newStatus)

        // 3. Apply to TrustTuner
        let suggestionType = proactiveStore.findSuggestion(id: suggestionId)?.type ?? .followup
        trustTuner.applyFeedback(feedback, suggestionType: suggestionType)

        // 4. Diagnostics
        let counterKey: String
        switch eventType {
        case .thumbsUp: counterKey = "proactive_feedback_thumbs_up_total"
        case .thumbsDown: counterKey = "proactive_feedback_thumbs_down_total"
        case .dismiss: counterKey = "proactive_feedback_dismiss_total"
        case .snooze: counterKey = "proactive_feedback_snooze_total"
        }
        DiagnosticsStore.shared.increment(counterKey)

        logger.info("Feedback recorded: \(eventType.rawValue) for suggestion \(suggestionId)")
    }
}
