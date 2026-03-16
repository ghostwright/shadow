import SwiftUI

// MARK: - View Model

/// Filter mode for the run records list.
enum ProactiveActivityFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case pushed = "Pushed"
    case errors = "Errors"

    var id: String { rawValue }
}

/// View model for the Proactive Activity window.
@Observable
@MainActor
final class ProactiveActivityViewModel {
    var records: [ProactiveRunRecord] = []
    var filter: ProactiveActivityFilter = .all
    var engineStatus: ProactiveEngineStatus = .idle
    var lastRunDate: Date?
    var nextEligibleDate: Date?
    var expandedRecordId: UUID?

    /// Deep-link callback — wired by window controller.
    var onOpenTimeline: ((UInt64, UInt32?) -> Void)?

    private let store: ProactiveStore
    private let tuner: TrustTuner
    private var refreshTimer: Timer?

    init(store: ProactiveStore, tuner: TrustTuner) {
        self.store = store
        self.tuner = tuner
        refresh()
    }

    var filteredRecords: [ProactiveRunRecord] {
        switch filter {
        case .all:
            return records
        case .pushed:
            return records.filter { $0.decision == .pushNow }
        case .errors:
            return records.filter { $0.status == .failed }
        }
    }

    func refresh() {
        records = store.listRunRecords()
        lastRunDate = records.first?.startedAt

        // Engine status: running > backoff > error > idle
        if let last = records.first, last.status == .running {
            engineStatus = .running
        } else {
            let backoffActive = DiagnosticsStore.shared.gauge("context_backoff_active")
            if backoffActive > 0 {
                engineStatus = .backoff
            } else if let last = records.first, last.status == .failed {
                engineStatus = .error
            } else {
                engineStatus = .idle
            }
        }

        // Effective parameters for display
        let params = tuner.effectiveParameters()
        if let lastRun = lastRunDate {
            nextEligibleDate = lastRun.addingTimeInterval(params.defaultCooldownSeconds)
        }
    }

    func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
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
        if expandedRecordId == id {
            expandedRecordId = nil
        } else {
            expandedRecordId = id
        }
    }
}

// MARK: - Main View

struct ProactiveActivityView: View {
    @Bindable var viewModel: ProactiveActivityViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            filterBar
            Divider()
            recordsList
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
                Image(systemName: "brain.head.profile")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Proactive Engine")
                    .font(.headline)
                Spacer()
                statusChip(viewModel.engineStatus)
            }

            HStack(spacing: 16) {
                if let last = viewModel.lastRunDate {
                    Label {
                        Text("Last run: \(last, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "clock")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("No runs yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let next = viewModel.nextEligibleDate, next > Date() {
                    Label {
                        Text("Next eligible: \(next, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "timer")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Text("\(viewModel.records.count) records")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(ProactiveActivityFilter.allCases) { filter in
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

    // MARK: - Records List

    private var recordsList: some View {
        Group {
            if viewModel.filteredRecords.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(viewModel.filteredRecords) { record in
                            RunRecordRow(
                                record: record,
                                isExpanded: viewModel.expandedRecordId == record.id,
                                onToggle: { viewModel.toggleExpanded(record.id) },
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
            Text("No matching runs")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("The proactive engine hasn't produced any \(viewModel.filter == .all ? "" : viewModel.filter.rawValue.lowercased() + " ")records yet.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Status Chip

    private func statusChip(_ status: ProactiveEngineStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)
            Text(status.rawValue.capitalized)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusColor(status).opacity(0.1), in: Capsule())
    }

    private func statusColor(_ status: ProactiveEngineStatus) -> Color {
        switch status {
        case .idle: return .green
        case .running: return .blue
        case .backoff: return .yellow
        case .error: return .red
        }
    }
}

// MARK: - Run Record Row

private struct RunRecordRow: View {
    let record: ProactiveRunRecord
    let isExpanded: Bool
    let onToggle: () -> Void
    let onOpenTimeline: ((UInt64, UInt32?) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Summary row
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    statusIcon(record.status)
                    decisionChip(record.decision)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.startedAt, style: .time)
                            .font(.callout.monospacedDigit())
                        Text(record.startedAt, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    if let ms = record.latencyMs {
                        Text(String(format: "%.0fms", ms))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if let conf = record.confidence {
                        Text(String(format: "%.2f", conf))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
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

    // MARK: - Expanded Detail

    @ViewBuilder
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 6) {
                if let whyNow = record.whyNow, !whyNow.isEmpty {
                    detailRow("Why now", value: whyNow)
                }

                if let model = record.model, !model.isEmpty {
                    detailRow("Model", value: model)
                }

                if let ms = record.latencyMs {
                    detailRow("Latency", value: String(format: "%.0f ms", ms))
                }

                if let conf = record.confidence {
                    detailRow("Confidence", value: String(format: "%.3f (\(ConfidenceBand(score: conf).rawValue))", conf))
                }

                if let error = record.errorSummary, !error.isEmpty {
                    detailRow("Error", value: error)
                }

                if !record.sourceRecordIds.isEmpty {
                    detailRow("Source records", value: record.sourceRecordIds.joined(separator: ", "))
                }

                // Evidence rows with deep-link
                if !record.evidenceRefs.isEmpty {
                    Text("Evidence")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)

                    ForEach(Array(record.evidenceRefs.enumerated()), id: \.offset) { _, evidence in
                        evidenceRow(evidence)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private func evidenceRow(_ evidence: SuggestionEvidence) -> some View {
        HStack(spacing: 6) {
            if let app = evidence.app {
                Text(app)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 3))
            }

            Text(evidence.snippet.prefix(80))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
                onOpenTimeline?(evidence.timestamp, evidence.displayId)
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Open in Timeline")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Chips

    private func statusIcon(_ status: ProactiveRunStatus) -> some View {
        Group {
            switch status {
            case .running:
                Image(systemName: "arrow.circlepath")
                    .foregroundStyle(.blue)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .skipped:
                Image(systemName: "forward.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func decisionChip(_ decision: SuggestionDecision?) -> some View {
        Group {
            if let decision {
                Text(decision.rawValue)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(decisionColor(decision).opacity(0.15), in: Capsule())
                    .foregroundStyle(decisionColor(decision))
            } else {
                Text("\u{2014}")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
    }

    private func decisionColor(_ decision: SuggestionDecision) -> Color {
        switch decision {
        case .pushNow: return .green
        case .inboxOnly: return .blue
        case .drop: return .secondary
        }
    }
}
