import CryptoKit
import Foundation
import XCTest
@testable import ProxmarkKit

final class AppUpdateTests: XCTestCase {
    func testSemanticVersionOrderingAndInvalidTags() {
        XCTAssertTrue(AppVersion("v1.10.0")! > AppVersion("1.9.9")!)
        XCTAssertTrue(AppVersion("1.2.1")! > AppVersion("1.2.0")!)
        XCTAssertNil(AppVersion("v1.2.3-beta"))
        XCTAssertNil(AppVersion("v1.2"))
        XCTAssertNil(AppVersion("v1.2.3/../bad"))
    }

    func testSelectsHighestCompletePublishedRelease() throws {
        let data = try payload([
            release("v0.2.0", prerelease: true),
            release("v9.0.0", draft: true),
            release("v0.4.0", digest: nil),
            release("v0.3.0", assetURL: "https://evil.example/app.zip"),
            release("v0.1.1"),
        ])
        XCTAssertEqual(try AppUpdateService.availableUpdate(from: data, currentVersion: "0.1.0")?.tag, "v0.2.0")
        XCTAssertEqual(try AppUpdateService.availableUpdate(from: data, currentVersion: "0.1.0", includePrereleases: false)?.tag, "v0.1.1")
        XCTAssertNil(try AppUpdateService.availableUpdate(from: data, currentVersion: "0.2.0"))
    }

    func testRejectsWrongReleaseAndAssetPaths() throws {
        let redirectedRelease = release("v0.2.0", releaseURL: "https://evil.example/claudfuen/proxmark-ui/releases/tag/v0.2.0")
        let pathTraversal = release("v0.2.0", assetURL: "https://github.com/claudfuen/proxmark-ui/releases/download/v0.2.0/%2e%2e/app.zip")
        XCTAssertNil(try AppUpdateService.availableUpdate(from: payload([redirectedRelease, pathTraversal]), currentVersion: "0.1.0"))
        XCTAssertThrowsError(try AppUpdateService.availableUpdate(from: Data("{}".utf8), currentVersion: "0.1.0"))
    }

    func testCheckUsesPublicGitHubAPIAndDownloadVerifiesDigest() async throws {
        let bytes = Data("small fixture ZIP content".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let releaseData = try payload([release("v0.2.0", size: bytes.count, digest: "sha256:\(digest)")])
        let session = mockSession { request in
            if request.url?.host == "api.github.com" {
                XCTAssertEqual(request.url?.path, "/repos/claudfuen/proxmark-ui/releases")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, releaseData)
            }
            XCTAssertEqual(request.url?.host, "github.com")
            return (200, bytes)
        }
        let checked = try await AppUpdateService.checkForUpdates(currentVersion: "0.1.0", session: session)
        let update = try XCTUnwrap(checked)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = try await AppUpdateService.download(update, toDirectory: directory, session: session)
        XCTAssertEqual(try Data(contentsOf: saved), bytes)
        XCTAssertEqual(saved.lastPathComponent, "ProxmarkUI-v0.2.0-macos-arm64.zip")
        let savedAgain = try await AppUpdateService.download(update, toDirectory: directory, session: session)
        XCTAssertEqual(savedAgain, saved)
    }

    func testTamperedDownloadNeverReachesDestination() async throws {
        let expected = Data("authentic".utf8)
        let actual = Data("malicious".utf8)
        XCTAssertEqual(expected.count, actual.count)
        let digest = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        let data = try payload([release("v0.2.0", size: expected.count, digest: "sha256:\(digest)")])
        let update = try XCTUnwrap(AppUpdateService.availableUpdate(from: data, currentVersion: "0.1.0"))
        let session = mockSession { _ in (200, actual) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await AppUpdateService.download(update, toDirectory: directory, session: session)
            XCTFail("A changed ZIP must be rejected")
        } catch AppUpdateError.incorrectDigest {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    private func release(
        _ tag: String,
        prerelease: Bool = false,
        draft: Bool = false,
        size: Int = 123,
        digest: String? = "sha256:" + String(repeating: "a", count: 64),
        releaseURL: String? = nil,
        assetURL: String? = nil
    ) -> [String: Any] {
        let name = "ProxmarkUI-\(tag)-macos-arm64.zip"
        var asset: [String: Any] = [
            "name": name, "state": "uploaded", "size": size,
            "browser_download_url": assetURL ?? "https://github.com/claudfuen/proxmark-ui/releases/download/\(tag)/\(name)",
        ]
        if let digest { asset["digest"] = digest }
        return [
            "tag_name": tag, "body": "Release notes", "draft": draft, "prerelease": prerelease,
            "html_url": releaseURL ?? "https://github.com/claudfuen/proxmark-ui/releases/tag/\(tag)",
            "assets": [asset],
        ]
    }

    private func payload(_ releases: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: releases)
    }

    private func mockSession(_ handler: @escaping (URLRequest) -> (Int, Data)) -> URLSession {
        MockUpdateURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockUpdateURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class MockUpdateURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else { return }
        let (status, data) = handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
