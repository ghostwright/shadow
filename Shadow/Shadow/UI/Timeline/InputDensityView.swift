import SwiftUI

/// Heatmap bar showing input activity density over time.
/// Warmer/brighter = more mouse/keyboard activity in that time bucket.
struct InputDensityView: View {
    let entries: [TimelineEntry]
    let dayStart: UInt64
    let dayEnd: UInt64

    /// Bucket size in microseconds (1 minute).
    private let bucketUs: UInt64 = 60_000_000

    var body: some View {
        Canvas { context, size in
            guard dayEnd > dayStart else { return }
            let totalDuration = Double(dayEnd - dayStart)

            // Background
            let bgRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            context.fill(Path(roundedRect: bgRect, cornerRadius: 4),
                         with: .color(.primary.opacity(0.04)))

            guard !entries.isEmpty else { return }

            // Bucket events into 1-minute intervals
            let bucketCount = max(1, Int((dayEnd - dayStart) / bucketUs) + 1)
            var buckets = [Int](repeating: 0, count: bucketCount)

            for entry in entries {
                guard entry.ts >= dayStart else { continue }
                let idx = Int((entry.ts - dayStart) / bucketUs)
                if idx >= 0, idx < bucketCount {
                    buckets[idx] += 1
                }
            }

            let maxCount = buckets.max() ?? 1

            // Render each bucket as a warm-colored bar
            let bucketWidth = size.width / Double(bucketCount)
            for i in 0..<bucketCount {
                guard buckets[i] > 0 else { continue }

                let intensity = Double(buckets[i]) / Double(maxCount)
                let x = Double(i) * bucketWidth
                let rect = CGRect(x: x, y: 0, width: max(bucketWidth, 1), height: size.height)

                // Orange heatmap: faint at low activity, vivid at peak
                context.fill(Path(rect),
                             with: .color(Color.orange.opacity(0.15 + intensity * 0.65)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("Input activity density")
    }
}
