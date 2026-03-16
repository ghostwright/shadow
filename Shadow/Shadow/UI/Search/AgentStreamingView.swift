import SwiftUI

/// View displaying the live agent run: header, streaming answer, tool timeline, and evidence.
/// Used for both `.agentStreaming` (in-flight) and `.agentResult` (completed) states.
struct AgentStreamingView: View {
    let state: AgentStreamState
    let isComplete: Bool
    var onOpenTimeline: ((UInt64, UInt32?) -> Void)?

    @State private var copiedFeedback = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                answerSection

                if !state.toolTimeline.isEmpty {
                    toolTimelineSection
                }

                if !state.evidence.isEmpty && isComplete {
                    AgentEvidenceListView(
                        evidence: state.evidence,
                        onOpenTimeline: onOpenTimeline
                    )
                }

                if isComplete, let metrics = state.metrics {
                    metricsFooter(metrics)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Header

    /// Ghost mood derived from completion state.
    private var ghostMood: GhostMood {
        isComplete ? .happy : .speaking
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    ExpressiveGhostView(
                        mood: .constant(ghostMood),
                        size: 40
                    )
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusText)
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        if let intent = state.classifiedIntent {
                            Text(formatIntentBadge(intent))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.fill.tertiary, in: Capsule())
                        }
                    }
                }

                Text(state.task)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            Spacer()

            if isComplete {
                Button {
                    copyAnswerToClipboard()
                } label: {
                    Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                        .font(.body)
                        .foregroundStyle(copiedFeedback ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy answer to clipboard")
            }
        }
    }

    private var statusText: String {
        switch state.status {
        case .starting:
            "Remembering\u{2026}"
        case .streaming:
            "Thinking\u{2026}"
        case .toolRunning:
            if let active = state.toolTimeline.last(where: { $0.status == .running }) {
                "Searching: \(formatToolName(active.name))\u{2026}"
            } else {
                "Searching your timeline\u{2026}"
            }
        case .complete:
            "Here\u{2019}s what I found"
        }
    }

    // MARK: - Answer

    @ViewBuilder
    private var answerSection: some View {
        if state.liveAnswer.isEmpty && !isComplete {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Gathering information\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text(state.liveAnswer)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Tool Timeline

    private var toolTimelineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tools")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)

            ForEach(state.toolTimeline) { entry in
                toolRow(entry)
            }
        }
    }

    private func toolRow(_ entry: ToolActivityEntry) -> some View {
        HStack(spacing: 8) {
            toolStatusIcon(entry.status)
                .frame(width: 14)

            Text(formatToolName(entry.name))
                .font(.caption)
                .foregroundStyle(.primary)

            Spacer()

            switch entry.status {
            case .running:
                ProgressView()
                    .controlSize(.mini)
            case .completed(let ms):
                Text("\(Int(ms))ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            case .failed:
                Text("failed")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func toolStatusIcon(_ status: ToolActivityStatus) -> some View {
        switch status {
        case .running:
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(.orange)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        }
    }

    /// Format classified intent into a human-readable badge label.
    private func formatIntentBadge(_ intent: String) -> String {
        switch intent {
        case "simpleQuestion": return "Quick Answer"
        case "memorySearch": return "Memory Search"
        case "procedureReplay": return "Procedure Replay"
        case "procedureLearning": return "Learning Mode"
        case "complexReasoning": return "Deep Analysis"
        case "directiveCreation": return "Creating Directive"
        case "uiAction": return "UI Action"
        case "ambiguous": return "Analyzing..."
        default: return intent
        }
    }

    /// Format tool_name_with_underscores to Title Case With Spaces.
    private func formatToolName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: - Metrics Footer

    private func metricsFooter(_ metrics: AgentRunMetrics) -> some View {
        HStack(spacing: 8) {
            Text(SearchTheme.friendlyProviderName(metrics.provider))
                .foregroundStyle(.tertiary)
            Text("\u{00B7}")
                .foregroundStyle(.quaternary)
            Text(metrics.modelId)
                .foregroundStyle(.tertiary)
            Text("\u{00B7}")
                .foregroundStyle(.quaternary)
            Text(SearchTheme.formatSteps(metrics.stepCount))
                .foregroundStyle(.tertiary)
            Text("\u{00B7}")
                .foregroundStyle(.quaternary)
            Text(SearchTheme.formatDuration(ms: metrics.totalMs))
                .foregroundStyle(.tertiary)
            Spacer()
            Text("Esc to return")
                .foregroundStyle(.quaternary)
        }
        .font(.caption)
        .padding(.top, 4)
    }

    // MARK: - Clipboard

    private func copyAnswerToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.liveAnswer, forType: .string)

        withAnimation { copiedFeedback = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copiedFeedback = false }
        }
    }
}
