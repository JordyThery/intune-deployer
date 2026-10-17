import Foundation
import Observation
import OSLog

/// A per-item platform choice for files that cannot state their own platform
/// (`.mobileconfig` profiles). JSON files and app packages carry their
/// platform in the content and are never overridden.
nonisolated struct PlatformOverride: Codable, Sendable, Hashable {
    /// Item identity short ID — unchanged by the override.
    let itemID: String
    let sourceID: UUID
    let relativePath: String
    var platform: ItemPlatform
}

/// App-wide store of platform overrides, persisted in Application Support —
/// the same model as in-app item edits, so overrides survive source syncs.
@MainActor
@Observable
final class PlatformOverrideStore {
    private static let logger = Logger(subsystem: "be.jordythery.intune-deployer", category: "PlatformOverrides")

    private(set) var overrides: [String: PlatformOverride] = [:]
    private let storageURL: URL

    init(storageURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intune Deployer", isDirectory: true)
        self.storageURL = storageURL ?? base.appendingPathComponent("platform-overrides.json")
        load()
    }

    func platform(for itemID: String) -> ItemPlatform? {
        overrides[itemID]?.platform
    }

    /// Platform overrides per relative path for one source — applied by the
    /// inference scan.
    func overrides(forSource sourceID: UUID) -> [String: ItemPlatform] {
        var result: [String: ItemPlatform] = [:]
        for override in overrides.values where override.sourceID == sourceID {
            result[override.relativePath] = override.platform
        }
        return result
    }

    /// Stores the platform choice for an item. The override always wins, so
    /// a profile inside the export layout's iOS folder can still be forced
    /// back to macOS.
    func set(_ platform: ItemPlatform, for item: InferredItem) {
        overrides[item.id] = PlatformOverride(
            itemID: item.id,
            sourceID: item.sourceID,
            relativePath: item.relativePath,
            platform: platform
        )
        persist()
    }

    /// Drops every override of a removed source.
    func removeAll(forSource sourceID: UUID) {
        let before = overrides.count
        overrides = overrides.filter { $0.value.sourceID != sourceID }
        if overrides.count != before { persist() }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        do {
            let list = try JSONDecoder().decode([PlatformOverride].self, from: data)
            overrides = Dictionary(list.map { ($0.itemID, $0) }, uniquingKeysWith: { _, newer in newer })
        } catch {
            Self.logger.error("Failed to decode platform-overrides.json: \(error.localizedDescription)")
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
            try encoder.encode(overrides.values.sorted { $0.itemID < $1.itemID }).write(to: storageURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save platform-overrides.json: \(error.localizedDescription)")
        }
    }
}
