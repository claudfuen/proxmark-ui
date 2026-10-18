import Foundation
import ProxmarkKit

/// A tag the user chose to keep from a scan, with a name they gave it.
///
/// This is the lightweight counterpart to `DumpEntry`: a `DumpEntry` is a full
/// binary dump (Classic sectors, Ultralight pages), while a `SavedTag` records
/// an identity read (EM410x, HID Prox, and the like) that has no dump file. It
/// stores enough to write the tag back from the Library.
struct SavedTag: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    var name: String
    let kind: String
    let uid: String
    let family: TagFamily
    let details: [Detail]
    let write: WriteSpec
    let savedAt: Date

    /// How this tag is written back, reconstructed at scan time so the Library
    /// never has to re-parse client output.
    enum WriteSpec: Codable, Equatable, Hashable {
        case em410x(id: String)
        case hid(facility: String, card: String)
        /// Readable identity with no write path this app supports yet.
        case none(reason: String)

        var isWritable: Bool {
            if case .none = self { return false }
            return true
        }
    }

    var spacedUID: String {
        stride(from: 0, to: uid.count, by: 2).map { i -> String in
            let s = uid.index(uid.startIndex, offsetBy: i)
            let e = uid.index(s, offsetBy: min(2, uid.count - i))
            return String(uid[s..<e])
        }.joined(separator: " ")
    }

    /// Build a saved tag from a scan. Returns nil for tags that belong in the
    /// dump library instead (Classic, Ultralight/NTAG), which are saved by
    /// reading a full dump rather than kept as an identity.
    init?(from scan: ScanResult, name: String) {
        guard !scan.isClassic, !scan.isUltralight else { return nil }
        self.id = UUID()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = scan.kind
        self.uid = scan.uid
        self.family = scan.family
        self.details = scan.details
        self.savedAt = Date()
        self.write = Self.writeSpec(for: scan)
    }

    private static func writeSpec(for scan: ScanResult) -> WriteSpec {
        if scan.isEM410x, scan.uid.range(of: #"^[0-9A-Fa-f]{10}$"#, options: .regularExpression) != nil {
            return .em410x(id: scan.uid.uppercased())
        }
        if scan.isHID,
           let fc = scan.details.first(where: { $0.label.localizedCaseInsensitiveContains("facility") })?.value,
           let cn = scan.details.first(where: { $0.label.localizedCaseInsensitiveContains("card") })?.value,
           fc.range(of: #"^\d+$"#, options: .regularExpression) != nil,
           cn.range(of: #"^\d+$"#, options: .regularExpression) != nil {
            return .hid(facility: fc, card: cn)
        }
        return .none(reason: "This app can't write a \(scan.kind) tag yet. Its details are kept for reference.")
    }
}
