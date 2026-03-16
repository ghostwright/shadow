import SwiftUI

/// Thin floating indicator showing that learning mode is active.
///
/// Shows a recording dot, "Recording..." text, elapsed time, action count, and a stop button.
/// Appears at the top-center of the screen. Non-activating panel, floating above all windows.
struct LearningIndicatorView: View {
    let elapsedSeconds: Int
    let actionCount: Int
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Recording indicator dot
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .shadow(color: .red.opacity(0.6), radius: 4)

            Text("Recording")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            Text(formatElapsed(elapsedSeconds))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)

            if actionCount > 0 {
                Text("\(actionCount) actions")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .frame(height: 16)

            Button(action: onStop) {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9))
                    Text("Stop")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)

            Text("(\u{2318}\u{21E7}L)")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThickMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
