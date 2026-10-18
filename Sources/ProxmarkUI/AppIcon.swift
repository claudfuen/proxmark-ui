import AppKit
import SwiftUI

/// The app icon, drawn in code so the Dock icon, the sidebar mark and the
/// packaged AppIcon.icns all come from one source. Laid out on Apple's
/// 1024 grid: an 824pt squircle with a 100pt margin for the shadow.
///
/// The motif is the in-app AntennaField: a contactless card floating in
/// the reader's field rings.
struct AppIconView: View {
    /// true: the squircle fills the frame (sidebar). false: Apple icon grid.
    var bleed: Bool = true

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let canvas: CGFloat = bleed ? 824 : 1024
            IconArt(withShadow: !bleed)
                .frame(width: 1024, height: 1024)
                .scaleEffect(side / canvas)
                .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct IconArt: View {
    var withShadow: Bool

    private let deep = Color(red: 0.055, green: 0.110, blue: 0.200)
    private let slate = Color(red: 0.165, green: 0.333, blue: 0.545)
    private let glow = Color(red: 0.533, green: 0.780, blue: 1.0)
    private let squircle = RoundedRectangle(cornerRadius: 185, style: .continuous)

    var body: some View {
        ZStack {
            ZStack {
                // Ground: slate lifting to a lit top-left.
                LinearGradient(colors: [slate, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [glow.opacity(0.55), glow.opacity(0.12), .clear], center: UnitPoint(x: 0.5, y: 0.52), startRadius: 0, endRadius: 520)

                // The reader's field: concentric rings, brightest near the card.
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .strokeBorder(glow.opacity(0.55 - Double(i) * 0.1), lineWidth: 9 - CGFloat(i) * 1.4)
                        .frame(width: 300 + CGFloat(i) * 150, height: 300 + CGFloat(i) * 150)
                }
                .offset(y: 10)

                card
                    .rotationEffect(.degrees(-16))
                    .offset(y: 10)

                // Top sheen.
                LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
            }
            .frame(width: 824, height: 824)
            .clipShape(squircle)
            .overlay(squircle.strokeBorder(.white.opacity(0.12), lineWidth: 2))
            .shadow(color: .black.opacity(withShadow ? 0.35 : 0), radius: 24, y: 14)
        }
        .frame(width: 1024, height: 1024)
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(white: 0.88)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.35), radius: 30, y: 22)

            // Contactless mark, in the app accent.
            Image(systemName: "wave.3.right")
                .font(.system(size: 96, weight: .bold))
                .foregroundStyle(slate)
                .offset(x: 330, y: 44)

            // Chip.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [glow, slate], startPoint: .top, endPoint: .bottom))
                .frame(width: 96, height: 74)
                .overlay(
                    VStack(spacing: 14) {
                        Rectangle().frame(height: 3)
                        Rectangle().frame(height: 3)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 10)
                )
                .offset(x: 52, y: 60)

            // The UID being read, the thing this app is for.
            Text("A3 4F 19 C2")
                .font(.system(size: 50, weight: .semibold, design: .monospaced))
                .foregroundStyle(deep.opacity(0.78))
                .offset(x: 50, y: 172)
            Capsule().fill(Color(white: 0.78)).frame(width: 170, height: 12)
                .offset(x: 52, y: 248)

            // Scan beam sweeping the card.
            Rectangle()
                .fill(LinearGradient(colors: [glow.opacity(0), .white, glow.opacity(0)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 560, height: 7)
                .shadow(color: glow, radius: 14)
                .shadow(color: glow.opacity(0.8), radius: 28)
                .offset(x: -45, y: 142)
        }
        .frame(width: 470, height: 296)
    }
}

enum AppIcon {
    /// Renders the icon at `pixels` square, Apple grid (with margin).
    @MainActor
    static func image(pixels: CGFloat = 1024) -> NSImage? {
        let renderer = ImageRenderer(content: AppIconView(bleed: false).frame(width: pixels, height: pixels))
        renderer.scale = 1
        return renderer.nsImage
    }

    /// `ProxmarkUI --render-icon out.png` writes the 1024px master and exits.
    /// scripts/make-app.sh turns it into AppIcon.icns.
    @MainActor
    static func renderIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        guard let image = image(),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write("icon render failed\n".data(using: .utf8)!)
            exit(1)
        }
        do { try png.write(to: out) } catch {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
            exit(1)
        }
        exit(0)
    }
}
