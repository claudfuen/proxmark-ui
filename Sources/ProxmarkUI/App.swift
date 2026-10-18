import AppKit
import SwiftUI

/// A bare SwiftPM executable has no Info.plist, so without this AppKit
/// treats it as a background agent and never surfaces a window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // `swift run` has no bundle icon; the packaged .app also gets the .icns.
        if let icon = AppIcon.image(pixels: 512) {
            NSApp.applicationIconImage = icon
        }
        // Saved Settings choice; PMUI_APPEARANCE=light|dark overrides it (QA).
        AppearancePreference.apply()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ProxmarkUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app: AppModel

    init() {
        AppIcon.renderIfRequested()
        AppModel.applySavedClientPath()
        _app = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("Proxmark") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Proxmark") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Reader") {
                Button("Scan 13.56 MHz") { Task { await app.scan(family: .hf) } }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(!app.connection.isReady || app.isBusy)
                Button("Scan 125 kHz") { Task { await app.scan(family: .lf) } }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(!app.connection.isReady || app.isBusy)
                Divider()
                Button("Reconnect") { Task { await app.checkConnection() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(app.isBusy)
                Button("Update Firmware…") { app.showFirmwareUpdate() }
                    .disabled(app.isBusy || !app.connection.isFirmwareMismatch)
                Button("Locate Client…") { app.chooseClient() }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }
}
