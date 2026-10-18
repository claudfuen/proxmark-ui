import XCTest
@testable import ProxmarkKit

final class ParserTests: XCTestCase {
    func testClassicHF() {
        let out = """
        [=] Searching for ISO14443-A tag...
        [+]  UID: DE AD BE EF
        [+] ATQA: 00 04
        [+]  SAK: 08 [2]
        [+] Possible types:
        [+]    MIFARE Classic 1K
        [=]
        [=] Magic capabilities... Gen 1a
        [+] Prng detection....: weak
        [+] Valid ISO 14443-A tag found
        """
        let r = Parsers.parseHF(out)
        XCTAssertEqual(r?.uid, "DEADBEEF")
        XCTAssertEqual(r?.kind, "MIFARE Classic 1K")
        XCTAssertEqual(r?.classicDumpSize, 1024)
        XCTAssertEqual(r?.details.first { $0.label == "SAK" }?.value, "08")
        XCTAssertEqual(r?.details.first { $0.label == "PRNG" }?.value, "Weak")
        XCTAssertEqual(r?.details.first { $0.label == "Magic" }?.value, "Gen 1a")
        XCTAssertEqual(r?.spacedUID, "DE AD BE EF")
    }

    func testUltralightSevenByteUID() {
        let out = """
        [+]  UID: 04 A1 B2 C3 D4 E5 80
        [+] ATQA: 00 44
        [+]  SAK: 00 [2]
        [+] Possible types:
        [+]    MIFARE Ultralight
        [+]    NTAG 213
        """
        let r = Parsers.parseHF(out)
        XCTAssertEqual(r?.uid, "04A1B2C3D4E580")
        XCTAssertEqual(r?.isUltralight, true)
    }

    func testNoHFTag() {
        XCTAssertNil(Parsers.parseHF("[!] No known/supported 13.56 MHz tags found"))
    }

    func testEM410x() {
        let r = Parsers.parseLF("[+] EM 410x ID 0F0368568B\n[+] Valid EM410x ID found!")
        XCTAssertEqual(r?.uid, "0F0368568B")
        XCTAssertEqual(r?.isEM410x, true)
    }

    func testHID() {
        let out = """
        [+] [H10301  ] HID H10301 26-bit;  FC: 118  CN: 1603    parity: valid
        [+] raw: 2006EC0C86
        [+] Valid HID Prox ID found!
        """
        let r = Parsers.parseLF(out)
        XCTAssertEqual(r?.kind, "HID Prox H10301")
        XCTAssertEqual(r?.uid, "2006EC0C86")
        XCTAssertEqual(r?.details.first { $0.label == "Facility code" }?.value, "118")
        XCTAssertEqual(r?.isHID, true)
    }

    func testNoLF() {
        XCTAssertNil(Parsers.parseLF("[-] No data found!"))
    }

    func testFirmwareMismatch() {
        let m = Parsers.parseCapabilityMismatch("[!!] Capabilities structure version sent by Proxmark3 is not the one expected by this client! (v6 != v13)")
        XCTAssertEqual(m?.device, 6)
        XCTAssertEqual(m?.client, 13)
    }

    func testHardwareModelRequiresDeviceEvidence() {
        let header = "[ Proxmark3 ]\n[ Client ]\n  Iceman/master/v4.0"
        XCTAssertNil(Parsers.parseDevice(port: "/dev/cu.usbmodem1", from: header))

        let generic = header + "\n[ Model ]\n  Firmware.................. PM3 GENERIC\n  --= Processor Unique ID: 0x1234"
        XCTAssertEqual(Parsers.parseDevice(port: "/dev/cu.usbmodem1", from: generic)?.model, "Proxmark3")
        XCTAssertEqual(Parsers.parseDevice(port: "/dev/cu.usbmodem1", from: generic + "\nRDV4 mentioned in an unrelated message")?.model, "Proxmark3")

        let validatedRDV4 = header + "\n[ Model ]\n  Device.................... RDV4\n  Firmware.................. RDV4"
        XCTAssertEqual(Parsers.parseDevice(port: "/dev/cu.usbmodem1", from: validatedRDV4)?.model, "RDV4")
    }

    func testSavedFiles() {
        let out = "[+] Saved 1024 bytes to binary file `hf-mf-DEADBEEF-dump.bin`\n[+] Saved to json file `hf-mf-DEADBEEF-dump.json`"
        XCTAssertEqual(Parsers.savedFiles(in: out).first, "hf-mf-DEADBEEF-dump.bin")
    }

    func testAnsiStrip() {
        XCTAssertEqual(Ansi.strip("\u{1B}[32m[+]\u{1B}[0m ok\r"), "[+] ok")
    }
}

final class CommandTests: XCTestCase {
    func testRejectsInjection() {
        XCTAssertThrowsError(try Commands.em410xClone(id: "0F0368568B; hw tune"))
        XCTAssertThrowsError(try Commands.em410xClone(id: "ZZ"))
        XCTAssertThrowsError(try Commands.path(URL(fileURLWithPath: "/tmp/a b.bin")))
        XCTAssertThrowsError(try Commands.path(URL(fileURLWithPath: "/tmp/a;b.bin")))
        XCTAssertThrowsError(try Commands.path(URL(fileURLWithPath: "/tmp/a.bin\n")))
        XCTAssertThrowsError(try Commands.hidClone(format: "H10301\n", facility: "1", card: "2"))
    }

    func testBuilds() throws {
        XCTAssertEqual(try Commands.em410xClone(id: "0f 03 68 56 8b"), "lf em 410x clone --id 0F0368568B")
        XCTAssertEqual(try Commands.hidClone(facility: "118", card: "1603"), "lf hid clone -w H10301 --fc 118 --cn 1603")
        XCTAssertEqual(Commands.classicRead(sizeBytes: 4096), "hf mf autopwn --4k -f mfc_default_keys")
        XCTAssertThrowsError(try Commands.hidClone(facility: "99999999", card: "1"))
    }

    func testH10301FieldLimits() throws {
        XCTAssertEqual(try Commands.hidClone(facility: "255", card: "65535"), "lf hid clone -w H10301 --fc 255 --cn 65535")
        XCTAssertThrowsError(try Commands.hidClone(facility: "256", card: "0"))
        XCTAssertThrowsError(try Commands.hidClone(facility: "0", card: "65536"))
    }

    func testClassicReadUsesBundledDefaultDictionary() {
        XCTAssertEqual(Commands.classicRead(sizeBytes: 1024), "hf mf autopwn --1k -f mfc_default_keys")
    }

    func testClassicRestoreAuthenticationMode() throws {
        let dump = URL(fileURLWithPath: "/tmp/hf-mf-DEADBEEF-dump.bin")
        let keys = URL(fileURLWithPath: "/tmp/hf-mf-DEADBEEF-dump-keys.bin")
        XCTAssertEqual(
            try Commands.classicRestore(dump: dump, keys: keys, sizeBytes: 1024, authenticateWithKeys: true),
            "hf mf restore --1k -f /tmp/hf-mf-DEADBEEF-dump.bin -k /tmp/hf-mf-DEADBEEF-dump-keys.bin --ka"
        )
        XCTAssertEqual(
            try Commands.classicRestore(dump: dump, keys: keys, sizeBytes: 1024),
            "hf mf restore --1k -f /tmp/hf-mf-DEADBEEF-dump.bin -k /tmp/hf-mf-DEADBEEF-dump-keys.bin"
        )
        XCTAssertThrowsError(try Commands.classicRestore(dump: dump, keys: URL(fileURLWithPath: "/tmp/bad;key.bin"), sizeBytes: 1024, authenticateWithKeys: true))
    }

    func testUltralightRestoreDoesNotRequestMagicTagWrites() throws {
        let dump = URL(fileURLWithPath: "/tmp/hf-mfu-04A2245A6E7380-dump.bin")
        XCTAssertEqual(try Commands.ultralightRestore(dump: dump), "hf mfu restore -f /tmp/hf-mfu-04A2245A6E7380-dump.bin")
    }
}

final class FirmwareTests: XCTestCase {
    func testBuildsFullImageOnlyArguments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageDirectory = directory.appendingPathComponent("PM3EASY")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let image = imageDirectory.appendingPathComponent("fullimage.elf")
        try Data([0x7F, 0x45, 0x4C, 0x46, 0x01]).write(to: image)

        let args = try Pm3Firmware.flashArguments(port: "/dev/cu.usbmodem2101", fullImage: image)
        XCTAssertEqual(args, ["--incognito", "-f", "-p", "/dev/cu.usbmodem2101", "--flash", "--image", image.path])
        XCTAssertFalse(args.contains("--unlock-bootloader"))
        XCTAssertFalse(args.contains("--force"))
    }

    func testRejectsBadPortAndNonFirmware() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageDirectory = directory.appendingPathComponent("PM3EASY")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let image = imageDirectory.appendingPathComponent("fullimage.elf")
        let bootrom = imageDirectory.appendingPathComponent("bootrom.elf")
        try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: image)
        try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: bootrom)

        XCTAssertThrowsError(try Pm3Firmware.flashArguments(port: "/dev/cu.usbmodem2101; hw version", fullImage: image))
        XCTAssertThrowsError(try Pm3Firmware.flashArguments(port: "/dev/cu.usbmodem2101\n", fullImage: image))
        XCTAssertThrowsError(try Pm3Firmware.flashArguments(port: "tcp:localhost:18888", fullImage: image))
        XCTAssertThrowsError(try Pm3Firmware.flashArguments(port: "/dev/cu.usbmodem2101", fullImage: bootrom))
        let wrongTargetDirectory = directory.appendingPathComponent("PM3GENERIC")
        try FileManager.default.createDirectory(at: wrongTargetDirectory, withIntermediateDirectories: true)
        let wrongTargetImage = wrongTargetDirectory.appendingPathComponent("fullimage.elf")
        try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: wrongTargetImage)
        XCTAssertThrowsError(try Pm3Firmware.flashArguments(port: "/dev/cu.usbmodem2101", fullImage: wrongTargetImage))
        try Data("not an ELF".utf8).write(to: image)
        XCTAssertThrowsError(try Pm3Firmware.flashArguments(port: "/dev/cu.usbmodem2101", fullImage: image))
    }

    func testBundledImageSelectionRequiresMatchingMetadata() throws {
        let sampleSHA = "3bdbb4fe8397cd2b842430b39ccff01a8663c751945ef5e9a09e267fb8b1d359"
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: resources) }
        let firmware = resources.appendingPathComponent("pm3/share/proxmark3/firmware")
        let easy = firmware.appendingPathComponent("PM3EASY")
        let rdv4 = firmware.appendingPathComponent("PM3RDV4")
        try FileManager.default.createDirectory(at: easy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rdv4, withIntermediateDirectories: true)
        try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: easy.appendingPathComponent("fullimage.elf"))
        try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: rdv4.appendingPathComponent("fullimage.elf"))
        try Data("{\"target\":\"PM3EASY\",\"sourceRevision\":\"693ead0\",\"buildPlatform\":\"PM3GENERIC\",\"ledOrder\":\"PM3EASY\",\"maxFlashKB\":256,\"sha256\":\"\(sampleSHA)\"}".utf8)
            .write(to: easy.appendingPathComponent("build.json"))
        try Data("{\"target\":\"PM3RDV4\",\"sourceRevision\":\"693ead0\",\"buildPlatform\":\"PM3RDV4\",\"ledOrder\":null,\"maxFlashKB\":512,\"sha256\":\"\(sampleSHA)\"}".utf8)
            .write(to: rdv4.appendingPathComponent("build.json"))

        XCTAssertEqual(Pm3Firmware.fullImage(for: .easy, inResources: resources)?.path, easy.appendingPathComponent("fullimage.elf").path)
        XCTAssertEqual(Pm3Firmware.fullImage(for: .rdv4, inResources: resources)?.path, rdv4.appendingPathComponent("fullimage.elf").path)

        try Data("{\"target\":\"PM3RDV4\",\"sourceRevision\":\"693ead0\",\"buildPlatform\":\"PM3GENERIC\",\"ledOrder\":\"PM3EASY\",\"maxFlashKB\":256,\"sha256\":\"\(sampleSHA)\"}".utf8)
            .write(to: easy.appendingPathComponent("build.json"))
        XCTAssertNil(Pm3Firmware.fullImage(for: .easy, inResources: resources))
        XCTAssertNotNil(Pm3Firmware.fullImage(for: .rdv4, inResources: resources))
        try Data([0x7F, 0x45, 0x4C, 0x46, 0x01]).write(to: rdv4.appendingPathComponent("fullimage.elf"))
        XCTAssertNil(Pm3Firmware.fullImage(for: .rdv4, inResources: resources))
    }

    func testFlasherOutputRequiresSuccessWithoutFailure() {
        XCTAssertTrue(Pm3Firmware.outputIndicatesSuccess("[+] Flashing...\n[+] All done\n"))
        XCTAssertFalse(Pm3Firmware.outputIndicatesSuccess("[!] The flashing procedure failed\n[+] All done\n"))
        XCTAssertFalse(Pm3Firmware.outputIndicatesSuccess("[!] Aborted on error\n"))
    }

    func testFlashStreamsAndRejectsReportedFailureWithZeroExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageDirectory = directory.appendingPathComponent("PM3EASY")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let image = imageDirectory.appendingPathComponent("fullimage.elf")
        try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: image)
        let fakeClient = directory.appendingPathComponent("fake-proxmark3")
        let script = """
        #!/bin/sh
        printf '%s\\n' '[!] The flashing procedure failed' '[+] All done'
        exit 0
        """
        try script.write(to: fakeClient, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClient.path)

        let lines = LockedLines()
        let result = try await Pm3Client(executable: fakeClient).flashFullImage(
            port: "/dev/cu.usbmodem2101", fullImage: image,
            onLine: { lines.append($0) }
        )
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(lines.snapshot.contains { $0.contains("flashing procedure failed") })
    }

    func testClientUsesIsolatedHomeForDefaultDumps() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeClient = directory.appendingPathComponent("fake-proxmark3")
        try "#!/bin/sh\nprintf '%s\\n' \"$HOME\"\n".write(to: fakeClient, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClient.path)

        let result = await Pm3Client(executable: fakeClient).run(port: nil, commands: [])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), Pm3Locator.homeDirectory.path)
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

final class DumpTests: XCTestCase {
    func testDumpEntryConfinesFileNamesAndKeyPairing() {
        func entry(_ fileName: String, key: String? = nil) -> DumpEntry {
            DumpEntry(fileName: fileName, name: "Test", kind: "MIFARE Classic 1K", uid: "DEADBEEF", date: Date(), byteCount: 1024, keyFileName: key)
        }

        for unsafeName in ["../evil.bin", "..", "sub/evil.bin"] {
            let unsafe = entry(unsafeName, key: "hf-mf-DEADBEEF-dump-keys.bin")
            XCTAssertFalse(unsafe.hasSafeFileName, unsafeName)
            XCTAssertNil(unsafe.keyURL, unsafeName)
        }

        let generated = entry("hf-mf-DEADBEEF-dump.bin", key: "hf-mf-DEADBEEF-dump-keys.bin")
        XCTAssertTrue(generated.hasSafeFileName)
        XCTAssertEqual(generated.keyURL?.lastPathComponent, "hf-mf-DEADBEEF-dump-keys.bin")
        XCTAssertNil(entry("hf-mf-DEADBEEF-dump.bin", key: "hf-mf-OTHER-dump-keys.bin").keyURL)
    }

    func testClassic1K() throws {
        var bytes = [UInt8](repeating: 0, count: 1024)
        bytes[0...3] = [0xDE, 0xAD, 0xBE, 0xEF]
        // sector 0 trailer: key A FFFFFFFFFFFF, access 787788, key B FFFFFFFFFFFF
        let trailer: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x78, 0x77, 0x88, 0xC1, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        bytes.replaceSubrange(48..<64, with: trailer)
        let dump = try XCTUnwrap(ClassicDump(data: Data(bytes)))
        XCTAssertEqual(dump.sectors.count, 16)
        XCTAssertEqual(dump.uid, "DEADBEEF")
        XCTAssertEqual(dump.sectors[0].keyA, "FFFFFFFFFFFF")
        XCTAssertEqual(dump.sectors[0].accessBits, "787788C1")
        XCTAssertTrue(dump.sectors[0].keysPresent)
        XCTAssertFalse(dump.sectors[1].keysPresent)
    }

    func testClassic4KLayout() throws {
        let dump = try XCTUnwrap(ClassicDump(data: Data(repeating: 0, count: 4096)))
        XCTAssertEqual(dump.sectors.count, 40)
        XCTAssertEqual(dump.sectors[32].blocks.count, 16)
        XCTAssertEqual(dump.sectors[32].firstBlock, 128)
    }

    func testRejectsOddSize() {
        XCTAssertNil(ClassicDump(data: Data(count: 1000)))
    }
}
