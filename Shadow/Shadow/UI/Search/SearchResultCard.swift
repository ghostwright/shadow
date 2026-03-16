import SwiftUI

/// A single search result card showing app icon, window title, snippet,
/// metadata line, and deep-link affordance. Transcript results get a play button.
struct SearchResultCard: View {
    let result: SearchResult
    let isSelected: Bool

    private var audioPlayer: AudioPlayer { AudioPlayer.shared }

    /// Whether this card's segment is the one currently loaded in the player.
    private var isThisPlaying: Bool {
        guard result.sourceKind == "transcript" else { return false }
        return audioPlayer.currentSegmentId != nil && audioPlayer.isPlaying
            && audioPlayer.lastAttemptedResultTs == result.ts
    }

    /// Whether this card's segment is paused in the player.
    private var isThisPaused: Bool {
        guard result.sourceKind == "transcript" else { return false }
        return audioPlayer.currentSegmentId != nil && audioPlayer.isPaused
            && audioPlayer.lastAttemptedResultTs == result.ts
    }

    /// Whether this card has a playback error.
    private var hasError: Bool {
        audioPlayer.lastAttemptedResultTs == result.ts && audioPlayer.error != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                // App icon (real icon with colored rounded-rect fallback)
                Group {
                    if let icon = SearchTheme.appIcon(for: result.appName) {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: SearchTheme.appIconSize, height: SearchTheme.appIconSize)
                            .clipShape(RoundedRectangle(cornerRadius: SearchTheme.appIconCornerRadius))
                    } else {
                        RoundedRectangle(cornerRadius: SearchTheme.appIconCornerRadius)
                            .fill(appColor)
                            .frame(width: SearchTheme.appIconSize, height: SearchTheme.appIconSize)
                            .overlay {
                                Text(appInitial)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                    }
                }

                // Content
                VStack(alignment: .leading, spacing: 3) {
                    // Window title (primary text)
                    if !result.windowTitle.isEmpty {
                        Text(result.windowTitle)
                            .font(.body)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    // OCR/transcript snippet (when available)
                    if !result.snippet.isEmpty {
                        Text(result.snippet)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }

                    // Visual match fallback: when a visual result has no title and no snippet
                    if result.sourceKind == "visual" && result.windowTitle.isEmpty && result.snippet.isEmpty {
                        Text("Visual similarity match")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .italic()
                    }

                    // Error message (scoped to this card only)
                    if hasError, let errorMsg = audioPlayer.error {
                        Text(errorMsg)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }

                    // Metadata line: app, source badge, URL, display, confidence, timestamp
                    HStack(spacing: 4) {
                        if !result.appName.isEmpty {
                            Text(result.appName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        // Source kind badge (icon + label pill)
                        Text("\u{00B7}")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                        sourceBadge

                        if !result.url.isEmpty {
                            Text("\u{00B7}")
                                .font(.caption)
                                .foregroundStyle(.quaternary)
                            Text(shortenedURL)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        // Display badge
                        if let displayId = result.displayId, displayId > 0 {
                            Text("\u{00B7}")
                                .font(.caption)
                                .foregroundStyle(.quaternary)
                            Text("Display \(displayId)")
                                .font(.caption)
                                .foregroundStyle(.quaternary)
                        }

                        // Confidence (only for visual results above threshold)
                        if let confidence = result.confidence, confidence > 0.1, result.sourceKind == "visual" {
                            Text("\(Int(confidence * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        Text(formattedTime)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: 0)

                // Play button for transcript results / deep-link arrow for others
                if result.sourceKind == "transcript" {
                    Button {
                        if isThisPlaying {
                            audioPlayer.pause()
                        } else if isThisPaused {
                            audioPlayer.resume()
                        } else {
                            audioPlayer.playTranscriptResult(result)
                        }
                    } label: {
                        Image(systemName: playButtonIcon)
                            .font(.system(size: 24))
                            .foregroundStyle(hasError ? .red : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(playButtonHelp)
                } else if isSelected {
                    Image(systemName: "return")
                        .font(.caption)
                        .foregroundStyle(SearchTheme.accent)
                } else {
                    Image(systemName: "arrow.right.circle")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }

            // Progress bar for actively playing transcript
            if (isThisPlaying || isThisPaused) && audioPlayer.duration > 0 {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor.opacity(0.3))
                        .frame(height: 2)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * audioPlayer.progress, height: 2)
                        }
                }
                .frame(height: 2)
                .padding(.top, 4)
                .padding(.horizontal, 48) // align with content (36px icon + 12px spacing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isSelected ? AnyShapeStyle(SearchTheme.accentSoft) : AnyShapeStyle(Color.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(SearchTheme.selectionRail)
                    .frame(width: SearchTheme.selectionRailWidth)
                    .padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Play Button

    private var playButtonIcon: String {
        if hasError { return "exclamationmark.circle" }
        if isThisPlaying { return "pause.circle.fill" }
        if isThisPaused { return "play.circle.fill" }
        return "play.circle.fill"
    }

    private var playButtonHelp: String {
        if hasError { return audioPlayer.error ?? "Playback error" }
        if isThisPlaying { return "Pause audio" }
        if isThisPaused { return "Resume audio" }
        return "Play audio"
    }

    // MARK: - Computed Properties

    private var appInitial: String {
        String(result.appName.prefix(1)).uppercased()
    }

    private var appColor: Color {
        // DJB2 hash -> hue (same algorithm as AppTrackView)
        var hash: UInt64 = 5381
        for char in result.appName.unicodeScalars {
            hash = hash &* 33 &+ UInt64(char.value)
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.7)
    }

    /// Source kind badge: icon + short label in a subtle pill.
    private var sourceBadge: some View {
        let (icon, label) = sourceKindDisplay
        return Label(label, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 4))
    }

    /// Icon and label for the source kind badge.
    private var sourceKindDisplay: (icon: String, label: String) {
        switch result.sourceKind {
        case "ocr":
            ("text.viewfinder", "OCR")
        case "visual":
            ("eye", "Visual")
        case "transcript":
            (result.audioSource == "mic" ? "mic.fill" : "speaker.wave.2.fill", "Transcript")
        default:
            ("text.magnifyingglass", "Text")
        }
    }

    private var shortenedURL: String {
        guard let url = URL(string: result.url),
              let host = url.host else {
            return result.url
        }
        // Strip "www." prefix
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let path = url.path.isEmpty ? nil : url.path, path != "/" {
            return "\(domain)\(path)"
        }
        return domain
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    private var formattedTime: String {
        let date = Date(timeIntervalSince1970: Double(result.ts) / 1_000_000)
        let now = Date()
        let interval = now.timeIntervalSince(date)

        // Under 1 minute: "just now"
        if interval < 60 {
            return "just now"
        }
        // Under 1 hour: "N min ago"
        if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) min ago"
        }
        // Today: "2:30 PM"
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        // Yesterday: "Yesterday 2:30 PM"
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday \(Self.timeFormatter.string(from: date))"
        }
        // Older: "Feb 22, 2:30 PM"
        return Self.dayTimeFormatter.string(from: date)
    }
}
