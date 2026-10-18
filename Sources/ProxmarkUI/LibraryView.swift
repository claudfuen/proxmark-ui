import ProxmarkKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var app: AppModel
    var goToScan: () -> Void = {}
    @State private var selected: DumpEntry?
    @State private var query = ""
    @State private var pendingDelete: DumpEntry?

    private var filtered: [DumpEntry] {
        guard !query.isEmpty else { return app.dumps }
        return app.dumps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.uid.localizedCaseInsensitiveContains(query.replacingOccurrences(of: " ", with: ""))
                || $0.kind.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if app.dumps.isEmpty {
                EmptyLibrary(goToScan: goToScan)
            } else {
                HSplitView {
                    list
                        .frame(minWidth: 240, idealWidth: 270, maxWidth: 300)
                    Group {
                        if let entry = selected {
                            DumpDetailView(entry: entry)
                        } else {
                            Text(filtered.isEmpty ? "No dumps match \u{201C}\(query)\u{201D}" : "Select a dump")
                                .font(Theme.sans(.regular, 13))
                                .foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            if !AppModel.isDemo { app.loadDumps() }
            if selected == nil { selected = app.dumps.first }
        }
        .onChange(of: app.dumps) { dumps in
            if selected == nil || !dumps.contains(selected!) { selected = dumps.first }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "dump")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { entry in
            Button("Delete dump", role: .destructive) {
                pendingDelete = nil
                app.deleteDump(entry)
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("The dump, its metadata, and any saved key file will be removed from the Library. This can't be undone.")
        }
    }

    private var list: some View {
        List(filtered, selection: $selected) { entry in
            DumpRow(entry: entry)
                .tag(entry)
                .contextMenu {
                    CopyMenuItem(title: "Copy UID", value: entry.uid)
                    Button("Reveal in Finder") { app.reveal(entry) }
                    Divider()
                    Button("Delete", role: .destructive) { pendingDelete = entry }
                }
        }
        .listStyle(.inset)
        .searchable(text: $query, placement: .toolbar, prompt: "Name, UID or type")
    }
}

struct CopyMenuItem: View {
    let title: String
    let value: String
    var body: some View {
        Button(title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }
}

struct DumpRow: View {
    let entry: DumpEntry

    var body: some View {
        HStack(spacing: 10) {
            IconTile(systemName: icon(for: entry.kind), size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(Theme.sans(.medium, 13))
                    .lineLimit(1)
                Text(spaced(entry.uid))
                    .font(Theme.mono(.regular, 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.date, format: .dateTime.month(.abbreviated).day())
                    .font(Theme.sans(.regular, 11))
                    .foregroundStyle(.secondary)
                Text(byteSize(entry.byteCount))
                    .font(Theme.sans(.regular, 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

func icon(for kind: String) -> String {
    let k = kind.lowercased()
    if k.contains("ultralight") || k.contains("ntag") { return "tag" }
    if k.contains("classic") || k.contains("mini") { return "creditcard" }
    return "wave.3.right"
}

func spaced(_ hex: String) -> String {
    stride(from: 0, to: hex.count, by: 2).map { i -> String in
        let s = hex.index(hex.startIndex, offsetBy: i)
        let e = hex.index(s, offsetBy: min(2, hex.count - i))
        return String(hex[s..<e])
    }.joined(separator: " ")
}

func byteSize(_ n: Int) -> String {
    n >= 1024 && n % 1024 == 0 ? "\(n / 1024) KB" : "\(n) B"
}

struct EmptyLibrary: View {
    var goToScan: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            IconTile(systemName: "tray", size: 52)
            Text("No dumps yet")
                .font(Theme.sans(.semibold, 17))
                .foregroundStyle(Theme.ink)
            Text("Scan a MIFARE Classic or Ultralight/NTAG tag, then choose Read full dump. Every sector and key lands here, ready to inspect or write to a blank.")
                .font(Theme.sans(.regular, 13))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                goToScan()
            } label: {
                Label("Go to Scan", systemImage: "wave.3.right")
            }
            .buttonStyle(PillButtonStyle(large: true))
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DumpDetailView: View {
    @EnvironmentObject var app: AppModel
    let entry: DumpEntry
    @State private var dump: ClassicDump?
    @State private var rawBytes: [UInt8] = []
    @State private var showHex = ProcessInfo.processInfo.environment["PMUI_HEX"] != nil
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 14) {
                            IconTile(systemName: icon(for: entry.kind), size: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name).font(Theme.sans(.semibold, 17)).foregroundStyle(Theme.ink)
                                Text(spaced(entry.uid))
                                    .font(Theme.mono(.medium, 14))
                                    .foregroundStyle(Theme.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                        }
                        .padding(18)

                        Divider().overlay(Theme.hairline)
                        VStack(spacing: 0) {
                            DetailRow(label: "Type", value: entry.kind, monospace: false)
                            Divider().overlay(Theme.hairline)
                            DetailRow(label: "Size", value: "\(entry.byteCount) bytes", monospace: false)
                            Divider().overlay(Theme.hairline)
                            DetailRow(label: "Saved", value: entry.date.formatted(date: .abbreviated, time: .shortened), monospace: false)
                            Divider().overlay(Theme.hairline)
                            DetailRow(label: "File", value: entry.fileName)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 4)

                        Divider().overlay(Theme.hairline)
                        HStack(spacing: 8) {
                            CopyButton(value: entry.uid, label: "Copy UID")
                            Button {
                                app.reveal(entry)
                            } label: {
                                Label("Reveal", systemImage: "folder")
                            }
                            .buttonStyle(PillButtonStyle(filled: false))
                            Spacer()
                            Button(role: .destructive) {
                                confirmDelete = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .buttonStyle(PillButtonStyle(filled: false, destructive: true))
                        }
                        .padding(14)
                    }
                }

                if let dump {
                    SectorTableCard(dump: dump)
                }

                if !rawBytes.isEmpty {
                    HexDumpCard(bytes: rawBytes, trailerRanges: trailerRanges, expanded: $showHex)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: entry.id) {
            let data = DemoData.dumpBytes[entry.fileName] ?? (try? Data(contentsOf: entry.url))
            rawBytes = data.map { [UInt8]($0) } ?? []
            dump = data.flatMap(ClassicDump.init(data:))
        }
        .confirmationDialog("Delete \u{201C}\(entry.name)\u{201D}?", isPresented: $confirmDelete) {
            Button("Delete dump", role: .destructive) { app.deleteDump(entry) }
        } message: {
            Text("The .bin file and its metadata are removed from the library. This can't be undone.")
        }
    }

    /// The last block of each Classic sector holds the keys + access bits.
    private var trailerRanges: [Range<Int>] {
        guard let dump else { return [] }
        return dump.sectors.compactMap { s in
            guard let last = s.blocks.indices.last else { return nil }
            let block = s.firstBlock + last
            return (block * 16)..<(block * 16 + 16)
        }
    }
}

/// A collapsible raw-bytes panel. Collapsed by default so the sector table
/// stays the headline; expanded for anyone who wants to read the memory.
struct HexDumpCard: View {
    let bytes: [UInt8]
    var trailerRanges: [Range<Int>]
    @Binding var expanded: Bool

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text("Raw bytes")
                            .font(Theme.sans(.semibold, 12.5))
                            .foregroundStyle(Theme.ink)
                        Text("\(bytes.count) bytes")
                            .font(Theme.sans(.regular, 11.5))
                            .foregroundStyle(Theme.tertiary)
                        Spacer()
                        if expanded {
                            HexLegend()
                        }
                    }
                    .foregroundStyle(Theme.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(16)

                if expanded {
                    HexDumpView(bytes: bytes, trailerRanges: trailerRanges)
                        .frame(height: min(CGFloat(bytes.count / 16 + 2) * 22, 420))
                        .padding([.horizontal, .bottom], 14)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: expanded)
    }
}

struct SectorTableCard: View {
    let dump: ClassicDump

    private var recovered: Int { dump.sectors.filter(\.keysPresent).count }

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "Sector keys", trailing: "\(recovered) of \(dump.sectors.count) with keys")
                        // Honest without cluttering the card: key bytes in a dump
                        // can be placeholders, so they don't prove recovery.
                        .help("A dump can contain placeholder keys. Key bytes here don't prove that every sector was recovered.")
                    KeyCoverageBar(sectors: dump.sectors)
                }
                .padding(18)

                HStack(spacing: 0) {
                    Text("Sector").frame(width: 50, alignment: .leading)
                    Text("Key A").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Key B").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Access").frame(width: 78, alignment: .trailing)
                }
                .font(Theme.sans(.medium, 11))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(Theme.inset)

                ForEach(dump.sectors) { sector in
                    HStack(spacing: 0) {
                        Text(String(format: "%02d", sector.index))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 50, alignment: .leading)
                        keyCell(sector.keyA, present: sector.keysPresent)
                        keyCell(sector.keyB, present: sector.keysPresent)
                        Text(sector.accessBits.isEmpty ? "—" : sector.accessBits)
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                            .frame(width: 78, alignment: .trailing)
                    }
                    .font(Theme.mono(.regular, 11))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(sector.index % 2 == 1 ? Theme.inset.opacity(0.5) : .clear)
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func keyCell(_ key: String, present: Bool) -> some View {
        Text(present ? key : "not in dump")
            .foregroundStyle(present ? Theme.ink : Theme.tertiary)
            .textSelection(.enabled)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One segment per sector with nonzero key bytes in its trailer.
struct KeyCoverageBar: View {
    let sectors: [ClassicDump.Sector]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(sectors) { s in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(s.keysPresent ? Theme.good : Theme.hairline)
                    .frame(height: 8)
            }
        }
    }
}
