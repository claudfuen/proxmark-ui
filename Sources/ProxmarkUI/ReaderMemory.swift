import Foundation
import IOKit
import ProxmarkKit

/// Remembers a model only when the client reports an explicit hardware
/// identity, so the firmware sheet can preselect it later.
///
/// Why this exists: while the firmware and client protocols differ, the client
/// refuses to talk to the reader at all, and the USB descriptor is identical on
/// an Easy and an RDV4. A successful connection can identify a validated RDV4,
/// while generic firmware still leaves the board unknown. Known identities are
/// keyed by USB serial number rather than the usbmodem port name.
enum ReaderMemory {
    private static let key = "readerModels"

    /// The model a matching-firmware connection reported, mapped to a firmware
    /// target. Generic firmware is not evidence of an Easy. nil for unknown
    /// hardware or models this app has no image for (e.g. RDV2).
    static func target(forReportedModel model: String) -> Pm3Firmware.Target? {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if m == "rdv4" || m.hasPrefix("rdv4.") { return .rdv4 }
        if m == "proxmark3 easy" || m == "pm3easy" { return .easy }
        return nil
    }

    /// Record the model for whichever Proxmark3 is plugged in now.
    static func remember(reportedModel model: String) {
        guard let target = target(forReportedModel: model), let serial = connectedSerial() else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all[serial] = target.rawValue
        UserDefaults.standard.set(all, forKey: key)
    }

    /// The remembered model for the reader plugged in now, if any.
    static func rememberedTarget() -> Pm3Firmware.Target? {
        guard let serial = connectedSerial(),
              let all = UserDefaults.standard.dictionary(forKey: key) as? [String: String],
              let raw = all[serial] else { return nil }
        return Pm3Firmware.Target(rawValue: raw)
    }

    /// Demo mode: preview the "remembered" state without touching UserDefaults.
    static var demoOverride: Pm3Firmware.Target? {
        switch ProcessInfo.processInfo.environment["PMUI_REMEMBERED"] {
        case "easy": return .easy
        case "rdv4": return .rdv4
        default: return nil
        }
    }

    /// USB serial of the single attached Proxmark3 (vendor 0x9AC4, product
    /// 0x4B8F). Returns nil when none or more than one is attached, so a
    /// remembered model can never be applied to the wrong reader.
    static func connectedSerial() -> String? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var serials: [String] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard intProperty(service, "idVendor") == 0x9AC4,
                  intProperty(service, "idProduct") == 0x4B8F,
                  let serial = IORegistryEntryCreateCFProperty(service, "USB Serial Number" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  !serial.isEmpty
            else { continue }
            serials.append(serial)
        }
        return serials.count == 1 ? serials[0] : nil
    }

    private static func intProperty(_ service: io_object_t, _ name: String) -> Int? {
        IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
    }
}
