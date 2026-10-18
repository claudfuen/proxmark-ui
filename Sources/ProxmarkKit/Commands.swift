import Foundation

public enum CommandError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let m) = self { return m }
        return nil
    }
}

/// Builds client command lines. Every value that reaches a command line is
/// validated here, because the client treats `;` as a command separator and
/// a stray one would run a second command.
public enum Commands {
    public static let hwVersion = "hw version"
    public static let hfSearch = "hf search"
    public static let lfSearch = "lf search"
    public static let t5577Detect = "lf t55xx detect"

    public static func hex(_ value: String, length: ClosedRange<Int>) throws -> String {
        let cleaned = value.filter { !$0.isWhitespace }.uppercased()
        guard length.contains(cleaned.count), cleaned.allSatisfy({ $0.isHexDigit }) else {
            throw CommandError.invalid("Expected \(length.lowerBound == length.upperBound ? "\(length.lowerBound)" : "\(length.lowerBound) to \(length.upperBound)") hex characters.")
        }
        return cleaned
    }

    public static func number(_ value: String, max: Int) throws -> Int {
        guard let n = Int(value.trimmingCharacters(in: .whitespaces)), n >= 0, n <= max else {
            throw CommandError.invalid("Expected a number from 0 to \(max).")
        }
        return n
    }

    /// Paths go through the client's parser, so only a conservative set is allowed.
    public static func path(_ url: URL) throws -> String {
        let p = url.path
        guard p.range(of: #"^[A-Za-z0-9_./~+@-]+$"#, options: .regularExpression) == p.startIndex..<p.endIndex else {
            throw CommandError.invalid("The path \(p) contains characters the Proxmark client can't take (spaces, quotes). Move the file to a plain path.")
        }
        return p
    }

    // MARK: Read

    public static func classicRead(sizeBytes: Int?) -> String {
        let sizeFlag: String
        switch sizeBytes {
        case 320: sizeFlag = "--mini"
        case 2048: sizeFlag = "--2k"
        case 4096: sizeFlag = "--4k"
        default: sizeFlag = "--1k"
        }
        return "hf mf autopwn \(sizeFlag) -f mfc_default_keys"
    }

    public static let ultralightRead = "hf mfu dump"

    // MARK: Write

    public static func em410xClone(id: String) throws -> String {
        "lf em 410x clone --id \(try hex(id, length: 10...10))"
    }

    public static func hidClone(format: String = "H10301", facility: String, card: String) throws -> String {
        guard format.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) == format.startIndex..<format.endIndex else {
            throw CommandError.invalid("Bad HID format name.")
        }
        // H10301 is a 26-bit format: 8 bits for facility and 16 for card.
        return "lf hid clone -w \(format) --fc \(try number(facility, max: 255)) --cn \(try number(card, max: 65535))"
    }

    /// Writes a Classic dump to a card whose sectors accept the dump's keys.
    public static func classicRestore(dump: URL, keys: URL, sizeBytes: Int, authenticateWithKeys: Bool = false) throws -> String {
        let flag: String
        switch sizeBytes {
        case 320: flag = "--mini"
        case 1024: flag = "--1k"
        case 2048: flag = "--2k"
        case 4096: flag = "--4k"
        default: throw CommandError.invalid("That file is not a recognized MIFARE Classic dump size.")
        }
        var cmd = "hf mf restore \(flag) -f \(try path(dump)) -k \(try path(keys))"
        if authenticateWithKeys {
            cmd += " --ka"
        }
        return cmd
    }

    /// Gen1a ("magic") cards take a whole dump, UID and block 0 included, over the backdoor.
    public static func magicLoad(dump: URL) throws -> String {
        "hf mf cload -f \(try path(dump))"
    }

    public static func ultralightRestore(dump: URL) throws -> String {
        "hf mfu restore -f \(try path(dump))"
    }
}
