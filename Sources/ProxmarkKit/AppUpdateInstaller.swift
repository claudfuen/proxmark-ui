import Foundation

public struct AppUpdateInstallPlan: Sendable {
    public let destination: URL
    public let backup: URL
    public let workDirectory: URL

    fileprivate init(destination: URL, backup: URL, workDirectory: URL) {
        self.destination = destination
        self.backup = backup
        self.workDirectory = workDirectory
    }
}

public enum AppUpdateProgress: String, Sendable {
    case downloading
    case verifying
    case staging
    case readyToQuit
}

public enum AppUpdateInstallError: LocalizedError {
    case invalidDestination
    case unwritableDestination
    case missingHelper
    case invalidArchive
    case invalidBundle
    case invalidSignature
    case helperLaunchFailed
    case launchNotConfirmed
    case rollbackFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidDestination: "Install ProxmarkUI in a normal Applications folder before updating. A translocated or linked app cannot update itself."
        case .unwritableDestination: "The app's folder is not writable by your account. Move ProxmarkUI to your Applications folder and try again."
        case .missingHelper: "This app copy does not contain the update installer helper. Download a complete app build."
        case .invalidArchive: "The update ZIP has an unsafe or unexpected layout."
        case .invalidBundle: "The downloaded app does not match the expected ProxmarkUI version and contents."
        case .invalidSignature: "The downloaded app failed its code-signature integrity check."
        case .helperLaunchFailed: "The update installer could not start. Your current app was not changed."
        case .launchNotConfirmed: "The new app did not confirm a healthy launch."
        case .rollbackFailed(let backup): "The update failed and automatic recovery could not finish. Your previous app is preserved at \(backup.path)."
        }
    }
}

public struct AppUpdateInstallResult: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case pending
        case failed
        case installed
        case rolledBack
        case recoveryRequired
    }

    public let outcome: Outcome
    public let message: String
    public let destination: URL
    public let backup: URL
    public let version: String
    public let timestamp: Date

    public init(outcome: Outcome, message: String, destination: URL, backup: URL, version: String) {
        self.outcome = outcome
        self.message = message
        self.destination = destination
        self.backup = backup
        self.version = version
        self.timestamp = Date()
    }
}

public enum AppUpdateInstaller {
    public static let bundleIdentifier = "dev.claudio.proxmarkui"
    public static var resultURL: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PMUI_UPDATE_TEST_RESULT_PATH"] {
            return URL(fileURLWithPath: path)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProxmarkUI/update-result.json")
    }

    public static func lastResult() -> AppUpdateInstallResult? {
        guard let data = try? Data(contentsOf: resultURL) else { return nil }
        return try? JSONDecoder().decode(AppUpdateInstallResult.self, from: data)
    }

    public static func recordResult(_ result: AppUpdateInstallResult) throws {
        try FileManager.default.createDirectory(at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(result).write(to: resultURL, options: .atomic)
    }

    /// Called once by the newly launched app after AppKit finished launching.
    /// Arguments come from our update helper, never from release notes or ZIP
    /// contents. A normal launch leaves the filesystem untouched.
    public static func signalLaunchReady() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--pmui-update-handshake"),
              index + 2 < arguments.count,
              UUID(uuidString: arguments[index + 2]) != nil else { return }
        let marker = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        let work = marker.deletingLastPathComponent()
        let appParent = Bundle.main.bundleURL.standardizedFileURL.deletingLastPathComponent()
        guard marker.lastPathComponent == "launch-ready",
              work.lastPathComponent.hasPrefix(".ProxmarkUI-update-"),
              work.deletingLastPathComponent() == appParent,
              work.resolvingSymlinksInPath() == work else { return }
        let value = "\(arguments[index + 2]):\(ProcessInfo.processInfo.processIdentifier)"
        try? Data(value.utf8).write(to: marker, options: .atomic)
    }

    /// Calculates exact install and recovery paths before the user approves.
    /// A user-writable installed app is required; no privilege escalation occurs.
    public static func installationPlan(for currentBundle: URL) throws -> AppUpdateInstallPlan {
        let destination = currentBundle.standardizedFileURL
        let path = destination.path
        guard destination.lastPathComponent == "ProxmarkUI.app",
              !path.contains("/AppTranslocation/"),
              destination.resolvingSymlinksInPath().path == path,
              bundleInfo(at: destination)?.identifier == bundleIdentifier else {
            throw AppUpdateInstallError.invalidDestination
        }
        guard FileManager.default.isExecutableFile(atPath: destination.appendingPathComponent("Contents/Resources/ProxmarkUIUpdater").path) else {
            throw AppUpdateInstallError.missingHelper
        }
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw AppUpdateInstallError.unwritableDestination
        }
        let identifier = UUID().uuidString
        return AppUpdateInstallPlan(
            destination: destination,
            backup: parent.appendingPathComponent(".ProxmarkUI-backup-\(identifier).app", isDirectory: true),
            workDirectory: parent.appendingPathComponent(".ProxmarkUI-update-\(identifier)", isDirectory: true)
        )
    }

    /// Stages and validates the app, starts an external helper, then returns.
    /// The caller must promptly terminate the current app after `.readyToQuit`.
    /// The helper waits for this process to exit before changing the bundle.
    @discardableResult
    public static func install(
        _ update: AppUpdate,
        plan: AppUpdateInstallPlan,
        session: URLSession = .shared,
        progress: @escaping @Sendable (AppUpdateProgress) -> Void = { _ in }
    ) async throws -> AppUpdateInstallPlan {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: plan.workDirectory.path),
              !fm.fileExists(atPath: plan.backup.path),
              let installed = bundleInfo(at: plan.destination),
              installed.identifier == bundleIdentifier,
              let installedVersion = AppVersion(installed.version),
              update.version > installedVersion else {
            throw AppUpdateInstallError.invalidDestination
        }
        try fm.createDirectory(at: plan.workDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var helperStarted = false
        defer {
            if !helperStarted { try? fm.removeItem(at: plan.workDirectory) }
        }

        progress(.downloading)
        let zip = try await AppUpdateService.download(update, toDirectory: plan.workDirectory, session: session)
        progress(.verifying)
        guard try AppUpdateService.sha256(of: zip) == update.sha256 else {
            throw AppUpdateError.incorrectDigest
        }
        try ReleaseZIPValidator.validate(zip)

        progress(.staging)
        let extracted = plan.workDirectory.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: false)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
        let topLevel = try fm.contentsOfDirectory(atPath: extracted.path)
        guard topLevel.allSatisfy({ $0 == "ProxmarkUI.app" || $0 == "__MACOSX" }) else {
            throw AppUpdateInstallError.invalidArchive
        }
        let stagedApp = extracted.appendingPathComponent("ProxmarkUI.app", isDirectory: true)
        try validateBundle(at: stagedApp, version: update.version.description)

        let sourceHelper = plan.destination.appendingPathComponent("Contents/Resources/ProxmarkUIUpdater")
        guard fm.isExecutableFile(atPath: sourceHelper.path) else { throw AppUpdateInstallError.missingHelper }
        let helper = plan.workDirectory.appendingPathComponent("ProxmarkUIUpdater")
        try fm.copyItem(at: sourceHelper, to: helper)
        let process = Process()
        process.executableURL = helper
        process.arguments = [
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
            "--destination", plan.destination.path,
            "--staged-app", stagedApp.path,
            "--backup", plan.backup.path,
            "--version", update.version.description,
            "--nonce", UUID().uuidString,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? recordResult(AppUpdateInstallResult(
            outcome: .pending, message: "Installing ProxmarkUI \(update.version) after this app quits.",
            destination: plan.destination, backup: plan.backup, version: update.version.description
        ))
        do { try process.run() } catch {
            try? recordResult(AppUpdateInstallResult(
                outcome: .failed,
                message: "The update installer could not start. The installed app was not changed.",
                destination: plan.destination, backup: plan.backup, version: update.version.description
            ))
            throw AppUpdateInstallError.helperLaunchFailed
        }
        helperStarted = true
        progress(.readyToQuit)
        return plan
    }

    @discardableResult
    public static func install(
        _ update: AppUpdate,
        currentBundle: URL,
        session: URLSession = .shared,
        progress: @escaping @Sendable (AppUpdateProgress) -> Void = { _ in }
    ) async throws -> AppUpdateInstallPlan {
        try await install(update, plan: installationPlan(for: currentBundle), session: session, progress: progress)
    }

    public static func validateBundle(at app: URL, version: String) throws {
        let fm = FileManager.default
        guard let info = bundleInfo(at: app),
              info.identifier == bundleIdentifier,
              info.version == version,
              app.lastPathComponent == "ProxmarkUI.app" else {
            throw AppUpdateInstallError.invalidBundle
        }
        let required = [
            "Contents/MacOS/ProxmarkUI",
            "Contents/Resources/ProxmarkUIUpdater",
            "Contents/Resources/pm3/bin/proxmark3",
            "Contents/Resources/pm3/share/proxmark3/dictionaries/mfc_default_keys.dic",
            "Contents/Resources/pm3/share/proxmark3/firmware/PM3EASY/fullimage.elf",
            "Contents/Resources/pm3/share/proxmark3/firmware/PM3RDV4/fullimage.elf",
        ]
        guard required.allSatisfy({ fm.fileExists(atPath: app.appendingPathComponent($0).path) }) else {
            throw AppUpdateInstallError.invalidBundle
        }
        guard let files = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw AppUpdateInstallError.invalidBundle
        }
        for case let file as URL in files {
            if (try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
                throw AppUpdateInstallError.invalidBundle
            }
        }
        for relative in ["Contents/MacOS/ProxmarkUI", "Contents/Resources/pm3/bin/proxmark3", "Contents/Resources/ProxmarkUIUpdater"] {
            let binary = app.appendingPathComponent(relative)
            guard fm.isExecutableFile(atPath: binary.path),
                  (try? output("/usr/bin/lipo", ["-archs", binary.path]).split(whereSeparator: \.isWhitespace).contains("arm64")) == true else {
                throw AppUpdateInstallError.invalidBundle
            }
        }
        do { try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) }
        catch { throw AppUpdateInstallError.invalidSignature }
    }

    private static func bundleInfo(at app: URL) -> (identifier: String, version: String)? {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              let version = plist["CFBundleShortVersionString"] as? String else { return nil }
        return (identifier, version)
    }

    private static func output(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppUpdateInstallError.invalidBundle }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppUpdateInstallError.invalidArchive }
    }
}

/// This small transaction is shared with the external helper and exercised in
/// temporary directories by tests. All three paths must already be on one
/// volume, so FileManager moves use filesystem renames.
public enum AppUpdateSwap {
    public static func replace(
        destination: URL,
        stagedApp: URL,
        backup: URL,
        launch: () throws -> Void
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path),
              fm.fileExists(atPath: stagedApp.path),
              !fm.fileExists(atPath: backup.path) else {
            throw AppUpdateInstallError.invalidDestination
        }
        try fm.moveItem(at: destination, to: backup)
        do {
            try fm.moveItem(at: stagedApp, to: destination)
            try launch()
        } catch {
            // Rename the failed new app out of the way, then restore the old
            // app. If either rename fails, the retained backup path is named
            // explicitly so the user can recover it in Finder.
            do {
                if fm.fileExists(atPath: destination.path) {
                    let failed = stagedApp.deletingLastPathComponent()
                        .appendingPathComponent("failed-\(UUID().uuidString).app")
                    try fm.moveItem(at: destination, to: failed)
                }
                if fm.fileExists(atPath: backup.path) {
                    try fm.moveItem(at: backup, to: destination)
                }
            } catch {
                throw AppUpdateInstallError.rollbackFailed(backup)
            }
            throw error
        }
    }
}
