import SwiftUI

/// Floating panel showing step-by-step progress during procedure replay.
///
/// Displays the procedure name, current step with progress indicator,
/// completed steps with checkmarks, and a cancel button (triggers kill switch).
struct ExecutionProgressView: View {
    let procedureName: String
    let steps: [StepStatus]
    let currentStepIndex: Int?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)

                Text("Running: \(procedureName)")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                Button(action: onCancel) {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                        Text("Stop")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Steps list
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        stepRow(index: index, step: step)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 240)

            Divider()

            // Footer
            HStack {
                let completed = steps.filter { $0.state == .completed }.count
                Text("\(completed)/\(steps.count) steps")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("Option+Escape to cancel")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        .background(.ultraThickMaterial)
    }

    private func stepRow(index: Int, step: StepStatus) -> some View {
        HStack(spacing: 8) {
            // Status icon
            Group {
                switch step.state {
                case .pending:
                    Image(systemName: "circle")
                        .foregroundStyle(.quaternary)
                case .running:
                    ProgressView()
                        .controlSize(.small)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .skipped:
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .frame(width: 16)

            Text(step.intent)
                .font(.system(size: 12))
                .foregroundStyle(step.state == .pending ? .secondary : .primary)
                .lineLimit(2)

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Step Status

/// Status of a single step in the execution progress view.
struct StepStatus: Sendable {
    let intent: String
    let state: StepState

    enum StepState: Sendable {
        case pending
        case running
        case completed
        case failed
        case skipped
    }
}
