import AppKit
import SwiftUI

// A native macOS tool: system font, system surfaces, one slate-blue accent.
// Every colour resolves per appearance, so the window follows Light/Dark
// Mode instead of painting a light canvas under dark system chrome.

extension Color {
    /// A colour that resolves at draw time against the view's appearance.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

enum Theme {
    // Deep slate blue in light mode, lifted so it still reads on dark.
    static let accent = Color(light: rgb(0.145, 0.271, 0.420), dark: rgb(0.478, 0.639, 0.863))
    static let onAccent = Color(light: .white, dark: rgb(0.047, 0.086, 0.141))
    static let accentSoft = Color(light: rgb(0.145, 0.271, 0.420, 0.10), dark: rgb(0.478, 0.639, 0.863, 0.16))

    static let good = Color(light: rgb(0.161, 0.494, 0.306), dark: rgb(0.380, 0.792, 0.541))
    static let warn = Color(light: rgb(0.627, 0.424, 0.035), dark: rgb(0.925, 0.706, 0.322))
    static let bad = Color(light: rgb(0.698, 0.200, 0.200), dark: rgb(0.973, 0.443, 0.443))

    static let canvas = Color(light: rgb(0.961, 0.961, 0.969), dark: rgb(0.106, 0.110, 0.122))
    static let surface = Color(light: .white, dark: rgb(0.149, 0.153, 0.169))
    static let inset = Color(light: rgb(0.949, 0.949, 0.957), dark: rgb(0.118, 0.122, 0.133))
    static let console = Color(light: rgb(0.106, 0.114, 0.133), dark: rgb(0.075, 0.078, 0.086))
    static let border = Color(light: rgb(0, 0, 0, 0.09), dark: rgb(1, 1, 1, 0.08))
    static let hairline = Color(light: rgb(0, 0, 0, 0.06), dark: rgb(1, 1, 1, 0.06))

    static let ink = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)

    /// UIDs, keys, hex: true monospace so columns of hex line up.
    static func mono(_ weight: Font.Weight, _ size: CGFloat) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func sans(_ weight: Font.Weight, _ size: CGFloat) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
}

/// The scanned tag drawn as a physical card: the thing you just held to the
/// antenna, rendered back so the UID reads as an object, not a log line. HF is
/// slate, LF is a warmer bronze, so the band is legible before you read a word.
struct TagCard: View {
    let kind: String
    let spacedUID: String
    let isHF: Bool
    var systemName: String = "wave.3.right"

    private var top: Color {
        isHF ? Color(red: 0.192, green: 0.345, blue: 0.525)
             : Color(red: 0.502, green: 0.361, blue: 0.188)
    }
    private var bottom: Color {
        isHF ? Color(red: 0.102, green: 0.180, blue: 0.310)
             : Color(red: 0.310, green: 0.216, blue: 0.098)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                HStack(spacing: 7) {
                    Text(isHF ? "HF" : "LF")
                        .font(Theme.mono(.bold, 11))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.white.opacity(0.18), in: Capsule())
                    Text(isHF ? "13.56 MHz" : "125 kHz")
                        .font(Theme.sans(.medium, 12))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 18)
            Text("UID")
                .font(Theme.sans(.semibold, 10))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.6))
            Text(spacedUID)
                .font(Theme.mono(.semibold, 25))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.top, 2)
            Text(kind)
                .font(Theme.sans(.medium, 13))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 6)
        }
        .padding(20)
        .frame(height: 188)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                GeometryReader { geo in
                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1.5)
                            .frame(width: 120 + CGFloat(i) * 90)
                            .position(x: geo.size.width - 40, y: 20)
                    }
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: bottom.opacity(0.35), radius: 16, y: 8)
    }
}

/// Small section title inside a card. Sentence case, quiet.
struct SectionTitle: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(Theme.sans(.semibold, 12))
                .foregroundStyle(Theme.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(Theme.sans(.regular, 11.5))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }
}

/// The app's card surface: one hairline border, no heavy shadow.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        // Stack the children first: without this, a Card given several views
        // applies its background to each one and draws a box per row.
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

/// A `label  value` row. Values are selectable so a UID can be copied.
struct DetailRow: View {
    let label: String
    let value: String
    var monospace: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(Theme.sans(.regular, 12.5))
                .foregroundStyle(Theme.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(monospace ? Theme.mono(.regular, 12) : Theme.sans(.regular, 12.5))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

struct PillButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var filled: Bool = true
    var destructive: Bool = false
    var large: Bool = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let color = destructive ? Theme.bad : tint
        configuration.label
            .font(Theme.sans(.semibold, large ? 13.5 : 12.5))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, large ? 16 : 12)
            .padding(.vertical, large ? 9 : 6)
            .foregroundStyle(filled ? (destructive ? Color.white : Theme.onAccent) : color)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(filled ? color : color.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(filled ? .clear : color.opacity(0.28), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small colour-coded dot + label, for connection status.
struct StatusDot: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(Theme.sans(.medium, 12))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// "HF" / "LF" capsule.
struct FamilyBadge: View {
    let isHF: Bool
    var body: some View {
        Text(isHF ? "HF" : "LF")
            .font(Theme.mono(.semibold, 10))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Theme.accent)
            .background(Theme.accentSoft, in: Capsule())
    }
}

/// A rounded icon tile, used in list rows and empty states.
struct IconTile: View {
    let systemName: String
    var tint: Color = Theme.accent
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// Click to copy, with a brief checkmark.
struct CopyButton: View {
    let value: String
    var label: String = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(PillButtonStyle(filled: false))
    }
}

/// A colour-tinted inline message with an icon, for errors and warnings.
struct Callout<Actions: View>: View {
    let systemName: String
    let tint: Color
    let title: String
    var message: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.sans(.semibold, 13)).foregroundStyle(Theme.ink)
                if let message {
                    Text(message)
                        .font(Theme.sans(.regular, 12.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        )
    }
}

extension Callout where Actions == EmptyView {
    init(systemName: String, tint: Color, title: String, message: String? = nil) {
        self.init(systemName: systemName, tint: tint, title: title, message: message) { EmptyView() }
    }
}

/// The signature element: an antenna with concentric field rings. Idle it
/// sits still; while `active` the rings radiate outward; on `found` it
/// settles to a solid accent disc.
struct AntennaField: View {
    var active: Bool
    var found: Bool = false
    var size: CGFloat = 132

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        ZStack {
            // Static field rings.
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .strokeBorder(Theme.accent.opacity(0.10 + Double(2 - i) * 0.05), lineWidth: 1)
                    .frame(width: size * (0.52 + CGFloat(i) * 0.24), height: size * (0.52 + CGFloat(i) * 0.24))
            }
            // Radiating rings while scanning.
            if active && !reduceMotion {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1.5)
                        .frame(width: size * 0.42, height: size * 0.42)
                        .scaleEffect(phase ? 2.4 : 1)
                        .opacity(phase ? 0 : 1)
                        .animation(
                            .easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(Double(i) * 0.6),
                            value: phase
                        )
                }
            }
            Circle()
                .fill(found ? Theme.accent : Theme.accentSoft)
                .frame(width: size * 0.36, height: size * 0.36)
            Image(systemName: found ? "checkmark" : "wave.3.right")
                .font(.system(size: size * 0.13, weight: .bold))
                .foregroundStyle(found ? Theme.onAccent : Theme.accent)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: size, height: size)
        .onAppear { phase = active }
        .onChange(of: active) { phase = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: found)
        .accessibilityHidden(true)
    }
}
