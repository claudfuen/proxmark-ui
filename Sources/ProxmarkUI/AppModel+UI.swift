import AppKit
import Foundation
import ProxmarkKit

// View-layer additions to AppModel. AppModel.swift owns the business logic;
// nothing here changes how scans, reads or writes run.

extension AppModel {
    static let clientPathKey = "pm3ClientPath"

    /// A client binary the user picked by hand. Pm3Locator already honours
    /// PM3_CLIENT, so exporting it is enough for refreshClient() to find it.
    static func applySavedClientPath() {
        if let path = UserDefaults.standard.string(forKey: clientPathKey), !path.isEmpty {
            setenv("PM3_CLIENT", path, 1)
        }
    }

    func chooseClient() {
        let panel = NSOpenPanel()
        panel.title = "Locate the proxmark3 client"
        panel.message = "Choose the proxmark3 executable (for example proxmark3/client/proxmark3)."
        panel.prompt = "Use This Client"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            lastError = "\(url.lastPathComponent) isn't an executable."
            return
        }
        UserDefaults.standard.set(url.path, forKey: Self.clientPathKey)
        Self.applySavedClientPath()
        refreshClient()
        Task { await checkConnection() }
    }

    // MARK: Demo seed (PMUI_DEMO=1), for screenshots without hardware

    static var isDemo: Bool { ProcessInfo.processInfo.environment["PMUI_DEMO"] != nil }

    func seedDemo() {
        connection = .ready(DeviceInfo(
            port: "/dev/cu.usbmodem2101", model: "Proxmark3 Easy",
            firmware: "Iceman/master/v4.20728", raw: ""
        ))
        let now = Date()
        let classic = ScanResult(
            date: now, family: .hf, kind: "MIFARE Classic 1K", uid: "A34F19C2",
            details: [
                Detail("ATQA", "00 04"), Detail("SAK", "08 [2]"),
                Detail("PRNG", "weak"), Detail("Magic", "Gen 1a"),
            ],
            raw: ""
        )
        history = [
            classic,
            ScanResult(date: now.addingTimeInterval(-420), family: .lf, kind: "EM410x", uid: "0F0368568B", details: [], raw: ""),
            ScanResult(date: now.addingTimeInterval(-1260), family: .lf, kind: "HID Prox H10301", uid: "2006EC0C86", details: [Detail("FC / CN", "118 / 1603")], raw: ""),
            ScanResult(date: now.addingTimeInterval(-3000), family: .hf, kind: "NTAG215", uid: "04A2245A6E7380", details: [], raw: ""),
        ]
        lastResult = classic
        log = [
            "[usb] pm3 --> hf search",
            " UID: A3 4F 19 C2",
            "ATQA: 00 04",
            " SAK: 08 [2]",
            "[+] Possible types:",
            "[+]    MIFARE Classic 1K",
            "[+] Prng detection: weak",
            "[+] Magic capabilities : Gen 1a",
            "[+] Valid ISO 14443-A tag found",
        ]
        let entry = DumpEntry(fileName: "hf-mf-A34F19C2-dump.bin", name: "Office door fob", kind: "MIFARE Classic 1K", uid: "A34F19C2", date: now.addingTimeInterval(-86_400), byteCount: 1024)
        dumps = [
            entry,
            DumpEntry(fileName: "hf-mfu-04A2245A6E7380-dump.bin", name: "Amiibo NTAG215", kind: "NTAG215", uid: "04A2245A6E7380", date: now.addingTimeInterval(-86_400 * 4), byteCount: 540),
            DumpEntry(fileName: "hf-mf-7B11C0DE-dump.bin", name: "Gym locker", kind: "MIFARE Classic 1K", uid: "7B11C0DE", date: now.addingTimeInterval(-86_400 * 12), byteCount: 1024),
        ]
        DemoData.dumpBytes[entry.fileName] = DemoData.classic1K(uid: [0xA3, 0x4F, 0x19, 0xC2], missingSectors: [9, 13])

        // PMUI_DEMO=<state> previews a connection state instead of "ready".
        switch ProcessInfo.processInfo.environment["PMUI_DEMO"] {
        case "checking": connection = .checking
        case "noclient": connection = .noClient; lastResult = nil; history = []
        case "nodevice": connection = .noDevice; lastResult = nil; history = []
        case "mismatch": connection = .firmwareMismatch(device: 6, client: 13)
        case "empty": lastResult = nil; history = []; log = []; dumps = []
        case "busy":
            isBusy = true
            busyLabel = "Reading MIFARE Classic 1K…"
            log.append("[=] Running strategy 2 (hardnested), sector 9 key A")
        default: break
        }
    }
}

/// In-memory dump bytes for the demo seed, so the sector table renders
/// without writing anything into the real library folder.
enum DemoData {
    @MainActor static var dumpBytes: [String: Data] = [:]

    static func classic1K(uid: [UInt8], missingSectors: Set<Int>) -> Data {
        var bytes = [UInt8](repeating: 0, count: 1024)
        for (i, b) in uid.enumerated() { bytes[i] = b }
        let keys: [[UInt8]] = [
            [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5],
            [0xD3, 0xF7, 0xD3, 0xF7, 0xD3, 0xF7], [0x4D, 0x3A, 0x99, 0xC3, 0x51, 0xDD],
        ]
        for sector in 0..<16 where !missingSectors.contains(sector) {
            let t = (sector * 4 + 3) * 16
            let key = keys[sector % keys.count]
            for i in 0..<6 { bytes[t + i] = key[i]; bytes[t + 10 + i] = keys[(sector + 1) % keys.count][i] }
            bytes[t + 6] = 0xFF; bytes[t + 7] = 0x07; bytes[t + 8] = 0x80; bytes[t + 9] = 0x69
        }
        return Data(bytes)
    }
}
