import SwiftUI

/// Compact horizontal bar showing today's app usage as colored blocks.
/// Each block represents a 5-minute aggregation from the Rust day_summary query.
struct MiniTimelineBar: View {
    let blocks: [ActivityBlock]

    /// The time range to display (start of today to now).
    private var dayStart: UInt64 {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        return UInt64(startOfDay.timeIntervalSince1970 * 1_000_000)
    }

    private var dayEnd: UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000)
    }

    var body: some View {
        Canvas { context, size in
            let totalDuration = Double(dayEnd - dayStart)
            guard totalDuration > 0 else { return }

            // Background track
            let bgRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            context.fill(Path(roundedRect: bgRect, cornerRadius: 3),
                         with: .color(.primary.opacity(0.06)))

            for block in blocks {
                let xStart = Double(block.startTs - dayStart) / totalDuration * size.width
                let xEnd = Double(block.endTs - dayStart) / totalDuration * size.width
                let width = max(xEnd - xStart, 2) // Minimum 2pt visibility

                let rect = CGRect(
                    x: max(xStart, 0),
                    y: 0,
                    width: min(width, size.width - max(xStart, 0)),
                    height: size.height
                )

                let color = appColor(for: block.appName)
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(color))
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Derive a stable color from an app name using a hash.
/// Produces distinct, visually pleasant colors per app.
func appColor(for name: String) -> Color {
    let hash = djb2Hash(name)
    let hue = Double(hash % 360) / 360.0
    return Color(hue: hue, saturation: 0.55, brightness: 0.75)
}

/// DJB2 string hash — simple, fast, good distribution.
private func djb2Hash(_ string: String) -> UInt {
    var hash: UInt = 5381
    for byte in string.utf8 {
        hash = ((hash &<< 5) &+ hash) &+ UInt(byte)
    }
    return hash
}
