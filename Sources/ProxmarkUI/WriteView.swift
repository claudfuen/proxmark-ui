import ProxmarkKit
import SwiftUI

/// Every action here overwrites whatever tag is physically on the antenna.
/// Each one goes through a confirm step and through ProxmarkKit.Commands,
/// which validates input before it ever reaches the client's command line.
struct WriteView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var tags: TagLibrary
    var goToScan: () -> Void = {}
    @State private var mode: WriteMode = .fromLibrary
    // PMUI_WRITE_PICK=first preselects the first saved tag (screenshots, QA).
    @State private var selectedTag: SavedTag? = nil
    private let pickFirstTag = ProcessInfo.processInfo.environment["PMUI_WRITE_PICK"] == "first"
    // PMUI_WRITE_ID prefills the EM410x field (screenshots, QA).
    @State private var em410xID = ProcessInfo.processInfo.environment["PMUI_WRITE_ID"] ?? ""
    @State private var hidFacility = ""
    @State private var hidCard = ""
    @State private var selectedDump: DumpEntry?
    @State private var pending: PendingWrite?
    @State private var phase: WritePhase = WriteView.demoPhase
    @State private var retry: (() async -> Void)?

    /// PMUI_WRITE_PHASE previews a write outcome for screenshots and QA.
    static var demoPhase: WritePhase {
        switch ProcessInfo.processInfo.environment["PMUI_WRITE_PHASE"] {
        case "busy": return .busy(step: "Reading back", attempt: 2, total: 3)
        case "verified": return .verified(name: "Front door fob", attempt: 2, total: 3)
        case "unverified": return .unverified(name: "Front door fob", attempts: 3)
        case "failed": return .failed("The reader didn't respond. Is a tag on the antenna?")
        default: return .idle
        }
    }

    /// How many write-then-read cycles a verifiable write will try before it
    /// reports that it couldn't confirm the tag.
    private let verifyAttempts = 3

    struct PendingWrite {
        let summary: String
        let run: () async -> Void
    }

    /// The state machine a write moves through. EM410x and HID writes verify by
    /// reading the tag back; dump restores report wrote/failed without a compare.
    enum WritePhase: Equatable {
        case idle
        case busy(step: String, attempt: Int, total: Int)
        case verified(name: String, attempt: Int, total: Int)
        case wrote(name: String)
        case unverified(name: String, attempts: Int)
        case failed(String)

        var isRunning: Bool { if case .busy = self { return true }; return false }
    }

    enum WriteMode: String, CaseIterable, Identifiable {
        case fromLibrary = "From Library"
        case em410x = "EM410x"
        case hid = "HID Prox"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .fromLibrary: return "tray.full"
            case .em410x: return "key.radiowaves.forward"
            case .hid: return "person.text.rectangle"
            }
        }
        var blurb: String {
            switch self {
            case .fromLibrary: return "A saved tag or dump"
            case .em410x: return "Type a 125 kHz ID"
            case .hid: return "Type facility + card"
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
                case .fromLibrary: fromLibraryCard
                case .em410x: em410xCard
                case .hid: hidCard_
                }

                WriteStatusPanel(phase: phase, onRetry: retry.map { r in { phase = .idle; Task { await r() } } }, onDone: { phase = .idle })
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .animation(.easeOut(duration: 0.2), value: phase)
        .confirmationDialog(
            "Write to the tag on the antenna?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { p in
            Button("Write", role: .destructive) {
                let run = p.run
                pending = nil
                retry = run
                Task { await run() }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { p in
            Text("\(p.summary)\n\nThis overwrites the tag currently on the reader and can't be undone.")
        }
    }

    private var canWrite: Bool { app.connection.isReady && !app.isBusy }

    // MARK: Write then verify

    /// Writes, then reads the tag back and compares it to what was intended,
    /// retrying the whole cycle up to `verifyAttempts` times. This is what makes
    /// a write trustworthy: the reader confirms the tag now reads as expected,
    /// rather than assuming the flash command worked.
    private func writeAndVerify(name: String, family: TagFamily, write: @escaping () async -> Void, matches: @escaping (ScanResult) -> Bool) async {
        guard app.connection.isReady else { return }
        let total = verifyAttempts
        for attempt in 1...total {
            phase = .busy(step: "Writing", attempt: attempt, total: total)
            await write()
            if let error = app.lastError {
                if attempt == total { phase = .failed(error); return }
                continue
            }
            phase = .busy(step: "Reading back", attempt: attempt, total: total)
            let previousResultID = app.lastResult?.id
            await app.scan(family: family)
            // A failed scan leaves the previous result visible in Scan. Only a
            // fresh, successful read can verify the write we just made.
            if app.lastError == nil,
               let read = app.lastResult,
               read.id != previousResultID,
               matches(read) {
                phase = .verified(name: name, attempt: attempt, total: total)
                return
            }
            if attempt == total { phase = .unverified(name: name, attempts: total) }
        }
    }

    /// A write with no automatic read-back (dump restores), reported plainly.
    private func plainWrite(name: String, write: @escaping () async -> Void) async {
        guard app.connection.isReady else { return }
        phase = .busy(step: "Writing", attempt: 1, total: 1)
        await write()
        if let error = app.lastError { phase = .failed(error) } else { phase = .wrote(name: name) }
    }

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
                let id = em410xID.filter { !$0.isWhitespace }.uppercased()
                pending = .init(summary: "EM410x \(id)") {
                    await writeAndVerify(name: "EM410x \(id)", family: .lf,
                        write: { await app.writeEM410x(id: id) },
                        matches: { $0.isEM410x && $0.uid.uppercased() == id })
                }
            } label: {
                Label("Write and verify", systemImage: "arrow.triangle.2.circlepath")
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
                pending = .init(summary: "HID Prox \(fc)/\(cn)") {
                    await writeAndVerify(name: "HID Prox \(fc)/\(cn)", family: .lf,
                        write: { await app.writeHID(facility: fc, card: cn) },
                        matches: { hidMatch($0, facility: fc, card: cn) })
                }
            } label: {
                Label("Write and verify", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(PillButtonStyle(destructive: true, large: true))
            .disabled(!canWrite || (try? hidCommand.get()) == nil)
        }
    }

    // MARK: From Library

    private var writableTags: [SavedTag] { tags.tags.filter { $0.write.isWritable } }

    private var fromLibraryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Write from your Library", trailing: "\(writableTags.count + app.dumps.count) available")

                if writableTags.isEmpty && app.dumps.isEmpty {
                    Text("Nothing to write yet. Scan a tag and choose Add to Library, or read a full dump, then come back here.")
                        .font(Theme.sans(.regular, 12.5))
                        .foregroundStyle(Theme.secondary)
                }

                if !writableTags.isEmpty {
                    Text("Saved tags")
                        .font(Theme.sans(.semibold, 11))
                        .foregroundStyle(Theme.secondary)
                    VStack(spacing: 0) {
                        ForEach(writableTags) { t in
                            Button {
                                selectedTag = t
                                selectedDump = nil
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedTag == t ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(selectedTag == t ? Theme.accent : Theme.tertiary)
                                    SavedTagRow(tag: t)
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

                if let t = selectedTag, selectedDump == nil {
                    Divider().overlay(Theme.hairline)
                    savedTagActions(t)
                }

                if !app.dumps.isEmpty {
                    Text("Dumps")
                        .font(Theme.sans(.semibold, 11))
                        .foregroundStyle(Theme.secondary)
                    VStack(spacing: 0) {
                        ForEach(app.dumps) { d in
                            Button {
                                selectedDump = d
                                selectedTag = nil
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
                                        await plainWrite(name: d.name) { await app.restoreClassic(dump: d, authenticateWithKeys: true) }
                                    }
                                } label: {
                                    Label("Restore with saved keys", systemImage: "square.and.arrow.down")
                                }
                                .buttonStyle(PillButtonStyle(destructive: true, large: true))
                                .help("Authenticates with the keys recovered during the full read.")
                                .disabled(!canWrite || d.keyURL == nil)

                                Button {
                                    pending = .init(summary: "Restore \(d.name) (\(spaced(d.uid))) to a Classic tag that still uses default FFFFFFFFFFFF keys") {
                                        await plainWrite(name: d.name) { await app.restoreClassic(dump: d, authenticateWithKeys: false) }
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
                                    await plainWrite(name: d.name) { await app.loadMagic(dump: d) }
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
                                    await plainWrite(name: d.name) { await app.restoreUltralight(dump: d) }
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
            if let t = selectedTag, !tags.tags.contains(t) { selectedTag = nil }
            if pickFirstTag, selectedTag == nil { selectedTag = writableTags.first }
        }
    }

    /// Write buttons for a saved identity tag, routed through the same confirm
    /// flow and the same AppModel write calls as typing the values by hand.
    @ViewBuilder private func savedTagActions(_ tag: SavedTag) -> some View {
        switch tag.write {
        case .em410x(let id):
            VStack(alignment: .leading, spacing: 8) {
                commandPreview((try? Commands.em410xClone(id: id)) ?? "")
                Button {
                    pending = .init(summary: "Write \(tag.name), EM410x \(id), onto a blank T5577") {
                        await writeAndVerify(name: tag.name, family: .lf,
                            write: { await app.writeEM410x(id: id) },
                            matches: { $0.isEM410x && $0.uid.uppercased() == id.uppercased() })
                    }
                } label: {
                    Label("Write \(tag.name) and verify", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(PillButtonStyle(destructive: true, large: true))
                .disabled(!canWrite)
            }
        case .hid(let facility, let card):
            VStack(alignment: .leading, spacing: 8) {
                commandPreview((try? Commands.hidClone(facility: facility, card: card)) ?? "")
                Button {
                    pending = .init(summary: "Write \(tag.name), HID Prox \(facility)/\(card), onto a blank T5577") {
                        await writeAndVerify(name: tag.name, family: .lf,
                            write: { await app.writeHID(facility: facility, card: card) },
                            matches: { hidMatch($0, facility: facility, card: card) })
                    }
                } label: {
                    Label("Write \(tag.name) and verify", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(PillButtonStyle(destructive: true, large: true))
                .disabled(!canWrite)
            }
        case .none(let reason):
            Text(reason).font(Theme.sans(.regular, 12)).foregroundStyle(Theme.secondary)
        }
    }

    /// A read-back is an HID match when the family and both numbers agree.
    private func hidMatch(_ read: ScanResult, facility: String, card: String) -> Bool {
        guard read.isHID,
              read.details.first(where: { $0.label.caseInsensitiveCompare("Format") == .orderedSame })?.value.uppercased() == "H10301",
              let expectedFacility = Int(facility),
              let expectedCard = Int(card) else { return false }
        func number(_ labelFragment: String) -> String? {
            read.details.first { $0.label.localizedCaseInsensitiveContains(labelFragment) }?.value
        }
        // The Iceman parser provides separate numeric fields. A substring
        // match could call FC 157 a match for FC 57, so never use one here.
        guard let fc = number("facility"), let cn = number("card") else { return false }
        return Int(fc) == expectedFacility && Int(cn) == expectedCard
    }

    private func commandPreview(_ cmd: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            Text(cmd).font(Theme.mono(.regular, 11.5)).foregroundStyle(Theme.secondary).textSelection(.enabled)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The outcome area under the write forms: a live write-then-verify cycle, a
/// verified or unverified result, or a failure, each with the next step.
struct WriteStatusPanel: View {
    let phase: WriteView.WritePhase
    var onRetry: (() -> Void)?
    var onDone: () -> Void

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()

        case .busy(let step, let attempt, let total):
            HStack(spacing: 14) {
                AntennaField(active: true, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(step)…").font(Theme.sans(.semibold, 13.5)).foregroundStyle(Theme.ink)
                    Text(total > 1 ? "Write and verify \u{00B7} attempt \(attempt) of \(total)" : "Keep the tag on the antenna.")
                        .font(Theme.sans(.regular, 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 6)

        case .verified(let name, let attempt, let total):
            Callout(
                systemName: "checkmark.seal.fill", tint: Theme.good,
                title: "Verified \(name)",
                message: attempt == 1
                    ? "The reader wrote the tag and read it back to confirm it matches."
                    : "Confirmed on attempt \(attempt) of \(total). The reader read the tag back and it matches."
            ) {
                Button("Done") { onDone() }.buttonStyle(PillButtonStyle(filled: false)).padding(.top, 2)
            }
            .transition(.opacity)

        case .wrote(let name):
            Callout(
                systemName: "checkmark.circle.fill", tint: Theme.good,
                title: "Wrote \(name)",
                message: "The write finished. Scan the tag to confirm it reads back as expected."
            ) {
                Button("Done") { onDone() }.buttonStyle(PillButtonStyle(filled: false)).padding(.top, 2)
            }
            .transition(.opacity)

        case .unverified(let name, let attempts):
            Callout(
                systemName: "exclamationmark.triangle.fill", tint: Theme.warn,
                title: "Couldn't confirm \(name)",
                message: "Wrote and read back \(attempts) times, but the tag didn't read as expected. It may not be a writable T5577, or it slipped off the antenna. Reposition it and try again."
            ) {
                if let onRetry {
                    Button("Write and verify again") { onRetry() }
                        .buttonStyle(PillButtonStyle()).padding(.top, 2)
                }
            }
            .transition(.opacity)

        case .failed(let reason):
            Callout(systemName: "exclamationmark.circle.fill", tint: Theme.bad, title: "Write failed", message: reason) {
                if let onRetry {
                    Button("Try again") { onRetry() }
                        .buttonStyle(PillButtonStyle()).padding(.top, 2)
                }
            }
            .transition(.opacity)
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
