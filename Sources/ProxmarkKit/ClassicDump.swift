import Foundation

/// A MIFARE Classic dump laid out the way the card is: sectors of blocks,
/// the last block of each sector holding the keys and access bits.
public struct ClassicDump: Equatable, Sendable {
    public struct Sector: Equatable, Identifiable, Sendable {
        public var id: Int { index }
        public let index: Int
        public let blocks: [[UInt8]]
        public let firstBlock: Int

        public var trailer: [UInt8] { blocks.last ?? [] }
        public var keyA: String { hex(trailer.prefix(6)) }
        public var accessBits: String { trailer.count == 16 ? hex(trailer[6..<10]) : "" }
        public var keyB: String { trailer.count == 16 ? hex(trailer[10..<16]) : "" }
        /// Key A is never readable back from a real card, so a dump of all
        /// zeros there means the dump came from a source that hid it.
        public var keysPresent: Bool { trailer.count == 16 && trailer.prefix(6).contains { $0 != 0 } }
    }

    public let bytes: [UInt8]
    public let sectors: [Sector]

    public static let validSizes: Set<Int> = [320, 1024, 2048, 4096]

    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard Self.validSizes.contains(bytes.count) else { return nil }
        self.bytes = bytes
        var out: [Sector] = []
        var block = 0
        var sector = 0
        let total = bytes.count / 16
        while block < total {
            let perSector = (bytes.count == 4096 && sector >= 32) ? 16 : 4
            let end = min(block + perSector, total)
            let blocks = (block..<end).map { Array(bytes[($0 * 16)..<($0 * 16 + 16)]) }
            out.append(Sector(index: sector, blocks: blocks, firstBlock: block))
            block = end
            sector += 1
        }
        self.sectors = out
    }

    public var uid: String {
        guard bytes.count >= 4 else { return "" }
        return hex(bytes.prefix(4))
    }

    public var kindName: String {
        switch bytes.count {
        case 320: return "MIFARE Mini"
        case 2048: return "MIFARE Classic 2K"
        case 4096: return "MIFARE Classic 4K"
        default: return "MIFARE Classic 1K"
        }
    }
}

public func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02X", $0) }.joined()
}
