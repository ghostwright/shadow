import SwiftUI

@main
struct ShadowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                state: appDelegate.recordingState,
                permissions: appDelegate.permissionManager,
                onShowProactiveInbox: {
                    appDelegate.showProactiveInbox()
                }
            )
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)

        Window("Shadow Timeline", id: "timeline") {
            TimelineView()
        }
        .defaultSize(width: 1200, height: 800)

        Window("Shadow Diagnostics", id: "diagnostics") {
            DiagnosticsView(
                currentLLMOrchestrator: { appDelegate.llmOrchestrator },
                currentSummaryJobQueue: { appDelegate.summaryJobQueue },
                showProactiveInbox: { appDelegate.showProactiveInbox() },
                showProactiveActivity: { appDelegate.showProactiveActivity() }
            )
        }
        .defaultSize(width: 520, height: 600)

        Settings {
            SettingsView()
        }
    }
}
