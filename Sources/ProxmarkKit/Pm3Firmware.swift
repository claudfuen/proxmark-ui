import CryptoKit
import Foundation

/// The app only offers a full-image update. Bootloader writes require a
/// separate recovery procedure and are never enabled here.
public enum Pm3Firmware {
    public enum Target: String, CaseIterable, Sendable {
        /// Easy uses upstream's generic platform with Easy LED ordering. This
        /// package fits readers with 256 KB or 512 KB of flash.
        case easy = "PM3EASY"
        case rdv4 = "PM3RDV4"

        public var displayName: String {
            switch self {
            case .easy: return "Proxmark3 Easy"
            case .rdv4: return "Proxmark3 RDV4"
            }
        }

        fileprivate var buildPlatform: String {
            switch self {
            case .easy: return "PM3GENERIC"
            case .rdv4: return "PM3RDV4"
            }
        }

        fileprivate var ledOrder: String? { self == .easy ? "PM3EASY" : nil }
        fileprivate var maxFlashKB: Int { self == .easy ? 256 : 512 }
    }

    public static func bundledFullImage(for target: Target) -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        return fullImage(for: target, inResources: resources)
    }

    public static func bundledSourceRevision(for target: Target) -> String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        return metadata(for: target, inResources: resources)?.sourceRevision
    }

    /// Build the flasher's argv without passing any value through a shell or
    /// the client's semicolon-separated command parser.
    public static func flashArguments(port: String, fullImage: URL) throws -> [String] {
        guard port.range(of: #"^/dev/cu\.(usbmodem|usbserial)[A-Za-z0-9._-]+$"#, options: .regularExpression) == port.startIndex..<port.endIndex else {
            throw CommandError.invalid("Choose a connected USB Proxmark3 reader before updating firmware.")
        }
        guard isFullImage(fullImage), Target(rawValue: fullImage.deletingLastPathComponent().lastPathComponent) != nil else {
            throw CommandError.invalid("A readable fullimage.elf for a supported reader is required. Rebuild the app with matching firmware.")
        }
        return ["--incognito", "-f", "-p", port, "--flash", "--image", fullImage.path]
    }

    /// The upstream CLI exits zero even when its flasher reports failure.
    public static func outputIndicatesSuccess(_ output: String) -> Bool {
        let clean = Ansi.strip(output)
        return clean.contains("All done")
            && !clean.localizedCaseInsensitiveContains("flashing procedure failed")
            && !clean.localizedCaseInsensitiveContains("aborted on error")
            && !clean.localizedCaseInsensitiveContains("aborted by user")
    }

    /// Kept internal so tests can verify target and metadata pairing without
    /// constructing a signed application bundle.
    static func fullImage(for target: Target, inResources resources: URL) -> URL? {
        guard let metadata = metadata(for: target, inResources: resources) else { return nil }
        let url = resources.appendingPathComponent("pm3/share/proxmark3/firmware/\(target.rawValue)/fullimage.elf")
        guard isFullImage(url), let data = try? Data(contentsOf: url), digest(data) == metadata.sha256 else { return nil }
        return url
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isFullImage(_ url: URL) -> Bool {
        guard url.isFileURL, url.lastPathComponent == "fullimage.elf",
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x7F, 0x45, 0x4C, 0x46])
    }

    private static func metadata(for target: Target, inResources resources: URL) -> Metadata? {
        let url = resources.appendingPathComponent("pm3/share/proxmark3/firmware/\(target.rawValue)/build.json")
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              metadata.target == target.rawValue,
              metadata.buildPlatform == target.buildPlatform,
              metadata.ledOrder == target.ledOrder,
              metadata.maxFlashKB == target.maxFlashKB,
              metadata.sourceRevision.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) == metadata.sourceRevision.startIndex..<metadata.sourceRevision.endIndex,
              metadata.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) == metadata.sha256.startIndex..<metadata.sha256.endIndex else { return nil }
        return metadata
    }

    private struct Metadata: Decodable {
        let target: String
        let sourceRevision: String
        let buildPlatform: String
        let ledOrder: String?
        let maxFlashKB: Int
        let sha256: String
    }
}
