import Foundation

/// The outcome of one run of the `proxmark3` client.
public struct Pm3Result: Sendable {
    public let output: String
    public let status: Int32
    public let timedOut: Bool

    public var succeeded: Bool { status == 0 && !timedOut }
}

public enum Ansi {
    /// The client colours its output even through a pipe on some builds.
    public static func strip(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }
}

/// Finds the client binary and the serial ports a Proxmark can be on.
public enum Pm3Locator {
    /// Where ProxmarkUI keeps its own state (dumps, a client it built). No
    /// spaces in the path: the client's command parser splits on them.
    public static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".proxmark3/ui", isDirectory: true)
    }

    public static var dumpsDirectory: URL {
        homeDirectory.appendingPathComponent("dumps", isDirectory: true)
    }

    /// The client shipped inside the .app bundle, if present. This is the
    /// normal case: a bundled client needs nothing installed, symlinked, or on
    /// PATH, and carries its own data files under `../share/proxmark3`.
    /// Layout: `ProxmarkUI.app/Contents/Resources/pm3/bin/proxmark3`.
    public static var bundledClient: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("pm3/bin/proxmark3")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public static func candidates(custom: String? = nil) -> [URL] {
        var list: [URL] = []
        // An explicit choice always wins, so a power user can point at their
        // own build.
        if let custom, !custom.isEmpty { list.append(URL(fileURLWithPath: custom)) }
        if let env = ProcessInfo.processInfo.environment["PM3_CLIENT"] {
            list.append(URL(fileURLWithPath: env))
        }
        // Then the bundled client: the default, so a fresh copy of the app
        // works with no setup at all.
        if let bundled = bundledClient { list.append(bundled) }
        // Finally, fall back to anything the user already has on the machine.
        let home = FileManager.default.homeDirectoryForCurrentUser
        list.append(homeDirectory.appendingPathComponent("proxmark3/client/proxmark3"))
        list.append(home.appendingPathComponent("proxmark3/client/proxmark3"))
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] {
            list.append(URL(fileURLWithPath: dir).appendingPathComponent("proxmark3"))
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            list.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("proxmark3"))
        }
        return list
    }

    public static func locate(custom: String? = nil) -> URL? {
        candidates(custom: custom).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// True when the resolved client is the one inside the app bundle.
    public static func isBundled(_ url: URL?) -> Bool {
        guard let url, let bundled = bundledClient else { return false }
        return url.standardizedFileURL == bundled.standardizedFileURL
    }

    /// USB-CDC ports. `cu.` rather than `tty.`: it doesn't wait for carrier.
    public static func ports() -> [String] {
        let dev = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return dev
            .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") }
            .sorted()
            .map { "/dev/" + $0 }
    }
}

/// Runs the client one command batch at a time. A fresh process per batch
/// costs about a second of connect time but means a wedged device or a
/// crashed client can never leave the app in a half-open state.
public final class Pm3Client: @unchecked Sendable {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    /// Client version string, e.g. "Iceman/master/v4.20728-...". Needs no device.
    public func version() async -> String? {
        let r = await run(port: nil, commands: [], extraArguments: ["--version"], timeout: 10)
        let text = Ansi.strip(r.output)
        return text.split(separator: "\n").map(String.init).first { $0.localizedCaseInsensitiveContains("iceman") || $0.localizedCaseInsensitiveContains("proxmark") }
    }

    public func run(
        port: String?,
        commands: [String],
        extraArguments: [String] = [],
        timeout: TimeInterval? = 90,
        workingDirectory: URL? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> Pm3Result {
        var args = ["--incognito", "-f"]
        if let port { args += ["-p", port] }
        if !commands.isEmpty { args += ["-c", commands.joined(separator: "; ")] }
        args += extraArguments
        return await runArguments(args, timeout: timeout, workingDirectory: workingDirectory, onLine: onLine)
    }

    /// Flash only the application image. The client's own flasher checks its
    /// build version and device chip type. It is deliberately never forced.
    public func flashFullImage(
        port: String,
        fullImage: URL,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Pm3Result {
        let args = try Pm3Firmware.flashArguments(port: port, fullImage: fullImage)
        // Do not terminate a process in the middle of writing flash blocks.
        let result = await runArguments(args, timeout: nil, workingDirectory: nil, onLine: onLine)
        return Pm3Result(
            output: result.output,
            status: result.succeeded && Pm3Firmware.outputIndicatesSuccess(result.output) ? 0 : -2,
            timedOut: result.timedOut
        )
    }

    private func runArguments(
        _ args: [String],
        timeout: TimeInterval?,
        workingDirectory: URL?,
        onLine: (@Sendable (String) -> Void)?
    ) async -> Pm3Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = workingDirectory ?? Pm3Locator.homeDirectory
        try? FileManager.default.createDirectory(at: process.currentDirectoryURL!, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        // Iceman uses HOME as its default dump path, even in incognito mode.
        env["HOME"] = Pm3Locator.homeDirectory.path
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let collector = Collector(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            collector.append(data)
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Pm3Result, Never>) in
            let timeoutFlag = Flag()
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                // Drain whatever was still buffered when the process exited.
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty { collector.append(rest) }
                collector.flush()
                continuation.resume(returning: Pm3Result(
                    output: Ansi.strip(collector.text),
                    status: proc.terminationStatus,
                    timedOut: timeoutFlag.value
                ))
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: Pm3Result(output: "Could not start client: \(error.localizedDescription)", status: -1, timedOut: false))
                return
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        timeoutFlag.set()
                        process.terminate()
                    }
                }
            }
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

/// Accumulates raw bytes and reports complete lines as they arrive.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var pending = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        pending += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let range = pending.range(of: "\n") {
            lines.append(String(pending[..<range.lowerBound]))
            pending.removeSubrange(..<range.upperBound)
        }
        lock.unlock()
        for line in lines { onLine?(Ansi.strip(line)) }
    }

    func flush() {
        lock.lock()
        let rest = pending
        pending = ""
        lock.unlock()
        if !rest.isEmpty { onLine?(Ansi.strip(rest)) }
    }
}
