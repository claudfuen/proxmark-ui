import Foundation
import ProxmarkKit
import SwiftUI

enum FirmwareUpdateSheet: String, Identifiable {
    case confirmation
    case progress
    var id: String { rawValue }
}

enum FirmwareUpdatePhase: Equatable {
    case ready
    case connecting
    case waitingForBootloader
    case flashing
    case reconnecting
    case complete
    case failed(String)

    var isActive: Bool {
        self == .connecting || self == .waitingForBootloader || self == .flashing || self == .reconnecting
    }
}

extension ConnectionState {
    var isFirmwareMismatch: Bool {
        if case .firmwareMismatch = self { return true }
        return false
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var clientPath: URL?
    @Published var connection: ConnectionState = .checking
    @Published var availablePorts: [String] = []
    @Published var selectedPort: String?

    @Published var isBusy = false
    @Published var busyLabel: String = ""
    @Published var log: [String] = []

    @Published var lastResult: ScanResult?
    @Published var history: [ScanResult] = []

    @Published var dumps: [DumpEntry] = []
    @Published var lastError: String?

    @Published var firmwareUpdateSheet: FirmwareUpdateSheet?
    @Published var firmwareUpdatePhase: FirmwareUpdatePhase = .ready
    @Published var firmwareUpdateLog: [String] = []
    @Published var firmwareUpdateTarget: Pm3Firmware.Target?

    private var client: Pm3Client?

    /// True while a connection check is in flight, so overlapping checks (a
    /// timer tick landing on top of a manual reconnect) can't fight each other.
    private var isChecking = false
    private var portPoll: Timer?
    private var knownPorts: [String] = []

    init() {
        try? FileManager.default.createDirectory(at: Pm3Locator.dumpsDirectory, withIntermediateDirectories: true)
        refreshClient()
        refreshPorts()
        loadDumps()
        startPortPolling()
    }

    deinit { portPoll?.invalidate() }

    /// Watches /dev for the reader appearing or disappearing, so plugging it
    /// in just works and unplugging it is reflected without a manual reconnect.
    private func startPortPolling() {
        guard !Self.isDemo else { return }
        knownPorts = availablePorts
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPorts() }
        }
        RunLoop.main.add(timer, forMode: .common)
        portPoll = timer
    }

    private func pollPorts() {
        guard !isBusy else { return }
        let current = Pm3Locator.ports()
        guard current != knownPorts else { return }
        let appeared = !Set(current).subtracting(knownPorts).isEmpty
        knownPorts = current
        refreshPorts()
        // A reader just showed up (or the selected one came back) and we're not
        // already talking to it: reconnect automatically.
        if appeared, client != nil, !connection.isReady {
            Task { await checkConnection() }
        } else if current.isEmpty {
            connection = .noDevice
        }
    }

    // MARK: Setup

    func refreshClient() {
        if let url = Pm3Locator.locate() {
            clientPath = url
            client = Pm3Client(executable: url)
        } else {
            clientPath = nil
            client = nil
            connection = .noClient
        }
    }

    func refreshPorts() {
        availablePorts = Pm3Locator.ports()
        if selectedPort == nil || !availablePorts.contains(selectedPort!) {
            selectedPort = availablePorts.first
        }
        if availablePorts.isEmpty, client != nil {
            connection = .noDevice
        }
    }

    // MARK: Connection check

    func checkConnection(allowWhileBusy: Bool = false) async {
        guard !isChecking, !isBusy || allowWhileBusy else { return }
        isChecking = true
        defer { isChecking = false }
        refreshPorts()
        guard let client else { connection = .noClient; return }
        guard let port = selectedPort else { connection = .noDevice; return }
        connection = .checking
        let result = await client.run(port: port, commands: [Commands.hwVersion], timeout: 20)
        let text = result.output
        if let mismatch = Parsers.parseCapabilityMismatch(text) {
            connection = .firmwareMismatch(device: mismatch.device, client: mismatch.client)
            return
        }
        if result.timedOut {
            connection = .unreachable("The client didn't respond. Check the cable and that nothing else (another pm3 session) has the port open.")
            return
        }
        guard result.succeeded else {
            connection = .unreachable("The client could not complete its firmware check. Review the client output and reconnect the reader.")
            return
        }
        if let device = Parsers.parseDevice(port: port, from: text) {
            connection = .ready(device)
        } else {
            connection = .unreachable("Connected to the port, but couldn't confirm it's a Proxmark3.")
        }
    }

    // MARK: Firmware update

    /// The updater deliberately accepts only the image packaged with the
    /// exact bundled client. A manually selected client may have different
    /// firmware, so it cannot borrow the app's image.
    func canUpdateFirmware(for target: Pm3Firmware.Target?) -> Bool {
        guard let target, !isBusy else { return false }
        if Self.isDemo { return true }
        return connection.isFirmwareMismatch && selectedPort != nil && client != nil
            && Pm3Locator.isBundled(clientPath)
            && Pm3Firmware.bundledFullImage(for: target) != nil
            && Pm3Firmware.bundledSourceRevision(for: target) != nil
    }

    func firmwareUpdateUnavailableReason(for target: Pm3Firmware.Target?) -> String? {
        if Self.isDemo { return nil }
        if selectedPort == nil { return "Connect the reader over USB first." }
        if !connection.isFirmwareMismatch { return "Reconnect the reader and check its firmware status first." }
        if !Pm3Locator.isBundled(clientPath) {
            return "The updater requires the bundled client. In Settings > Reader, choose Use Default, then reconnect."
        }
        if let target, Pm3Firmware.bundledFullImage(for: target) == nil {
            return "This app copy has no \(target.displayName) firmware image. Rebuild the complete app package."
        }
        return nil
    }

    func showFirmwareUpdate() {
        guard !isBusy else { return }
        firmwareUpdatePhase = .ready
        firmwareUpdateLog.removeAll()
        firmwareUpdateTarget = nil
        firmwareUpdateSheet = .confirmation
    }

    func startFirmwareUpdate(hardwareConfirmed: Bool, target: Pm3Firmware.Target?) async {
        guard hardwareConfirmed, let target, !isBusy else { return }
        guard canUpdateFirmware(for: target) else {
            firmwareUpdatePhase = .failed(firmwareUpdateUnavailableReason(for: target) ?? "The selected firmware is unavailable.")
            firmwareUpdateSheet = .progress
            return
        }
        firmwareUpdateTarget = target
        firmwareUpdateSheet = .progress
        firmwareUpdatePhase = .connecting
        firmwareUpdateLog.removeAll()
        isBusy = true
        busyLabel = "Updating reader firmware"
        defer { isBusy = false; busyLabel = "" }

        // Screenshots and UI checks can exercise the whole sheet safely.
        // Demo mode never launches a flasher or changes attached hardware.
        if Self.isDemo {
            firmwareUpdateLog = ["Connecting to bootloader…", "Checking fullimage.elf…", "Writing application firmware…"]
            firmwareUpdatePhase = .flashing
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            firmwareUpdatePhase = .reconnecting
            firmwareUpdateLog.append("Reconnecting to reader…")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            firmwareUpdatePhase = .complete
            firmwareUpdateLog.append("Reader and client are ready.")
            return
        }

        guard let client, let port = selectedPort,
              Pm3Locator.isBundled(clientPath),
              let image = Pm3Firmware.bundledFullImage(for: target) else {
            firmwareUpdatePhase = .failed(firmwareUpdateUnavailableReason(for: target) ?? "The bundled firmware is unavailable.")
            return
        }

        do {
            let result = try await client.flashFullImage(port: port, fullImage: image, onLine: { line in
                Task { @MainActor in
                    self.firmwareUpdateLog.append(line)
                    let lower = line.lowercased()
                    if lower.contains("press and hold down button") {
                        self.firmwareUpdatePhase = .waitingForBootloader
                    } else if lower.contains("flashing...") {
                        self.firmwareUpdatePhase = .flashing
                    }
                }
            })
            guard result.succeeded else {
                firmwareUpdatePhase = .failed("Flashing did not finish successfully. If the reader is waiting for bootloader mode, unplug it, hold its button, and reconnect it. Review the log before trying again.")
                return
            }

            firmwareUpdatePhase = .reconnecting
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await checkConnection(allowWhileBusy: true)
                if connection.isReady {
                    firmwareUpdatePhase = .complete
                    return
                }
            }
            firmwareUpdatePhase = .failed("The firmware was written, but the reader did not reconnect with a matching protocol. Reconnect the USB cable and check again.")
        } catch {
            firmwareUpdatePhase = .failed(error.localizedDescription)
        }
    }

    // MARK: Scanning

    func scan(family: TagFamily) async {
        guard let client, let port = selectedPort, connection.isReady else { return }
        await runBusy("Searching \(family == .hf ? "13.56 MHz" : "125 kHz")...") {
            let cmd = family == .hf ? Commands.hfSearch : Commands.lfSearch
            let result = await client.run(port: port, commands: [cmd], timeout: 25, onLine: { line in
                Task { @MainActor in self.log.append(line) }
            })
            let parsed = family == .hf ? Parsers.parseHF(result.output) : Parsers.parseLF(result.output)
            if let parsed {
                self.lastResult = parsed
                self.history.insert(parsed, at: 0)
                if self.history.count > 50 { self.history.removeLast() }
            } else if !result.succeeded {
                self.lastError = "The reader didn't respond. Is a tag on the antenna?"
            } else {
                self.lastError = "No \(family == .hf ? "13.56 MHz" : "125 kHz") tag found."
            }
        }
    }

    // MARK: Full reads -> saved dumps

    /// Reads the whole card (keys + data for Classic, pages for Ultralight)
    /// and files the result in the library. Classic goes through `autopwn`,
    /// which tries known/weak-key and nonce attacks; it can take minutes on
    /// a card with unknown non-default keys, and may not recover every key.
    func readFullDump(for scan: ScanResult) async {
        guard let client, let port = selectedPort else { return }
        let command: String
        if scan.isClassic {
            command = Commands.classicRead(sizeBytes: scan.classicDumpSize)
        } else if scan.isUltralight {
            command = Commands.ultralightRead
        } else {
            lastError = "Full-dump reading isn't wired up for \(scan.kind) yet; use the client directly for this tag."
            return
        }
        await runBusy("Reading \(scan.kind)... this can take a while") {
            let before = self.existingDumpFiles()
            let result = await client.run(
                port: port, commands: [command], timeout: 600, workingDirectory: Pm3Locator.homeDirectory,
                onLine: { line in Task { @MainActor in self.log.append(line) } }
            )
            let named = Parsers.savedFiles(in: result.output)
            let after = Set(self.existingDumpFiles())
            let reported = named.map { URL(fileURLWithPath: $0).lastPathComponent }
            let newFiles = after.subtracting(before).union(reported.filter { after.contains($0) })
            let prefix = scan.isClassic ? "hf-mf-" : "hf-mfu-"
            let allDumpNames = newFiles.filter { $0.hasPrefix(prefix) && $0.contains("-dump") && $0.hasSuffix(".bin") }
            let expectedPrefix = "\(prefix)\(scan.uid)-".uppercased()
            let dumpNames = allDumpNames.filter { $0.uppercased().hasPrefix(expectedPrefix) }
            guard !dumpNames.isEmpty else {
                if !allDumpNames.isEmpty {
                    self.lastError = "A different tag was read. Scan that tag again before saving a full dump."
                } else {
                    self.lastError = result.succeeded ? "No full dump was saved. For Classic cards, key recovery may be incomplete. See the client log." : "Read failed; see the client log."
                }
                return
            }
            let keyName = scan.isClassic
                ? newFiles.sorted().first { $0.hasPrefix("hf-mf-\(scan.uid)-key") && $0.hasSuffix(".bin") }
                : nil
            var saved = 0
            for name in dumpNames.sorted() {
                if self.fileDump(name: name, scan: scan, keyName: keyName) { saved += 1 }
            }
            self.loadDumps()
            if saved == 0, self.lastError == nil {
                self.lastError = "The client saved a dump, but the app could not add it to the Library."
            }
        }
    }

    private func existingDumpFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: Pm3Locator.homeDirectory.path)) ?? []
    }

    @discardableResult
    private func fileDump(name: String, scan: ScanResult, keyName: String?) -> Bool {
        guard DumpEntry.isSafeFileName(name) else {
            lastError = "The client reported an invalid dump filename."
            return false
        }
        let fm = FileManager.default
        let source = Pm3Locator.homeDirectory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: source) else { return false }
        let dest = Pm3Locator.dumpsDirectory.appendingPathComponent(name)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: source, to: dest)
            var storedKeyName: String?
            if let keyName {
                let keySource = Pm3Locator.homeDirectory.appendingPathComponent(keyName)
                if fm.fileExists(atPath: keySource.path) {
                    let keyDestName = dest.deletingPathExtension().lastPathComponent + "-keys.bin"
                    let keyDest = Pm3Locator.dumpsDirectory.appendingPathComponent(keyDestName)
                    if fm.fileExists(atPath: keyDest.path) { try fm.removeItem(at: keyDest) }
                    try fm.copyItem(at: keySource, to: keyDest)
                    storedKeyName = keyDestName
                }
            }
            let entry = DumpEntry(fileName: name, name: scan.kind, kind: scan.kind, uid: scan.uid, date: Date(), byteCount: data.count, keyFileName: storedKeyName)
            try JSONEncoder.pm3.encode(entry).write(to: entry.sidecarURL)
            return true
        } catch {
            lastError = "Could not save \(name): \(error.localizedDescription)"
            return false
        }
    }

    func loadDumps() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Pm3Locator.dumpsDirectory, includingPropertiesForKeys: nil)) ?? []
        dumps = files
            .filter { $0.pathExtension == "json" }
            .compactMap { sidecar -> DumpEntry? in
                guard let data = try? Data(contentsOf: sidecar),
                      let entry = try? JSONDecoder.pm3.decode(DumpEntry.self, from: data),
                      entry.hasSafeFileName,
                      sidecar.lastPathComponent == entry.sidecarURL.lastPathComponent,
                      fm.fileExists(atPath: entry.url.path) else { return nil }
                return entry
            }
            .sorted { $0.date > $1.date }
    }

    func deleteDump(_ entry: DumpEntry) {
        guard entry.hasSafeFileName else { return }
        try? FileManager.default.removeItem(at: entry.url)
        try? FileManager.default.removeItem(at: entry.sidecarURL)
        if let keyURL = entry.keyURL { try? FileManager.default.removeItem(at: keyURL) }
        loadDumps()
    }

    func reveal(_ entry: DumpEntry) {
        guard entry.hasSafeFileName else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    // MARK: Writes — each call is built by ProxmarkKit.Commands, which

    // validates every field, so nothing here can inject a second command.

    func writeEM410x(id: String) async {
        await write(label: "Writing EM410x \(id)...") { try Commands.em410xClone(id: id) }
    }

    func writeHID(facility: String, card: String) async {
        await write(label: "Writing HID \(facility)/\(card)...") { try Commands.hidClone(facility: facility, card: card) }
    }

    func restoreClassic(dump: DumpEntry, authenticateWithKeys: Bool) async {
        guard dump.hasSafeFileName else { lastError = "The saved dump filename is invalid."; return }
        guard let size = ClassicDump.validSizes.contains(dump.byteCount) ? dump.byteCount : nil else {
            lastError = "That file isn't a recognized Classic dump size."
            return
        }
        guard let keyURL = dump.keyURL, FileManager.default.fileExists(atPath: keyURL.path) else {
            lastError = "This Classic dump has no saved key file. Read the card again with full key recovery before restoring it."
            return
        }
        await write(label: "Restoring \(dump.name) to tag...") {
            try Commands.classicRestore(dump: dump.url, keys: keyURL, sizeBytes: size, authenticateWithKeys: authenticateWithKeys)
        }
    }

    func loadMagic(dump: DumpEntry) async {
        guard dump.hasSafeFileName else { lastError = "The saved dump filename is invalid."; return }
        await write(label: "Writing full dump to magic tag...") { try Commands.magicLoad(dump: dump.url) }
    }

    func restoreUltralight(dump: DumpEntry) async {
        guard dump.hasSafeFileName else { lastError = "The saved dump filename is invalid."; return }
        await write(label: "Restoring Ultralight/NTAG dump...") { try Commands.ultralightRestore(dump: dump.url) }
    }

    private func write(label: String, build: () throws -> String) async {
        guard let client, let port = selectedPort, connection.isReady else { return }
        let command: String
        do { command = try build() } catch {
            lastError = error.localizedDescription
            return
        }
        await runBusy(label) {
            let result = await client.run(port: port, commands: [command], timeout: 120, onLine: { line in
                Task { @MainActor in self.log.append(line) }
            })
            if !result.succeeded {
                self.lastError = "Write failed; see the log."
            }
        }
    }

    // MARK: Helpers

    private func runBusy(_ label: String, _ body: @escaping () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        busyLabel = label
        lastError = nil
        log.removeAll()
        defer { isBusy = false }
        await body()
    }
}

private extension JSONEncoder {
    static let pm3: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let pm3: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
