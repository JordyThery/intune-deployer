import Foundation
import Testing
@testable import Intune_Deployer

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "export-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Tenant export")
struct TenantExportTests {
    private let prefix = "[LAB9]"
    private let variables = ["OrgName": "Contoso", "EnrollmentProfileName": "Contoso ADE"]

    // MARK: - Round trip

    /// Deploy a fixture (as the app would), treat the built body as the
    /// tenant object, export it, rescan the export and rebuild: the rebuilt
    /// payload must match the deployed one, so re-planning the export
    /// against that object would report no changes.
    private func assertRoundTrip(
        _ fixture: String,
        relativePath: String,
        expectedType: ItemType,
        expectedName: String,
        serverKeys: [String: Any] = ["id": "obj-1", "createdDateTime": "2026-01-01T00:00:00Z", "lastModifiedDateTime": "2026-01-02T00:00:00Z"]
    ) throws {
        // 1. Original source → deployed body.
        let source = try tempDir()
        defer { try? FileManager.default.removeItem(at: source) }
        let fileURL = source.appending(path: relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.write(to: fileURL, atomically: true, encoding: .utf8)
        let original = try #require(InferenceEngine.scan(root: source, sourceID: UUID()).items.first)
        let deployed = try PayloadBuilder.build(item: original, fileData: Data(fixture.utf8), namingPrefix: prefix, variables: variables)

        // 2. Simulate the tenant object: server keys added on top.
        var tenantObject = try #require(try JSONSerialization.jsonObject(with: deployed.body) as? [String: Any])
        for (key, value) in serverKeys { tenantObject[key] = value }
        let tenantBody = try JSONSerialization.data(withJSONObject: tenantObject)

        // 3. Export and rescan.
        let outcome = TenantExporter.export(collection: deployed.collection, body: tenantBody, namingPrefix: prefix)
        guard case .file = outcome else {
            Issue.record("Expected a file, got \(outcome)")
            return
        }
        let exportFolder = try tempDir()
        defer { try? FileManager.default.removeItem(at: exportFolder) }
        let result = try TenantSession.write([outcome], to: exportFolder)
        #expect(result.written.count == 1)
        let exported = try #require(InferenceEngine.scan(root: exportFolder, sourceID: UUID()).items.first)
        #expect(exported.type == expectedType)
        #expect(exported.displayName == expectedName)

        // 4. Rebuild and compare with the deployed body.
        let exportedData = try Data(contentsOf: exportFolder.appending(path: result.written[0]))
        let rebuilt = try PayloadBuilder.build(item: exported, fileData: exportedData, namingPrefix: prefix, variables: variables)
        let changes = try GraphDiff.changes(
            desired: rebuilt.body,
            remote: deployed.body,
            // The identity tag differs (new source), file names may too.
            ignoringKeys: ["description", "payloadFileName", "fileName"]
        )
        #expect(changes.isEmpty, "unexpected changes: \(changes)")
    }

    @Test func settingsCatalogRoundTrips() throws {
        try assertRoundTrip(Fixtures.settingsCatalogJSON, relativePath: "sc/content.json",
                            expectedType: .settingsCatalog, expectedName: "macOS - Restrictions - Content Caching")
    }

    @Test func compliancePolicyRoundTrips() throws {
        try assertRoundTrip(Fixtures.complianceJSON, relativePath: "compliance/enc.json",
                            expectedType: .compliancePolicy, expectedName: "macOS - Compliance - Encryption")
    }

    @Test func assignmentFilterRoundTrips() throws {
        try assertRoundTrip(Fixtures.assignmentFilterJSON, relativePath: "filters/ade.json",
                            expectedType: .assignmentFilter, expectedName: "macOS - ADE Enrolled")
    }

    @Test func mobileconfigRoundTrips() throws {
        // Variables were substituted on deploy; the export holds real values.
        try assertRoundTrip(Fixtures.mobileconfig, relativePath: "profiles/dock.mobileconfig",
                            expectedType: .customConfiguration, expectedName: "Dock Settings Contoso")
    }

    @Test func shellScriptRoundTripsWithDirective() throws {
        try assertRoundTrip(Fixtures.scriptWithOptionsDirective, relativePath: "scripts/greeting.sh",
                            expectedType: .shellScript, expectedName: "greeting")
    }

    @Test func customAttributeRoundTripsIntoItsFolder() throws {
        try assertRoundTrip(Fixtures.scriptWithCustomAttributeDirective, relativePath: "attributes/osversion.sh",
                            expectedType: .customAttribute, expectedName: "osversion")
    }

    // MARK: - Cleaning

    @Test func exportStripsServerKeysTagAndPrefix() throws {
        let body = Data("""
        {"@odata.type":"#microsoft.graph.macOSCompliancePolicy","@odata.context":"x","id":"abc",
         "createdDateTime":"2026-01-01T00:00:00Z","displayName":"[LAB9] Encryption",
         "description":"Baseline [IntuneDeployer:0a1b2c3d]","assignments":[{"id":"1"}],
         "scheduledActionsForRule":[{"id":"r1","ruleName":"PasswordRequired"}]}
        """.utf8)
        guard case .file(let file) = TenantExporter.export(collection: .compliancePolicies, body: body, namingPrefix: "[LAB9]") else {
            Issue.record("Expected a file")
            return
        }
        let dict = try #require(try JSONSerialization.jsonObject(with: file.contents) as? [String: Any])
        #expect(dict["displayName"] as? String == "Encryption")
        #expect(dict["description"] as? String == "Baseline")
        #expect(dict["id"] == nil && dict["@odata.context"] == nil && dict["createdDateTime"] == nil && dict["assignments"] == nil)
        let rules = try #require(dict["scheduledActionsForRule"] as? [[String: Any]])
        #expect(rules.first?["id"] == nil)
        #expect(file.folder == "macOS/Compliance")
        #expect(file.baseName == "Encryption")

        // The placeholder description written for empty ones disappears.
        #expect(TenantExporter.cleanedDescription("Managed by Intune Deployer [IntuneDeployer:0a1b2c3d]") == nil)
        #expect(TenantExporter.cleanedDescription("Legacy [gw:0a1b2c3d]") == "Legacy")
        // Only an exact "prefix + space" is removed.
        #expect(TenantExporter.unprefixed("[LAB9]Name", prefix: "[LAB9]") == "[LAB9]Name")
        #expect(TenantExporter.unprefixed("Name", prefix: "") == "Name")
    }

    @Test func unsupportedObjectsAreSkippedWithReasons() {
        func skipped(_ collection: TenantCollection, _ json: String) -> Bool {
            if case .skipped = TenantExporter.export(collection: collection, body: Data(json.utf8), namingPrefix: "") { return true }
            return false
        }
        #expect(skipped(.compliancePolicies, Fixtures.windowsComplianceJSON))
        #expect(skipped(.deviceConfigurations, ##"{"@odata.type":"#microsoft.graph.macOSGeneralDeviceConfiguration","displayName":"General"}"##))
        #expect(skipped(.settingsCatalog, #"{"name":"Win","platforms":"windows10","technologies":"mdm","settings":[]}"#))
        #expect(skipped(.settingsCatalog, #"{"name":"No settings fetched","platforms":"macOS","technologies":"mdm"}"#))
        #expect(skipped(.assignmentFilters, #"{"displayName":"Win","platform":"windows10AndLater","rule":"x"}"#))
        #expect(skipped(.shellScripts, #"{"displayName":"Empty"}"#))
        #expect(skipped(.apps, #"{"displayName":"Some.pkg"}"#))
    }

    // MARK: - Scripts

    @Test func directiveReplacesExistingOneAfterShebang() {
        let text = "#!/bin/zsh\n# intune: runAsAccount=system\necho hi\n"
        let result = TenantExporter.withDirective("# intune: runAsAccount=user", in: text)
        #expect(result == "#!/bin/zsh\n# intune: runAsAccount=user\necho hi\n")
        // No shebang → directive goes first.
        #expect(TenantExporter.withDirective("# intune: x=1", in: "echo hi") == "# intune: x=1\necho hi")
    }

    @Test func isoDurationsConvertToMinutes() {
        #expect(TenantExporter.minutes(fromISODuration: "P1D") == 1440)
        #expect(TenantExporter.minutes(fromISODuration: "PT3H") == 180)
        #expect(TenantExporter.minutes(fromISODuration: "PT45M") == 45)
        #expect(TenantExporter.minutes(fromISODuration: "P1DT2H") == 1560)
        #expect(TenantExporter.minutes(fromISODuration: "PT1440M") == 1440)
        #expect(TenantExporter.minutes(fromISODuration: "garbage") == nil)
        // Round trip with the deploy-side formatter.
        for minutes in [15, 60, 1440, 2880] {
            #expect(TenantExporter.minutes(fromISODuration: PayloadBuilder.isoDuration(minutes: minutes)) == minutes)
        }
    }

    // MARK: - Writing

    @Test func writeNeverOverwritesAndNumbersCollisions() throws {
        let folder = try tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "Scripts"), withIntermediateDirectories: true)
        try "existing".write(to: folder.appending(path: "Scripts/Dock.sh"), atomically: true, encoding: .utf8)

        let file = TenantExporter.ExportFile(folder: "Scripts", baseName: "Dock", fileExtension: "sh", contents: Data("new".utf8))
        let unsafe = TenantExporter.ExportFile(folder: "Scripts", baseName: "../a/b:c", fileExtension: "sh", contents: Data("x".utf8))
        let result = try TenantSession.write([.file(file), .file(file), .file(unsafe)], to: folder)

        #expect(Set(result.written) == ["Scripts/Dock (2).sh", "Scripts/Dock (3).sh", "Scripts/-a-b-c.sh"])
        #expect(try String(contentsOf: folder.appending(path: "Scripts/Dock.sh"), encoding: .utf8) == "existing")
        #expect(result.skipped.isEmpty)
    }
}
