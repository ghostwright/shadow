import SwiftUI

/// Hour labels with tick marks along the bottom of the timeline.
struct TimeAxisView: View {
    let dayStart: UInt64
    let dayEnd: UInt64

    private var hourMarks: [HourMark] {
        guard dayEnd > dayStart else { return [] }
        let totalDuration = Double(dayEnd - dayStart)

        let startDate = Date(timeIntervalSince1970: Double(dayStart) / 1_000_000)
        let endDate = Date(timeIntervalSince1970: Double(dayEnd) / 1_000_000)
        let cal = Calendar.current

        // Iterate by hour from the start hour boundary up to (and including) the end date.
        // This handles same-day ranges, cross-midnight ranges, and multi-day ranges correctly
        // — no closed integer range (startHour...endHour) that traps when startHour > endHour.
        var marks: [HourMark] = []
        guard var cursor = cal.dateInterval(of: .hour, for: startDate)?.start else {
            return []
        }

        while cursor <= endDate {
            let cursorUs = UInt64(cursor.timeIntervalSince1970 * 1_000_000)
            if cursorUs >= dayStart, cursorUs <= dayEnd {
                let fraction = Double(cursorUs - dayStart) / totalDuration
                let hour = cal.component(.hour, from: cursor)
                marks.append(HourMark(cursorUs: cursorUs, hour: hour, fraction: fraction))
            }

            guard let next = cal.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
        }

        return marks
    }

    var body: some View {
        GeometryReader { geo in
            ForEach(hourMarks) { mark in
                VStack(spacing: 2) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 0.5, height: 5)

                    Text(hourLabel(mark.hour))
                        .font(.system(size: 10, weight: .regular, design: .default))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                .position(x: mark.fraction * geo.size.width, y: geo.size.height / 2)
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let suffix = hour < 12 ? "a" : "p"
        return "\(h)\(suffix)"
    }

    private struct HourMark: Identifiable {
        let cursorUs: UInt64
        let hour: Int
        let fraction: Double
        /// Use microsecond timestamp as ID — unique even across midnight boundary
        /// (unlike bare hour which would collide: hour 0 from two different days).
        var id: UInt64 { cursorUs }
    }
}
