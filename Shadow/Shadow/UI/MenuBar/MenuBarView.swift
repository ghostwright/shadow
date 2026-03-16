import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    var state: RecordingState
    var permissions: PermissionManager
    var onShowProactiveInbox: (@MainActor () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("Shadow")
                    .font(.headline)
                Spacer()
                Button {
                    state.isPaused.toggle()
                } label: {
                    Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(state.isPaused ? "Resume recording" : "Pause recording")

                SettingsLink {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }

            Divider()

            // Recording status
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.subheadline)
                Spacer()
                Text(state.elapsedTimeString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Storage info
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                let snap = DiagnosticsStore.shared.snapshot()
                let totalGB = snap.gauges["storage_total_gb", default: 0]
                let freeGB = snap.gauges["storage_disk_available_gb", default: 0]
                Text(String(format: "%.1f GB used", totalGB))
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.0f GB free", freeGB))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Mini timeline
            if !state.todayBlocks.isEmpty {
                MiniTimelineBar(blocks: state.todayBlocks)

                // Time labels
                HStack {
                    Text(dayStartLabel)
                    Spacer()
                    Text("now")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            // Stats
            HStack(spacing: 12) {
                StatBadge(
                    icon: "macwindow",
                    value: "\(state.distinctAppCount)",
                    label: "apps"
                )
                StatBadge(
                    icon: "arrow.left.arrow.right",
                    value: "\(state.appSwitchCount)",
                    label: "switches"
                )
                StatBadge(
                    icon: "cursorarrow.click.2",
                    value: "\(state.inputEventCount)",
                    label: "inputs"
                )
            }
            .padding(.vertical, 2)

            // Model download indicator (only visible during active downloads)
            if DiagnosticsStore.shared.gauge("provisioning_download_active") > 0 {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading local AI model...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Search hint
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                Text("Search")
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\u{2325}Space")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }
            .font(.subheadline)

            // Permission warnings — only show if recording isn't active
            if !permissions.allGranted && !state.isRecording {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                        Text("Missing permissions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(permissions.missingPermissions, id: \.self) { perm in
                        Button {
                            openPermissionSettings(perm)
                        } label: {
                            HStack(spacing: 4) {
                                Text(perm)
                                    .font(.caption)
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }

            Divider()

            // Actions
            Button {
                openWindow(id: "timeline")
                // Activate the app so the window comes to front
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Timeline", systemImage: "timeline.selection")
            }
            .buttonStyle(.plain)

            Button {
                onShowProactiveInbox?()
            } label: {
                Label("Proactive Inbox", systemImage: "tray.fill")
            }
            .buttonStyle(.plain)

            Button {
                state.isPaused.toggle()
            } label: {
                Label(
                    state.isPaused ? "Resume Recording" : "Pause Recording",
                    systemImage: state.isPaused ? "play.fill" : "pause.fill"
                )
            }
            .buttonStyle(.plain)

            Button {
                openWindow(id: "diagnostics")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Diagnostics", systemImage: "waveform.badge.magnifyingglass")
            }
            .buttonStyle(.plain)

            Divider()

            Button("Quit Shadow") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            state.refreshDaySummary()
            // Refresh permissions without probing Input Monitoring.
            // The Input Monitoring CGEventTap probe gives false negatives on macOS
            // Sequoia. The reconciler sets inputMonitoringGranted from real
            // InputMonitor health instead.
            permissions.checkAll(probeInputMonitoring: false)
            // Backup bridge: store openWindow for SearchPanelController
            // in case MenuBarIcon body-evaluation bridge didn't fire.
            if (NSApp.delegate as? AppDelegate)?.openTimelineAction == nil {
                (NSApp.delegate as? AppDelegate)?.openTimelineAction = openWindow
            }
        }
    }

    private var statusColor: Color {
        if state.isPaused { return .yellow }
        if state.isRecording { return .green }
        return .gray
    }

    private var statusLabel: String {
        if state.isPaused { return "Paused" }
        if state.isRecording { return "Recording" }
        return "Stopped"
    }

    private func openPermissionSettings(_ permission: String) {
        switch permission {
        case "Screen Recording":
            permissions.openScreenRecordingSettings()
        case "Input Monitoring":
            permissions.openInputMonitoringSettings()
        case "Accessibility":
            permissions.openAccessibilitySettings()
        case "Microphone":
            permissions.openMicrophoneSettings()
        case "Speech Recognition":
            permissions.openSpeechRecognitionSettings()
        default:
            break
        }
    }

    private var dayStartLabel: String {
        guard let first = state.todayBlocks.first else { return "" }
        let date = Date(timeIntervalSince1970: Double(first.startTs) / 1_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mma"
        return formatter.string(from: date).lowercased()
    }
}

// MARK: - Stat Badge

private struct StatBadge: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
