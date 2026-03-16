import Foundation

/// Testable time formatting for meeting summary display.
/// Resolves the source timezone from metadata (IANA identifier),
/// falling back to the device's current timezone if invalid.
struct SummaryTimeFormatter {
    let timeZone: TimeZone

    init(timezoneIdentifier: String) {
        self.timeZone = TimeZone(identifier: timezoneIdentifier) ?? .current
    }

    /// Format a time window as "h:mm a – h:mm a · N min".
    func formatWindow(startUs: UInt64, endUs: UInt64) -> String {
        let start = Date(timeIntervalSince1970: Double(startUs) / 1_000_000)
        let end = Date(timeIntervalSince1970: Double(endUs) / 1_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = timeZone
        let duration = Int((endUs - startUs) / 1_000_000 / 60)
        return "\(formatter.string(from: start)) \u{2013} \(formatter.string(from: end)) \u{00B7} \(duration) min"
    }

    /// Format a single timestamp as "h:mm:ss a" for evidence links.
    func formatTimestamp(_ ts: UInt64) -> String {
        let date = Date(timeIntervalSince1970: Double(ts) / 1_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
