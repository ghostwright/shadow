import SwiftUI

/// Draggable vertical playhead line spanning the track area.
/// Click anywhere to jump; drag to scrub.
///
/// The playhead is the single gesture owner for the entire track area (overlay).
/// `onTap` fires only for tap-like interactions (translation < 4pt), allowing
/// the parent to route taps to child views (e.g., audio track segment playback).
struct PlayheadView: View {
    @Binding var position: Double // 0.0 to 1.0
    var onScrub: (Double) -> Void

    /// Called on tap-like gesture end. Parameters: (location in overlay-local coordinates, normalized position 0–1).
    var onTap: ((CGPoint, Double) -> Void)?

    @State private var isDragging = false

    /// Translation threshold (points) below which a gesture is considered a tap.
    /// 8pt accommodates trackpad jitter while still distinguishing intentional drags.
    private let tapThreshold: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let x = position * geo.size.width

            ZStack {
                // Transparent hit area — click or drag anywhere to move playhead
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                let newPos = value.location.x / geo.size.width
                                onScrub(newPos)
                            }
                            .onEnded { value in
                                let wasDrag = isDragging
                                    && (abs(value.translation.width) >= tapThreshold
                                        || abs(value.translation.height) >= tapThreshold)
                                isDragging = false

                                let newPos = value.location.x / geo.size.width
                                onScrub(newPos)

                                // Fire onTap only for tap-like interactions
                                if !wasDrag {
                                    let clampedPos = max(0, min(1, newPos))
                                    onTap?(value.location, clampedPos)
                                }
                            }
                    )

                // Playhead line — uses system accent color
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))
                }
                .stroke(Color.accentColor, lineWidth: isDragging ? 2.5 : 1.5)
                .shadow(color: Color.accentColor.opacity(0.3), radius: 2)
                .allowsHitTesting(false)

                // Handle circle at top — accent color with shadow for depth
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .position(x: x, y: 6)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Playhead")
        .accessibilityValue("\(Int(position * 100))%")
    }
}
