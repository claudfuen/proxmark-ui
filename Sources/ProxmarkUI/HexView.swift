import SwiftUI

/// A classic offset | hex | ASCII dump view, the way every byte-level tool
/// shows a card's memory. 16 bytes a row, sector trailers tinted so keys and
/// access bits stand out from data blocks.
struct HexDumpView: View {
    let bytes: [UInt8]
    /// Byte ranges to tint as "key material" (sector trailers).
    var trailerRanges: [Range<Int>] = []
    var bytesPerRow: Int = 16

    private var rows: [Int] { Array(stride(from: 0, to: bytes.count, by: bytesPerRow)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.self) { offset in
                        HexRow(
                            offset: offset,
                            bytes: Array(bytes[offset..<min(offset + bytesPerRow, bytes.count)]),
                            bytesPerRow: bytesPerRow,
                            isTrailer: trailerRanges.contains { $0.contains(offset) }
                        )
                        .background(rowTint(offset))
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Theme.console)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func rowTint(_ offset: Int) -> Color {
        let block = offset / bytesPerRow
        return block % 2 == 1 ? Color.white.opacity(0.025) : .clear
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("OFFSET").frame(width: 70, alignment: .leading)
            Text("BYTES").frame(maxWidth: .infinity, alignment: .leading)
            Text("ASCII").frame(width: CGFloat(bytesPerRow) * 9 + 16, alignment: .leading)
        }
        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
        .tracking(0.6)
        .foregroundStyle(.white.opacity(0.35))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        }
    }
}

private struct HexRow: View {
    let offset: Int
    let bytes: [UInt8]
    let bytesPerRow: Int
    let isTrailer: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text(String(format: "%04X", offset))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 70, alignment: .leading)

            HStack(spacing: 0) {
                ForEach(Array(bytes.enumerated()), id: \.offset) { i, b in
                    Text(String(format: "%02X", b))
                        .foregroundStyle(byteColor(b))
                        .frame(width: 22, alignment: .leading)
                        .padding(.trailing, i % 8 == 7 ? 8 : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(ascii)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: CGFloat(bytesPerRow) * 9 + 16, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 2.5)
        .overlay(alignment: .leading) {
            if isTrailer {
                Rectangle().fill(Theme.warn).frame(width: 2.5)
            }
        }
    }

    private func byteColor(_ b: UInt8) -> Color {
        if b == 0 { return .white.opacity(0.28) }        // padding reads quiet
        if isTrailer { return Theme.warn.opacity(0.95) } // keys + access bits
        return .white.opacity(0.9)
    }

    private var ascii: String {
        String(bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "·" })
    }
}

/// A small inline legend explaining the hex tint.
struct HexLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            legendItem(Theme.warn, "Sector trailer (keys + access)")
            legendItem(.secondary.opacity(0.5), "Zero / padding")
        }
        .font(Theme.sans(.regular, 10.5))
        .foregroundStyle(Theme.secondary)
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label)
        }
    }
}
