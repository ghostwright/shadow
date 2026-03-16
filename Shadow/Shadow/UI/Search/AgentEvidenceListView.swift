import SwiftUI

/// Evidence list from an agent run result.
/// Each row shows timestamp, app, source kind, snippet, and a deep-link button.
/// Deep-link uses the same `onOpenTimeline?(timestamp, displayId)` callback path as search results.
struct AgentEvidenceListView: View {
    let evidence: [AgentEvidenceItem]
    var onOpenTimeline: ((UInt64, UInt32?) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Evidence")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text("(\(evidence.count))")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }

            ForEach(Array(evidence.prefix(10).enumerated()), id: \.offset) { _, item in
                evidenceRow(item)
            }

            if evidence.count > 10 {
                Text("\(evidence.count - 10) more items not shown")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
    }

    private func evidenceRow(_ item: AgentEvidenceItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let app = item.app {
                    Text(app)
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                }
                Text(item.sourceKind)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(SearchTheme.accentSoft, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)

                if let displayId = item.displayId {
                    Text("Display \(displayId)")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }

                Spacer()

                Button {
                    onOpenTimeline?(item.timestamp, item.displayId)
                } label: {
                    Label(formatTimestamp(item.timestamp), systemImage: "arrow.right.circle.fill")
                        .font(.caption)
                        .foregroundStyle(SearchTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Jump to this moment in the timeline")
            }

            if !item.snippet.isEmpty {
                Text(item.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let url = item.url, !url.isEmpty {
                Text(url)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatTimestamp(_ ts: UInt64) -> String {
        let date = Date(timeIntervalSince1970: Double(ts) / 1_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
