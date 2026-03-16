import SwiftUI

/// Progress view shown while a command (meeting summarization) is executing.
/// Displays an animated hairline bar and a stage description that updates
/// as the pipeline progresses through resolution, assembly, and generation.
struct CommandProgressView: View {
    let stage: String

    @State private var animationOffset: CGFloat = -1.0

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            ExpressiveGhostView(mood: .constant(.speaking), size: 48)
                .frame(width: 48, height: 48)

            Text(stage)
                .font(.headline)
                .foregroundStyle(.secondary)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: stage)
                .id(stage)

            // Animated indeterminate hairline
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(height: 2)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * 0.3, height: 2)
                            .offset(x: animationOffset * geo.size.width)
                    }
            }
            .frame(height: 2)
            .padding(.horizontal, 80)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.5)
                    .repeatForever(autoreverses: true)
                ) {
                    animationOffset = 0.7
                }
            }

            Text("Esc to cancel")
                .font(.caption)
                .foregroundStyle(.quaternary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
