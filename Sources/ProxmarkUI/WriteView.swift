import ProxmarkKit
import SwiftUI

/// Every action here overwrites whatever tag is physically on the antenna.
/// Each one goes through a confirm step and through ProxmarkKit.Commands,
/// which validates input before it ever reaches the client's command line.
struct WriteView: View {
    @EnvironmentObject var app: AppModel
    var goToScan: () -> Void = {}
    @State private var mode: WriteMode = .em410x
    // PMUI_WRITE_ID prefills the EM410x field (screenshots, QA).
    @State private var em410xID = ProcessInfo.processInfo.environment["PMUI_WRITE_ID"] ?? ""
    @State private var hidFacility = ""
    @State private var hidCard = ""
    @State private var selectedDump: DumpEntry?
    @State private var pending: PendingWrite?
    @State private var inFlight: String?
    @State private var succeeded: String?

    struct PendingWrite {
        let summary: String
        let action: () async -> Void
    }

    enum WriteMode: String, CaseIterable, Identifiable {
        case em410x = "EM410x"
        case hid = "HID Prox"
        case fromDump = "From a dump"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .em410x: return "key.radiowaves.forward"
            case .hid: return "person.text.rectangle"
            case .fromDump: return "doc.on.doc"
            }
        }
        var blurb: String {
            switch self {
            case .em410x: return "125 kHz ID onto a T5577"
            case .hid: return "Facility + card onto a T5577"
            case .fromDump: return "Classic or NTAG from Library"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ConnectionBanner()
                Callout(
                    systemName: "exclamationmark.triangle",
                    tint: Theme.warn,
                    title: "Writing replaces what's on the tag",
                    message: "The tag on the antenna right now is overwritten. Only write to tags you own or are authorized to test."
                )

                HStack(spacing: 10) {
                    ForEach(WriteMode.allCases) { m in
                        ModeTile(mode: m, selected: mode == m) { mode = m }
                    }
                }

                switch mode {
                case .em410x: em410xCard
                case .hid: hidCard_
                case .fromDump: fromDumpCard
                }

                if app.isBusy {
                    HStack(spacing: 14) {
                        AntennaField(active: true, size: 44)
                        Text(app.busyLabel).font(Theme.sans(.medium, 13)).foregroundStyle(Theme.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                }
                if let error = app.lastError, !app.isBusy {
                    Callout(systemName: "exclamationmark.circle", tint: Theme.bad, title: "Write failed", message: error)
                }
                if let ok = succeeded, !app.isBusy, app.lastError == nil {
                    Callout(
                        systemName: "checkmark.seal.fill", tint: Theme.good,
                        title: "Wrote \(ok)",
                        message: "Scan the tag to confirm it reads back as expected."
                    ) {
                        Button("Verify in Scan") { succeeded = nil; goToScan() }
                            .buttonStyle(PillButtonStyle(filled: false))
                            .padding(.top, 2)
                    }
                    .transition(.opacity)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .animation(.easeOut(duration: 0.2), value: succeeded)
        .onChange(of: app.isBusy) { busy in
            if busy {
                succeeded = nil
                let label = app.busyLabel
                inFlight = label.hasPrefix("Writing ") || label.hasPrefix("Restoring ") ? label : nil
            } else if app.lastError == nil, let done = inFlight {
                // Ignore scans, reads, and firmware updates that can also
                // change the shared busy state while Write is visible.
                succeeded = done.replacingOccurrences(of: "Writing ", with: "")
                    .replacingOccurrences(of: "Restoring ", with: "")
                    .replacingOccurrences(of: "...", with: "")
                inFlight = nil
            } else {
                inFlight = nil
            }
        }
        .confirmationDialog(
            "Write to the tag on the antenna?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { p in
            Button("Write", role: .destructive) {
                pending = nil
                Task { await p.action() }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { p in
            Text("\(p.summary)\n\nThis overwrites the tag currently on the reader and can't be undone.")
        }
    }

    private var canWrite: Bool { app.connection.isReady && !app.isBusy }

    // MARK: EM410x

    private var em410xCommand: Result<String, Error> { Result { try Commands.em410xClone(id: em410xID) } }

    private var em410xCard: some View {
        FormCard(
            title: "EM410x ID",
            footnote: "Ten hex digits, as printed by an LF scan. Spaces are ignored.",
            command: em410xID.isEmpty ? nil : em410xCommand
        ) {
            LabeledField(label: "ID") {
                TextField("0F0368568B", text: $em410xID)
                    .font(Theme.mono(.regular, 14))
            }
        } action: {
            Button {
                let id = em410xID
                pending = .init(summary: "EM410x \(id.uppercased())") { await app.writeEM410x(id: id) }
            } label: {
                Label("Write EM410x", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(PillButtonStyle(destructive: true, large: true))
            .disabled(!canWrite || (try? em410xCommand.get()) == nil)
        }
    }

    // MARK: HID

    private var hidCommand: Result<String, Error> {
        Result { try Commands.hidClone(facility: hidFacility, card: hidCard) }
    }

    private var hidCard_: some View {
        FormCard(
            title: "HID Prox H10301",
            footnote: "26-bit format: facility code and card number, in decimal.",
            command: hidFacility.isEmpty || hidCard.isEmpty ? nil : hidCommand
        ) {
            HStack(spacing: 12) {
                LabeledField(label: "Facility code") {
                    TextField("123", text: $hidFacility).font(Theme.mono(.regular, 14))
                }
                LabeledField(label: "Card number") {
                    TextField("45678", text: $hidCard).font(Theme.mono(.regular, 14))
                }
            }
        } action: {
            Button {
                let fc = hidFacility, cn = hidCard
                pending = .init(summary: "HID Prox \(fc)/\(cn)") { await app.writeHID(facility: fc, card: cn) }
            } label: {
                Label("Write HID", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(PillButtonStyle(destructive: true, large: true))
            .disabled(!canWrite || (try? hidCommand.get()) == nil)
        }
    }

    // MARK: From a dump

    private var fromDumpCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Restore a saved dump", trailing: "\(app.dumps.count) in Library")
                if app.dumps.isEmpty {
                    Text("No dumps saved yet. Read a Classic or Ultralight tag in Scan first.")
                        .font(Theme.sans(.regular, 12.5))
                        .foregroundStyle(Theme.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(app.dumps) { d in
                            Button {
                                selectedDump = d
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedDump == d ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(selectedDump == d ? Theme.accent : Theme.tertiary)
                                    DumpRow(entry: d)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(RowHoverStyle())
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }

                if let d = selectedDump {
                    Divider().overlay(Theme.hairline)
                    VStack(alignment: .leading, spacing: 9) {
                        if d.kind.localizedCaseInsensitiveContains("classic") || d.kind.localizedCaseInsensitiveContains("mini") {
                            HStack(spacing: 8) {
                                Button {
                                    pending = .init(summary: "Restore \(d.name) (\(spaced(d.uid))) to a Classic tag that already uses the saved keys") {
                                        await app.restoreClassic(dump: d, authenticateWithKeys: true)
                                    }
                                } label: {
                                    Label("Restore with saved keys", systemImage: "square.and.arrow.down")
                                }
                                .buttonStyle(PillButtonStyle(destructive: true, large: true))
                                .help("Authenticates with the keys recovered during the full read.")
                                .disabled(!canWrite || d.keyURL == nil)

                                Button {
                                    pending = .init(summary: "Restore \(d.name) (\(spaced(d.uid))) to a Classic tag that still uses default FFFFFFFFFFFF keys") {
                                        await app.restoreClassic(dump: d, authenticateWithKeys: false)
                                    }
                                } label: {
                                    Label("Restore to default-key tag", systemImage: "square.and.arrow.down")
                                }
                                .buttonStyle(PillButtonStyle(filled: false, destructive: true, large: true))
                                .help("Authenticates with factory-default keys and writes the saved sector keys.")
                                .disabled(!canWrite || d.keyURL == nil)
                            }
                            if d.keyURL == nil {
                                Text("This dump has no saved key file. Read the source tag with full key recovery to use either restore option.")
                                    .font(Theme.sans(.regular, 11.5))
                                    .foregroundStyle(Theme.secondary)
                            }
                            Button {
                                pending = .init(summary: "Load \(d.name) (\(spaced(d.uid))) onto a Gen1a magic tag, UID included") {
                                    await app.loadMagic(dump: d)
                                }
                            } label: {
                                Label("Load onto magic Gen1a", systemImage: "wand.and.stars")
                            }
                            .buttonStyle(PillButtonStyle(filled: false, destructive: true, large: true))
                            .help("Writes every block, including block 0 (the UID).")
                            .disabled(!canWrite)
                        } else {
                            Button {
                                pending = .init(summary: "Restore writable user pages from \(d.name) (\(spaced(d.uid))) to an Ultralight/NTAG") {
                                    await app.restoreUltralight(dump: d)
                                }
                            } label: {
                                Label("Restore user pages to Ultralight/NTAG", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(PillButtonStyle(destructive: true, large: true))
                            .help("Writes user pages only. UID and lock/configuration pages are not changed.")
                            .disabled(!canWrite)
                        }
                    }
                }
            }
        }
        .onAppear {
            if let s = selectedDump, !app.dumps.contains(s) { selectedDump = nil }
        }
    }
}

struct ModeTile: View {
    let mode: WriteView.WriteMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(systemName: mode.icon, tint: selected ? Theme.accent : Theme.secondary, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.rawValue).font(Theme.sans(.semibold, 13)).foregroundStyle(Theme.ink)
                    Text(mode.blurb).font(Theme.sans(.regular, 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(TilePressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A write form: fields, live validation from ProxmarkKit.Commands, the exact
/// client command that will run, and the write button.
struct FormCard<Fields: View, Action: View>: View {
    let title: String
    let footnote: String
    /// nil while the fields are empty; otherwise the validated command or why it's invalid.
    let command: Result<String, Error>?
    @ViewBuilder var fields: Fields
    @ViewBuilder var action: Action

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: title)
                fields
                Text(footnote)
                    .font(Theme.sans(.regular, 11.5))
                    .foregroundStyle(Theme.secondary)

                switch command {
                case .success(let cmd):
                    HStack(spacing: 8) {
                        Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        Text(cmd)
                            .font(Theme.mono(.regular, 11.5))
                            .foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                case .failure(let error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.circle")
                        .font(Theme.sans(.medium, 12))
                        .foregroundStyle(Theme.bad)
                case nil:
                    EmptyView()
                }

                action
            }
        }
    }
}

struct LabeledField<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.sans(.medium, 12)).foregroundStyle(Theme.secondary)
            field
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
