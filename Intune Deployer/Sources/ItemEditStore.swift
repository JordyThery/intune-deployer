import CryptoKit
import Foundation
import Observation
import OSLog

/// One in-app content override for a source item. The source file is never
/// written — the edit deploys instead of the file until it is reverted or
/// the source catches up (then it clears itself).
nonisolated struct ItemEdit: Codable, Sendable, Hashable {
    /// Item identity short ID (sourceID + relative path) — unchanged by the
    /// edit, so the tenant object keeps its identity tag.
    let itemID: String
    let sourceID: UUID
    let relativePath: String
    var content: Data
    /// SHA-256 (hex) of the source file at the time of the last save, used
    /// to detect upstream changes on rescan.
    var baseContentHash: String
    var modified: Date
    /// Set when the source file changed since the edit was saved.
    var hasConflict: Bool = false
}

/// Validation shared by the editor UI and tests: an edit must stay parseable
/// and must not change the detected item type (that would move the object to
/// a different Graph collection while keeping its identity tag).
nonisolated enum ItemEditValidation {
    static let maxSize = 2 * 1024 * 1024

    enum Outcome: Equatable {
        case valid(Data)
        case invalid(String)
    }

    static func validate(text: String, for item: InferredItem) -> Outcome {
        let data = Data(text.utf8)
        guard data.count <= maxSize else {
            return .invalid("The edited content is larger than 2 MB — edit the source file directly instead.")
        }
        switch InferenceEngine.classify(data: data, url: item.fileURL, relativePath: item.relativePath, sourceID: item.sourceID) {
        case .item(let edited):
            guard edited.type == item.type else {
                return .invalid("The edit changes the detected type from \(item.type.displayName) to \(edited.type.displayName). Create a new file for that instead.")
            }
            return .valid(data)
        case .skip(let reason):
            return .invalid("The edited content is no longer a valid \(item.type.displayName): \(reason)")
        }
    }
}

/// App-wide store of in-app item edits, persisted in Application Support.
@MainActor
@Observable
final class ItemEditStore {
    private static let logger = Logger(subsystem: "be.jordythery.intune-deployer", category: "ItemEditStore")

    private(set) var edits: [String: ItemEdit] = [:]
    private let storageURL: URL

    init(storageURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intune Deployer", isDirectory: true)
        self.storageURL = storageURL ?? base.appendingPathComponent("item-edits.json")
        load()
    }

    func edit(for itemID: String) -> ItemEdit? {
        edits[itemID]
    }

    /// Edited content for an item, nil when the item is unedited.
    func contentOverride(for itemID: String) -> Data? {
        edits[itemID]?.content
    }

    /// Edited contents per relative path for one source — the overlay the
    /// inference scan applies.
    func overrides(forSource sourceID: UUID) -> [String: Data] {
        var result: [String: Data] = [:]
        for edit in edits.values where edit.sourceID == sourceID {
            result[edit.relativePath] = edit.content
        }
        return result
    }

    func save(_ edit: ItemEdit) {
        edits[edit.itemID] = edit
        persist()
    }

    /// Removes the edit; the source file deploys again.
    func revert(itemID: String) {
        edits[itemID] = nil
        persist()
    }

    /// Drops every edit of a removed source.
    func removeAll(forSource sourceID: UUID) {
        let before = edits.count
        edits = edits.filter { $0.value.sourceID != sourceID }
        if edits.count != before { persist() }
    }

    /// Resolves a conflict by keeping the edit: the changed source content
    /// becomes the new base, so the conflict clears until the next change.
    func keepDespiteConflict(itemID: String, currentOriginal: Data) {
        guard var edit = edits[itemID] else { return }
        edit.baseContentHash = Self.hash(currentOriginal)
        edit.hasConflict = false
        edits[itemID] = edit
        persist()
    }

    /// Reconciles this source's edits against the current file contents
    /// (keyed by relative path; a missing path means the file is gone):
    /// - file gone → edit removed
    /// - file now equals the edit → edit cleared (the source caught up)
    /// - file unchanged since the edit → kept
    /// - file changed differently → kept, flagged as a conflict
    ///
    /// `consideredPaths` is the scan's override snapshot: edits saved while
    /// the scan was running are not part of it and must not be touched (a
    /// stale scan would otherwise mistake them for deleted files).
    func reconcile(sourceID: UUID, originalContents: [String: Data], consideredPaths: Set<String>) {
        var changed = false
        for (id, edit) in edits
        where edit.sourceID == sourceID && consideredPaths.contains(edit.relativePath) {
            guard let original = originalContents[edit.relativePath] else {
                edits[id] = nil
                changed = true
                continue
            }
            if original == edit.content {
                edits[id] = nil
                changed = true
                continue
            }
            let conflict = Self.hash(original) != edit.baseContentHash
            if conflict != edit.hasConflict {
                edits[id]?.hasConflict = conflict
                changed = true
            }
        }
        if changed { persist() }
    }

    nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        do {
            let list = try JSONDecoder().decode([ItemEdit].self, from: data)
            // Duplicate IDs (hand-edited file) must not crash the launch.
            edits = Dictionary(list.map { ($0.itemID, $0) }, uniquingKeysWith: { _, newer in newer })
        } catch {
            Self.logger.error("Failed to decode item-edits.json: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(edits.values.sorted { $0.itemID < $1.itemID }).write(to: storageURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save item-edits.json: \(error.localizedDescription)")
        }
    }
}
