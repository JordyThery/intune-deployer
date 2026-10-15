import Foundation
import Testing
@testable import Intune_Deployer

@Suite("Inference engine")
struct InferenceEngineTests {
    private let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    /// One tree containing every fixture kind, scanned once per test case.
    private func scanFullTree() throws -> ScanResult {
        try Fixtures.withTree(files: [
            "Settings Catalog/gatekeeper.json": Fixtures.settingsCatalogJSON,
            "Settings Catalog/updates.json": Fixtures.intuneManagementSettingsCatalogJSON,
            "Compliance/encryption.json": Fixtures.complianceJSON,
            "Compliance/windows.json": Fixtures.windowsComplianceJSON,
            "Filters/ade-filter.json": Fixtures.assignmentFilterJSON,
            "Custom/dock-custom.json": Fixtures.customConfigurationJSON,
            "Custom/dock.mobileconfig": Fixtures.mobileconfig,
            "Custom/anonymous.mobileconfig": Fixtures.mobileconfigWithoutDisplayName,
            "Scripts/os-version-attribute.zsh": Fixtures.scriptWithCustomAttributeDirective,
            "Scripts/greeting.sh": Fixtures.scriptWithOptionsDirective,
            "Scripts/plain.sh": Fixtures.plainScript,
            "Custom Attributes/battery-health.sh": Fixtures.attributeScriptByFolder,
            "README.md": "# docs",
            "manifests/old-manifest.xml": "<manifest/>",
            "apps/Installer.pkg": "not really a pkg",
        ]) { root in
            try InferenceEngine.scan(root: root, sourceID: sourceID)
        }
    }

    private func item(_ result: ScanResult, _ relativePath: String) throws -> InferredItem {
        try #require(result.items.first { $0.relativePath == relativePath })
    }

    @Test func detectsAllSupportedTypes() throws {
        let result = try scanFullTree()

        #expect(try item(result, "Settings Catalog/gatekeeper.json").type == .settingsCatalog)
        #expect(try item(result, "Settings Catalog/updates.json").type == .settingsCatalog)
        #expect(try item(result, "Compliance/encryption.json").type == .compliancePolicy)
        #expect(try item(result, "Filters/ade-filter.json").type == .assignmentFilter)
        #expect(try item(result, "Custom/dock-custom.json").type == .customConfiguration)
        #expect(try item(result, "Custom/dock.mobileconfig").type == .customConfiguration)
        #expect(try item(result, "Scripts/os-version-attribute.zsh").type == .customAttribute)
        #expect(try item(result, "Scripts/greeting.sh").type == .shellScript)
        #expect(try item(result, "Scripts/plain.sh").type == .shellScript)
        #expect(try item(result, "Custom Attributes/battery-health.sh").type == .customAttribute)
        #expect(try item(result, "apps/Installer.pkg").type == .app)
    }

    @Test func displayNamesComeFromContentWithFilenameFallback() throws {
        let result = try scanFullTree()

        #expect(try item(result, "Settings Catalog/gatekeeper.json").displayName == "macOS - Restrictions - Content Caching")
        #expect(try item(result, "Compliance/encryption.json").displayName == "macOS - Compliance - Encryption")
        #expect(try item(result, "Custom/dock.mobileconfig").displayName == "Dock Settings {{OrgName}}")
        // No PayloadDisplayName → filename without extension.
        #expect(try item(result, "Custom/anonymous.mobileconfig").displayName == "anonymous")
        #expect(try item(result, "Scripts/plain.sh").displayName == "plain")
    }

    @Test func skipsUnsupportedFilesWithReasons() throws {
        let result = try scanFullTree()
        let skippedPaths = Set(result.skipped.map(\.relativePath))

        #expect(skippedPaths.contains("README.md"))
        #expect(skippedPaths.contains("manifests/old-manifest.xml"))
        #expect(skippedPaths.contains("Compliance/windows.json"))
        // .pkg files are app items, not skipped.
        #expect(!skippedPaths.contains("apps/Installer.pkg"))

        let windowsReason = result.skipped.first { $0.relativePath == "Compliance/windows.json" }?.reason ?? ""
        #expect(windowsReason.contains("non-macOS"))
        #expect(result.skipped.allSatisfy { !$0.reason.isEmpty })
    }

    @Test func signedMobileconfigIsReportedUnsupported() throws {
        // CMS/DER wrapper starts with a 0x30 SEQUENCE byte.
        let root = try Fixtures.makeTree(files: [:])
        defer { try? FileManager.default.removeItem(at: root) }
        let signed = Data([0x30, 0x82, 0x0A, 0x00] + Array(repeating: UInt8(0), count: 32))
        try signed.write(to: root.appending(path: "signed.mobileconfig"))

        let result = try InferenceEngine.scan(root: root, sourceID: sourceID)
        #expect(result.items.isEmpty)
        let reason = try #require(result.skipped.first { $0.relativePath == "signed.mobileconfig" }).reason
        #expect(reason.localizedCaseInsensitiveContains("signed"))
    }

    @Test func scriptDirectiveOptionsAreParsedIntoSettings() throws {
        let result = try scanFullTree()
        let script = try item(result, "Scripts/greeting.sh")
        let settings = try #require(script.scriptSettings)

        #expect(settings.runAsAccount == .user)
        #expect(settings.frequencyMinutes == 1440)
        #expect(settings.retries == 3)
        #expect(settings.hideNotifications)

        let attribute = try item(result, "Scripts/os-version-attribute.zsh")
        #expect(attribute.customAttributeType == .string)
    }

    @Test func tokensAreDetectedAcrossFileKinds() throws {
        let result = try scanFullTree()

        #expect(try item(result, "Settings Catalog/updates.json").tokens == ["OrgName"])
        #expect(try item(result, "Filters/ade-filter.json").tokens == ["EnrollmentProfileName"])
        #expect(try item(result, "Custom/dock.mobileconfig").tokens == ["OrgName"])
        #expect(try item(result, "Scripts/greeting.sh").tokens == ["OrgName"])
        #expect(try item(result, "Scripts/plain.sh").tokens.isEmpty)
    }

    @Test func baselineOverridesFileIsIgnoredSilently() throws {
        let result = try Fixtures.withTree(files: [
            ".baseline.json": "{}",
            "Scripts/plain.sh": Fixtures.plainScript,
        ]) { root in
            try InferenceEngine.scan(root: root, sourceID: sourceID)
        }
        #expect(result.items.count == 1)
        #expect(!result.skipped.contains { $0.relativePath.contains(".baseline.json") })
    }
}

@Suite("Script directive parsing")
struct ScriptDirectiveTests {
    @Test func parsesTypeAndAttributeType() {
        let directive = ScriptDirective.parse(scriptText: Fixtures.scriptWithCustomAttributeDirective)
        #expect(directive.declaredType == .customAttribute)
        #expect(directive.attributeType == .string)
    }

    @Test func parsesRunOptions() {
        let directive = ScriptDirective.parse(scriptText: Fixtures.scriptWithOptionsDirective)
        #expect(directive.declaredType == nil)
        #expect(directive.runAsAccount == .user)
        #expect(directive.frequencyMinutes == 1440)
        #expect(directive.retries == 3)
        #expect(directive.hideNotifications == true)
    }

    @Test func mergesMultipleDirectiveLinesAndCollectsUnknownKeys() {
        let text = """
        #!/bin/zsh
        # intune: type=customAttribute
        # intune: attributeType=integer banana=yes
        """
        let directive = ScriptDirective.parse(scriptText: text)
        #expect(directive.declaredType == .customAttribute)
        #expect(directive.attributeType == .integer)
        #expect(directive.unknownKeys == ["banana"])
    }

    @Test func directivesBelowTheHeaderWindowAreIgnored() {
        let text = (1...20).map { "echo line \($0)" }.joined(separator: "\n")
            + "\n# intune: type=customAttribute"
        let directive = ScriptDirective.parse(scriptText: text)
        #expect(directive.declaredType == nil)
    }
}

@Suite("Identity and tokens")
struct IdentityAndTokenTests {
    @Test func shortIDIsStableAndPathSensitive() {
        let source = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let a = ItemIdentity.shortID(sourceID: source, relativePath: "Scripts/a.sh")
        let b = ItemIdentity.shortID(sourceID: source, relativePath: "Scripts/a.sh")
        let c = ItemIdentity.shortID(sourceID: source, relativePath: "Scripts/b.sh")
        let d = ItemIdentity.shortID(sourceID: UUID(), relativePath: "Scripts/a.sh")

        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
        #expect(a.count == 8)
        #expect(a.allSatisfy { $0.isHexDigit })
    }

    @Test func tagRoundTripsThroughDescription() {
        let shortID = "3f9a1c2e"
        let tag = ItemIdentity.tag(forShortID: shortID)
        #expect(tag == "[IntuneDeployer:3f9a1c2e]")

        let description = "Baseline Gatekeeper settings \(tag)"
        #expect(ItemIdentity.shortID(inDescription: description) == shortID)
        #expect(ItemIdentity.shortID(inDescription: "no tag here") == nil)
    }

    @Test func legacyGWTagIsStillRecognised() {
        // Objects deployed by early builds carry [gw:…]; matching must keep
        // working so re-runs update instead of duplicating them.
        #expect(ItemIdentity.shortID(inDescription: "x [gw:642ff2f5]") == "642ff2f5")
        let retagged = PayloadBuilder.taggedDescription("old text [gw:642ff2f5]", tag: ItemIdentity.tag(forShortID: "642ff2f5"))
        #expect(retagged == "old text [IntuneDeployer:642ff2f5]")
    }

    @Test func emptyDescriptionGetsReadableManagedText() {
        let tagged = PayloadBuilder.taggedDescription(nil, tag: "[IntuneDeployer:3f9a1c2e]")
        #expect(tagged == "Managed by Intune Deployer [IntuneDeployer:3f9a1c2e]")
        // Re-tagging the result must not stack the prefix text.
        let retagged = PayloadBuilder.taggedDescription(tagged, tag: "[IntuneDeployer:3f9a1c2e]")
        #expect(retagged == tagged)
    }

    @Test func tokenScannerFindsUniqueSortedTokens() {
        let text = """
        {"a": "{{Zebra}}", "b": "{{ Alpha }}", "c": "{{Zebra}}", "d": "{{not-a-token}}", "e": "{single}"}
        """
        #expect(TokenScanner.tokens(in: text) == ["Alpha", "Zebra"])
    }
}
