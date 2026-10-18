import AppKit
import ProxmarkKit
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
        AppUpdateInstaller.signalLaunchReady()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !SoftwareUpdateModel.installationInProgress
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SoftwareUpdateModel.installationInProgress else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Installing Proxmark UI"
        alert.informativeText = "Please wait for the app update to finish before quitting. Reader operations are paused during this step."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return .terminateCancel
    }
}

@main
struct ProxmarkUIApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app: AppModel
    @StateObject private var tagLibrary = TagLibrary()
    @StateObject private var softwareUpdates = SoftwareUpdateModel()

    init() {
        AppIcon.renderIfRequested()
        AppModel.applySavedClientPath()
        _app = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("Proxmark") {
            RootView()
                .environmentObject(app)
                .environmentObject(tagLibrary)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    softwareUpdates.showInstallFailure = { [openWindow] in
                        openWindow(id: "software-update")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    softwareUpdates.startAutomaticChecks()
                    presentPendingUpdateIfIdle()
                }
                .onChange(of: softwareUpdates.pendingAutomaticPrompt) { _ in presentPendingUpdateIfIdle() }
                .onChange(of: softwareUpdates.pendingRecoveryPrompt) { _ in presentPendingUpdateIfIdle() }
                .onChange(of: app.isBusy) { _ in presentPendingUpdateIfIdle() }
                .onChange(of: app.connection) { _ in presentPendingUpdateIfIdle() }
                .onChange(of: app.firmwareUpdatePhase) { _ in presentPendingUpdateIfIdle() }
                .onChange(of: app.firmwareUpdateSheet) { _ in presentPendingUpdateIfIdle() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    presentPendingUpdateIfIdle()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Proxmark") { AboutPanel.show() }
            }
            CommandGroup(after: .appInfo) {
                Button(softwareUpdates.availableUpdate == nil ? "Check for Updates…" : "Update Available…") {
                    openWindow(id: "software-update")
                    softwareUpdates.acknowledgeRecoveryPrompt()
                    if let tag = softwareUpdates.pendingAutomaticPrompt {
                        softwareUpdates.markPromptShown(for: tag)
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    Task { await softwareUpdates.check() }
                }
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

        Window("Software Update", id: "software-update") {
            SoftwareUpdateView(updates: softwareUpdates, app: app)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }

    private func presentPendingUpdateIfIdle() {
        guard NSApp.isActive,
              !app.isBusy,
              !app.firmwareUpdatePhase.isActive,
              app.firmwareUpdateSheet == nil else { return }
        if case .checking = app.connection { return }
        if softwareUpdates.pendingRecoveryPrompt {
            openWindow(id: "software-update")
            softwareUpdates.acknowledgeRecoveryPrompt()
            return
        }
        guard let tag = softwareUpdates.pendingAutomaticPrompt else { return }
        openWindow(id: "software-update")
        softwareUpdates.markPromptShown(for: tag)
    }
}
