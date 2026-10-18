import Foundation
import ProxmarkKit

/// The store for saved identity tags, kept separate from the dump library in
/// AppModel so it owns no business logic and can't collide with reader state.
/// Persists one JSON file per tag under ~/.proxmark3/ui/saved-tags.
@MainActor
final class TagLibrary: ObservableObject {
    @Published private(set) var tags: [SavedTag] = []

    private let directory: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(directory: URL = Pm3Locator.homeDirectory.appendingPathComponent("saved-tags", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if TagLibrary.isDemo { tags = TagLibrary.demoTags; return }
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        tags = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SavedTag.self, from: Data(contentsOf: $0)) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    /// True when this scan is already saved as an identity tag, so Scan can show
    /// "Saved" instead of offering to add it twice.
    func contains(_ scan: ScanResult) -> Bool {
        tags.contains { $0.uid == scan.uid && $0.kind == scan.kind }
    }

    @discardableResult
    func add(_ scan: ScanResult, name: String) -> SavedTag? {
        guard let tag = SavedTag(from: scan, name: name.isEmpty ? scan.kind : name) else { return nil }
        guard persist(tag) else { return nil }
        tags.insert(tag, at: 0)
        return tag
    }

    func rename(_ tag: SavedTag, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = tags.firstIndex(of: tag) else { return }
        var updated = tag
        updated.name = trimmed
        guard persist(updated) else { return }
        tags[i] = updated
    }

    func delete(_ tag: SavedTag) {
        try? FileManager.default.removeItem(at: fileURL(for: tag))
        tags.removeAll { $0.id == tag.id }
    }

    // MARK: Persistence

    private func fileURL(for tag: SavedTag) -> URL {
        directory.appendingPathComponent("\(tag.id.uuidString).json")
    }

    @discardableResult
    private func persist(_ tag: SavedTag) -> Bool {
        guard !TagLibrary.isDemo else { return true }
        do {
            try encoder.encode(tag).write(to: fileURL(for: tag), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: Demo

    static var isDemo: Bool { ProcessInfo.processInfo.environment["PMUI_DEMO"] != nil }

    static let demoTags: [SavedTag] = {
        func make(_ name: String, _ kind: String, _ uid: String, _ family: TagFamily, _ details: [Detail], _ write: SavedTag.WriteSpec, _ ago: TimeInterval) -> SavedTag {
            var t = SavedTag(from: ScanResult(family: family, kind: kind, uid: uid, details: details, raw: ""), name: name)!
            t = SavedTag(id: t.id, name: name, kind: kind, uid: uid, family: family, details: details, write: write, savedAt: Date().addingTimeInterval(-ago))
            return t
        }
        return [
            make("Front door fob", "EM410x", "0F0368568B", .lf, [], .em410x(id: "0F0368568B"), 900),
            make("Office badge", "HID Prox H10301", "2004720AE7", .lf,
                 [Detail("Format", "H10301"), Detail("Facility code", "57"), Detail("Card number", "627")],
                 .hid(facility: "57", card: "627"), 7200),
        ]
    }()
}

private extension SavedTag {
    /// Full initializer, used only to build fixed demo records.
    init(id: UUID, name: String, kind: String, uid: String, family: TagFamily, details: [Detail], write: WriteSpec, savedAt: Date) {
        self.id = id
        self.name = name
        self.kind = kind
        self.uid = uid
        self.family = family
        self.details = details
        self.write = write
        self.savedAt = savedAt
    }
}
