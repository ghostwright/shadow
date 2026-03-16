import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.shadow.app", category: "CommandResponse")

/// Rich response view for displaying a meeting summary.
/// Shows title, overview, key points, decisions, action items, and timestamped highlights.
/// Evidence rows deep-link into the timeline via the same path as search results.
struct CommandResponseView: View {
    let summary: MeetingSummary
    /// Reuses the same deep-link callback as search results.
    var onOpenTimeline: ((UInt64, UInt32?) -> Void)?

    @State private var copiedFeedback = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                overviewSection

                if !summary.keyPoints.isEmpty {
                    keyPointsSection
                }
                if !summary.decisions.isEmpty {
                    decisionsSection
                }
                if !summary.actionItems.isEmpty {
                    actionItemsSection
                }
                if !summary.openQuestions.isEmpty {
                    openQuestionsSection
                }
                if !summary.highlights.isEmpty {
                    highlightsSection
                }

                metadataFooter
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(.title3.bold())
                    .lineLimit(2)

                Text(timeWindowText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                copyToClipboard()
            } label: {
                Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                    .font(.body)
                    .foregroundStyle(copiedFeedback ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy summary to clipboard")
        }
    }

    // MARK: - Overview

    private var overviewSection: some View {
        Text(summary.summary)
            .font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Key Points

    private var keyPointsSection: some View {
        sectionView(title: "Key Points", icon: "list.bullet") {
            ForEach(Array(summary.keyPoints.enumerated()), id: \.offset) { _, point in
                bulletRow(point)
            }
        }
    }

    // MARK: - Decisions

    private var decisionsSection: some View {
        sectionView(title: "Decisions", icon: "checkmark.seal") {
            ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, decision in
                bulletRow(decision)
            }
        }
    }

    // MARK: - Action Items

    private var actionItemsSection: some View {
        sectionView(title: "Action Items", icon: "checklist") {
            ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                actionItemRow(item)
            }
        }
    }

    // MARK: - Open Questions

    private var openQuestionsSection: some View {
        sectionView(title: "Open Questions", icon: "questionmark.circle") {
            ForEach(Array(summary.openQuestions.enumerated()), id: \.offset) { _, question in
                bulletRow(question)
            }
        }
    }

    // MARK: - Highlights

    private var highlightsSection: some View {
        sectionView(title: "Highlights", icon: "star") {
            ForEach(Array(summary.highlights.enumerated()), id: \.offset) { _, highlight in
                highlightRow(highlight)
            }
        }
    }

    // MARK: - Metadata Footer

    private var metadataFooter: some View {
        HStack(spacing: 8) {
            Text(SearchTheme.friendlyProviderName(summary.metadata.provider))
                .foregroundStyle(.tertiary)
            Text("\u{00B7}")
                .foregroundStyle(.quaternary)
            Text(summary.metadata.modelId)
                .foregroundStyle(.tertiary)
            Spacer()
            Text("Esc to return")
                .foregroundStyle(.quaternary)
        }
        .font(.caption)
        .padding(.top, 4)
    }

    // MARK: - Reusable Components

    private func sectionView<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            content()
        }
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}")
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionItemRow(_ item: ActionItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.description)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                if let owner = item.owner, !owner.isEmpty {
                    Label(owner, systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let due = item.dueDateText, !due.isEmpty {
                    Label(due, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(item.evidenceTimestamps.prefix(3), id: \.self) { ts in
                    evidenceLink(ts: ts)
                }
            }
            .padding(.leading, 22)
        }
    }

    private func highlightRow(_ highlight: TimestampedHighlight) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 4) {
                Text(highlight.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                evidenceLink(ts: highlight.tsStart)
            }
        }
    }

    /// Evidence timestamp link that deep-links into the timeline.
    /// Uses the same `onOpenTimeline?(ts, displayID)` callback path as search results.
    private func evidenceLink(ts: UInt64) -> some View {
        Button {
            onOpenTimeline?(ts, nil)
        } label: {
            Label(formatTimestamp(ts), systemImage: "arrow.right.circle.fill")
                .font(.caption)
                .foregroundStyle(SearchTheme.accent)
        }
        .buttonStyle(.plain)
        .help("Jump to this moment in the timeline")
    }

    // MARK: - Formatting

    private var timeFormatter: SummaryTimeFormatter {
        SummaryTimeFormatter(timezoneIdentifier: summary.metadata.sourceWindow.timezone)
    }

    private var timeWindowText: String {
        timeFormatter.formatWindow(
            startUs: summary.metadata.sourceWindow.startUs,
            endUs: summary.metadata.sourceWindow.endUs
        )
    }

    private func formatTimestamp(_ ts: UInt64) -> String {
        timeFormatter.formatTimestamp(ts)
    }

    // MARK: - Clipboard

    private func copyToClipboard() {
        var text = "# \(summary.title)\n\n"
        text += "\(summary.summary)\n\n"

        if !summary.keyPoints.isEmpty {
            text += "## Key Points\n"
            for point in summary.keyPoints {
                text += "- \(point)\n"
            }
            text += "\n"
        }

        if !summary.decisions.isEmpty {
            text += "## Decisions\n"
            for decision in summary.decisions {
                text += "- \(decision)\n"
            }
            text += "\n"
        }

        if !summary.actionItems.isEmpty {
            text += "## Action Items\n"
            for item in summary.actionItems {
                var line = "- [ ] \(item.description)"
                if let owner = item.owner { line += " (@\(owner))" }
                if let due = item.dueDateText { line += " [due: \(due)]" }
                text += "\(line)\n"
            }
            text += "\n"
        }

        if !summary.openQuestions.isEmpty {
            text += "## Open Questions\n"
            for q in summary.openQuestions {
                text += "- \(q)\n"
            }
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation {
            copiedFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                copiedFeedback = false
            }
        }
    }
}
