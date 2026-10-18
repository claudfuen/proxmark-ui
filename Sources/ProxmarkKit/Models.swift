import Foundation

public enum TagFamily: String, Codable, Sendable {
    case hf = "HF 13.56 MHz"
    case lf = "LF 125 kHz"
}

public struct Detail: Codable, Equatable, Hashable, Sendable {
    public let label: String
    public let value: String
    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// One tag the reader found.
public struct ScanResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var family: TagFamily
    /// "MIFARE Classic 1K", "EM410x", "HID Prox H10301" ...
    public var kind: String
    /// Hex, no separators.
    public var uid: String
    public var details: [Detail]
    public var raw: String

    public init(id: UUID = UUID(), date: Date = Date(), family: TagFamily, kind: String, uid: String, details: [Detail], raw: String) {
        self.id = id
        self.date = date
        self.family = family
        self.kind = kind
        self.uid = uid
        self.details = details
        self.raw = raw
    }

    public var spacedUID: String {
        stride(from: 0, to: uid.count, by: 2).map { i -> String in
            let s = uid.index(uid.startIndex, offsetBy: i)
            let e = uid.index(s, offsetBy: min(2, uid.count - i))
            return String(uid[s..<e])
        }.joined(separator: " ")
    }

    public var isClassic: Bool { kind.localizedCaseInsensitiveContains("classic") || kind.localizedCaseInsensitiveContains("mini") && family == .hf }
    public var isUltralight: Bool {
        kind.localizedCaseInsensitiveContains("ultralight") || kind.localizedCaseInsensitiveContains("ntag")
    }
    public var isEM410x: Bool { family == .lf && kind.localizedCaseInsensitiveContains("EM410") }
    public var isHID: Bool { family == .lf && kind.localizedCaseInsensitiveContains("HID") }

    /// Size in bytes a full Classic dump of this tag would be, or nil.
    public var classicDumpSize: Int? {
        let k = kind.lowercased()
        guard k.contains("classic") || k.contains("mini") else { return nil }
        if k.contains("mini") { return 320 }
        if k.contains("4k") { return 4096 }
        if k.contains("2k") { return 2048 }
        return 1024
    }
}

public enum ConnectionState: Equatable, Sendable {
    case noClient
    case noDevice
    case checking
    case ready(DeviceInfo)
    /// The device firmware and the client speak different protocol versions.
    case firmwareMismatch(device: Int, client: Int)
    case unreachable(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public struct DeviceInfo: Equatable, Sendable {
    public var port: String
    public var model: String
    public var firmware: String
    public var raw: String

    public init(port: String, model: String, firmware: String, raw: String) {
        self.port = port
        self.model = model
        self.firmware = firmware
        self.raw = raw
    }
}

/// A dump saved in the library.
public struct DumpEntry: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String { fileName }
    public var fileName: String
    public var name: String
    public var kind: String
    public var uid: String
    public var date: Date
    public var byteCount: Int
    /// The companion key file produced by Classic autopwn, when available.
    public var keyFileName: String?

    public init(fileName: String, name: String, kind: String, uid: String, date: Date, byteCount: Int, keyFileName: String? = nil) {
        self.fileName = fileName
        self.name = name
        self.kind = kind
        self.uid = uid
        self.date = date
        self.byteCount = byteCount
        self.keyFileName = keyFileName
    }

    /// Sidecars are user-writable JSON. Keep every resolved file inside the
    /// library and associate a key file only with its own dump.
    public static func isSafeFileName(_ name: String) -> Bool {
        guard let match = name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*\.bin$"#, options: .regularExpression) else { return false }
        return match == name.startIndex..<name.endIndex
    }

    public var hasSafeFileName: Bool { Self.isSafeFileName(fileName) }

    public var url: URL { Pm3Locator.dumpsDirectory.appendingPathComponent(fileName) }
    public var sidecarURL: URL { url.deletingPathExtension().appendingPathExtension("json") }
    public var keyURL: URL? {
        guard hasSafeFileName, let keyFileName,
              keyFileName == url.deletingPathExtension().lastPathComponent + "-keys.bin",
              Self.isSafeFileName(keyFileName) else { return nil }
        return Pm3Locator.dumpsDirectory.appendingPathComponent(keyFileName)
    }
}
