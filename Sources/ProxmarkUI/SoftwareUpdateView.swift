import AppKit
import ProxmarkKit
import SwiftUI

/// App releases update the Mac app and the client packaged inside it. Reader
/// firmware is a separate, explicitly initiated hardware operation.
@MainActor
final class SoftwareUpdateModel: ObservableObject {
    static var installationInProgress = false
    enum Phase {
        case idle
        case checking
        case current
        case available(AppUpdate)
        case downloading(AppUpdate, Double?)
        case installing(AppUpdate, String)
        case checkFailed(String, AppUpdate?)
        case installFailed(String, AppUpdate)
    }

    static let automaticChecksKey = "softwareUpdates.automaticChecks"
    private static let lastAutomaticCheckKey = "softwareUpdates.lastAutomaticCheck"
    private static let lastPresentedReleaseKey = "softwareUpdates.lastPresentedRelease"
    private static let lastAcknowledgedRecoveryKey = "softwareUpdates.lastAcknowledgedRecovery"
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pendingAutomaticPrompt: String?
    @Published private(set) var pendingRecoveryPrompt = false
    @Published private(set) var lastInstallResult: AppUpdateInstallResult?
    @Published private(set) var pendingResultTimedOut = false
    private var automaticCheckTimer: Timer?
    private var installationToken: UUID?
    private var lastProgressOrder = 0
    var showInstallFailure: (() -> Void)?

    let currentVersion: String

    init() {
        if let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           AppVersion(bundleVersion) != nil {
            currentVersion = bundleVersion
        } else {
            currentVersion = "0.0.0"
        }
    }

    var displayVersion: String { currentVersion == "0.0.0" ? "Development build" : "Version \(currentVersion)" }

    var availableUpdate: AppUpdate? {
        switch phase {
        case .available(let update), .downloading(let update, _), .installing(let update, _): return update
        case .checkFailed(_, let update): return update
        case .installFailed(_, let update): return update
        default: return nil
        }
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    func startAutomaticChecks() {
        guard automaticCheckTimer == nil, !AppModel.isDemo, currentVersion != "0.0.0" else { return }
        refreshInstallResult()
        if lastInstallResult?.outcome == .pending {
            Task {
                // The helper writes pending before the old app quits. The new
                // app can launch while the helper is still checking its health.
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    refreshInstallResult()
                    if lastInstallResult?.outcome != .pending { return }
                }
                pendingResultTimedOut = true
                pendingRecoveryPrompt = true
            }
        }
        Task { await checkAutomaticallyIfDue() }
        automaticCheckTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkAutomaticallyIfDue() }
        }
    }

    /// Called from the app's main window on launch and hourly while it remains
    /// open. Persist the attempt time, including network failures, so a broken
    /// connection does not trigger a request every time the app opens.
    func checkAutomaticallyIfDue() async {
        guard !AppModel.isDemo, currentVersion != "0.0.0", automaticChecksEnabled, !isBusy else { return }
        let defaults = UserDefaults.standard
        let lastAttempt = defaults.object(forKey: Self.lastAutomaticCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastAttempt) >= Self.automaticCheckInterval else { return }
        defaults.set(Date(), forKey: Self.lastAutomaticCheckKey)
        await check(manual: false)
    }

    var automaticChecksEnabled: Bool {
        let value = UserDefaults.standard.object(forKey: Self.automaticChecksKey)
        return value as? Bool ?? true
    }

    func check(manual: Bool = true) async {
        guard !isBusy else { return }
        let previousUpdate = availableUpdate
        phase = .checking
        do {
            if let update = try await AppUpdateService.checkForUpdates(currentVersion: currentVersion) {
                phase = .available(update)
                if manual {
                    markPromptShown(for: update.tag)
                } else if UserDefaults.standard.string(forKey: Self.lastPresentedReleaseKey) != update.tag {
                    pendingAutomaticPrompt = update.tag
                    NSApp.dockTile.badgeLabel = "1"
                }
            } else {
                phase = .current
            }
        } catch {
            if manual {
                phase = .checkFailed(error.localizedDescription, previousUpdate)
            } else {
                // Background checks remain quiet; an update already found in
                // this session stays available despite a later network error.
                phase = previousUpdate.map(Phase.available) ?? .idle
            }
        }
    }

    func markPromptShown(for tag: String) {
        UserDefaults.standard.set(tag, forKey: Self.lastPresentedReleaseKey)
        if pendingAutomaticPrompt == tag { pendingAutomaticPrompt = nil }
        NSApp.dockTile.badgeLabel = nil
    }

    func refreshInstallResult() {
        guard let result = AppUpdateInstaller.lastResult() else { return }
        lastInstallResult = result
        switch result.outcome {
        case .installed:
            pendingRecoveryPrompt = false
            pendingResultTimedOut = false
            return
        case .pending:
            return
        case .failed, .rolledBack, .recoveryRequired:
            pendingResultTimedOut = false
        }
        let acknowledged = UserDefaults.standard.object(forKey: Self.lastAcknowledgedRecoveryKey) as? Date ?? .distantPast
        if result.timestamp > acknowledged { pendingRecoveryPrompt = true }
    }

    func acknowledgeRecoveryPrompt() {
        guard let result = lastInstallResult else { return }
        UserDefaults.standard.set(result.timestamp, forKey: Self.lastAcknowledgedRecoveryKey)
        pendingRecoveryPrompt = false
    }

    /// The button is the only entry point for replacement. Hold the reader's
    /// busy lock from the first download byte until this process exits, so a
    /// scan or firmware flash cannot start while the helper prepares a swap.
    func install(_ update: AppUpdate, plan: AppUpdateInstallPlan, app: AppModel) async {
        guard !isBusy, !app.isBusy, !app.firmwareUpdatePhase.isActive else { return }
        app.isBusy = true
        app.busyLabel = "Installing Mac app update"
        Self.installationInProgress = true
        phase = .downloading(update, nil)
        let token = UUID()
        installationToken = token
        lastProgressOrder = 0
        do {
            try await AppUpdateInstaller.install(update, plan: plan) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.show(progress: progress, update: update, token: token)
                }
            }
            installationToken = nil
            phase = .installing(update, "Quitting Proxmark UI to finish installation…")
            Self.installationInProgress = false
            NSApp.terminate(nil)
        } catch {
            installationToken = nil
            Self.installationInProgress = false
            app.isBusy = false
            app.busyLabel = ""
            phase = .installFailed(error.localizedDescription, update)
            showInstallFailure?()
        }
    }

    private func show(progress: AppUpdateProgress, update: AppUpdate, token: UUID) {
        guard installationToken == token else { return }
        let order: Int
        switch progress {
        case .downloading: order = 1
        case .verifying: order = 2
        case .staging: order = 3
        case .readyToQuit: order = 4
        }
        guard order >= lastProgressOrder else { return }
        lastProgressOrder = order
        switch progress {
        case .downloading: phase = .downloading(update, nil)
        case .verifying: phase = .installing(update, "Verifying the download and its contents…")
        case .staging: phase = .installing(update, "Preparing the new app for installation…")
        case .readyToQuit: phase = .installing(update, "Ready to replace the app after it quits…")
        }
    }
}

struct SoftwareUpdateView: View {
    @ObservedObject var updates: SoftwareUpdateModel
    @ObservedObject var app: AppModel
    @AppStorage(SoftwareUpdateModel.automaticChecksKey) private var automaticallyCheck = true
    @State private var installPlan: AppUpdateInstallPlan?
    @State private var installUnavailableReason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                AppIconView()
                    .frame(width: 62, height: 62)
                    .padding(9)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border))

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(Theme.sans(.semibold, 21))
                        .foregroundStyle(Theme.ink)
                    Text(subtitle)
                        .font(Theme.sans(.regular, 13))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 5)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 22)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let result = updates.lastInstallResult,
                       result.outcome != .installed,
                       (result.outcome != .pending || updates.pendingResultTimedOut) {
                        recoveryContent(result)
                    }
                    statusContent
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
                .padding(.top, 18)
                .padding(.bottom, 15)

            HStack(spacing: 12) {
                Toggle("Automatically check for updates", isOn: $automaticallyCheck)
                    .toggleStyle(.checkbox)
                    .font(Theme.sans(.regular, 12))
                    .onChange(of: automaticallyCheck) { enabled in
                        if enabled { Task { await updates.checkAutomaticallyIfDue() } }
                    }
                Spacer(minLength: 8)
                actions
            }
        }
        .padding(25)
        .frame(width: 580, height: windowHeight)
        .background(Theme.canvas)
        .onAppear {
            loadInstallPlan()
            if !AppModel.isDemo { updates.refreshInstallResult() }
        }
    }

    private var windowHeight: CGFloat {
        let base: CGFloat
        switch updates.phase {
        case .available, .downloading, .installing, .installFailed, .checkFailed:
            base = 560
        case .idle, .checking, .current:
            base = 350
        }
        let hasRecovery = updates.lastInstallResult.map {
            $0.outcome != .installed && ($0.outcome != .pending || updates.pendingResultTimedOut)
        } ?? false
        return min(base + (hasRecovery ? 180 : 0), 680)
    }

    private func recoveryContent(_ result: AppUpdateInstallResult) -> some View {
        let title: String
        let symbol: String
        let tint: Color
        switch result.outcome {
        case .rolledBack:
            title = "Previous app restored"
            symbol = "arrow.uturn.backward.circle"
            tint = Theme.warn
        case .recoveryRequired:
            title = "Update needs recovery"
            symbol = "exclamationmark.triangle"
            tint = Theme.bad
        case .pending:
            title = "Update result is still unknown"
            symbol = "questionmark.circle"
            tint = Theme.warn
        case .failed:
            title = "Update did not finish"
            symbol = "exclamationmark.triangle"
            tint = Theme.bad
        case .installed:
            title = "Update installed"
            symbol = "checkmark.circle"
            tint = Theme.good
        }
        return Card {
            Label(title, systemImage: symbol)
            .font(Theme.sans(.semibold, 13.5))
            .foregroundStyle(tint)
            Text(result.outcome == .pending ? "The installer did not report a final result. Check the installed app and try again if needed." : result.message)
                .font(Theme.sans(.regular, 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if FileManager.default.fileExists(atPath: result.backup.path) {
                Text(result.backup.path)
                    .font(Theme.mono(.regular, 10.5))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Button("Show previous app in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.backup])
                }
                .buttonStyle(.link)
                .font(Theme.sans(.medium, 11.5))
            }
        }
    }

    @ViewBuilder private var statusContent: some View {
        switch updates.phase {
        case .idle:
            Card {
                Label("Ready to check for updates", systemImage: "arrow.triangle.2.circlepath")
                    .font(Theme.sans(.semibold, 14))
                    .foregroundStyle(Theme.accent)
                Text("Check GitHub for a newer Mac app and bundled client.")
                    .font(Theme.sans(.regular, 12.5))
                    .foregroundStyle(Theme.secondary)
            }
        case .checking:
            Card {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Checking GitHub releases…")
                        .font(Theme.sans(.medium, 13))
                        .foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .current:
            Card {
                Label("You have the latest version", systemImage: "checkmark.circle.fill")
                    .font(Theme.sans(.semibold, 14))
                    .foregroundStyle(Theme.good)
                Text("\(updates.displayVersion) is the newest available release.")
                    .font(Theme.sans(.regular, 12.5))
                    .foregroundStyle(Theme.secondary)
            }
        case .available(let update), .downloading(let update, _), .installing(let update, _):
            releaseContent(update)
        case .checkFailed(let message, let update):
            VStack(alignment: .leading, spacing: 12) {
                Card {
                    Label("Could not check for updates", systemImage: "exclamationmark.triangle")
                        .font(Theme.sans(.semibold, 14))
                        .foregroundStyle(Theme.bad)
                    Text(message)
                        .font(Theme.sans(.regular, 12.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let update { releaseNotes(update) }
            }
        case .installFailed(let message, let update):
            VStack(alignment: .leading, spacing: 12) {
                Card {
                    Label("Installation stopped", systemImage: "exclamationmark.triangle")
                        .font(Theme.sans(.semibold, 14))
                        .foregroundStyle(Theme.bad)
                    Text(message)
                        .font(Theme.sans(.regular, 12.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Your current app is still in place.")
                        .font(Theme.sans(.medium, 11.5))
                        .foregroundStyle(Theme.secondary)
                }
                installLocation
                releaseNotes(update)
            }
        }
    }

    private func releaseContent(_ update: AppUpdate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Version \(update.version.description)")
                    .font(Theme.sans(.semibold, 14))
                    .foregroundStyle(Theme.ink)
                if update.isPrerelease {
                    Text("Preview release")
                        .font(Theme.sans(.semibold, 10))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .foregroundStyle(Theme.accent)
                        .background(Theme.accentSoft, in: Capsule())
                }
                Spacer()
                Text("You have \(updates.currentVersion)")
                    .font(Theme.sans(.regular, 11.5))
                    .foregroundStyle(Theme.secondary)
            }
            releaseNotes(update)
            installLocation
            if case .downloading(_, let fraction) = updates.phase {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: fraction)
                    Text(fraction.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading and verifying the update…")
                        .font(Theme.sans(.regular, 11.5))
                        .foregroundStyle(Theme.secondary)
                }
            } else if case .installing(_, let message) = updates.phase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message)
                        .font(Theme.sans(.regular, 11.5))
                        .foregroundStyle(Theme.secondary)
                }
            } else {
                Text("The app update also includes its matching command-line client. Reader firmware is updated separately.")
                    .font(Theme.sans(.regular, 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("This release is not notarized by Apple. macOS may ask you to allow it when it reopens.")
                .font(Theme.sans(.regular, 11))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !updates.isBusy && (app.isBusy || app.firmwareUpdatePhase.isActive) {
                Label("Finish the current reader operation before installing the Mac app update.", systemImage: "hourglass")
                    .font(Theme.sans(.medium, 11.5))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var installLocation: some View {
        if let plan = installPlan {
            Card(padding: 13) {
                installPath("Install in", path: plan.destination.path)
                installPath("Keep previous version at", path: plan.backup.path)
            }
        } else if let installUnavailableReason {
            Card(padding: 13) {
                Label("Install from this app is unavailable", systemImage: "info.circle")
                    .font(Theme.sans(.semibold, 12.5))
                    .foregroundStyle(Theme.warn)
                Text(installUnavailableReason)
                    .font(Theme.sans(.regular, 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func installPath(_ label: String, path: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.sans(.regular, 11.5))
                .foregroundStyle(Theme.secondary)
            Text(path)
                .font(Theme.mono(.regular, 11))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func loadInstallPlan() {
        do {
            installPlan = try AppUpdateInstaller.installationPlan(for: Bundle.main.bundleURL)
            installUnavailableReason = nil
        } catch {
            installPlan = nil
            installUnavailableReason = error.localizedDescription
        }
    }

    private func releaseNotes(_ update: AppUpdate) -> some View {
        Card {
            SectionTitle(text: "What’s new")
            ScrollView {
                Text(formattedNotes(for: update))
                    .font(Theme.sans(.regular, 12))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 135)
            Button("View release on GitHub") { NSWorkspace.shared.open(update.releaseURL) }
                .buttonStyle(.link)
                .font(Theme.sans(.medium, 11.5))
        }
    }

    private func displayNotes(for update: AppUpdate) -> String {
        let notes = update.releaseNotes
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("![") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? "See the release page for details." : notes
    }

    private func formattedNotes(for update: AppUpdate) -> AttributedString {
        let notes = displayNotes(for: update)
        return (try? AttributedString(markdown: notes)) ?? AttributedString(notes)
    }

    @ViewBuilder private var actions: some View {
        switch updates.phase {
        case .idle:
            Button("Check Now") { Task { await updates.check() } }
                .buttonStyle(PillButtonStyle())
        case .current:
            Button("Check Again") { Task { await updates.check() } }
                .buttonStyle(PillButtonStyle(filled: false))
        case .checkFailed(_, let update):
            Button("Check Again") { Task { await updates.check() } }
                .buttonStyle(PillButtonStyle(filled: false))
            if let update, let installPlan {
                Button("Retry Install") { Task { await updates.install(update, plan: installPlan, app: app) } }
                    .buttonStyle(PillButtonStyle())
                    .disabled(app.isBusy || app.firmwareUpdatePhase.isActive)
            }
        case .installFailed(_, let update):
            Button("Check Again") { Task { await updates.check() } }
                .buttonStyle(PillButtonStyle(filled: false))
            if let installPlan {
                Button("Retry Install") { Task { await updates.install(update, plan: installPlan, app: app) } }
                    .buttonStyle(PillButtonStyle())
                    .disabled(app.isBusy || app.firmwareUpdatePhase.isActive)
            }
        case .checking:
            Button("Checking…") {}
                .buttonStyle(PillButtonStyle(filled: false))
                .disabled(true)
        case .available(let update):
            Button("Download and Install") {
                if let installPlan {
                    Task { await updates.install(update, plan: installPlan, app: app) }
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(installPlan == nil || app.isBusy || app.firmwareUpdatePhase.isActive)
        case .downloading, .installing:
            Button("Working…") {}
                .buttonStyle(PillButtonStyle())
                .disabled(true)
        }
    }

    private var title: String {
        switch updates.phase {
        case .available, .downloading, .installing: return "An update is available"
        case .current: return "Proxmark UI is up to date"
        case .checkFailed: return "Couldn’t check for updates"
        case .installFailed: return "Couldn’t install update"
        default: return "Software Update"
        }
    }

    private var subtitle: String {
        switch updates.phase {
        case .available(let update), .downloading(let update, _), .installing(let update, _):
            return "Proxmark UI \(update.version) is ready for your Mac."
        case .current: return "Your Mac app and bundled client are current."
        case .checkFailed: return "Check your connection and try again."
        case .installFailed: return "The app you were using is still installed."
        default: return "Checking for a newer Mac app and bundled client."
        }
    }
}
