import SwiftUI

/// Shared color and typography constants for the search overlay.
///
/// Derives from OnboardingTheme where values overlap (accent, ghost colors).
/// Defines search-specific tokens for information density contexts.
enum SearchTheme {

    // MARK: - Accent (from OnboardingTheme)

    /// Primary accent: twilight purple for selection, deep-links, action bar.
    static let accent = OnboardingTheme.accent

    /// Soft accent: twilight purple at 15% for selected result background.
    static let accentSoft = OnboardingTheme.accentSoft

    // MARK: - Search-Specific

    /// Left border color for selected result card.
    static let selectionRail = OnboardingTheme.accent.opacity(0.6)

    /// Width of the selection rail on selected result cards.
    static let selectionRailWidth: CGFloat = 2.5

    // MARK: - Ghost Size

    /// Ghost size in the search overlay (empty state, agent header).
    static let ghostSize: CGFloat = 32

    // MARK: - Layout

    /// Horizontal padding for content areas.
    static let contentPadding: CGFloat = 16

    /// Vertical padding for the search field area.
    static let searchFieldVerticalPadding: CGFloat = 14

    // MARK: - App Icon

    /// Size of app icons in search result cards.
    static let appIconSize: CGFloat = 36

    /// Corner radius for app icon clipping.
    static let appIconCornerRadius: CGFloat = 8

    // MARK: - Metrics Formatting

    /// Format agent run duration for display.
    /// Under 60s: "30s". Over 60s: "1m 12s". Sub-second rounds up to "1s".
    static func formatDuration(ms: Double) -> String {
        let totalSeconds = Int(ms / 1000)
        if totalSeconds < 60 {
            return "\(max(totalSeconds, 1))s"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
    }

    /// Format step count with correct pluralization.
    static func formatSteps(_ count: Int) -> String {
        count == 1 ? "1 step" : "\(count) steps"
    }

    /// Human-friendly provider name.
    ///
    /// Provider IDs from the LLM layer use descriptive suffixes
    /// (e.g. "cloud_claude", "ollama_local", "local_apple_foundation").
    /// Uses contains-matching to be resilient to future suffix changes.
    static func friendlyProviderName(_ provider: String) -> String {
        if provider.contains("mlx") { return "Shadow's local brain" }
        if provider.contains("ollama") { return "Shadow via Ollama" }
        if provider.contains("apple_foundation") { return "Shadow" }
        if provider.contains("cloud") { return "Shadow" }
        return "Shadow"
    }

    // MARK: - App Icon Resolution

    /// Known bundle identifiers for common macOS apps.
    /// Used to resolve real app icons from app names in search results.
    static let knownBundleIds: [String: String] = [
        // Browsers
        "Google Chrome": "com.google.Chrome",
        "Safari": "com.apple.Safari",
        "Firefox": "org.mozilla.firefox",
        "Arc": "company.thebrowser.Browser",
        "Brave Browser": "com.brave.Browser",
        "Microsoft Edge": "com.microsoft.edgemac",
        "Vivaldi": "com.vivaldi.Vivaldi",
        "Orion": "com.kagi.kagimacOS",

        // Editors and IDEs
        "VS Code": "com.microsoft.VSCode",
        "Visual Studio Code": "com.microsoft.VSCode",
        "Code": "com.microsoft.VSCode",
        "Xcode": "com.apple.dt.Xcode",
        "Cursor": "com.todesktop.230313mzl4w4u92",
        "Zed": "dev.zed.Zed",
        "Sublime Text": "com.sublimetext.4",
        "Nova": "com.panic.Nova",
        "IntelliJ IDEA": "com.jetbrains.intellij",
        "PyCharm": "com.jetbrains.pycharm",
        "WebStorm": "com.jetbrains.WebStorm",
        "DataGrip": "com.jetbrains.datagrip",
        "CLion": "com.jetbrains.CLion",
        "GoLand": "com.jetbrains.goland",

        // Terminals
        "Terminal": "com.apple.Terminal",
        "iTerm2": "com.googlecode.iterm2",
        "Warp": "dev.warp.Warp-Stable",
        "Alacritty": "org.alacritty",
        "kitty": "net.kovidgoyal.kitty",
        "Ghostty": "com.mitchellh.ghostty",

        // Communication
        "Slack": "com.tinyspeck.slackmacgap",
        "Discord": "com.DiscordInc.Discord",
        "Zoom": "us.zoom.xos",
        "Microsoft Teams": "com.microsoft.teams2",
        "Messages": "com.apple.MobileSMS",
        "Mail": "com.apple.mail",
        "Telegram": "ru.keepcoder.Telegram",
        "WhatsApp": "net.whatsapp.WhatsApp",
        "Mimestream": "com.mimestream.Mimestream",

        // Productivity
        "Finder": "com.apple.finder",
        "Preview": "com.apple.Preview",
        "Notes": "com.apple.Notes",
        "Calendar": "com.apple.iCal",
        "Reminders": "com.apple.reminders",
        "TextEdit": "com.apple.TextEdit",
        "Pages": "com.apple.iWork.Pages",
        "Numbers": "com.apple.iWork.Numbers",
        "Keynote": "com.apple.iWork.Keynote",
        "Notion": "notion.id",
        "Obsidian": "md.obsidian",
        "Bear": "net.shinyfrog.bear",
        "Craft": "com.lukilabs.lukiapp",
        "Things": "com.culturedcode.ThingsMac",
        "Fantastical": "com.flexibits.fantastical2.mac",
        "Todoist": "com.todoist.mac.Todoist",
        "Linear": "com.linear",

        // Design
        "Figma": "com.figma.Desktop",
        "Sketch": "com.bohemiancoding.sketch3",
        "Adobe Photoshop": "com.adobe.Photoshop",
        "Adobe Illustrator": "com.adobe.illustrator",

        // Media
        "Music": "com.apple.Music",
        "Spotify": "com.spotify.client",
        "Podcasts": "com.apple.podcasts",
        "Photos": "com.apple.Photos",
        "Books": "com.apple.iBooksX",

        // AI
        "ChatGPT": "com.openai.chat",
        "Claude": "com.anthropic.claudefordesktop",

        // Developer Tools
        "Activity Monitor": "com.apple.ActivityMonitor",
        "Docker": "com.docker.docker",
        "Postman": "com.postmanlabs.mac",
        "TablePlus": "com.tinyapp.TablePlus",
        "Tower": "com.fournova.Tower3",
        "Fork": "com.DanPristupov.Fork",
        "GitHub Desktop": "com.github.GitHubClient",
        "Transmit": "com.panic.Transmit",

        // System and Utilities
        "System Settings": "com.apple.systempreferences",
        "Maps": "com.apple.Maps",
        "News": "com.apple.news",
        "Stocks": "com.apple.stocks",
        "Weather": "com.apple.weather",
        "1Password": "com.1password.1password",
        "Raycast": "com.raycast.macos",
        "Alfred": "com.runningwithcrayons.Alfred",
    ]

    /// Resolve the NSImage icon for an app name.
    /// Returns nil if the app cannot be found (caller should use fallback).
    static func appIcon(for appName: String) -> NSImage? {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let workspace = NSWorkspace.shared

        // Try known bundle ID first
        if let bundleId = knownBundleIds[trimmed],
           let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) {
            return workspace.icon(forFile: appURL.path)
        }

        // Try common Apple app pattern: com.apple.AppName
        let guessId = "com.apple.\(trimmed.replacingOccurrences(of: " ", with: ""))"
        if let appURL = workspace.urlForApplication(withBundleIdentifier: guessId) {
            return workspace.icon(forFile: appURL.path)
        }

        return nil
    }
}
