import CryptoKit
import Foundation

/// Published app releases are deliberately separate from reader firmware updates.
/// A new app bundle carries its own matching client and firmware images.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ value: String) {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct AppUpdate: Sendable {
    public let version: AppVersion
    public let tag: String
    public let releaseNotes: String
    public let releaseURL: URL
    public let assetURL: URL
    public let assetName: String
    public let assetSize: Int
    public let sha256: String
    public let isPrerelease: Bool
}

public enum AppUpdateError: LocalizedError {
    case invalidCurrentVersion
    case invalidResponse
    case downloadFailed
    case incorrectSize
    case incorrectDigest
    case fileAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion: "The app version could not be read."
        case .invalidResponse: "GitHub did not return a valid release response."
        case .downloadFailed: "The update could not be downloaded."
        case .incorrectSize, .incorrectDigest: "The downloaded update failed its integrity check."
        case .fileAlreadyExists: "A different file with this update name already exists in the destination."
        }
    }
}

public enum AppUpdateService {
    /// The initial public release is a prerelease. List releases rather than
    /// calling /releases/latest, which excludes prereleases.
    public static let releasesURL = URL(string: "https://api.github.com/repos/claudfuen/proxmark-ui/releases?per_page=30")!

    private struct Release: Decodable {
        let tagName: String
        let body: String?
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", body, htmlURL = "html_url", draft, prerelease, assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let state: String
        let size: Int
        let digest: String?
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, state, size, digest, browserDownloadURL = "browser_download_url"
        }
    }

    public static func checkForUpdates(
        currentVersion: String,
        includePrereleases: Bool = true,
        session: URLSession = .shared
    ) async throws -> AppUpdate? {
        guard AppVersion(currentVersion) != nil else { throw AppUpdateError.invalidCurrentVersion }
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ProxmarkUI update checker", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw AppUpdateError.invalidResponse
        }
        return try availableUpdate(from: data, currentVersion: currentVersion, includePrereleases: includePrereleases)
    }

    /// Kept pure so malformed, missing, and out-of-order releases can be tested
    /// without network access.
    public static func availableUpdate(
        from data: Data,
        currentVersion: String,
        includePrereleases: Bool = true
    ) throws -> AppUpdate? {
        guard let current = AppVersion(currentVersion) else { throw AppUpdateError.invalidCurrentVersion }
        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else {
            throw AppUpdateError.invalidResponse
        }

        return releases.compactMap { release -> AppUpdate? in
            guard !release.draft, (includePrereleases || !release.prerelease),
                  let version = AppVersion(release.tagName), version > current,
                  release.tagName == "v\(version)",
                  release.htmlURL.absoluteString == "https://github.com/claudfuen/proxmark-ui/releases/tag/\(release.tagName)" else {
                return nil
            }
            let name = "ProxmarkUI-\(release.tagName)-macos-arm64.zip"
            guard let asset = release.assets.first(where: { $0.name == name && $0.state == "uploaded" }),
                  asset.size > 0, asset.size < 1_000_000_000,
                  asset.browserDownloadURL.absoluteString == "https://github.com/claudfuen/proxmark-ui/releases/download/\(release.tagName)/\(name)",
                  let digest = asset.digest,
                  digest.hasPrefix("sha256:"),
                  digest.dropFirst(7).count == 64,
                  digest.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
                return nil
            }
            return AppUpdate(
                version: version, tag: release.tagName,
                releaseNotes: release.body ?? "", releaseURL: release.htmlURL,
                assetURL: asset.browserDownloadURL, assetName: name,
                assetSize: asset.size, sha256: String(digest.dropFirst(7)).lowercased(),
                isPrerelease: release.prerelease
            )
        }.max(by: { $0.version < $1.version })
    }

    /// Downloads a ZIP to a user-chosen directory after checking the exact
    /// GitHub release asset size and GitHub-published SHA-256 digest. It does
    /// not execute or replace a running app. Ad hoc code signing cannot prove
    /// publisher identity for unattended installation.
    public static func download(
        _ update: AppUpdate,
        toDirectory directory: URL,
        session: URLSession = .shared
    ) async throws -> URL {
        let (temporaryURL, response) = try await session.download(from: update.assetURL)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw AppUpdateError.downloadFailed
        }
        let size = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber
        guard size?.intValue == update.assetSize else { throw AppUpdateError.incorrectSize }
        guard try sha256(of: temporaryURL) == update.sha256 else { throw AppUpdateError.incorrectDigest }

        let destination = directory.appendingPathComponent(update.assetName, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try sha256(of: destination) == update.sha256 else { throw AppUpdateError.fileAlreadyExists }
            return destination
        }
        try FileManager.default.copyItem(at: temporaryURL, to: destination)
        return destination
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
            hash.update(data: block)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
