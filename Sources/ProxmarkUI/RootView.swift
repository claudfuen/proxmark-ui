import ProxmarkKit
import SwiftUI

enum Section_: String, CaseIterable, Identifiable {
    case scan = "Scan"
    case library = "Library"
    case write = "Write"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .scan: return "wave.3.right"
        case .library: return "tray.full"
        case .write: return "square.and.pencil"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var tags: TagLibrary
    // PMUI_SECTION=scan|library|write opens on that screen (screenshots, QA).
    @State private var section: Section_ = Section_.allCases.first {
        $0.rawValue.lowercased() == ProcessInfo.processInfo.environment["PMUI_SECTION"]?.lowercased()
    } ?? .scan

    var body: some View {
        NavigationSplitView {
            // One container, fixed width: the header, nav list and device panel
            // slide together when the sidebar collapses, instead of each
            // reflowing at intermediate widths (the toggle glitch).
            VStack(spacing: 0) {
                SidebarHeader()
                    .padding(.horizontal, 10)
                List(selection: $section) {
                    ForEach(Section_.allCases) { s in
                        Label(s.rawValue, systemImage: s.icon)
                            .badge(s == .library ? app.dumps.count + tags.tags.count : 0)
                            .tag(s)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                DevicePanel()
            }
            .frame(minWidth: 232, idealWidth: 232, maxWidth: .infinity)
            .clipped()
            .navigationSplitViewColumnWidth(232)
        } detail: {
            Group {
                switch section {
                case .scan: ScanView(goToLibrary: { section = .library })
                case .library: LibraryView(goToScan: { section = .scan })
                case .write: WriteView(goToScan: { section = .scan })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
            .navigationTitle(section.rawValue)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await app.checkConnection() }
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .help("Check the connection again (⌘R)")
                    .disabled(app.isBusy)
                }
            }
        }
        .task {
            if AppModel.isDemo { app.seedDemo() } else { await app.checkConnection() }
        }
        .onChange(of: app.connection) { state in
            // Learn the model whenever the reader answers with matching firmware;
            // it can't be read later during a protocol mismatch.
            if case .ready(let device) = state, !AppModel.isDemo {
                ReaderMemory.remember(reportedModel: device.model)
            }
        }
        .sheet(item: $app.firmwareUpdateSheet) { sheet in
            FirmwareUpdateView(sheet: sheet)
                .environmentObject(app)
        }
    }
}

/// The app's identity at the top of the sidebar.
struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            AppIconView()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Proxmark").font(Theme.sans(.semibold, 13.5)).foregroundStyle(Theme.ink)
                Text("RFID read and write").font(Theme.sans(.regular, 11)).foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
        .textCase(nil)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}

/// The reader, pinned to the bottom of the sidebar: what it is, which port,
/// and whether it's answering.
struct DevicePanel: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                indicator
                Text(title)
                    .font(Theme.sans(.semibold, 12.5))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if let detail {
                Text(detail)
                    .font(Theme.mono(.regular, 10.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if app.availablePorts.count > 1 {
                Picker("Port", selection: Binding(get: { app.selectedPort ?? "" }, set: { app.selectedPort = $0 })) {
                    ForEach(app.availablePorts, id: \.self) { Text(shortPort($0)).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: app.selectedPort) { _ in Task { await app.checkConnection() } }
                .disabled(app.isBusy)
            }
        }
        .padding(12)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
        .padding(12)
    }

    @ViewBuilder private var indicator: some View {
        if case .checking = app.connection {
            ProgressView().controlSize(.mini).frame(width: 8, height: 8)
        } else {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: app.connection.isReady ? color.opacity(0.6) : .clear, radius: 4)
        }
    }

    private var color: Color {
        switch app.connection {
        case .ready: return Theme.good
        case .checking: return Theme.warn
        case .noDevice: return Theme.tertiary
        default: return Theme.bad
        }
    }

    private var title: String {
        switch app.connection {
        case .ready(let d): return d.model
        case .checking: return "Connecting…"
        case .noClient: return "Client missing"
        case .noDevice: return "No reader"
        case .firmwareMismatch: return "Firmware mismatch"
        case .unreachable: return "Not responding"
        }
    }

    private var detail: String? {
        switch app.connection {
        case .ready(let d): return "\(d.firmware)\n\(shortPort(d.port))"
        case .firmwareMismatch(let device, let client):
            let model = (ReaderMemory.demoOverride ?? ReaderMemory.rememberedTarget())?.displayName ?? "Model unknown"
            return "\(model)\ndevice v\(device) / client v\(client)"
        case .noDevice: return "Plug in over USB"
        default: return app.selectedPort.map(shortPort)
        }
    }
}

func shortPort(_ port: String) -> String {
    port.replacingOccurrences(of: "/dev/", with: "")
}

/// Shown above every screen until the reader is ready. Each state says what
/// is wrong and offers the way out, so nobody hunts for a README.
struct ConnectionBanner: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        switch app.connection {
        case .ready:
            EmptyView()
        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking for the Proxmark3…").font(Theme.sans(.medium, 12.5)).foregroundStyle(Theme.secondary)
                Spacer()
            }
            .padding(.vertical, 4)
        case .noClient:
            Callout(
                systemName: "shippingbox",
                tint: Theme.warn,
                title: "Proxmark3 client unavailable",
                message: "The packaged app should include the Iceman client. Choose a working client, or rebuild the complete app bundle."
            ) {
                HStack(spacing: 8) {
                    Button("Locate client…") { app.chooseClient() }
                        .buttonStyle(PillButtonStyle(filled: false))
                    Button("Check again") {
                        app.refreshClient()
                        Task { await app.checkConnection() }
                    }
                    .buttonStyle(PillButtonStyle())
                }
                .padding(.top, 2)
            }
        case .noDevice:
            Callout(
                systemName: "cable.connector",
                tint: Theme.accent,
                title: "Plug in your Proxmark3",
                message: "Connect the reader over USB. It shows up as a usbmodem port."
            ) {
                retry
            }
        case .firmwareMismatch(let device, let client):
            Callout(
                systemName: "exclamationmark.triangle",
                tint: Theme.bad,
                title: "Firmware and client don't match",
                message: "The reader runs protocol v\(device), the client speaks v\(client). The model cannot be verified until they match. Choose your hardware before updating."
            ) {
                HStack(spacing: 8) {
                    Button("Update firmware…") { app.showFirmwareUpdate() }
                        .buttonStyle(PillButtonStyle())
                        .disabled(app.isBusy)
                    retry
                }
                .padding(.top, 2)
            }
        case .unreachable(let reason):
            Callout(systemName: "bolt.horizontal.circle", tint: Theme.bad, title: "The reader isn't answering", message: reason) {
                retry
            }
        }
    }

    private var retry: some View {
        Button("Check again") { Task { await app.checkConnection() } }
            .buttonStyle(PillButtonStyle())
            .padding(.top, 2)
            .disabled(app.isBusy)
    }
}
