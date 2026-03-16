import SwiftUI

/// Approval dialog shown when a procedure step requires user confirmation.
///
/// Displays the risk assessment, rationale, and approve/deny buttons.
/// Blocks execution until the user responds.
struct SafetyApprovalView: View {
    let riskLevel: String
    let rationale: String
    let stepDescription: String
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: riskIcon)
                    .font(.system(size: 18))
                    .foregroundStyle(riskColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Safety Approval Required")
                        .font(.system(size: 14, weight: .semibold))

                    Text("Risk: \(riskLevel.capitalized)")
                        .font(.system(size: 12))
                        .foregroundStyle(riskColor)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // Details
            VStack(alignment: .leading, spacing: 10) {
                Text("The following action requires your approval:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text(stepDescription)
                    .font(.system(size: 13, weight: .medium))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                if !rationale.isEmpty {
                    Text(rationale)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            // Actions
            HStack {
                Spacer()

                Button("Deny") {
                    onDeny()
                }
                .keyboardShortcut(.escape)

                Button("Approve") {
                    onApprove()
                }
                .buttonStyle(.borderedProminent)
                .tint(riskColor == .red ? .orange : .blue)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .background(.ultraThickMaterial)
    }

    private var riskIcon: String {
        switch riskLevel.lowercased() {
        case "high": return "exclamationmark.triangle.fill"
        case "critical": return "xmark.octagon.fill"
        default: return "exclamationmark.shield.fill"
        }
    }

    private var riskColor: Color {
        switch riskLevel.lowercased() {
        case "high": return .orange
        case "critical": return .red
        default: return .yellow
        }
    }
}
