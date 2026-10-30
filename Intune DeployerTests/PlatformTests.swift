import Foundation
import Testing
@testable import Intune_Deployer

private let sourceID = UUID(uuidString: "77777777-6666-5555-4444-333333333333")!

private func makeItem(
    _ relativePath: String,
    type: ItemType,
    platform: ItemPlatform = .macOS,
    scriptSettings: ScriptSettings? = nil
) -> InferredItem {
    let url = URL(filePath: "/tmp/fixture/\(relativePath)")
    return InferredItem(
        id: ItemIdentity.shortID(sourceID: sourceID, relativePath: relativePath),
        sourceID: sourceID,
        relativePath: relativePath,
        fileURL: url,
        type: type,
        platform: platform,
        displayName: url.deletingPathExtension().lastPathComponent,
        detectionReason: "test",
        scriptSettings: scriptSettings
    )
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "platform-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeProfile(_ item: InferredItem, intent: AssignmentIntent? = nil, variables: [String: String] = [:]) -> TenantProfile {
    TenantProfile(
        displayName: "T", clientID: "e445f0a6-0000-0000-0000-000000000000", tenantID: "t",
        variables: variables,
        selectedItemIDs: [item.id],
        assignments: intent.map { [item.id: $0] } ?? [:]
    )
}

// MARK: - Platform detection

@Suite("Platform detection")
struct PlatformDetectionTests {
    @Test func jsonFilesStateTheirPlatform() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixtures.iosComplianceJSON.write(to: root.appending(path: "c.json"), atomically: true, encoding: .utf8)
        try Fixtures.iosSettingsCatalogJSON.write(to: root.appending(path: "s.json"), atomically: true, encoding: .utf8)
        try Fixtures.iosFilterJSON.write(to: root.appending(path: "f.json"), atomically: true, encoding: .utf8)
        try Fixtures.complianceJSON.write(to: root.appending(path: "mac.json"), atomically: true, encoding: .utf8)
        try Fixtures.windowsComplianceJSON.write(to: root.appending(path: "win.json"), atomically: true, encoding: .utf8)

        let result = try InferenceEngine.scan(root: root, sourceID: sourceID)
        let byPath = Dictionary(uniqueKeysWithValues: result.items.map { ($0.relativePath, $0) })
        #expect(byPath["c.json"]?.platform == .iOSiPadOS)
        #expect(byPath["c.json"]?.type == .compliancePolicy)
        #expect(byPath["s.json"]?.platform == .iOSiPadOS)
        #expect(byPath["f.json"]?.platform == .iOSiPadOS)
        #expect(byPath["mac.json"]?.platform == .macOS)
        #expect(result.skipped.map(\.relativePath) == ["win.json"])
    }

    @Test func mobileconfigDefaultsToMacOSWithOverridesAndExportFolderRule() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let iosFolder = root.appending(path: "iOS and iPadOS/Configuration Profiles")
        try FileManager.default.createDirectory(at: iosFolder, withIntermediateDirectories: true)
        try Fixtures.mobileconfig.write(to: root.appending(path: "plain.mobileconfig"), atomically: true, encoding: .utf8)
        try Fixtures.mobileconfig.write(to: root.appending(path: "overridden.mobileconfig"), atomically: true, encoding: .utf8)
        try Fixtures.mobileconfig.write(to: iosFolder.appending(path: "exported.mobileconfig"), atomically: true, encoding: .utf8)
        try Fixtures.mobileconfig.write(to: iosFolder.appending(path: "forced-mac.mobileconfig"), atomically: true, encoding: .utf8)

        let result = try InferenceEngine.scan(root: root, sourceID: sourceID, platformOverrides: [
            "overridden.mobileconfig": .iOSiPadOS,
            // The override wins even against the export folder rule.
            "iOS and iPadOS/Configuration Profiles/forced-mac.mobileconfig": .macOS,
        ])
        let byPath = Dictionary(uniqueKeysWithValues: result.items.map { ($0.relativePath, $0.platform) })
        #expect(byPath["plain.mobileconfig"] == .macOS)
        #expect(byPath["overridden.mobileconfig"] == .iOSiPadOS)
        #expect(byPath["iOS and iPadOS/Configuration Profiles/exported.mobileconfig"] == .iOSiPadOS)
        #expect(byPath["iOS and iPadOS/Configuration Profiles/forced-mac.mobileconfig"] == .macOS)
    }

    @Test @MainActor func staleOverridesAreDroppedWhenTheFileDisappears() throws {
        let store = PlatformOverrideStore(storageURL: try tempDir().appending(path: "overrides.json"))
        let item = makeItem("Profiles/vpn.mobileconfig", type: .customConfiguration)
        store.set(.iOSiPadOS, for: item)
        // File still present → kept.
        store.reconcile(sourceID: sourceID, validPaths: ["Profiles/vpn.mobileconfig"], consideredPaths: ["Profiles/vpn.mobileconfig"])
        #expect(store.overrides(forSource: sourceID).count == 1)
        // File gone → dropped (a later file at the same path starts fresh).
        store.reconcile(sourceID: sourceID, validPaths: [], consideredPaths: ["Profiles/vpn.mobileconfig"])
        #expect(store.overrides(forSource: sourceID).isEmpty)
        // Overrides outside a stale scan's snapshot are never touched.
        store.set(.iOSiPadOS, for: item)
        store.reconcile(sourceID: sourceID, validPaths: [], consideredPaths: [])
        #expect(store.overrides(forSource: sourceID).count == 1)
    }

    @Test func exportFolderRuleMatchesNestedPaths() {
        #expect(InferenceEngine.pathIsInIOSExportFolder("iOS and iPadOS/Compliance/p.json"))
        #expect(InferenceEngine.pathIsInIOSExportFolder("Exports/iOS and iPadOS/Compliance/p.json"))
        #expect(!InferenceEngine.pathIsInIOSExportFolder("Compliance/p.json"))
        #expect(!InferenceEngine.pathIsInIOSExportFolder("iOS and iPadOS.json"))
    }

    @Test func ipaFilesAreIOSApps() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fake".utf8).write(to: root.appending(path: "Tool.ipa"))
        let item = try #require(try InferenceEngine.scan(root: root, sourceID: sourceID).items.first)
        #expect(item.type == .app)
        #expect(item.platform == .iOSiPadOS)
    }
}

// MARK: - iOS payloads

@Suite("iOS payloads")
struct IOSPayloadTests {
    @Test func iosJSONPayloadsGetIOSTypes() throws {
        let compliance = makeItem("c.json", type: .compliancePolicy, platform: .iOSiPadOS)
        let complianceBody = try PayloadBuilder.build(item: compliance, fileData: Data(Fixtures.iosComplianceJSON.utf8), namingPrefix: "", variables: [:])
        let complianceDict = try #require(try JSONSerialization.jsonObject(with: complianceBody.body) as? [String: Any])
        #expect(complianceDict["@odata.type"] as? String == "#microsoft.graph.iosCompliancePolicy")

        let profile = makeItem("p.mobileconfig", type: .customConfiguration, platform: .iOSiPadOS)
        let profileBody = try PayloadBuilder.build(item: profile, fileData: Data(Fixtures.mobileconfig.utf8), namingPrefix: "", variables: ["OrgName": "Contoso"])
        let profileDict = try #require(try JSONSerialization.jsonObject(with: profileBody.body) as? [String: Any])
        #expect(profileDict["@odata.type"] as? String == "#microsoft.graph.iosCustomConfiguration")

        let catalog = makeItem("s.json", type: .settingsCatalog, platform: .iOSiPadOS)
        let catalogBody = try PayloadBuilder.build(item: catalog, fileData: Data(Fixtures.iosSettingsCatalogJSON.utf8), namingPrefix: "", variables: [:])
        let catalogDict = try #require(try JSONSerialization.jsonObject(with: catalogBody.body) as? [String: Any])
        #expect(catalogDict["platforms"] as? String == "iOS")
    }

    @Test func minimumOSKeysRoundDownToDefinedValues() {
        #expect(PayloadBuilder.iosMinimumOSKey(for: "14.2") == "v14_0")
        #expect(PayloadBuilder.iosMinimumOSKey(for: "18.0") == "v18_0")
        #expect(PayloadBuilder.iosMinimumOSKey(for: "19.0") == "v18_0")
        #expect(PayloadBuilder.iosMinimumOSKey(for: "26.1") == "v26_0")
        #expect(PayloadBuilder.iosMinimumOSKey(for: "7.0") == "v8_0")
        #expect(PayloadBuilder.iosMinimumOSKey(for: nil) == "v9_0")
    }

    @Test func expiredOrUnsignedIpaIsAPlanError() {
        let item = makeItem("Tool.ipa", type: .app, platform: .iOSiPadOS)
        var info = AppPackageInfo(primaryBundleID: "com.example.tool", primaryBundleVersion: "1.0", includedApps: [])

        // No provisioning profile (unsigned).
        #expect(throws: PayloadError.self) {
            _ = try PayloadBuilder.buildIOSApp(item: item, appInfo: info, prefix: "", tag: "[IntuneDeployer:00000000]")
        }
        // Expired profile.
        info.provisioningExpiration = Date(timeIntervalSinceNow: -86_400)
        #expect(throws: PayloadError.self) {
            _ = try PayloadBuilder.buildIOSApp(item: item, appInfo: info, prefix: "", tag: "[IntuneDeployer:00000000]")
        }
        // Expiring soon → warning, not error.
        info.provisioningExpiration = Date(timeIntervalSinceNow: 10 * 86_400)
        let built = try? PayloadBuilder.buildIOSApp(item: item, appInfo: info, prefix: "", tag: "[IntuneDeployer:00000000]")
        #expect(built?.warnings.contains { $0.contains("expires") } == true)
    }

    @Test func iosLobAppBodyCarriesVerifiedProperties() throws {
        let item = makeItem("Tool.ipa", type: .app, platform: .iOSiPadOS)
        var info = AppPackageInfo(primaryBundleID: "com.example.tool", primaryBundleVersion: "2.1", includedApps: [])
        info.buildNumber = "210"
        info.minimumOSVersion = "15.0"
        info.supportsIPhone = true
        info.supportsIPad = false
        info.provisioningExpiration = Date(timeIntervalSinceNow: 365 * 86_400)

        let built = try PayloadBuilder.buildIOSApp(item: item, appInfo: info, prefix: "[CONTOSO]", tag: "[IntuneDeployer:00000000]")
        let dict = try #require(try JSONSerialization.jsonObject(with: built.body) as? [String: Any])
        #expect(dict["@odata.type"] as? String == "#microsoft.graph.iosLobApp")
        #expect(dict["bundleId"] as? String == "com.example.tool")
        #expect(dict["versionNumber"] as? String == "2.1")
        #expect(dict["buildNumber"] as? String == "210")
        #expect((dict["expirationDateTime"] as? String)?.hasSuffix("Z") == true)
        let deviceType = try #require(dict["applicableDeviceType"] as? [String: Any])
        #expect(deviceType["iPhoneAndIPod"] as? Bool == true)
        #expect(deviceType["iPad"] as? Bool == false)
        let minOS = try #require(dict["minimumSupportedOperatingSystem"] as? [String: Any])
        #expect(minOS["v15_0"] as? Bool == true)
    }

    @Test func iosManifestSubstitutesAndEscapes() {
        let manifest = AppContentUploader.iosManifest(bundleID: "com.example.a&b", bundleVersion: "1.0", title: "A <Great> App")
        let xml = String(decoding: manifest, as: UTF8.self)
        #expect(xml.contains("<key>bundle-identifier</key><string>com.example.a&amp;b</string>"))
        #expect(xml.contains("<key>title</key><string>A &lt;Great&gt; App</string>"))
        #expect(xml.contains("{UrlPlaceHolder}"))
    }
}

// MARK: - .ipa inspection

@Suite("IPA inspection")
struct IpaInspectionTests {
    /// Builds a minimal signed-looking .ipa: Payload/Test.app with a binary
    /// Info.plist and an embedded.mobileprovision whose plist is wrapped in
    /// opaque bytes (like the real CMS envelope).
    private func makeIpa(expiration: Date?, in dir: URL) throws -> URL {
        let appDir = dir.appending(path: "stage/Payload/Test.app")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.test",
            "CFBundleShortVersionString": "3.2",
            "CFBundleVersion": "320",
            "MinimumOSVersion": "16.0",
            "UIDeviceFamily": [1, 2],
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: appDir.appending(path: "Info.plist"))
        if let expiration {
            let plist: [String: Any] = ["Name": "Test Profile", "ExpirationDate": expiration]
            let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            var blob = Data([0x30, 0x82, 0x01, 0x02]) // CMS-ish prefix
            blob.append(xml)
            blob.append(Data([0x00, 0x01, 0x02]))
            try blob.write(to: appDir.appending(path: "embedded.mobileprovision"))
        }
        let ipa = dir.appending(path: "Test.ipa")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", dir.appending(path: "stage").path, ipa.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return ipa
    }

    @Test func readsBundleInfoAndProvisioningExpiry() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let expiration = Date(timeIntervalSince1970: 1_900_000_000)
        let ipa = try makeIpa(expiration: expiration, in: dir)

        let info = try AppPackageInspector.inspect(packageAt: ipa)
        #expect(info.primaryBundleID == "com.example.test")
        #expect(info.primaryBundleVersion == "3.2")
        #expect(info.buildNumber == "320")
        #expect(info.minimumOSVersion == "16.0")
        #expect(info.supportsIPhone == true)
        #expect(info.supportsIPad == true)
        #expect(info.provisioningExpiration == expiration)
    }

    @Test func unsignedIpaHasNoExpiration() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ipa = try makeIpa(expiration: nil, in: dir)
        let info = try AppPackageInspector.inspect(packageAt: ipa)
        #expect(info.provisioningExpiration == nil)
    }
}

// MARK: - Plan: filters and install intent

@Suite("Platform plan rules")
struct PlatformPlanTests {
    private func plan(for item: InferredItem, fixture: String, intent: AssignmentIntent, variables: [String: String] = [:], existingFilters: [RemoteObject] = []) -> Plan {
        PlanEngine.makePlan(input: PlanInput(
            selectedItems: [.init(item: item, fileData: Data(fixture.utf8))],
            profile: makeProfile(item, intent: intent, variables: variables),
            existingObjects: [.assignmentFilters: existingFilters],
            groups: [:],
            knownSettingDefinitionIDs: nil
        ))
    }

    private func filterObject(name: String, platform: String) -> RemoteObject {
        RemoteObject(
            id: "f-1",
            displayName: name,
            description: nil,
            body: Data(#"{"id":"f-1","displayName":"\#(name)","platform":"\#(platform)","rule":"x"}"#.utf8)
        )
    }

    @Test func crossPlatformFilterIsAnError() {
        var intent = AssignmentIntent()
        intent.first.scope = .allDevices
        intent.first.filterName = "Mac Filter"
        let item = makeItem("c.json", type: .compliancePolicy, platform: .iOSiPadOS)
        let result = plan(for: item, fixture: Fixtures.iosComplianceJSON, intent: intent,
                          existingFilters: [filterObject(name: "Mac Filter", platform: "macOS")])
        #expect(result.hasErrors)
        #expect(result.actions.first?.assignments == nil)
    }

    @Test func matchingPlatformFilterResolves() {
        var intent = AssignmentIntent()
        intent.first.scope = .allDevices
        intent.first.filterName = "iOS Filter"
        let item = makeItem("c.json", type: .compliancePolicy, platform: .iOSiPadOS)
        let result = plan(for: item, fixture: Fixtures.iosComplianceJSON, intent: intent,
                          existingFilters: [filterObject(name: "iOS Filter", platform: "iOS")])
        #expect(!result.hasErrors)
        #expect(result.actions.first?.assignments?.first?.filter == .existing(id: "f-1"))
    }

    @Test func iosTemplateFilterIsCreatedWithIOSPlatform() {
        var intent = AssignmentIntent()
        intent.first.scope = .allDevices
        intent.first.filterName = BuiltInFilterTemplate.name(for: .iOSiPadOS)
        let item = makeItem("c.json", type: .compliancePolicy, platform: .iOSiPadOS)
        let result = plan(for: item, fixture: Fixtures.iosComplianceJSON, intent: intent,
                          variables: ["EnrollmentProfileName": "Contoso iOS"])
        #expect(!result.hasErrors)
        #expect(result.filtersToCreate.first?.platform == .iOSiPadOS)
        #expect(result.filtersToCreate.first?.rule.contains("Contoso iOS") == true)
    }

    @Test func macTemplateOnIOSItemIsAnError() {
        var intent = AssignmentIntent()
        intent.first.scope = .allDevices
        intent.first.filterName = BuiltInFilterTemplate.name(for: .macOS)
        let item = makeItem("c.json", type: .compliancePolicy, platform: .iOSiPadOS)
        let result = plan(for: item, fixture: Fixtures.iosComplianceJSON, intent: intent,
                          variables: ["EnrollmentProfileName": "Contoso"])
        #expect(result.hasErrors)
    }

    @Test func availableIntentNeedsUserAssignment() {
        var intent = AssignmentIntent()
        intent.first.appIntent = .available
        let item = makeItem("Tool.pkg", type: .app)

        intent.first.scope = .allDevices
        var result = PlanEngine.makePlan(input: PlanInput(
            selectedItems: [.init(item: item, fileData: Data(), appInfo: AppPackageInfo(primaryBundleID: "b", primaryBundleVersion: "1", includedApps: []))],
            profile: makeProfile(item, intent: intent),
            existingObjects: [:], groups: [:], knownSettingDefinitionIDs: nil
        ))
        #expect(result.hasErrors)

        intent.first.scope = .allUsers
        result = PlanEngine.makePlan(input: PlanInput(
            selectedItems: [.init(item: item, fileData: Data(), appInfo: AppPackageInfo(primaryBundleID: "b", primaryBundleVersion: "1", includedApps: []))],
            profile: makeProfile(item, intent: intent),
            existingObjects: [:], groups: [:], knownSettingDefinitionIDs: nil
        ))
        #expect(!result.hasErrors)
        #expect(result.actions.first?.assignments?.first?.appIntent == .available)
    }

    @Test func platformChangeBecomesCreatePlusOrphan() throws {
        // Graph cannot retype an object: an item that used to deploy as
        // macOSCustomConfiguration and is now iOS must plan as a create,
        // with the old object offered as an orphan.
        let item = makeItem("p.mobileconfig", type: .customConfiguration, platform: .iOSiPadOS)
        let profile = makeProfile(item, variables: ["OrgName": "Contoso"])
        let deployedAsMac = try PayloadBuilder.build(
            item: makeItem("p.mobileconfig", type: .customConfiguration, platform: .macOS),
            fileData: Data(Fixtures.mobileconfig.utf8),
            namingPrefix: "",
            variables: ["OrgName": "Contoso"],
            profileID: profile.id
        )
        let remote = RemoteObject(
            id: "obj-1",
            displayName: deployedAsMac.displayName,
            description: "x [IntuneDeployer:\(item.id)] \(ItemIdentity.profileTag(for: profile.id))",
            body: deployedAsMac.body
        )
        let result = PlanEngine.makePlan(input: PlanInput(
            selectedItems: [.init(item: item, fileData: Data(Fixtures.mobileconfig.utf8))],
            profile: profile,
            existingObjects: [.deviceConfigurations: [remote]],
            groups: [:],
            knownSettingDefinitionIDs: nil
        ))
        #expect(result.actions.first?.kind == .create)
        #expect(result.orphans.map(\.objectID) == ["obj-1"])
    }

    @Test func equalInstantsInDifferentISOFormatsAreNotChanges() throws {
        let desired = Data(#"{"expirationDateTime":"2027-06-05T12:34:56Z"}"#.utf8)
        let remote = Data(#"{"expirationDateTime":"2027-06-05T12:34:56.0000000Z","id":"x"}"#.utf8)
        #expect(try GraphDiff.changes(desired: desired, remote: remote).isEmpty)

        let changed = Data(#"{"expirationDateTime":"2028-01-01T00:00:00Z","id":"x"}"#.utf8)
        #expect(try GraphDiff.changes(desired: desired, remote: changed).count == 1)
    }

    @Test func intentsFromEarlierBuildsDecodeAsRequired() throws {
        let legacy = Data(#"{"mode":"allUsers","groupName":"","filterName":"","filterMode":"include"}"#.utf8)
        let intent = try JSONDecoder().decode(AssignmentIntent.self, from: legacy)
        #expect(intent.first.appIntent == .required)
        #expect(intent.first.scope == .allUsers)
    }
}

// MARK: - iOS export

@Suite("iOS export")
struct IOSExportTests {
    @Test func iosObjectsExportIntoTheIOSFolder() throws {
        let body = Data(Fixtures.iosComplianceJSON.utf8)
        var tenantObject = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        tenantObject["id"] = "obj-1"
        let outcome = TenantExporter.export(
            collection: .compliancePolicies,
            body: try JSONSerialization.data(withJSONObject: tenantObject),
            namingPrefix: ""
        )
        guard case .file(let file) = outcome else {
            Issue.record("Expected a file, got \(outcome)")
            return
        }
        #expect(file.folder == "iOS and iPadOS/Compliance")

        // An exported iOS profile lands where the re-import rule finds it.
        let configOutcome = TenantExporter.export(
            collection: .deviceConfigurations,
            body: Data("""
            {"@odata.type":"#microsoft.graph.iosCustomConfiguration","displayName":"Wi-Fi",
             "payload":"\(Data(Fixtures.mobileconfig.utf8).base64EncodedString())"}
            """.utf8),
            namingPrefix: ""
        )
        guard case .file(let config) = configOutcome else {
            Issue.record("Expected a file, got \(configOutcome)")
            return
        }
        #expect(config.folder == "iOS and iPadOS/Configuration Profiles")
        #expect(InferenceEngine.pathIsInIOSExportFolder("\(config.folder)/Wi-Fi.mobileconfig"))
    }

    @Test func iosComplianceRoundTripsThroughExport() throws {
        // Deploy → export → rescan → rebuild must match the deployed body.
        let item = makeItem("c.json", type: .compliancePolicy, platform: .iOSiPadOS)
        let deployed = try PayloadBuilder.build(item: item, fileData: Data(Fixtures.iosComplianceJSON.utf8), namingPrefix: "[CONTOSO]", variables: [:])
        var tenantObject = try #require(try JSONSerialization.jsonObject(with: deployed.body) as? [String: Any])
        tenantObject["id"] = "obj-1"

        let outcome = TenantExporter.export(
            collection: .compliancePolicies,
            body: try JSONSerialization.data(withJSONObject: tenantObject),
            namingPrefix: "[CONTOSO]"
        )
        let folder = try tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = try TenantSession.write([outcome], to: folder).written
        #expect(written.first?.hasPrefix("iOS and iPadOS/") == true)

        let rescanned = try #require(try InferenceEngine.scan(root: folder, sourceID: UUID()).items.first)
        #expect(rescanned.platform == .iOSiPadOS)
        let rebuilt = try PayloadBuilder.build(
            item: rescanned,
            fileData: try Data(contentsOf: folder.appending(path: written[0])),
            namingPrefix: "[CONTOSO]",
            variables: [:]
        )
        let changes = try GraphDiff.changes(desired: rebuilt.body, remote: deployed.body, ignoringKeys: ["description"])
        #expect(changes.isEmpty, "unexpected changes: \(changes)")
    }
}
