import SwiftUI

/// Horizontal colored blocks showing which app was active over time.
/// Each block spans from one app_switch event to the next.
struct AppTrackView: View {
    let entries: [TimelineEntry]
    let dayStart: UInt64
    let dayEnd: UInt64

    var body: some View {
        Canvas { context, size in
            guard dayEnd > dayStart else { return }
            let totalDuration = Double(dayEnd - dayStart)

            // Background
            let bgRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            context.fill(Path(roundedRect: bgRect, cornerRadius: 6),
                         with: .color(.primary.opacity(0.04)))

            guard !entries.isEmpty else { return }

            // Draw blocks between consecutive app_switch events
            for i in entries.indices {
                let entry = entries[i]
                guard let appName = entry.appName else { continue }

                let startTs = max(entry.ts, dayStart)
                let endTs: UInt64 = (i + 1 < entries.count) ? entries[i + 1].ts : dayEnd

                let xStart = Double(startTs - dayStart) / totalDuration * size.width
                let xEnd = Double(max(endTs, dayStart) - dayStart) / totalDuration * size.width
                let width = max(xEnd - xStart, 2)

                let rect = CGRect(
                    x: max(xStart, 0),
                    y: 0,
                    width: min(width, size.width - max(xStart, 0)),
                    height: size.height
                )

                context.fill(Path(roundedRect: rect, cornerRadius: 3),
                             with: .color(appColor(for: appName)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("App usage timeline")
    }
}
