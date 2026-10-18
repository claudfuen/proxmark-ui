import ProxmarkKit
import SwiftUI

struct ScanView: View {
    @EnvironmentObject var app: AppModel
    @State private var showLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ConnectionBanner()
                ReaderPanel()

                if let result = app.lastResult {
                    ResultCard(result: result)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !app.log.isEmpty {
                    ConsolePanel(lines: app.log, expanded: $showLog)
                }

                if !app.history.dropFirst().isEmpty {
                    RecentCard()
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.2), value: app.lastResult?.id)
        }
    }
}

/// The hero: the antenna field, what the reader is doing, and the two bands.
struct ReaderPanel: View {
    @EnvironmentObject var app: AppModel
    @State private var startedAt: Date?

    private var canScan: Bool { app.connection.isReady && !app.isBusy }

    var body: some View {
        panel
            .onAppear { if app.isBusy { startedAt = Date() } }
            .onChange(of: app.isBusy) { busy in startedAt = busy ? Date() : nil }
    }

    private var panel: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 22) {
                    AntennaField(active: app.isBusy, found: app.connection.isReady && !app.isBusy && app.lastResult != nil && app.lastError == nil)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(headline)
                                .font(Theme.sans(.semibold, 20))
                                .foregroundStyle(Theme.ink)
                            if app.isBusy, let startedAt {
                                // Full Classic reads can run for minutes; a ticking
                                // clock shows the reader is still working.
                                TimelineView(.periodic(from: startedAt, by: 1)) { ctx in
                                    Text(elapsed(since: startedAt, now: ctx.date))
                                        .font(Theme.mono(.medium, 12))
                                        .foregroundStyle(Theme.secondary)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(Theme.inset, in: Capsule())
                                }
                            }
                        }
                        Text(subhead)
                            .font(Theme.sans(.regular, 13))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if app.isBusy, let last = app.log.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                            Text(last)
                                .font(Theme.mono(.regular, 11))
                                .foregroundStyle(Theme.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 12) {
                    FrequencyTile(
                        band: "13.56 MHz", name: "High frequency",
                        examples: "MIFARE Classic, Ultralight, NTAG", shortcut: "1",
                        primary: true
                    ) { Task { await app.scan(family: .hf) } }

                    FrequencyTile(
                        band: "125 kHz", name: "Low frequency",
                        examples: "EM410x, HID Prox, Indala, T5577", shortcut: "2",
                        primary: false
                    ) { Task { await app.scan(family: .lf) } }
                }
                .disabled(!canScan)

                if let error = app.lastError, !app.isBusy {
                    Callout(systemName: "exclamationmark.circle", tint: Theme.warn, title: error)
                }
            }
        }
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var headline: String {
        if app.isBusy { return app.busyLabel }
        if case .checking = app.connection { return "Connecting…" }
        if !app.connection.isReady { return "Reader offline" }
        if app.lastError != nil { return "Nothing read" }
        if let r = app.lastResult { return r.kind }
        return "Hold a tag to the antenna"
    }

    private var subhead: String {
        if app.isBusy { return "Keep the tag still on the antenna." }
        if case .checking = app.connection { return "Asking the Proxmark3 for its firmware version." }
        if !app.connection.isReady { return "Fix the connection above, then scan." }
        if app.lastError != nil { return "Reposition the tag and try the other band if you're unsure which it is." }
        if app.lastResult != nil { return "Read complete. Scan again, or save a full dump below." }
        return "Most access cards are 13.56 MHz. Older proximity fobs are usually 125 kHz."
    }
}

/// A large, two-line button for one frequency band.
struct FrequencyTile: View {
    let band: String
    let name: String
    let examples: String
    let shortcut: String
    let primary: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 13, weight: .semibold))
                    Text(band)
                        .font(Theme.sans(.semibold, 15))
                    Spacer()
                    Text("⌘\(shortcut)")
                        .font(Theme.mono(.medium, 10.5))
                        .opacity(0.65)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Theme.sans(.medium, 12))
                    Text(examples).font(Theme.sans(.regular, 11.5)).opacity(0.75)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(primary ? Theme.onAccent : Theme.ink)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(primary ? Theme.accent : (hovering ? Theme.accentSoft : Theme.inset))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(primary ? Color.clear : Theme.border)
            )
            .brightness(primary && hovering ? 0.04 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(TilePressStyle())
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 && isEnabled }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct ResultCard: View {
    @EnvironmentObject var app: AppModel
    let result: ScanResult

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        SectionTitle(text: "Tag read")
                        Spacer()
                        Text(result.date, style: .time)
                            .font(Theme.sans(.regular, 11.5))
                            .foregroundStyle(Theme.tertiary)
                    }
                    TagCard(kind: result.kind, spacedUID: result.spacedUID, isHF: result.family == .hf)
                    HStack(spacing: 8) {
                        if result.isClassic || result.isUltralight {
                            Button {
                                Task { await app.readFullDump(for: result) }
                            } label: {
                                Label("Read full dump", systemImage: "arrow.down.doc")
                            }
                            .buttonStyle(PillButtonStyle())
                            .disabled(app.isBusy)
                            .help(result.isClassic
                                ? "Recovers keys with autopwn and saves every sector. Can take minutes."
                                : "Saves every page to the Library.")
                        }
                        CopyButton(value: result.uid, label: "Copy UID")
                    }
                }
                .padding(18)

                if !result.details.isEmpty {
                    Divider().overlay(Theme.hairline)
                    VStack(spacing: 0) {
                        ForEach(Array(result.details.enumerated()), id: \.offset) { i, d in
                            DetailRow(label: d.label, value: d.value)
                            if i < result.details.count - 1 {
                                Divider().overlay(Theme.hairline)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

/// The raw client output, collapsed by default, in a terminal-style well.
struct ConsolePanel: View {
    let lines: [String]
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                    Text("Client output")
                        .font(Theme.sans(.semibold, 12.5))
                    Text("\(lines.count) lines")
                        .font(Theme.sans(.regular, 11.5))
                        .foregroundStyle(Theme.tertiary)
                    Spacer()
                    if expanded {
                        CopyButton(value: lines.joined(separator: "\n"), label: "Copy")
                            .controlSize(.small)
                    }
                }
                .foregroundStyle(Theme.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if expanded {
                ScrollView {
                    Text(lines.joined(separator: "\n"))
                        .font(Theme.mono(.regular, 11))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(maxHeight: 260)
                .background(Theme.console)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding([.horizontal, .bottom], 12)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
        .animation(.easeOut(duration: 0.15), value: expanded)
    }
}

struct RecentCard: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "Earlier this session", trailing: "\(app.history.count - 1)")
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                ForEach(app.history.dropFirst().prefix(8)) { r in
                    Button {
                        app.lastError = nil
                        app.lastResult = r
                    } label: {
                        HStack(spacing: 10) {
                            FamilyBadge(isHF: r.family == .hf)
                            Text(r.kind).font(Theme.sans(.medium, 12.5)).foregroundStyle(Theme.ink)
                            Spacer()
                            Text(r.spacedUID).font(Theme.mono(.regular, 11.5)).foregroundStyle(Theme.secondary)
                            Text(r.date, style: .time)
                                .font(Theme.sans(.regular, 11))
                                .foregroundStyle(Theme.tertiary)
                                .frame(width: 64, alignment: .trailing)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowHoverStyle())
                }
            }
            .padding(.bottom, 8)
        }
    }
}

/// A list row that highlights on hover, for click-to-open rows inside cards.
struct RowHoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowHoverBody(configuration: configuration)
    }

    private struct RowHoverBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(hovering || configuration.isPressed ? Theme.accentSoft : .clear)
                .onHover { hovering = $0 }
        }
    }
}
