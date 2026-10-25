import Foundation
import JTKit
import Testing
@testable import Intune_Deployer

/// tenants.json through JTKit's connections: Settings › Connections changes
/// only the name, tenant ID and client ID; the main window only the baseline.
@MainActor
@Suite("Tenant store")
struct TenantStoreTests {

    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "intune-deployer-tenant-tests/\(UUID().uuidString)")
    private var fileURL: URL { folder.appending(path: "tenants.json") }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "intune-deployer-tenant-tests-\(UUID().uuidString)"))
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func sampleProfile() -> TenantProfile {
        TenantProfile(
            id: UUID(uuidString: "E367022F-03C4-4D89-9D7F-AB0C17F1C105")!,
            displayName: "Contoso",
            clientID: "11111111-2222-3333-4444-555555555555",
            tenantID: "contoso.onmicrosoft.com",
            namingPrefix: "[CONTOSO]",
            variables: ["EnrollmentProfileName": "Corporate"],
            selectedItemIDs: ["f5295918", "07162bbc", "b905306d", "17141746"],
            assignments: ["07162bbc": .single(.allUsers)],
            defaultAssignments: [.settingsCatalog: .single(.allDevices)],
            allowGroupCreation: true,
            accountIdentifier: "uid.tid"
        )
    }

    /// Writes tenants.json as today's app does, before JTKit is involved.
    private func writeExisting(_ profiles: [TenantProfile]) throws -> Data {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)
        try data.write(to: fileURL)
        return data
    }

    private func savedProfiles() throws -> [TenantProfile] {
        try JSONDecoder().decode([TenantProfile].self, from: Data(contentsOf: fileURL))
    }

    // MARK: Format

    @Test func chosenItemsAreSavedInSortedOrder() throws {
        let items = (1...20).map { String(format: "item%02d", $0) }
        var profile = sampleProfile()
        profile.selectedItemIDs = Set(items.shuffled())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // a set comes out in no particular order; with 20 items, sorted by chance is unlikely
        let saved = try JSONSerialization.jsonObject(with: encoder.encode(profile)) as? [String: Any]
        #expect(saved?["selectedItemIDs"] as? [String] == items)

        var sameItems = profile
        sameItems.selectedItemIDs = Set(items.reversed())
        #expect(try encoder.encode(sameItems) == encoder.encode(profile))
    }

    @Test func savingWithoutChangesWritesTheSameBytes() throws {
        defer { cleanUp() }
        let original = try writeExisting([sampleProfile()])
        let tenants = TenantStore(storageURL: fileURL, defaults: try makeDefaults())

        tenants.update(tenants.profiles[0])
        #expect(try Data(contentsOf: fileURL) == original)

        try tenants.connections.save(tenants.profiles[0])
        #expect(try Data(contentsOf: fileURL) == original)
    }

    @Test func readingAndSettingTheConnectionLeavesTheProfileUnchanged() {
        var profile = sampleProfile()
        profile.connection = profile.connection
        #expect(profile == sampleProfile())
        #expect(profile.connection.service == .intune)
        #expect(profile.connection.signIn == .microsoftInteractive)
    }

    // MARK: Each side changes only its own fields

    @Test func settingsChangesOnlyTheNameAndIDs() throws {
        defer { cleanUp() }
        _ = try writeExisting([sampleProfile()])
        let tenants = TenantStore(storageURL: fileURL, defaults: try makeDefaults())
        // what the Settings editor holds: opened before the main window changed the baseline
        var draft = tenants.profiles[0]

        var ticked = tenants.profiles[0]
        ticked.selectedItemIDs.insert("aaaa0001")
        tenants.update(ticked)

        draft.displayName = "Contoso Ltd"
        draft.tenantID = "22222222-3333-4444-5555-666666666666"
        draft.clientID = "33333333-4444-5555-6666-777777777777"
        draft.namingPrefix = "[STALE]"
        try tenants.connections.save(draft)

        var expected = ticked
        expected.displayName = "Contoso Ltd"
        expected.tenantID = "22222222-3333-4444-5555-666666666666"
        expected.clientID = "33333333-4444-5555-6666-777777777777"
        #expect(try savedProfiles() == [expected])
        #expect(tenants.profiles == [expected])
    }

    @Test func theMainWindowChangesOnlyTheBaseline() throws {
        defer { cleanUp() }
        _ = try writeExisting([sampleProfile()])
        let tenants = TenantStore(storageURL: fileURL, defaults: try makeDefaults())
        // what the main window holds: read before Settings renamed the tenant
        var stale = tenants.profiles[0]

        var renamed = tenants.profiles[0]
        renamed.displayName = "Contoso Ltd"
        try tenants.connections.save(renamed)

        stale.selectedItemIDs = ["aaaa0001"]
        stale.accountIdentifier = "other.account"
        tenants.update(stale)

        var expected = renamed
        expected.selectedItemIDs = ["aaaa0001"]
        expected.accountIdentifier = "other.account"
        #expect(try savedProfiles() == [expected])
        #expect(tenants.saveError == nil)
    }

    @Test func addingAndDeletingInSettingsKeepTheOtherProfiles() throws {
        defer { cleanUp() }
        _ = try writeExisting([sampleProfile()])
        let tenants = TenantStore(storageURL: fileURL, defaults: try makeDefaults())

        let added = TenantProfile(displayName: "New tenant")
        try tenants.connections.save(added)
        #expect(try savedProfiles() == [sampleProfile(), added])

        try tenants.connections.delete(id: sampleProfile().id)
        #expect(try savedProfiles() == [added])
    }

    // MARK: Safety

    @Test func theFirstSaveBacksUpTheOriginalOnce() throws {
        defer { cleanUp() }
        let original = try writeExisting([sampleProfile()])
        let backup = fileURL.appendingPathExtension("backup")
        let tenants = TenantStore(storageURL: fileURL, defaults: try makeDefaults())

        var ticked = tenants.profiles[0]
        ticked.selectedItemIDs.insert("aaaa0001")
        tenants.update(ticked)
        #expect(try Data(contentsOf: backup) == original)

        var renamed = tenants.profiles[0]
        renamed.displayName = "Contoso Ltd"
        try tenants.connections.save(renamed)
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test func anUnreadableFileIsKeptAndNeverSavedOver() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let damaged = Data("[{\"id\": \"not a profile\"".utf8)
        try damaged.write(to: fileURL)

        let tenants = TenantStore(storageURL: fileURL, defaults: try makeDefaults())
        #expect(tenants.connections.problem != nil)
        #expect(tenants.profiles.isEmpty)

        tenants.update(sampleProfile())
        #expect(tenants.saveError != nil)
        #expect(throws: (any Error).self) { try tenants.connections.save(TenantProfile(displayName: "New tenant")) }
        #expect(try Data(contentsOf: fileURL) == damaged)
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path())
        #expect(copies.contains { $0.hasPrefix("tenants.json.unreadable-") })
    }

    // MARK: Selection

    @Test func theTenantInUseKeepsItsKey() throws {
        defer { cleanUp() }
        _ = try writeExisting([sampleProfile()])
        let defaults = try makeDefaults()
        defaults.set(sampleProfile().id.uuidString, forKey: "selectedTenantProfileID")

        let tenants = TenantStore(storageURL: fileURL, defaults: defaults)
        #expect(tenants.selectedProfileID == sampleProfile().id)

        let other = TenantProfile(displayName: "Fabrikam")
        try tenants.connections.save(other)
        tenants.selectedProfileID = other.id
        #expect(defaults.string(forKey: "selectedTenantProfileID") == other.id.uuidString)
    }

    @Test func aMissingTenantInUseIsNotChosen() throws {
        defer { cleanUp() }
        _ = try writeExisting([sampleProfile()])
        let defaults = try makeDefaults()
        defaults.set(UUID().uuidString, forKey: "selectedTenantProfileID")

        #expect(TenantStore(storageURL: fileURL, defaults: defaults).selectedProfileID == nil)
    }

    @Test func deletingTheTenantInUseMovesToTheNextOne() throws {
        defer { cleanUp() }
        let other = TenantProfile(displayName: "Fabrikam")
        _ = try writeExisting([sampleProfile(), other])
        let tenants = TenantStore(storageURL: fileURL, defaults: try makeDefaults())
        tenants.selectedProfileID = sampleProfile().id

        try tenants.connections.delete(id: sampleProfile().id)
        tenants.selectedProfileID = nil // as JTKit does for the deleted connection
        tenants.didDelete(sampleProfile())
        #expect(tenants.selectedProfileID == other.id)
    }

    // MARK: Import and export

    @Test func anExportImportsSignedOutAndAsANewProfileWhenAlreadyThere() throws {
        let exported = try sampleProfile().exportText()
        #expect(!exported.contains("accountIdentifier"))

        let fresh = try TenantProfile.importedProfile(from: Data(exported.utf8), existingIDs: [])
        var expected = sampleProfile()
        expected.accountIdentifier = nil
        #expect(fresh == expected)

        let again = try TenantProfile.importedProfile(from: Data(exported.utf8), existingIDs: [sampleProfile().id])
        #expect(again.id != sampleProfile().id)
        #expect(again.displayName == "Contoso (imported)")
        #expect(again.selectedItemIDs == sampleProfile().selectedItemIDs)
    }

    @Test func aFileThatIsNotAProfileIsRefused() {
        #expect(throws: TenantStoreError.self) {
            try TenantProfile.importedProfile(from: Data("{\"name\": \"x\"}".utf8), existingIDs: [])
        }
    }
}
