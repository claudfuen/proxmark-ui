import AppKit
import ProxmarkKit
import SwiftUI

/// Appearance choice, stored in UserDefaults and applied to NSApp.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    static let key = "appearance"

    /// PMUI_APPEARANCE (QA) wins over the saved preference.
    @MainActor
    static func apply(_ pref: AppearancePreference? = nil) {
        let env = ProcessInfo.processInfo.environment["PMUI_APPEARANCE"]
        let value = env ?? pref?.rawValue ?? UserDefaults.standard.string(forKey: key) ?? "system"
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

/// ⌘, : a standard Mac settings window with toolbar tabs. The selected tab's
/// name is the window title. View-layer only; client discovery stays in
/// ProxmarkKit (Pm3Locator) and AppModel.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ReaderSettings()
                .tabItem { Label("Reader", systemImage: "wave.3.right") }
            LibrarySettings()
                .tabItem { Label("Library", systemImage: "tray.full") }
        }
        .frame(width: 560)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @AppStorage(AppearancePreference.key) private var appearance: AppearancePreference = .system

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    ForEach(AppearancePreference.allCases) { pref in
                        AppearanceSwatch(pref: pref, selected: appearance == pref) {
                            appearance = pref
                            AppearancePreference.apply(pref)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } header: {
                Text("Appearance")
            } footer: {
                SettingsFooter("Auto follows the Light or Dark setting in System Settings.")
            }

            Section("Keyboard shortcuts") {
                ShortcutRow(action: "Scan 13.56 MHz", keys: "⌘1")
                ShortcutRow(action: "Scan 125 kHz", keys: "⌘2")
                ShortcutRow(action: "Reconnect reader", keys: "⌘R")
                ShortcutRow(action: "Settings", keys: "⌘,")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A miniature window in each appearance, like System Settings.
private struct AppearanceSwatch: View {
    let pref: AppearancePreference
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(width: 112, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
                    )
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5)
                    )
                Text(pref.label)
                    .font(Theme.sans(selected ? .semibold : .regular, 12))
                    .foregroundStyle(selected ? Theme.ink : Theme.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(pref.label) appearance")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var preview: some View {
        switch pref {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            // Half light, half dark, split on the diagonal.
            ZStack {
                MiniWindow(dark: false)
                MiniWindow(dark: true)
                    .mask(
                        GeometryReader { g in
                            Path { p in
                                p.move(to: CGPoint(x: g.size.width, y: 0))
                                p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                                p.addLine(to: CGPoint(x: 0, y: g.size.height))
                                p.closeSubpath()
                            }
                        }
                    )
            }
        }
    }
}

/// Sidebar + content sketch of the app window, in fixed colours (it previews
/// an appearance, so it must not follow the current one).
private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let canvas = dark ? Color(white: 0.11) : Color(white: 0.96)
        let side = dark ? Color(white: 0.19) : Color(white: 0.89)
        let card = dark ? Color(white: 0.17) : .white
        let line = dark ? Color(white: 0.32) : Color(white: 0.80)
        let accent = dark ? Color(red: 0.48, green: 0.64, blue: 0.86) : Color(red: 0.15, green: 0.27, blue: 0.42)

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 2.5) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { c in
                        Circle().fill(c.opacity(0.8)).frame(width: 4, height: 4)
                    }
                }
                .padding(.bottom, 3)
                RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 22, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 18, height: 4)
                RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 20, height: 4)
                Spacer()
            }
            .padding(6)
            .frame(width: 34)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(side)

            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(card)
                    .frame(height: 26)
                    .overlay(alignment: .leading) {
                        Circle().fill(accent.opacity(0.85)).frame(width: 12, height: 12).padding(.leading, 6)
                    }
                RoundedRectangle(cornerRadius: 3).fill(card).frame(height: 20)
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(canvas)
        }
    }
}

private struct ShortcutRow: View {
    let action: String
    let keys: String

    var body: some View {
        LabeledContent(action) {
            Text(keys)
                .font(Theme.sans(.medium, 12))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.border))
        }
    }
}

// MARK: Reader

private struct ReaderSettings: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    IconTile(systemName: "wave.3.right", tint: statusColor, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle)
                            .font(Theme.sans(.semibold, 13.5))
                            .foregroundStyle(Theme.ink)
                        Text(statusDetail)
                            .font(Theme.sans(.regular, 11.5))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    StatusCapsule(text: statusBadge, color: statusColor)
                }
                .padding(.vertical, 4)

                if app.availablePorts.count > 1 {
                    Picker("Port", selection: Binding(get: { app.selectedPort ?? "" }, set: { app.selectedPort = $0 })) {
                        ForEach(app.availablePorts, id: \.self) { Text(shortPort($0)).tag($0) }
                    }
                    .onChange(of: app.selectedPort) { _ in Task { await app.checkConnection() } }
                } else {
                    LabeledContent("Port") {
                        Text(app.selectedPort.map(shortPort) ?? "None")
                            .font(Theme.mono(.regular, 12))
                            .foregroundStyle(app.selectedPort == nil ? Theme.secondary : Theme.ink)
                    }
                }

                LabeledContent("Connection") {
                    Button {
                        Task { await app.checkConnection() }
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .disabled(app.isBusy)
                }
            } header: {
                Text("Status")
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        if Pm3Locator.isBundled(app.clientPath) {
                            StatusCapsule(text: "Bundled", color: Theme.good)
                        } else if hasCustomClient {
                            StatusCapsule(text: "Custom", color: Theme.accent)
                        }
                        Button("Choose…") { app.chooseClient() }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Client")
                        Text(app.clientPath.map { abbreviate($0.path) } ?? "Not found")
                            .font(Theme.mono(.regular, 11))
                            .foregroundStyle(app.clientPath == nil ? Theme.bad : Theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                if hasCustomClient {
                    LabeledContent("Custom path") {
                        Button("Use Default") { resetClient() }
                    }
                }
            } header: {
                Text("Proxmark3 client")
            } footer: {
                SettingsFooter("The command-line client this app drives. Its version must match the firmware on your reader, or scans are blocked until you update it.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hasCustomClient: Bool {
        UserDefaults.standard.string(forKey: AppModel.clientPathKey) != nil
    }

    private var statusColor: Color {
        switch app.connection {
        case .ready: return Theme.good
        case .checking: return Theme.warn
        case .noDevice: return Theme.secondary
        default: return Theme.bad
        }
    }

    private var statusBadge: String {
        switch app.connection {
        case .ready: return "Connected"
        case .checking: return "Checking"
        case .noDevice: return "Unplugged"
        case .noClient: return "No client"
        case .firmwareMismatch: return "Mismatch"
        case .unreachable: return "No reply"
        }
    }

    private var statusTitle: String {
        switch app.connection {
        case .ready(let d): return d.model
        case .checking: return "Connecting…"
        case .noClient: return "Client missing"
        case .noDevice: return "No reader plugged in"
        case .firmwareMismatch: return "Firmware doesn't match the client"
        case .unreachable: return "The reader isn't answering"
        }
    }

    private var statusDetail: String {
        switch app.connection {
        case .ready(let d): return d.firmware
        case .checking: return "Asking the reader for its firmware version."
        case .noClient: return "Install the client or choose one below."
        case .noDevice: return "Connect the Proxmark3 over USB."
        case .firmwareMismatch(let device, let client): return "Reader protocol v\(device), client v\(client)."
        case .unreachable(let reason): return reason
        }
    }

    private func resetClient() {
        UserDefaults.standard.removeObject(forKey: AppModel.clientPathKey)
        unsetenv("PM3_CLIENT")
        app.refreshClient()
        Task { await app.checkConnection() }
    }
}

// MARK: Library

private struct LibrarySettings: View {
    @EnvironmentObject var app: AppModel

    private var totalBytes: Int { app.dumps.reduce(0) { $0 + $1.byteCount } }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: Pm3Locator.dumpsDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Pm3Locator.dumpsDirectory)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dumps folder")
                        Text(abbreviate(Pm3Locator.dumpsDirectory.path))
                            .font(Theme.mono(.regular, 11))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Saved dumps") {
                    Text(app.dumps.isEmpty ? "None yet" : "\(app.dumps.count) \u{00B7} \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))")
                        .foregroundStyle(Theme.secondary)
                }
            } header: {
                Text("Storage")
            } footer: {
                SettingsFooter("Each dump is a .bin file with a small .json file beside it for its name and UID. Back up the folder to keep them.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Shared

/// Grouped-form footers default to trailing alignment on macOS, which reads
/// badly for a sentence. Pin them leading.
private struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.sans(.regular, 11.5))
            .foregroundStyle(Theme.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatusCapsule: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(Theme.sans(.semibold, 10.5))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(color)
            .background(color.opacity(0.13), in: Capsule())
    }
}

private func abbreviate(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

enum AboutPanel {
    @MainActor
    static func show() {
        let credits = NSAttributedString(
            string: "A native Mac front end for the Iceman Proxmark3 client.\nOnly read or write tags you own or are authorized to test.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Proxmark",
            .credits: credits,
        ]
        if let icon = AppIcon.image(pixels: 256) { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }
}
