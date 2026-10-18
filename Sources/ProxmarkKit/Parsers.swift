import Foundation

/// Turns the client's human-readable output into values. The client has no
/// machine-readable mode, so these are deliberately tolerant: they look for
/// the stable `label: value` fragments, not exact line layout.
public enum Parsers {
    // MARK: Connection

    public static func parseCapabilityMismatch(_ text: String) -> (device: Int, client: Int)? {
        guard let m = firstMatch(#"\(v(\d+) != v(\d+)\)"#, in: text), m.count == 3,
              let d = Int(m[1]), let c = Int(m[2]) else { return nil }
        return (d, c)
    }

    public static func parseDevice(port: String, from text: String) -> DeviceInfo? {
        // The client prints a Proxmark3 header even when no device answers.
        // A generic firmware label describes the image, not the board. Only
        // RDV4's explicit validated Device line identifies hardware here.
        guard firstMatch(#"\[\s*Model\s*\]"#, in: text) != nil,
              firstMatch(#"(?m)^\s*Firmware\.+\s*\S+"#, in: text) != nil,
              !text.localizedCaseInsensitiveContains("cannot communicate") else { return nil }
        let model = firstMatch(#"(?m)^\s*Device\.+\s*(RDV4(?:\.\d+)?)\s*$"#, in: text, caseInsensitive: true)?[1] ?? "Proxmark3"
        let firmware = firstMatch(#"(Iceman/[^\s]+)"#, in: text)?[1] ?? "unknown"
        return DeviceInfo(port: port, model: model, firmware: firmware, raw: text)
    }

    // MARK: HF

    public static func parseHF(_ text: String) -> ScanResult? {
        guard text.contains("UID"), !text.localizedCaseInsensitiveContains("no known/supported 13.56 MHz tags found") else { return nil }
        guard let uidMatch = firstMatch(#"UID:\s*((?:[0-9A-Fa-f]{2}\s*)+)"#, in: text) else { return nil }
        let uid = uidMatch[1].filter { $0.isHexDigit }.uppercased()
        guard !uid.isEmpty else { return nil }

        var details: [Detail] = []
        if let m = firstMatch(#"ATQA:\s*([0-9A-Fa-f]{2}\s+[0-9A-Fa-f]{2})"#, in: text) {
            details.append(Detail("ATQA", m[1].uppercased()))
        }
        if let m = firstMatch(#"SAK:\s*([0-9A-Fa-f]{2})"#, in: text) {
            details.append(Detail("SAK", m[1].uppercased()))
        }
        if let m = firstMatch(#"Prng detection[.\s]*:\s*(\w+)"#, in: text, caseInsensitive: true) {
            details.append(Detail("PRNG", m[1].capitalized))
        }
        if let m = firstMatch(#"Magic capabilities[.\s:]*([^\n]+)"#, in: text, caseInsensitive: true) {
            details.append(Detail("Magic", m[1].trimmingCharacters(in: .whitespaces)))
        }

        var kind = "ISO 14443-A tag"
        if let types = possibleTypes(in: text), let first = types.first { kind = first }
        return ScanResult(family: .hf, kind: kind, uid: uid, details: details, raw: text)
    }

    /// The lines under "Possible types:", in the client's order (best guess first).
    static func possibleTypes(in text: String) -> [String]? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("Possible types") }) else { return nil }
        var types: [String] = []
        for line in lines[(start + 1)...] {
            let cleaned = line.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
            guard line.hasPrefix("[+]") || line.hasPrefix("[=]"), line.contains("   ") else { break }
            let t = cleaned.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            types.append(t)
        }
        return types.isEmpty ? nil : types
    }

    // MARK: LF

    public static func parseLF(_ text: String) -> ScanResult? {
        if let m = firstMatch(#"EM 410x(?: XL)? ID\s+([0-9A-Fa-f]{10})"#, in: text) {
            let id = m[1].uppercased()
            var details: [Detail] = []
            if let c = firstMatch(#"Unique Card Number\s*:?\s*(\d+)"#, in: text) ?? firstMatch(#"Unique TAG ID\s*:?\s*([0-9A-Fa-f]+)"#, in: text) {
                details.append(Detail("Card number", c[1]))
            }
            if let c = firstMatch(#"Pattern Paxton\s*:\s*(\d+)"#, in: text) {
                details.append(Detail("Paxton", c[1]))
            }
            return ScanResult(family: .lf, kind: "EM410x", uid: id, details: details, raw: text)
        }
        if let m = firstMatch(#"HID\s+(H\d+)[^\n]*?FC:\s*(\d+)\s+CN:\s*(\d+)"#, in: text) {
            let raw = firstMatch(#"raw:\s*([0-9A-Fa-f]+)"#, in: text)?[1].uppercased() ?? ""
            return ScanResult(
                family: .lf,
                kind: "HID Prox \(m[1])",
                uid: raw.isEmpty ? "\(m[2])\(m[3])" : raw,
                details: [Detail("Format", m[1]), Detail("Facility code", m[2]), Detail("Card number", m[3])],
                raw: text
            )
        }
        if let m = firstMatch(#"Valid\s+([A-Za-z0-9 \-]+?)\s+ID found"#, in: text) {
            let id = firstMatch(#"(?:ID|Raw)[:\s]+([0-9A-Fa-f]{6,})"#, in: text)?[1].uppercased() ?? ""
            return ScanResult(family: .lf, kind: m[1], uid: id, details: [], raw: text)
        }
        return nil
    }

    // MARK: Files the client reports saving

    /// Paths from lines like "Saved 1024 bytes to binary file `hf-mf-XXXX-dump.bin`".
    public static func savedFiles(in text: String) -> [String] {
        var out: [String] = []
        let regex = try? NSRegularExpression(pattern: #"(?:Saved|saved)[^\n`'"]*?(?:file|to)\s*[`'"]([^`'"\n]+)[`'"]"#)
        let ns = text as NSString
        for m in regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] where m.numberOfRanges > 1 {
            out.append(ns.substring(with: m.range(at: 1)))
        }
        return out
    }

    // MARK: Helpers

    static func firstMatch(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}
