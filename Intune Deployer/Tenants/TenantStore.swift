import Foundation
import Observation
import OSLog

/// Manages tenant profiles: persistence and the current selection.
@MainActor
@Observable
final class TenantStore {
    private static let logger = Logger(subsystem: "be.jordythery.intune-deployer", category: "TenantStore")

    private(set) var profiles: [TenantProfile] = []
    var selectedProfileID: UUID? {
        didSet { saveSelection() }
    }

    var selectedProfile: TenantProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    private let storageURL: URL
    private static let selectionKey = "selectedTenantProfileID"

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        load()
        if let stored = UserDefaults.standard.string(forKey: Self.selectionKey),
           let id = UUID(uuidString: stored),
           profiles.contains(where: { $0.id == id }) {
            selectedProfileID = id
        }
    }

    // MARK: - CRUD

    func add(_ profile: TenantProfile) {
        profiles.append(profile)
        selectedProfileID = profile.id
        save()
    }

    func update(_ profile: TenantProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id { selectedProfileID = profiles.first?.id }
        save()
    }

    // MARK: - Persistence

    private static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Intune Deployer", isDirectory: true)
            .appendingPathComponent("tenants.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        do {
            profiles = try JSONDecoder().decode([TenantProfile].self, from: data)
        } catch {
            Self.logger.error("Failed to decode tenants.json: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profiles).write(to: storageURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save tenants.json: \(error.localizedDescription)")
        }
    }

    private func saveSelection() {
        UserDefaults.standard.set(selectedProfileID?.uuidString, forKey: Self.selectionKey)
    }
}
