import SwiftUI

// MARK: - Inbox Filter

/// Filter mode for the suggestion inbox.
enum InboxFilter: String, CaseIterable, Identifiable {
    case active = "Active"
    case pushNow = "Push"
    case inboxOnly = "Inbox"
    case resolved = "Resolved"

    var id: String { rawValue }
}

// MARK: - View Model

/// View model for the Proactive Inbox window.
@Observable
@MainActor
final class ProactiveInboxViewModel {
    var suggestions: [ProactiveSuggestion] = []
    var filter: InboxFilter = .active
    var expandedSuggestionId: UUID?

    /// Deep-link callback — opens timeline at evidence timestamp.
    var onOpenTimeline: ((UInt64, UInt32?) -> Void)?

    /// Feedback callback — routes through ProactiveDeliveryManager.
    var onFeedback: ((UUID, FeedbackEventType) -> Void)?

    /// Suggestion to scroll to on next refresh (set by overlay click-through).
    var focusSuggestionId: UUID?

    private let store: ProactiveStore
    private var refreshTimer: Timer?

    init(store: ProactiveStore) {
        self.store = store
        refresh()
    }

    // MARK: - Computed

    var filteredSuggestions: [ProactiveSuggestion] {
        switch filter {
        case .active:
            return suggestions.filter { $0.status == .active }
        case .pushNow:
            return suggestions.filter { $0.decision == .pushNow && $0.status == .active }
        case .inboxOnly:
            return suggestions.filter { $0.decision == .inboxOnly && $0.status == .active }
        case .resolved:
            return suggestions.filter { [.dismissed, .archived, .acted].contains($0.status) }
        }
    }

    var activeCount: Int {
        suggestions.filter { $0.status == .active }.count
    }

    // MARK: - Actions

    func refresh() {
        suggestions = store.listSuggestions()

        // If a focus target was set, expand it and clear
        if let focusId = focusSuggestionId {
            expandedSuggestionId = focusId
            focusSuggestionId = nil
        }
    }

    func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func toggleExpanded(_ id: UUID) {
        if expandedSuggestionId == id {
            expandedSuggestionId = nil
        } else {
            expandedSuggestionId = id
        }
    }

    func sendFeedback(_ suggestionId: UUID, _ eventType: FeedbackEventType) {
        onFeedback?(suggestionId, eventType)
        // Refresh to reflect status change
        refresh()
    }
}

// MARK: - Main View

struct ProactiveInboxView: View {
    @Bindable var viewModel: ProactiveInboxViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            filterBar
            Divider()
            suggestionsList
        }
        .frame(minWidth: 420, minHeight: 400)
        .background(.regularMaterial)
        .onAppear { viewModel.startAutoRefresh() }
        .onDisappear { viewModel.stopAutoRefresh() }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "tray.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Proactive Inbox")
                    .font(.headline)
                Spacer()

                if viewModel.activeCount > 0 {
                    Text("\(viewModel.activeCount)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
            }

            HStack(spacing: 16) {
                Text("\(viewModel.suggestions.count) total suggestions")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding()
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(InboxFilter.allCases) { filter in
                Button {
                    viewModel.filter = filter
                } label: {
                    Text(filter.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            viewModel.filter == filter
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Suggestions List

    private var suggestionsList: some View {
        Group {
            if viewModel.filteredSuggestions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(viewModel.filteredSuggestions) { suggestion in
                            SuggestionRow(
                                suggestion: suggestion,
                                isExpanded: viewModel.expandedSuggestionId == suggestion.id,
                                onToggle: { viewModel.toggleExpanded(suggestion.id) },
                                onFeedback: { eventType in
                                    viewModel.sendFeedback(suggestion.id, eventType)
                                },
                                onOpenTimeline: viewModel.onOpenTimeline
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.quaternary)
            Text("No suggestions")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(emptyStateMessage)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyStateMessage: String {
        switch viewModel.filter {
        case .active:
            return "No active suggestions. The proactive engine will generate suggestions as it observes your workflow."
        case .pushNow:
            return "No push suggestions right now."
        case .inboxOnly:
            return "No inbox-only suggestions."
        case .resolved:
            return "No resolved suggestions yet."
        }
    }
}

// MARK: - Suggestion Row

private struct SuggestionRow: View {
    let suggestion: ProactiveSuggestion
    let isExpanded: Bool
    let onToggle: () -> Void
    let onFeedback: (FeedbackEventType) -> Void
    let onOpenTimeline: ((UInt64, UInt32?) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Summary row
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    // Type icon
                    Image(systemName: ProactiveOverlayView.iconName(for: suggestion.type))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)

                        Text(suggestion.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        decisionBadge(suggestion.decision)
                        Text(suggestion.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Expanded detail
            if isExpanded {
                expandedDetail
            }
        }
        .background(.background)
    }

    // MARK: - Decision Badge

    private func decisionBadge(_ decision: SuggestionDecision) -> some View {
        Text(decision == .pushNow ? "Push" : "Inbox")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (decision == .pushNow ? Color.orange : Color.blue).opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(decision == .pushNow ? .orange : .blue)
    }

    // MARK: - Expanded Detail

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            // Why now
            VStack(alignment: .leading, spacing: 4) {
                Text("Why now")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(suggestion.whyNow)
                    .font(.caption)
            }

            // Confidence
            HStack(spacing: 8) {
                Text("Confidence")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.2f", suggestion.confidence))
                    .font(.caption.monospacedDigit())
                Text(suggestion.confidenceBand.rawValue.capitalized)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        ProactiveOverlayView.bandColor(suggestion.confidenceBand).opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundStyle(ProactiveOverlayView.bandColor(suggestion.confidenceBand))
            }

            // Status
            HStack(spacing: 8) {
                Text("Status")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(suggestion.status.rawValue.capitalized)
                    .font(.caption)
            }

            // Evidence
            if !suggestion.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Evidence (\(suggestion.evidence.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(Array(suggestion.evidence.enumerated()), id: \.offset) { _, evidence in
                        Button {
                            onOpenTimeline?(evidence.timestamp, evidence.displayId)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    if let app = evidence.app {
                                        Text(app)
                                            .font(.caption2.weight(.medium))
                                    }
                                    Text(evidence.snippet)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Actions (only for active suggestions)
            if suggestion.status == .active {
                Divider()
                actionBar
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .transition(.opacity)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            actionButton("hand.thumbsup", label: "Helpful", color: .green) {
                onFeedback(.thumbsUp)
            }
            actionButton("hand.thumbsdown", label: "Not helpful", color: .red) {
                onFeedback(.thumbsDown)
            }
            actionButton("xmark", label: "Dismiss", color: .secondary) {
                onFeedback(.dismiss)
            }
            actionButton("clock", label: "Snooze", color: .orange) {
                onFeedback(.snooze)
            }
            Spacer()
        }
    }

    private func actionButton(
        _ icon: String,
        label: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
