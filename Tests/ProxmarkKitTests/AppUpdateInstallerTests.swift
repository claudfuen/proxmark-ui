import Foundation
import XCTest
@testable import ProxmarkKit

final class AppUpdateInstallerTests: XCTestCase {
    func testArchiveAcceptsOnlyExpectedAppAndAppleMetadata() throws {
        let zip = try fixtureZIP([
            ("ProxmarkUI.app/Contents/Info.plist", 0x81A4),
            ("__MACOSX/ProxmarkUI.app/Contents/._Info.plist", 0x81A4),
        ])
        defer { try? FileManager.default.removeItem(at: zip) }
        XCTAssertNoThrow(try ReleaseZIPValidator.validate(zip))
    }

    func testArchiveRejectsTraversalSymlinkAndExtraRoots() throws {
        for entry in [
            ("ProxmarkUI.app/../evil", 0x81A4),
            ("ProxmarkUI.app/Contents/link", 0xA1FF),
            ("Other.app/Contents/Info.plist", 0x81A4),
        ] {
            let zip = try fixtureZIP([("ProxmarkUI.app/Contents/Info.plist", 0x81A4), entry])
            XCTAssertThrowsError(try ReleaseZIPValidator.validate(zip), "Accepted \(entry.0)")
            try FileManager.default.removeItem(at: zip)
        }
    }

    func testArchiveRejectsLocalHeaderDisagreement() throws {
        let zip = try fixtureZIP([("ProxmarkUI.app/Contents/Info.plist", 0x81A4)])
        defer { try? FileManager.default.removeItem(at: zip) }
        var bytes = try Data(contentsOf: zip)
        bytes[8] = 8 // Central directory says stored, local header says deflated.
        try bytes.write(to: zip)
        XCTAssertThrowsError(try ReleaseZIPValidator.validate(zip))
    }

    func testPlanRequiresInstalledAppAndExposesUniqueRecoveryPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = directory.appendingPathComponent("ProxmarkUI.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist: [String: String] = ["CFBundleIdentifier": AppUpdateInstaller.bundleIdentifier, "CFBundleShortVersionString": "0.1.1"]
        let info = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try AppUpdateInstaller.installationPlan(for: app))
        let helper = contents.appendingPathComponent("ProxmarkUIUpdater")
        try Data("helper".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let plan = try AppUpdateInstaller.installationPlan(for: app)
        XCTAssertEqual(plan.destination, app)
        XCTAssertEqual(plan.backup.deletingLastPathComponent(), directory)
        XCTAssertTrue(plan.backup.lastPathComponent.hasPrefix(".ProxmarkUI-backup-"))
        XCTAssertEqual(plan.workDirectory.deletingLastPathComponent(), directory)
        XCTAssertNotEqual(plan.backup, try AppUpdateInstaller.installationPlan(for: app).backup)
    }

    func testSwapRetainsBackupAfterSuccessAndRestoresAfterLaunchFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("ProxmarkUI.app")
        let staged = root.appendingPathComponent("staged.app")
        let backup = root.appendingPathComponent("backup.app")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("version"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("version"))
        enum Expected: Error { case launch }
        XCTAssertThrowsError(try AppUpdateSwap.replace(destination: installed, stagedApp: staged, backup: backup) { throw Expected.launch })
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("version")), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        let failed = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("failed-") }
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(failed).appendingPathComponent("version")), "new")
        try FileManager.default.moveItem(at: XCTUnwrap(failed), to: staged)
        try AppUpdateSwap.replace(destination: installed, stagedApp: staged, backup: backup) {}
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("version")), "new")
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("version")), "old")
    }

    func testRollbackFailureNamesRetainedBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let installed = root.appendingPathComponent("ProxmarkUI.app", isDirectory: true)
        let staged = staging.appendingPathComponent("ProxmarkUI.app", isDirectory: true)
        let backup = root.appendingPathComponent("backup.app", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try AppUpdateSwap.replace(destination: installed, stagedApp: staged, backup: backup) {
                try FileManager.default.removeItem(at: staging)
                throw AppUpdateInstallError.helperLaunchFailed
            }
            XCTFail("The backup path must be reported if automatic rollback fails")
        } catch AppUpdateInstallError.rollbackFailed(let retained) {
            XCTAssertEqual(retained, backup)
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        }
    }

    private func fixtureZIP(_ entries: [(String, Int)]) throws -> URL {
        var archive = Data()
        var central = Data()
        for (name, mode) in entries {
            let nameBytes = Data(name.utf8)
            let offset = archive.count
            archive.appendLE32(0x04034b50)
            archive.appendLE16(20)
            archive.appendLE16(0)
            archive.appendLE16(0)
            archive.appendLE16(0)
            archive.appendLE16(0)
            archive.appendLE32(0)
            archive.appendLE32(0)
            archive.appendLE32(0)
            archive.appendLE16(nameBytes.count)
            archive.appendLE16(0)
            archive.append(nameBytes)

            central.appendLE32(0x02014b50)
            central.appendLE16(0x0314) // Unix creator, ZIP version 2.0
            central.appendLE16(20)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE32(0)
            central.appendLE32(0)
            central.appendLE32(0)
            central.appendLE16(nameBytes.count)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE32(mode << 16)
            central.appendLE32(offset)
            central.append(nameBytes)
        }
        let centralOffset = archive.count
        archive.append(central)
        archive.appendLE32(0x06054b50)
        archive.appendLE16(0)
        archive.appendLE16(0)
        archive.appendLE16(entries.count)
        archive.appendLE16(entries.count)
        archive.appendLE32(central.count)
        archive.appendLE32(centralOffset)
        archive.appendLE16(0)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try archive.write(to: file)
        return file
    }
}

private extension Data {
    mutating func appendLE16(_ value: Int) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE32(_ value: Int) {
        appendLE16(value)
        appendLE16(value >> 16)
    }
}
