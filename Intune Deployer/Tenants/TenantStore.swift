import Foundation
import JTKit
import Observation
import OSLog
import UniformTypeIdentifiers

/// Manages tenant profiles: persistence and the current selection.
///
/// The list lives in JTKit's `ConnectionStore` (Settings › Connections, the
/// toolbar picker and the Connection menu). The two sides of a profile are
/// saved separately, so neither can overwrite the other: Settings changes only
/// the name, tenant ID and client ID; the main window (`update`) changes only
/// the baseline.
@MainActor
@Observable
final class TenantStore {
    nonisolated private static let logger = Logger(subsystem: "be.jordythery.intune-deployer", category: "TenantStore")
    static let selectionKey = "selectedTenantProfileID"

    let connections: ConnectionStore<TenantProfile>

    var profiles: [TenantProfile] { connections.records }

    var selectedProfileID: UUID? {
        didSet { saveSelection() }
    }

    var selectedProfile: TenantProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    /// Why the last change made in the main window wasn't saved.
    var saveError: String?

    @ObservationIgnored private let storage: TenantFileStorage
    @ObservationIgnored private let defaults: UserDefaults

    init(storageURL: URL? = nil, defaults: UserDefaults = .standard) {
        storage = TenantFileStorage(fileURL: storageURL ?? Self.defaultStorageURL())
        self.defaults = defaults
        connections = ConnectionStore(storage: storage, secrets: [:]) { message in
            Self.logger.error("\(message)")
        }
        if let stored = defaults.string(forKey: Self.selectionKey),
           let id = UUID(uuidString: stored),
           connections.records.contains(where: { $0.id == id }) {
            selectedProfileID = id
        }
    }

    // MARK: - Main window

    /// Saves the baseline of a profile (items, assignments, variables, naming
    /// prefix, group creation, signed-in account). Its name and IDs stay as
    /// saved in Settings.
    func update(_ profile: TenantProfile) {
        do {
            if let problem = connections.problem { throw problem }
            try storage.backUpOnce()
            try storage.saveBaseline(profile)
            saveError = nil
        } catch {
            Self.logger.error("Failed to save tenants.json: \(error.localizedDescription)")
            saveError = error.localizedDescription
        }
        connections.reload()
    }

    // MARK: - Settings › Connections

    /// After deleting the tenant in use, the next one takes over.
    func didDelete(_ profile: TenantProfile) {
        if selectedProfileID == nil || selectedProfileID == profile.id {
            selectedProfileID = profiles.first?.id
        }
    }

    /// "Import Tenant Profile…" in the + menu.
    func makeImport() -> ConnectionImport<TenantProfile> {
        ConnectionImport(title: "Import Tenant Profile…", contentTypes: [.json]) { data in
            try TenantProfile.importedProfile(from: data, existingIDs: Set(self.profiles.map(\.id)))
        }
    }

    // MARK: - Persistence

    private static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Intune Deployer", isDirectory: true)
            .appendingPathComponent("tenants.json")
    }

    private func saveSelection() {
        defaults.set(selectedProfileID?.uuidString, forKey: Self.selectionKey)
    }
}

/// tenants.json where it has always been, in its format (pretty-printed,
/// sorted keys). Each kind of save changes only its own fields of a saved
/// profile, keeping the rest as they are in the file.
@MainActor
final class TenantFileStorage: ConnectionStorage {
    private let file: JSONFileConnectionStorage<TenantProfile>

    init(fileURL: URL) {
        file = JSONFileConnectionStorage(fileURL: fileURL,
                                         format: JSONConnectionFormat(outputFormatting: [.prettyPrinted, .sortedKeys]))
    }

    var fileURL: URL { file.fileURL }

    func load() throws -> [TenantProfile] {
        try file.load()
    }

    /// From Settings › Connections: saved profiles get only their name,
    /// tenant ID and client ID from `records`; new ones (added or imported)
    /// are saved whole; profiles left out are deleted.
    func save(_ records: [TenantProfile]) throws {
        let saved = Dictionary(try file.load().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        try file.save(records.map { record in
            guard var profile = saved[record.id] else { return record }
            profile.connection = record.connection
            return profile
        })
    }

    /// From the main window: everything but the name, tenant ID and client
    /// ID, which stay as saved.
    func saveBaseline(_ profile: TenantProfile) throws {
        var profiles = try file.load()
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw TenantStoreError.notSaved(profile.displayName)
        }
        var updated = profile
        updated.connection = profiles[index].connection
        profiles[index] = updated
        try file.save(profiles)
    }

    func backUpOnce() throws {
        try file.backUpOnce()
    }

    func keepUnreadableCopy() -> String? {
        file.keepUnreadableCopy()
    }
}

nonisolated enum TenantStoreError: LocalizedError, Equatable {
    case notSaved(String)
    case notAProfile(String)

    var errorDescription: String? {
        switch self {
        case .notSaved(let name):
            "“\(name)” is no longer in the saved tenant profiles, so the change wasn't saved."
        case .notAProfile(let detail):
            "Not a valid tenant profile: \(detail)"
        }
    }
}

extension TenantProfile {
    /// A profile read from an exported file, ready to add: signed out (sign
    /// in on this Mac), and with a new id when its id is already in the list.
    static func importedProfile(from data: Data, existingIDs: Set<UUID>) throws -> TenantProfile {
        var profile: TenantProfile
        do {
            profile = try JSONDecoder().decode(TenantProfile.self, from: data)
        } catch {
            throw TenantStoreError.notAProfile(error.localizedDescription)
        }
        profile.accountIdentifier = nil
        if existingIDs.contains(profile.id) {
            profile.id = UUID()
            profile.displayName += " (imported)"
        }
        return profile
    }

    /// The profile as an export file. The MSAL account identifier is
    /// machine/account-specific and is left out.
    func exportText() throws -> String {
        var exported = self
        exported.accountIdentifier = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(exported), as: UTF8.self)
    }
}
