import AppKit
import Darwin
import Foundation
import ProxmarkKit

@main
enum ProxmarkUIUpdater {
    static func main() {
        var input: Input?
        var swapAttempted = false
        var parentExited = false
        do {
            let parsed = try parse(CommandLine.arguments.dropFirst())
            input = parsed
            try waitForExit(of: parsed.parentPID)
            parentExited = true
            try validatePaths(parsed)
            try AppUpdateInstaller.validateBundle(at: parsed.stagedApp, version: parsed.version)
            swapAttempted = true
            try AppUpdateSwap.replace(
                destination: parsed.destination,
                stagedApp: parsed.stagedApp,
                backup: parsed.backup
            ) {
                try launchAndCheck(parsed)
            }
            let result = AppUpdateInstallResult(
                outcome: .installed,
                message: "ProxmarkUI \(parsed.version) launched successfully. The previous app is saved at \(parsed.backup.path).",
                destination: parsed.destination, backup: parsed.backup, version: parsed.version
            )
            try? AppUpdateInstaller.recordResult(result)
            writeStatus(result.message, beside: parsed.stagedApp)
            cleanSuccessfulStaging(beside: parsed.stagedApp)
        } catch {
            if let input {
                let fm = FileManager.default
                let originalAvailable = fm.fileExists(atPath: input.destination.path)
                let backupExists = fm.fileExists(atPath: input.backup.path)
                let stagedAvailable = fm.fileExists(atPath: input.stagedApp.path)
                let outcome: AppUpdateInstallResult.Outcome = backupExists || !originalAvailable
                    ? .recoveryRequired : (swapAttempted && !stagedAvailable ? .rolledBack : .failed)
                var message = "Update to \(input.version) failed: \(error.localizedDescription)"
                if outcome == .recoveryRequired {
                    message += " Previous app recovery copy: \(input.backup.path)."
                } else if outcome == .rolledBack {
                    message += " The previous app was restored."
                } else {
                    message += " The installed app was not changed."
                }
                let result = AppUpdateInstallResult(
                    outcome: outcome, message: message,
                    destination: input.destination, backup: input.backup, version: input.version
                )
                try? AppUpdateInstaller.recordResult(result)
                writeStatus(message, beside: input.stagedApp)
                if parentExited && originalAvailable && !backupExists {
                    do { try openApp(input.destination) }
                    catch {
                        message += " Open \(input.destination.path) manually to continue."
                        let amended = AppUpdateInstallResult(
                            outcome: outcome, message: message,
                            destination: input.destination, backup: input.backup, version: input.version
                        )
                        try? AppUpdateInstaller.recordResult(amended)
                        writeStatus(message, beside: input.stagedApp)
                    }
                }
            }
            fputs("ProxmarkUI update failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private struct Input {
        let parentPID: pid_t
        let destination: URL
        let stagedApp: URL
        let backup: URL
        let version: String
        let nonce: String

        var marker: URL {
            stagedApp.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("launch-ready")
        }
    }

    private static func parse(_ arguments: ArraySlice<String>) throws -> Input {
        let values = Array(arguments)
        guard values.count == 12 else { throw AppUpdateInstallError.invalidDestination }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: values.count, by: 2) {
            guard options[values[index]] == nil else { throw AppUpdateInstallError.invalidDestination }
            options[values[index]] = values[index + 1]
        }
        guard let rawPID = options["--parent-pid"], let pid = pid_t(rawPID), pid > 1,
              let destination = options["--destination"],
              let staged = options["--staged-app"],
              let backup = options["--backup"],
              let version = options["--version"], AppVersion(version) != nil,
              let nonce = options["--nonce"], UUID(uuidString: nonce) != nil,
              options.count == 6 else {
            throw AppUpdateInstallError.invalidDestination
        }
        return Input(
            parentPID: pid,
            destination: URL(fileURLWithPath: destination, isDirectory: true).standardizedFileURL,
            stagedApp: URL(fileURLWithPath: staged, isDirectory: true).standardizedFileURL,
            backup: URL(fileURLWithPath: backup, isDirectory: true).standardizedFileURL,
            version: version,
            nonce: nonce
        )
    }

    private static func waitForExit(of pid: pid_t) throws {
        for _ in 0..<180 {
            if kill(pid, 0) != 0 && errno == ESRCH { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw AppUpdateInstallError.helperLaunchFailed
    }

    private static func validatePaths(_ input: Input) throws {
        let parent = input.destination.deletingLastPathComponent()
        let work = input.stagedApp.deletingLastPathComponent().deletingLastPathComponent()
        guard input.destination.lastPathComponent == "ProxmarkUI.app",
              input.stagedApp.lastPathComponent == "ProxmarkUI.app",
              input.stagedApp.deletingLastPathComponent().lastPathComponent == "extracted",
              work.deletingLastPathComponent() == parent,
              work.lastPathComponent.hasPrefix(".ProxmarkUI-update-"),
              input.backup.deletingLastPathComponent() == parent,
              input.backup.lastPathComponent.hasPrefix(".ProxmarkUI-backup-"),
              input.backup.pathExtension == "app",
              !input.destination.path.contains("/AppTranslocation/"),
              input.destination.resolvingSymlinksInPath() == input.destination,
              input.stagedApp.resolvingSymlinksInPath() == input.stagedApp else {
            throw AppUpdateInstallError.invalidDestination
        }
    }

    private static func launchAndCheck(_ input: Input) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-a", input.destination.path, "--args",
                             "--pmui-update-handshake", input.marker.path, input.nonce]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppUpdateInstallError.launchNotConfirmed }

        #if DEBUG
        let attempts = ProcessInfo.processInfo.environment["PMUI_UPDATE_TEST_HANDSHAKE_ATTEMPTS"]
            .flatMap(Int.init).map { min(max($0, 1), 120) } ?? 120
        #else
        let attempts = 120
        #endif
        for _ in 0..<attempts {
            if let marker = try? String(contentsOf: input.marker, encoding: .utf8),
               let pid = markerPID(marker, nonce: input.nonce), isAlive(pid) {
                Thread.sleep(forTimeInterval: 2)
                guard isAlive(pid) else { break }
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        terminateFailedLaunch(at: input.destination)
        throw AppUpdateInstallError.launchNotConfirmed
    }

    private static func markerPID(_ text: String, nonce: String) -> pid_t? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == nonce, let pid = pid_t(parts[1]), pid > 1 else { return nil }
        return pid
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private static func terminateFailedLaunch(at app: URL) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: AppUpdateInstaller.bundleIdentifier)
            .filter { $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }
        for application in running {
            application.terminate()
            for _ in 0..<20 where !application.isTerminated {
                Thread.sleep(forTimeInterval: 0.25)
            }
            if !application.isTerminated { application.forceTerminate() }
        }
    }

    private static func openApp(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-a", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppUpdateInstallError.helperLaunchFailed }
    }

    private static func writeStatus(_ message: String, beside stagedApp: URL) {
        let work = stagedApp.deletingLastPathComponent().deletingLastPathComponent()
        try? message.write(to: work.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }

    private static func cleanSuccessfulStaging(beside stagedApp: URL) {
        let fm = FileManager.default
        let work = stagedApp.deletingLastPathComponent().deletingLastPathComponent()
        for file in (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "zip" {
            try? fm.removeItem(at: file)
        }
        try? fm.removeItem(at: stagedApp.deletingLastPathComponent())
    }
}
