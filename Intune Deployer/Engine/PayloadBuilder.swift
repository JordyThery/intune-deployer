import Foundation

nonisolated enum PayloadError: LocalizedError {
    case unreadableFile(String)
    case invalidJSON(String)
    case unresolvedTokens([String])
    case unsupportedItem(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let name): "Could not read \(name)"
        case .invalidJSON(let name): "\(name) is not valid JSON after variable substitution"
        case .unresolvedTokens(let tokens): "Unresolved variables: \(tokens.joined(separator: ", "))"
        case .unsupportedItem(let reason): reason
        }
    }
}

/// Builds the desired Graph request body for an inferred item: substitutes
/// variables, applies the naming prefix, appends the identity tag to the
/// description and strips keys that must not be sent on create/update.
nonisolated enum PayloadBuilder {
    struct Built: Sendable {
        let collection: TenantCollection
        let displayName: String
        /// JSON body ready for POST (and PUT/PATCH on update).
        let body: Data
        let warnings: [String]
    }

    /// Keys never sent to Graph on create/update. Mostly read-only/server
    /// fields; docs only mark a few explicitly (isAssigned, supportsScopeTags,
    /// createdDateTime/lastModifiedDateTime on scripts, createdDateTime on
    /// filters), the rest are server-managed in practice.
    static let strippedKeys: Set<String> = [
        "id", "createdDateTime", "lastModifiedDateTime", "version",
        "settingCount", "isAssigned", "creationSource", "priorityMetaData",
        "supportsScopeTags", "assignments", "groupAssignments", "payloads",
        "deviceStatuses", "userStatuses", "deviceStatusOverview",
        "userStatusOverview", "deviceSettingStateSummaries", "scheduledActionConfigurations",
        "deviceRunStates", "runSummary", "assignmentFilterManagementType",
        "@odata.context", "lastSyncDateTime",
    ]

    static func build(
        item: InferredItem,
        fileData: Data,
        namingPrefix: String,
        variables: [String: String],
        appInfo: AppPackageInfo? = nil
    ) throws -> Built {
        // Apps are binary: no variable substitution, metadata from inspection.
        if item.type == .app {
            return try buildApp(item: item, appInfo: appInfo, prefix: namingPrefix, tag: ItemIdentity.tag(forShortID: item.id))
        }

        let isMobileconfig = item.fileURL.pathExtension.lowercased() == "mobileconfig"

        // Normalise to text. Binary mobileconfig plists are converted to XML
        // first so they survive substitution and base64 encoding intact.
        let rawText: String
        if isMobileconfig {
            guard let plist = try? PropertyListSerialization.propertyList(from: fileData, format: nil),
                  let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                  let text = String(data: xml, encoding: .utf8) else {
                throw PayloadError.unreadableFile(item.relativePath)
            }
            rawText = text
        } else {
            guard let text = String(data: fileData, encoding: .utf8) else {
                throw PayloadError.unreadableFile(item.relativePath)
            }
            rawText = text
        }

        // Substituted values are escaped for the document format they land in.
        let escaping: VariableSubstitution.Escaping = switch item.type {
        case .shellScript, .customAttribute: .none
        default: isMobileconfig ? .xml : .json
        }
        let substitution = VariableSubstitution.substitute(rawText, variables: variables, escaping: escaping)
        guard substitution.unresolved.isEmpty else {
            throw PayloadError.unresolvedTokens(substitution.unresolved)
        }
        let text = substitution.text
        let tag = ItemIdentity.tag(forShortID: item.id)

        switch item.type {
        case .settingsCatalog:
            return try buildSettingsCatalog(item: item, text: text, prefix: namingPrefix, tag: tag)
        case .customConfiguration:
            if item.fileURL.pathExtension.lowercased() == "mobileconfig" {
                return try buildCustomConfigFromMobileconfig(item: item, text: text, prefix: namingPrefix, tag: tag)
            }
            return try buildCustomConfigFromJSON(item: item, text: text, prefix: namingPrefix, tag: tag)
        case .compliancePolicy:
            return try buildCompliance(item: item, text: text, prefix: namingPrefix, tag: tag)
        case .assignmentFilter:
            return try buildFilter(item: item, text: text, prefix: namingPrefix, tag: tag)
        case .shellScript:
            return try buildShellScript(item: item, text: text, prefix: namingPrefix, tag: tag)
        case .customAttribute:
            return try buildCustomAttribute(item: item, text: text, prefix: namingPrefix, tag: tag)
        case .app:
            throw PayloadError.unsupportedItem("macOS apps are handled before substitution")
        }
    }

    // MARK: - macOS apps (.pkg / .dmg)

    /// Graph body for macOSPkgApp / macOSDmgApp / iosLobApp (all beta).
    /// Content upload runs separately at apply time; this is the metadata
    /// object.
    static func buildApp(item: InferredItem, appInfo: AppPackageInfo?, prefix: String, tag: String) throws -> Built {
        guard let appInfo else {
            throw PayloadError.unsupportedItem("Could not read bundle ID/version from \(item.fileURL.lastPathComponent)")
        }
        if item.fileURL.pathExtension.lowercased() == "ipa" {
            return try buildIOSApp(item: item, appInfo: appInfo, prefix: prefix, tag: tag)
        }
        let isPkg = item.fileURL.pathExtension.lowercased() == "pkg"
        let name = prefixed(item.displayName, prefix: prefix)
        var warnings: [String] = []

        var includedApps = appInfo.includedApps
        if includedApps.isEmpty {
            includedApps = [AppPackageInfo.IncludedApp(bundleID: appInfo.primaryBundleID, bundleVersion: appInfo.primaryBundleVersion)]
        }
        if includedApps.count > 500 {
            includedApps = Array(includedApps.prefix(500))
            warnings.append("Package lists more than 500 bundles; truncated (Graph limit)")
        }
        warnings.append("Publisher defaults to the app name — edit it in Intune if needed")

        let dict: [String: Any] = [
            "@odata.type": isPkg ? "#microsoft.graph.macOSPkgApp" : "#microsoft.graph.macOSDmgApp",
            "displayName": name,
            "description": taggedDescription(nil, tag: tag),
            "publisher": item.displayName,
            "fileName": item.fileURL.lastPathComponent,
            "primaryBundleId": appInfo.primaryBundleID,
            "primaryBundleVersion": appInfo.primaryBundleVersion,
            "includedApps": includedApps.map { app in
                [
                    "@odata.type": "microsoft.graph.macOSIncludedApp",
                    "bundleId": app.bundleID,
                    "bundleVersion": app.bundleVersion,
                ] as [String: Any]
            },
            "minimumSupportedOperatingSystem": [
                "@odata.type": "microsoft.graph.macOSMinimumOperatingSystem",
                "v11_0": true,
            ] as [String: Any],
        ]
        return Built(collection: .apps, displayName: name, body: try encode(dict), warnings: warnings)
    }

    /// Graph body for iosLobApp (beta). Intune expects the provisioning
    /// profile's expiration date; an unsigned .ipa cannot be deployed.
    static func buildIOSApp(item: InferredItem, appInfo: AppPackageInfo, prefix: String, tag: String) throws -> Built {
        guard let expiration = appInfo.provisioningExpiration else {
            throw PayloadError.unsupportedItem("\(item.fileURL.lastPathComponent) has no embedded provisioning profile — only signed .ipa files can be deployed")
        }
        let name = prefixed(item.displayName, prefix: prefix)
        var warnings = ["Publisher defaults to the app name — edit it in Intune if needed"]
        if expiration < .now {
            throw PayloadError.unsupportedItem("The provisioning profile in \(item.fileURL.lastPathComponent) expired on \(expiration.formatted(date: .abbreviated, time: .omitted)) — re-sign the app first")
        }
        if expiration < .now.addingTimeInterval(30 * 86_400) {
            warnings.append("The provisioning profile expires on \(expiration.formatted(date: .abbreviated, time: .omitted))")
        }

        let dict: [String: Any] = [
            "@odata.type": "#microsoft.graph.iosLobApp",
            "displayName": name,
            "description": taggedDescription(nil, tag: tag),
            "publisher": item.displayName,
            "fileName": item.fileURL.lastPathComponent,
            "bundleId": appInfo.primaryBundleID,
            "versionNumber": appInfo.primaryBundleVersion,
            "buildNumber": appInfo.buildNumber ?? appInfo.primaryBundleVersion,
            "expirationDateTime": Self.iso8601UTC(expiration),
            "applicableDeviceType": [
                "@odata.type": "microsoft.graph.iosDeviceType",
                "iPhoneAndIPod": appInfo.supportsIPhone ?? true,
                "iPad": appInfo.supportsIPad ?? true,
            ] as [String: Any],
            "minimumSupportedOperatingSystem": [
                "@odata.type": "microsoft.graph.iosMinimumOperatingSystem",
                Self.iosMinimumOSKey(for: appInfo.minimumOSVersion): true,
            ] as [String: Any],
        ]
        return Built(collection: .apps, displayName: name, body: try encode(dict), warnings: warnings)
    }

    /// The iosMinimumOperatingSystem boolean for a MinimumOSVersion value.
    /// Graph defines v8_0 through v18_0 and v26_0 (exactly one must be true);
    /// versions in between are rounded down to a defined key.
    static func iosMinimumOSKey(for version: String?) -> String {
        guard let major = version?.split(separator: ".").first.flatMap({ Int($0) }) else {
            return "v9_0" // Microsoft's sample default when unknown.
        }
        switch major {
        case ..<8: return "v8_0"
        case 8...18: return "v\(major)_0"
        case 19...25: return "v18_0"
        default: return "v26_0"
        }
    }

    nonisolated private static func iso8601UTC(_ date: Date) -> String {
        date.ISO8601Format() // e.g. 2027-10-17T09:30:00Z
    }

    // MARK: - Shared helpers

    static func prefixed(_ name: String, prefix: String) -> String {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmedPrefix.isEmpty else { return name }
        // Already prefixed (exact word), not merely sharing leading letters.
        guard name != trimmedPrefix, !name.hasPrefix("\(trimmedPrefix) ") else { return name }
        return "\(trimmedPrefix) \(name)"
    }

    /// Replaces any existing identity tag (current or legacy format) and
    /// appends ours. An empty description becomes "Managed by Intune Deployer
    /// [IntuneDeployer:…]" so the portal shows something meaningful.
    static func taggedDescription(_ description: String?, tag: String) -> String {
        var text = (description ?? "")
            .replacing(/\s*\[(?:IntuneDeployer|gw):[0-9a-f]{8}\]/, with: "")
            .replacingOccurrences(of: "Managed by Intune Deployer", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Managed by Intune Deployer \(tag)" : "\(text) \(tag)"
    }

    private static func parseJSONObject(_ text: String, itemName: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw PayloadError.invalidJSON(itemName)
        }
        return dict
    }

    private static func encode(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    /// Also used by the tenant exporter, so exported files carry no keys the
    /// deploy path would strip anyway.
    static func stripServerKeys(_ dict: [String: Any]) -> [String: Any] {
        var result = dict.filter { !strippedKeys.contains($0.key) }
        // roleScopeTagIds: drop when unset/default so we don't fight the server.
        if let tags = result["roleScopeTagIds"] as? [String], tags.isEmpty || tags == ["0"] {
            result["roleScopeTagIds"] = nil
        }
        // Keys added by export tools (IntuneManagement etc.), not Graph fields.
        for key in result.keys where key.hasPrefix("#") || key.contains("@odata.count") {
            result[key] = nil
        }
        return result
    }

    // MARK: - Settings Catalog

    private static func buildSettingsCatalog(item: InferredItem, text: String, prefix: String, tag: String) throws -> Built {
        var dict = stripServerKeys(try parseJSONObject(text, itemName: item.displayName))
        var warnings: [String] = []

        let baseName = (dict["name"] as? String) ?? (dict["displayName"] as? String) ?? item.displayName
        dict["displayName"] = nil // configurationPolicies use `name`
        dict["name"] = prefixed(baseName, prefix: prefix)
        dict["description"] = taggedDescription(dict["description"] as? String, tag: tag)
        if dict["platforms"] == nil {
            dict["platforms"] = "macOS"
            warnings.append("No platforms in source; defaulting to macOS")
        }
        if dict["technologies"] == nil {
            dict["technologies"] = "mdm"
            warnings.append("No technologies in source; defaulting to mdm")
        }
        if (dict["settings"] as? [Any])?.isEmpty != false {
            warnings.append("Policy has no settings")
        }
        // Strip per-setting server ids inside the settings array.
        if let settings = dict["settings"] as? [Any] {
            dict["settings"] = stripIDsRecursively(settings)
        }
        return Built(
            collection: .settingsCatalog,
            displayName: dict["name"] as? String ?? baseName,
            body: try encode(dict),
            warnings: warnings
        )
    }

    // MARK: - Custom configuration

    private static func buildCustomConfigFromMobileconfig(item: InferredItem, text: String, prefix: String, tag: String) throws -> Built {
        // The display name comes from PayloadDisplayName, read before
        // substitution — take it from the substituted profile instead so
        // `{{Token}}` placeholders never reach the Intune object name.
        let plist = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any]
        let baseName = (plist?["PayloadDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? item.displayName
        let name = prefixed(baseName, prefix: prefix)
        let payload = Data(text.utf8).base64EncodedString()
        let dict: [String: Any] = [
            "@odata.type": item.platform == .iOSiPadOS
                ? "#microsoft.graph.iosCustomConfiguration"
                : "#microsoft.graph.macOSCustomConfiguration",
            "displayName": name,
            "description": taggedDescription(nil, tag: tag),
            "payloadName": name,
            "payloadFileName": item.fileURL.lastPathComponent,
            "payload": payload,
        ]
        return Built(collection: .deviceConfigurations, displayName: name, body: try encode(dict), warnings: [])
    }

    private static func buildCustomConfigFromJSON(item: InferredItem, text: String, prefix: String, tag: String) throws -> Built {
        var dict = stripServerKeys(try parseJSONObject(text, itemName: item.displayName))
        var warnings: [String] = []

        dict["@odata.type"] = item.platform == .iOSiPadOS
            ? "#microsoft.graph.iosCustomConfiguration"
            : "#microsoft.graph.macOSCustomConfiguration"
        let baseName = (dict["displayName"] as? String) ?? item.displayName
        dict["displayName"] = prefixed(baseName, prefix: prefix)
        dict["description"] = taggedDescription(dict["description"] as? String, tag: tag)
        if dict["payload"] == nil {
            warnings.append("Export has no payload — the profile will be empty")
        }
        if dict["payloadName"] == nil { dict["payloadName"] = dict["displayName"] }
        if dict["payloadFileName"] == nil { dict["payloadFileName"] = item.fileURL.lastPathComponent }
        return Built(
            collection: .deviceConfigurations,
            displayName: dict["displayName"] as? String ?? baseName,
            body: try encode(dict),
            warnings: warnings
        )
    }

    // MARK: - Compliance

    private static func buildCompliance(item: InferredItem, text: String, prefix: String, tag: String) throws -> Built {
        var dict = stripServerKeys(try parseJSONObject(text, itemName: item.displayName))
        var warnings: [String] = []

        dict["@odata.type"] = item.platform == .iOSiPadOS
            ? "#microsoft.graph.iosCompliancePolicy"
            : "#microsoft.graph.macOSCompliancePolicy"
        let baseName = (dict["displayName"] as? String) ?? item.displayName
        dict["displayName"] = prefixed(baseName, prefix: prefix)
        dict["description"] = taggedDescription(dict["description"] as? String, tag: tag)

        // Graph: "scheduledActionsForRule ... is a required property when
        // creating any individual per-platform compliance policies."
        // (deviceCompliancePolicy resource doc, v1.0)
        if let rules = cleanedScheduledActions(dict["scheduledActionsForRule"]) {
            dict["scheduledActionsForRule"] = rules
        } else {
            dict["scheduledActionsForRule"] = [defaultScheduledActionRule()]
            warnings.append("Source has no scheduledActionsForRule — adding default: mark noncompliant (block) after 24h")
        }
        return Built(
            collection: .compliancePolicies,
            displayName: dict["displayName"] as? String ?? baseName,
            body: try encode(dict),
            warnings: warnings
        )
    }

    /// Strips server ids from scheduled action rules; nil when absent/empty.
    private static func cleanedScheduledActions(_ value: Any?) -> [Any]? {
        guard let rules = value as? [[String: Any]], !rules.isEmpty else { return nil }
        return stripIDsRecursively(rules)
    }

    static func defaultScheduledActionRule() -> [String: Any] {
        [
            "ruleName": "PasswordRequired",
            "scheduledActionConfigurations": [
                ["actionType": "block", "gracePeriodHours": 24] as [String: Any],
            ],
        ]
    }

    // MARK: - Assignment filter

    private static func buildFilter(item: InferredItem, text: String, prefix: String, tag: String) throws -> Built {
        var dict = stripServerKeys(try parseJSONObject(text, itemName: item.displayName))
        var warnings: [String] = []

        dict["@odata.type"] = "#microsoft.graph.deviceAndAppManagementAssignmentFilter"
        let baseName = (dict["displayName"] as? String) ?? item.displayName
        dict["displayName"] = prefixed(baseName, prefix: prefix)
        dict["description"] = taggedDescription(dict["description"] as? String, tag: tag)
        if dict["platform"] == nil {
            dict["platform"] = "macOS"
            warnings.append("No platform in source; defaulting to macOS")
        }
        if dict["rule"] == nil {
            warnings.append("Filter has no rule")
        }
        return Built(
            collection: .assignmentFilters,
            displayName: dict["displayName"] as? String ?? baseName,
            body: try encode(dict),
            warnings: warnings
        )
    }

    // MARK: - Scripts

    private static func buildShellScript(item: InferredItem, text: String, prefix: String, tag: String) throws -> Built {
        let name = prefixed(item.displayName, prefix: prefix)
        let settings = item.scriptSettings ?? ScriptSettings()
        var dict: [String: Any] = [
            "@odata.type": "#microsoft.graph.deviceShellScript",
            "displayName": name,
            "description": taggedDescription(nil, tag: tag),
            "scriptContent": Data(text.utf8).base64EncodedString(),
            "fileName": item.fileURL.lastPathComponent,
            "runAsAccount": settings.runAsAccount.rawValue,
            "blockExecutionNotifications": settings.hideNotifications,
        ]
        if let minutes = settings.frequencyMinutes, minutes > 0 {
            // executionFrequency is an ISO 8601 duration. Intune normalises
            // stored values (PT1440M becomes P1D), so the canonical form is
            // emitted directly to keep re-runs idempotent.
            dict["executionFrequency"] = Self.isoDuration(minutes: minutes)
        }
        if let retries = settings.retries {
            dict["retryCount"] = retries
        }
        return Built(collection: .shellScripts, displayName: name, body: try encode(dict), warnings: [])
    }

    private static func buildCustomAttribute(item: InferredItem, text: String, prefix: String, tag: String) throws -> Built {
        let name = prefixed(item.displayName, prefix: prefix)
        // TODO(verify): customAttributeName constraints are undocumented; the
        // portal rejects spaces, so the unprefixed name is reduced to ASCII
        // letters and digits, with the item ID as a last resort.
        let asciiAlphanumerics = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var attributeName = item.displayName.components(separatedBy: asciiAlphanumerics.inverted).joined()
        if attributeName.isEmpty {
            attributeName = "attribute\(item.id)"
        }
        let dict: [String: Any] = [
            "@odata.type": "#microsoft.graph.deviceCustomAttributeShellScript",
            "customAttributeName": attributeName,
            "customAttributeType": (item.customAttributeType ?? .string).rawValue,
            "displayName": name,
            "description": taggedDescription(nil, tag: tag),
            "scriptContent": Data(text.utf8).base64EncodedString(),
            "fileName": item.fileURL.lastPathComponent,
            "runAsAccount": (item.scriptSettings?.runAsAccount ?? .system).rawValue,
        ]
        return Built(collection: .customAttributes, displayName: name, body: try encode(dict), warnings: [])
    }

    /// Canonical ISO 8601 duration for a minute count, matching how Intune
    /// stores it: P2D, PT3H, PT45M.
    static func isoDuration(minutes: Int) -> String {
        if minutes % 1440 == 0 { return "P\(minutes / 1440)D" }
        if minutes % 60 == 0 { return "PT\(minutes / 60)H" }
        return "PT\(minutes)M"
    }

    // MARK: - Utilities

    /// Removes "id" keys at any depth (server-assigned ids inside settings
    /// arrays and scheduled action rules).
    static func stripIDsRecursively(_ value: Any) -> [Any] {
        (value as? [Any])?.map(stripIDsIn) ?? []
    }

    private static func stripIDsIn(_ value: Any) -> Any {
        if var dict = value as? [String: Any] {
            dict["id"] = nil
            for (key, nested) in dict {
                dict[key] = stripIDsIn(nested)
            }
            return dict
        }
        if let array = value as? [Any] {
            return array.map(stripIDsIn)
        }
        return value
    }
}
