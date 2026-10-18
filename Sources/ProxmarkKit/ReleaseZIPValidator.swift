import Foundation

/// Inspects the ZIP central directory before `ditto` sees an update archive.
/// Only an app tree and Apple's `__MACOSX` resource-fork metadata are allowed.
public enum ReleaseZIPValidator {
    public static func validate(_ file: URL) throws {
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        guard bytes.count >= 22 else { throw AppUpdateInstallError.invalidArchive }
        let minimum = max(0, bytes.count - 65_557)
        guard let end = stride(from: bytes.count - 22, through: minimum, by: -1).first(where: {
            read32(bytes, $0) == 0x06054b50 &&
                $0 + 22 + Int(read16(bytes, $0 + 20) ?? 0) == bytes.count
        }),
              read16(bytes, end + 4) == 0,
              read16(bytes, end + 6) == 0,
              let count = read16(bytes, end + 10),
              count > 0, count < 20_000,
              read16(bytes, end + 8) == count,
              let centralSize = read32(bytes, end + 12),
              let centralOffset = read32(bytes, end + 16),
              centralOffset < bytes.count,
              centralSize <= bytes.count - centralOffset,
              centralOffset + centralSize <= end else {
            throw AppUpdateInstallError.invalidArchive
        }
        var cursor = centralOffset
        var names = Set<String>()
        var totalExpanded = 0
        var appFiles = 0
        for _ in 0..<count {
            guard read32(bytes, cursor) == 0x02014b50,
                  let flags = read16(bytes, cursor + 8), flags & 1 == 0,
                  let compression = read16(bytes, cursor + 10), compression == 0 || compression == 8,
                  let compressed = read32(bytes, cursor + 20), compressed < 500_000_000,
                  let expanded = read32(bytes, cursor + 24), expanded < 500_000_000,
                  let nameLength = read16(bytes, cursor + 28), nameLength > 0,
                  let extraLength = read16(bytes, cursor + 30),
                  let commentLength = read16(bytes, cursor + 32),
                  let attributes = read32(bytes, cursor + 38),
                  let localOffset = read32(bytes, cursor + 42) else {
                throw AppUpdateInstallError.invalidArchive
            }
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= centralOffset + centralSize,
                  cursor + 46 + nameLength <= bytes.count,
                  let name = String(data: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8),
                  safeName(name), !names.contains(name) else {
                throw AppUpdateInstallError.invalidArchive
            }
            names.insert(name)
            let mode = Int((attributes >> 16) & 0xF000)
            guard mode == 0 || mode == 0x4000 || mode == 0x8000,
                  read32(bytes, localOffset) == 0x04034b50,
                  read16(bytes, localOffset + 6) == flags,
                  read16(bytes, localOffset + 8) == compression,
                  let localNameLength = read16(bytes, localOffset + 26),
                  let localExtraLength = read16(bytes, localOffset + 28),
                  localOffset + 30 + localNameLength + localExtraLength <= centralOffset,
                  compressed <= centralOffset - (localOffset + 30 + localNameLength + localExtraLength),
                  localNameLength == nameLength,
                  bytes[(localOffset + 30)..<(localOffset + 30 + nameLength)] == bytes[(cursor + 46)..<(cursor + 46 + nameLength)] else {
                throw AppUpdateInstallError.invalidArchive
            }
            totalExpanded += expanded
            guard totalExpanded < 500_000_000 else { throw AppUpdateInstallError.invalidArchive }
            if name.hasPrefix("ProxmarkUI.app/") && !name.hasSuffix("/") { appFiles += 1 }
            cursor = next
        }
        guard cursor == centralOffset + centralSize, appFiles > 0 else {
            throw AppUpdateInstallError.invalidArchive
        }
    }

    private static func safeName(_ name: String) -> Bool {
        guard name == "ProxmarkUI.app/" || name.hasPrefix("ProxmarkUI.app/") ||
              name == "__MACOSX/" || name.hasPrefix("__MACOSX/ProxmarkUI.app/") else { return false }
        guard !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return false }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return parts.enumerated().allSatisfy { index, part in
            if index == parts.count - 1 && part.isEmpty { return true }
            return !part.isEmpty && part != "." && part != ".."
        }
    }

    private static func read16(_ data: Data, _ offset: Int) -> Int? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        return Int(data[offset]) | Int(data[offset + 1]) << 8
    }

    private static func read32(_ data: Data, _ offset: Int) -> Int? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return Int(data[offset]) | Int(data[offset + 1]) << 8 |
            Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
    }
}
