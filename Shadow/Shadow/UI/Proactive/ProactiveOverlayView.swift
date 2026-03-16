import SwiftUI

/// Compact floating nudge card for push_now suggestions.
///
/// Shows suggestion type icon, title, whyNow, and confidence band.
/// Tapping opens the inbox. Dismiss button removes the overlay.
struct ProactiveOverlayView: View {

    let suggestion: ProactiveSuggestion
    var onDismiss: () -> Void
    var onOpenInbox: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: Self.iconName(for: suggestion.type))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Text(suggestion.whyNow)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            // Confidence band pill
            Text(suggestion.confidenceBand.rawValue.capitalized)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Self.bandColor(suggestion.confidenceBand).opacity(0.15))
                .foregroundStyle(Self.bandColor(suggestion.confidenceBand))
                .clipShape(Capsule())

            // Dismiss button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss suggestion")
        }
        .padding(12)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onOpenInbox() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Suggestion: \(suggestion.title). \(suggestion.whyNow)")
        .accessibilityHint("Tap to view in inbox")
    }

    // MARK: - SF Symbol Mapping

    static func iconName(for type: SuggestionType) -> String {
        switch type {
        case .meetingPrep: return "person.3.fill"
        case .followup: return "arrow.uturn.forward"
        case .workloadPattern: return "chart.bar.fill"
        case .reminder: return "bell.fill"
        case .contextSwitch: return "arrow.triangle.branch"
        case .dailyDigest: return "sun.max.fill"
        }
    }

    // MARK: - Confidence Band Colors

    static func bandColor(_ band: ConfidenceBand) -> Color {
        switch band {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }
}
