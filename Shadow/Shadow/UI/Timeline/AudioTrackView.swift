import SwiftUI

/// Horizontal colored bars showing audio segments over time.
/// Mic segments render blue, system segments render purple.
///
/// This view is render-only — no gesture handlers. The parent (TimelineView)
/// routes taps via PlayheadView's onTap callback and this view's `segmentAt()`
/// hit-test helper.
struct AudioTrackView: View {
    let segments: [AudioSegment]
    let dayStart: UInt64
    let dayEnd: UInt64

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                drawSegmentBars(context: context, size: size)
                drawPlaybackIndicator(context: context, size: size)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .accessibilityLabel("Audio segments timeline")
    }

    // MARK: - Rendering

    private func drawSegmentBars(context: GraphicsContext, size: CGSize) {
        guard dayEnd > dayStart else { return }
        let totalDuration = Double(dayEnd - dayStart)

        // Background
        let bgRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.fill(Path(roundedRect: bgRect, cornerRadius: 4),
                     with: .color(.primary.opacity(0.04)))

        guard !segments.isEmpty else { return }

        for segment in segments {
            let segStart = max(segment.startTs, dayStart)
            let segEnd: UInt64 = (segment.endTs > 0) ? min(segment.endTs, dayEnd) : dayEnd
            guard segEnd > segStart else { continue }

            let xStart = Double(segStart - dayStart) / totalDuration * size.width
            let xEnd = Double(segEnd - dayStart) / totalDuration * size.width
            let width = max(xEnd - xStart, Self.minBarWidth)

            let rect = CGRect(
                x: max(xStart, 0),
                y: 2,
                width: min(width, size.width - max(xStart, 0)),
                height: size.height - 4
            )

            let color: Color = segment.source == "mic" ? .blue : .purple
            context.fill(Path(roundedRect: rect, cornerRadius: 3),
                         with: .color(color.opacity(0.5)))
        }
    }

    private func drawPlaybackIndicator(context: GraphicsContext, size: CGSize) {
        guard dayEnd > dayStart else { return }
        let totalDuration = Double(dayEnd - dayStart)

        let player = AudioPlayer.shared
        guard player.isPlaying || player.isPaused,
              let segId = player.currentSegmentId,
              let seg = segments.first(where: { $0.segmentId == segId }) else { return }

        let seekUs = UInt64(player.seekOffsetSeconds * 1_000_000)
        let playedUs = UInt64(player.currentTime * 1_000_000)
        let playbackUs = seg.startTs + seekUs + playedUs

        guard playbackUs >= dayStart, playbackUs <= dayEnd else { return }
        let indicatorX = Double(playbackUs - dayStart) / totalDuration * size.width

        var line = Path()
        line.move(to: CGPoint(x: indicatorX, y: 0))
        line.addLine(to: CGPoint(x: indicatorX, y: size.height))
        context.stroke(line, with: .color(.white), lineWidth: 1.5)
    }

    // MARK: - Hit Testing

    /// Minimum rendered bar width in points. Must match `drawSegmentBars`.
    private static let minBarWidth: CGFloat = 2

    /// Given a tap x-position and the view width, find the segment and compute seek offset.
    /// Hit-tests against rendered pixel geometry (including min-width expansion) so that
    /// tapping a visible bar always registers, even for very short segments.
    func segmentAt(tapX: CGFloat, viewWidth: CGFloat) -> (segment: AudioSegment, seekSeconds: Double)? {
        guard dayEnd > dayStart, viewWidth > 0, !segments.isEmpty else { return nil }
        let totalDuration = Double(dayEnd - dayStart)

        // Build rendered rects (same math as drawSegmentBars) and hit-test against them.
        for segment in segments {
            let segStart = max(segment.startTs, dayStart)
            let segEnd: UInt64 = (segment.endTs > 0) ? min(segment.endTs, dayEnd) : dayEnd
            guard segEnd > segStart else { continue }

            let xStart = Double(segStart - dayStart) / totalDuration * viewWidth
            let xEnd = Double(segEnd - dayStart) / totalDuration * viewWidth
            let barWidth = max(xEnd - xStart, Self.minBarWidth)
            let barX = max(xStart, 0)
            let clampedWidth = min(barWidth, viewWidth - barX)

            guard tapX >= barX, tapX <= barX + clampedWidth else { continue }

            // Convert tap pixel back to timestamp for seek offset
            let tapProportion = max(0, min(1, Double(tapX) / Double(viewWidth)))
            let tapUs = dayStart + UInt64(tapProportion * totalDuration)
            let clampedTapUs = max(tapUs, segment.startTs)
            let seekSec = Double(clampedTapUs - segment.startTs) / 1_000_000
            return (segment, seekSec)
        }

        return nil
    }
}
