import Foundation
import JTKit
import Observation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Manages tenant profiles: persistence and the current selection.
///
/// The list lives in JTKit's `ConnectionStore` (Settings › Connections, the
/// toolbar picker and the Connection menu). The two sides of a profile are
/// saved separately, so neither can overwrite the other: Settings changes only
/// the name, tenant ID and client ID; the main window (`update`) changes only
/// the baseline.
///
/// In demo mode the tenant in use is "Contoso Intune (Demo)" (`demoProfile`):
/// its baseline lives in memory for the launch and is never saved, and the
/// saved tenants and the one in use (`selectedProfileID`) stay as they are.
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

    /// The tenant in use: the demo tenant while demo mode is on, else the
    /// saved one chosen in the toolbar.
    var selectedProfile: TenantProfile? {
        if isDemoActive { return demoProfile }
        return profiles.first { $0.id == selectedProfileID }
    }

    /// A tenant by ID: a saved one, or the demo tenant.
    func profile(id: UUID) -> TenantProfile? {
        if id == demoProfile.id { return demo == nil ? nil : demoProfile }
        return profiles.first { $0.id == id }
    }

    // MARK: - Demo mode

    /// The app's demo mode; nil without demo mode (tests, previews).
    let demo: DemoMode?
    /// The demo tenant for the picker and the Connection menu.
    let demoChoice: DemoConnectionChoice?
    /// "Contoso Intune (Demo)", with the baseline chosen in demo mode. In
    /// memory only, new each launch.
    private(set) var demoProfile = TenantProfile.demo

    var isDemoActive: Bool { demo?.isOn == true }

    /// The picker's, the Connection menu's and Settings' role: the saved
    /// tenant in use, or in demo mode the demo tenant. Choosing a saved
    /// tenant leaves demo mode. While `isBusy` (a Plan, Apply or Remove
    /// Baseline runs) the tenant in use doesn't change, so the run keeps
    /// its results.
    func connectionRole(lockedWhile isBusy: @escaping @MainActor () -> Bool) -> ConnectionRole {
        .active(selection: Binding(get: { self.selectedProfileID },
                                   set: { if !isBusy() { self.selectedProfileID = $0 } }),
                demo: demoChoice)
    }

    /// Why the last change made in the main window wasn't saved.
    var saveError: String?

    @ObservationIgnored private let storage: TenantFileStorage
    @ObservationIgnored private let defaults: UserDefaults

    /// - Parameter demo: the app's demo mode; nil without demo mode.
    init(storageURL: URL? = nil, defaults: UserDefaults = .standard, demo: DemoMode? = nil) {
        storage = TenantFileStorage(fileURL: storageURL ?? Self.defaultStorageURL())
        self.defaults = defaults
        self.demo = demo
        demoChoice = demo.map { DemoConnectionChoice(mode: $0, connections: [.demoIntune]) }
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
        // The demo tenant's baseline stays in memory; tenants.json is never touched.
        if profile.id == demoProfile.id {
            var updated = profile
            updated.connection = demoProfile.connection
            updated.accountIdentifier = nil
            demoProfile = updated
            saveError = nil
            return
        }
        guard !profile.connection.isDemo else {
            saveError = TenantStoreError.demoProfile(profile.displayName).localizedDescription
            return
        }
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

    /// The other saved profiles whose naming prefix is this one (trimmed,
    /// ignoring case); none for an empty prefix. Objects deployed before
    /// profile tags are matched to a profile by this prefix, so two profiles
    /// sharing it could both claim them (Baseline Settings warns).
    func profiles(sharingPrefix prefix: String, besides profileID: UUID) -> [TenantProfile] {
        let wanted = prefix.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return [] }
        return profiles.filter {
            $0.id != profileID
                && $0.namingPrefix.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(wanted) == .orderedSame
        }
    }

    /// Whether no other saved profile is for this profile's tenant. Only
    /// then does a profile without a naming prefix claim objects deployed
    /// before profile tags. Tenants are compared by the tenant ID Microsoft's
    /// sign-in named (`knownTenantID`, JTKit's `EntraTenant.isSame`), so a
    /// profile with the tenant's domain and one with its tenant ID are the
    /// same tenant. As this decides what may be deleted, an unknown counts
    /// as the same tenant: this profile's own tenant ID must be known (Plan
    /// and Remove Baseline ask after their tenant check), and another
    /// profile with a domain that never signed in counts as possibly this
    /// tenant. Profiles with an empty tenant field don't count. The demo
    /// tenant is the only one for its tenant.
    func isOnlyProfile(forTenantOf profile: TenantProfile) -> Bool {
        if profile.id == demoProfile.id { return true }
        let current = profiles.first { $0.id == profile.id } ?? profile
        guard let tenant = current.knownTenantID ?? profile.knownTenantID else { return false }
        return !profiles.contains { other in
            guard other.id != profile.id, !other.typedTenant.isEmpty else { return false }
            guard let otherTenant = other.knownTenantID else {
                // a domain never signed in: possibly this tenant
                return true
            }
            return EntraTenant.isSame(typed: profile.typedTenant, signedIn: tenant, as: other.typedTenant, signedIn: otherTenant)
        }
    }

    /// Remembers the tenant ID Microsoft's sign-in named for a profile's
    /// tenant field (see `TenantProfile.signedInTenant`); saved only when
    /// it's new. Not for the demo tenant, and never in demo mode's memory.
    func noteSignedInTenant(_ tenantID: String, for profileID: UUID, typed: String) {
        let id = tenantID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty, profileID != demoProfile.id,
              var profile = profiles.first(where: { $0.id == profileID }), !profile.isDemo,
              profile.typedTenant == typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return }
        let learned = TenantProfile.SignedInTenant(typed: profile.typedTenant, id: id)
        guard profile.signedInTenant != learned else { return }
        profile.signedInTenant = learned
        update(profile)
    }

    /// "Import Tenant Profile…" in the + menu. `adopt` gets the profile and
    /// the identities of the sources it was exported with
    /// (`SourceStore.adopt`), so its items keep their IDs on this Mac.
    func makeImport(adopt: @escaping @MainActor (TenantProfile, [SourceIdentity]) -> TenantProfile = { profile, _ in profile })
        -> ConnectionImport<TenantProfile> {
        ConnectionImport(title: "Import Tenant Profile…", contentTypes: [.json]) { data in
            let profile = try TenantProfile.importedProfile(from: data, existingIDs: Set(self.profiles.map(\.id)))
            return adopt(profile, TenantProfile.exportedIdentities(in: data))
        }
    }

    // MARK: - Persistence

    private static func defaultStorageURL() -> URL {
        // Application Support/Intune Deployer; under the unit tests a temporary folder.
        UnderTest.dataFolder.appendingPathComponent("tenants.json")
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
    case demoProfile(String)

    var errorDescription: String? {
        switch self {
        case .notSaved(let name):
            "“\(name)” is no longer in the saved tenant profiles, so the change wasn’t saved."
        case .notAProfile(let detail):
            "Not a valid tenant profile: \(detail)"
        case .demoProfile(let name):
            "“\(name)” is a demo tenant profile. Demo tenants live in Demo Mode only and are never added to your tenant profiles."
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
        // An exported demo tenant, whatever its ID: never added to the real list.
        guard !profile.connection.isDemo else {
            throw TenantStoreError.demoProfile(profile.displayName)
        }
        profile.accountIdentifier = nil
        profile.signedInTenant = nil
        if existingIDs.contains(profile.id) {
            profile.id = UUID()
            profile.displayName += " (imported)"
        }
        return profile
    }

    /// Demo mode's tenant, "Contoso Intune (Demo)": JTKit's demo Intune
    /// connection with an empty baseline. Never saved.
    static var demo: TenantProfile {
        let connection = Connection.demoIntune
        return TenantProfile(id: connection.id, displayName: connection.name,
                             clientID: connection.clientID, tenantID: connection.tenantID)
    }

    /// The demo tenant (or an exported copy of it): signs in with demo
    /// mode's fixed token, never with MSAL, and is never saved.
    var isDemo: Bool { connection.isDemo }

    /// The profile as an export file, with the identities of the sources
    /// (`sourceIdentities`), so its items keep their IDs on another Mac. The
    /// MSAL account identifier is machine/account-specific and is left out,
    /// as is the tenant ID a sign-in named.
    func exportText(sourceIdentities: [SourceIdentity] = []) throws -> String {
        var exported = self
        exported.accountIdentifier = nil
        exported.signedInTenant = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var object = try JSONSerialization.jsonObject(with: encoder.encode(exported)) as? [String: Any] ?? [:]
        if !sourceIdentities.isEmpty {
            object[Self.sourceIdentitiesKey] = try JSONSerialization.jsonObject(with: encoder.encode(sourceIdentities))
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// The export's extra key; tenants.json never has it.
    static let sourceIdentitiesKey = "sourceIdentities"

    /// The source identities an export file carries; none in older exports.
    static func exportedIdentities(in data: Data) -> [SourceIdentity] {
        nonisolated struct Extras: Decodable { let sourceIdentities: [SourceIdentity]? }
        return (try? JSONDecoder().decode(Extras.self, from: data))?.sourceIdentities ?? []
    }
}
