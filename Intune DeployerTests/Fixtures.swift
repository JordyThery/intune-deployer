import Foundation
import JTKit
import JTKitTestSupport
@testable import Intune_Deployer

/// Builds a throwaway baseline-source folder on disk from fixture content, so
/// tests exercise the real recursive scan including folder-name detection.
enum Fixtures {
    /// Writes `files` (relative path → content) into a fresh temp directory.
    /// Caller is responsible for removal; `withTree` is the preferred entry.
    static func makeTree(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "IntuneDeployerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, content) in files {
            let url = root.appending(path: relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        return root
    }

    static func withTree<T>(files: [String: String], _ body: (URL) throws -> T) throws -> T {
        let root = try makeTree(files: files)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }

    // MARK: - Fixture content

    /// Settings Catalog export without @odata.type — detected by shape.
    /// The setting is a real macOS definition so live integration tests can
    /// deploy it.
    static let settingsCatalogJSON = """
    {
      "name": "macOS - Restrictions - Content Caching",
      "description": "Baseline restriction settings",
      "platforms": "macOS",
      "technologies": "mdm,appleRemoteManagement",
      "settings": [
        {
          "@odata.type": "#microsoft.graph.deviceManagementConfigurationSetting",
          "settingInstance": {
            "@odata.type": "#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance",
            "settingDefinitionId": "com.apple.applicationaccess_com.apple.applicationaccess",
            "groupSettingCollectionValue": [
              {
                "children": [
                  {
                    "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
                    "settingDefinitionId": "com.apple.applicationaccess_allowcontentcaching",
                    "choiceSettingValue": {
                      "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingValue",
                      "value": "com.apple.applicationaccess_allowcontentcaching_false",
                      "children": []
                    }
                  }
                ]
              }
            ]
          }
        }
      ]
    }
    """

    /// IntuneManagement (Micke-K) style export: Graph JSON with @odata.type
    /// plus extra keys (id, assignments, timestamps) that must not break detection.
    static let intuneManagementSettingsCatalogJSON = """
    {
      "@odata.type": "#microsoft.graph.deviceManagementConfigurationPolicy",
      "id": "f1e2d3c4-0000-1111-2222-333344445555",
      "createdDateTime": "2024-01-01T00:00:00Z",
      "lastModifiedDateTime": "2024-06-01T00:00:00Z",
      "name": "macOS - Updates - Deferral {{OrgName}}",
      "platforms": "macOS",
      "technologies": "mdm",
      "settingCount": 3,
      "settings": [],
      "assignments": [
        { "target": { "@odata.type": "#microsoft.graph.allDevicesAssignmentTarget" } }
      ]
    }
    """

    static let complianceJSON = """
    {
      "@odata.type": "#microsoft.graph.macOSCompliancePolicy",
      "displayName": "macOS - Compliance - Encryption",
      "storageRequireEncryption": true,
      "scheduledActionsForRule": [
        {
          "ruleName": "PasswordRequired",
          "scheduledActionConfigurations": [
            { "actionType": "block", "gracePeriodHours": 24 }
          ]
        }
      ]
    }
    """

    static let iosComplianceJSON = """
    {
      "@odata.type": "#microsoft.graph.iosCompliancePolicy",
      "displayName": "iOS - Compliance - Passcode",
      "passcodeRequired": true,
      "scheduledActionsForRule": [
        {
          "ruleName": "PasswordRequired",
          "scheduledActionConfigurations": [
            { "actionType": "block", "gracePeriodHours": 24 }
          ]
        }
      ]
    }
    """

    static let iosSettingsCatalogJSON = """
    {
      "name": "iOS - Restrictions",
      "description": "Baseline iOS restrictions",
      "platforms": "iOS",
      "technologies": "mdm",
      "settings": [
        {
          "@odata.type": "#microsoft.graph.deviceManagementConfigurationSetting",
          "settingInstance": {
            "@odata.type": "#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance",
            "settingDefinitionId": "com.apple.applicationaccess_com.apple.applicationaccess",
            "groupSettingCollectionValue": [
              {
                "children": [
                  {
                    "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
                    "settingDefinitionId": "com.apple.applicationaccess_allowcamera",
                    "choiceSettingValue": {
                      "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingValue",
                      "value": "com.apple.applicationaccess_allowcamera_false",
                      "children": []
                    }
                  }
                ]
              }
            ]
          }
        }
      ]
    }
    """

    static let iosFilterJSON = """
    {
      "displayName": "iOS - ADE Enrolled",
      "platform": "iOS",
      "rule": "(device.enrollmentProfileName -eq \\"{{EnrollmentProfileName}}\\")"
    }
    """

    static let windowsComplianceJSON = """
    {
      "@odata.type": "#microsoft.graph.windows10CompliancePolicy",
      "displayName": "Windows - Compliance",
      "bitLockerEnabled": true
    }
    """

    static let assignmentFilterJSON = """
    {
      "displayName": "macOS - ADE Enrolled",
      "platform": "macOS",
      "rule": "(device.enrollmentProfileName -eq \\"{{EnrollmentProfileName}}\\")"
    }
    """

    static let customConfigurationJSON = """
    {
      "@odata.type": "#microsoft.graph.macOSCustomConfiguration",
      "displayName": "macOS - Custom - Dock",
      "payloadFileName": "dock.mobileconfig",
      "payload": "PHBsaXN0Lz4="
    }
    """

    static let mobileconfig = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>PayloadDisplayName</key>
        <string>Dock Settings {{OrgName}}</string>
        <key>PayloadIdentifier</key>
        <string>com.example.dock</string>
        <key>PayloadType</key>
        <string>Configuration</string>
        <key>PayloadUUID</key>
        <string>8D44A5CC-0000-1111-2222-333344445555</string>
        <key>PayloadVersion</key>
        <integer>1</integer>
    </dict>
    </plist>
    """

    static let mobileconfigWithoutDisplayName = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>PayloadIdentifier</key>
        <string>com.example.anon</string>
    </dict>
    </plist>
    """

    static let scriptWithCustomAttributeDirective = """
    #!/bin/zsh
    # intune: type=customAttribute attributeType=string
    echo "$(sw_vers -productVersion)"
    """

    static let scriptWithOptionsDirective = """
    #!/bin/zsh
    # intune: runAsAccount=user frequency=1440 retries=3 hideNotifications=true
    echo "Hello {{OrgName}}"
    """

    static let plainScript = """
    #!/bin/zsh
    echo "no directive here"
    """

    static let attributeScriptByFolder = """
    #!/bin/zsh
    echo "battery: 93%"
    """
}

// MARK: - Assignment test helpers

/// Edits the first target of an intent, creating it when absent — keeps the
/// tests written for single-target assignments readable.
nonisolated extension AssignmentIntent {
    var first: AssignmentTarget {
        get { targets.first ?? AssignmentTarget() }
        set {
            if targets.isEmpty { targets = [newValue] } else { targets[0] = newValue }
        }
    }
}

/// A bearer token without a sign-in.
nonisolated struct TestToken: BearerTokenSource {
    var value = "token"

    func token() async throws -> String { value }
    func forgetToken() async {}
}

/// JTKit's Graph client against a fake Graph, as the app builds it.
func graphClient(_ server: MockServer, log: ActivityLog? = nil, connection: String? = nil,
                 tokens: any BearerTokenSource = TestToken()) -> Graph.Client {
    Graph.Client(tokens: tokens, access: .delegated,
                 recorder: Graph.recorder(session: server.session, log: log, connection: connection))
}
