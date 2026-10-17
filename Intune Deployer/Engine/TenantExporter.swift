import Foundation

/// Converts existing tenant objects (full Graph bodies) into baseline files
/// in the formats the inference engine reads back, so an export folder can be
/// added as a source as-is.
///
/// Exported files are cleaned: read-only Graph keys, server ids, the identity
/// tag and the tenant profile's naming prefix are removed, and assignments are
/// never included (they reference tenant-specific groups and filters).
/// App packages are never exported — Graph does not return their content.
nonisolated enum TenantExporter {
    /// One converted object, before a unique file name is assigned.
    struct ExportFile: Sendable, Equatable {
        /// Subfolder within the export folder, e.g. "Settings Catalog".
        let folder: String
        /// Display name the file name is derived from.
        let baseName: String
        let fileExtension: String
        let contents: Data
    }

    enum Outcome: Sendable, Equatable {
        case file(ExportFile)
        case skipped(name: String, reason: String)
    }

    /// Collections offered for export (app packages excluded).
    static let exportableCollections: [TenantCollection] = TenantCollection.allCases.filter { $0 != .apps }

    /// Subfolder per collection and platform, e.g. "macOS/Compliance". The
    /// "iOS and iPadOS" root marks re-imported profiles as iOS, and custom
    /// attributes must live in a folder whose name marks them as such.
    static func folder(for collection: TenantCollection, platform: ItemPlatform) -> String {
        let root = platform.exportFolderName
        let type: String = switch collection {
        case .settingsCatalog: "Settings Catalog"
        case .deviceConfigurations: "Configuration Profiles"
        case .compliancePolicies: "Compliance"
        case .shellScripts: "Scripts"
        case .customAttributes: "CustomAttributes"
        case .assignmentFilters: "Assignment Filters"
        case .apps: "Apps"
        }
        return "\(root)/\(type)"
    }

    // MARK: - Conversion

    /// Converts one Graph object body. For Settings Catalog policies the body
    /// must include the merged `settings`; for scripts, `scriptContent`.
    static func export(collection: TenantCollection, body: Data, namingPrefix: String) -> Outcome {
        guard let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .skipped(name: "Unknown object", reason: "Graph returned an unreadable object")
        }
        let rawName = (dict["displayName"] as? String) ?? (dict["name"] as? String) ?? (dict["id"] as? String) ?? "Untitled"
        let name = unprefixed(rawName, prefix: namingPrefix)
        let odataType = (dict["@odata.type"] as? String)?.lowercased() ?? ""

        switch collection {
        case .settingsCatalog:
            guard let platform = applePlatform(settingsCatalog: dict["platforms"] as? String) else {
                return .skipped(name: name, reason: "Not a macOS or iOS/iPadOS policy (\(dict["platforms"] as? String ?? "no platform"))")
            }
            guard dict["settings"] is [Any] else {
                return .skipped(name: name, reason: "The policy's settings could not be read")
            }
            var cleaned = cleanedJSON(dict, nameKey: "name", name: name)
            cleaned["displayName"] = nil
            return jsonFile(collection, platform: platform, name: name, dict: cleaned)

        case .compliancePolicies:
            guard let platform = applePlatform(odataType: odataType, suffix: "compliancepolicy") else {
                return .skipped(name: name, reason: "Not a macOS or iOS/iPadOS compliance policy")
            }
            return jsonFile(collection, platform: platform, name: name, dict: cleanedJSON(dict, nameKey: "displayName", name: name))

        case .assignmentFilters:
            guard let platform = applePlatform(filter: dict["platform"] as? String) else {
                return .skipped(name: name, reason: "Not a macOS or iOS/iPadOS assignment filter")
            }
            return jsonFile(collection, platform: platform, name: name, dict: cleanedJSON(dict, nameKey: "displayName", name: name))

        case .deviceConfigurations:
            guard let platform = applePlatform(odataType: odataType, suffix: "customconfiguration") else {
                return .skipped(name: name, reason: "Only macOS and iOS/iPadOS custom configuration profiles can be exported")
            }
            guard let payload = (dict["payload"] as? String).flatMap({ Data(base64Encoded: $0) }), !payload.isEmpty else {
                return .skipped(name: name, reason: "The profile has no payload")
            }
            return .file(ExportFile(folder: folder(for: collection, platform: platform), baseName: name, fileExtension: "mobileconfig", contents: payload))

        case .shellScripts, .customAttributes:
            guard let content = (dict["scriptContent"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let text = String(data: content, encoding: .utf8) ?? String(data: content, encoding: .isoLatin1) else {
                return .skipped(name: name, reason: "The script content could not be read")
            }
            let directive = collection == .customAttributes
                ? customAttributeDirective(dict)
                : shellScriptDirective(dict)
            let ext = ((dict["fileName"] as? String)?.lowercased().hasSuffix(".zsh") == true) ? "zsh" : "sh"
            return .file(ExportFile(
                folder: folder(for: collection, platform: .macOS),
                baseName: name,
                fileExtension: ext,
                contents: Data(withDirective(directive, in: text).utf8)
            ))

        case .apps:
            return .skipped(name: name, reason: "App packages are not exported")
        }
    }

    // MARK: - Platform detection
    // Unlike import (which defaults missing values to macOS), export skips
    // objects whose platform cannot be determined.

    private static func applePlatform(settingsCatalog platforms: String?) -> ItemPlatform? {
        ItemPlatform.fromPlatforms(platforms)
    }

    private static func applePlatform(filter platform: String?) -> ItemPlatform? {
        ItemPlatform.fromFilterValue(platform)
    }

    private static func applePlatform(odataType: String, suffix: String) -> ItemPlatform? {
        ItemPlatform.fromODataType(odataType, suffix: suffix)
    }

    // MARK: - Cleaning

    /// Removes the naming prefix the app adds on deploy ("[PREFIX] Name").
    static func unprefixed(_ name: String, prefix: String) -> String {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmedPrefix.isEmpty, name.hasPrefix("\(trimmedPrefix) ") else { return name }
        return String(name.dropFirst(trimmedPrefix.count + 1))
    }

    /// Removes the identity tag and the placeholder text written for empty
    /// descriptions; nil when nothing else remains.
    static func cleanedDescription(_ description: String?) -> String? {
        let text = (description ?? "")
            .replacing(/\s*\[(?:IntuneDeployer|gw):[0-9a-f]{8}\]/, with: "")
            .replacingOccurrences(of: "Managed by Intune Deployer", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func cleanedJSON(_ dict: [String: Any], nameKey: String, name: String) -> [String: Any] {
        var cleaned = PayloadBuilder.stripServerKeys(dict)
        cleaned[nameKey] = name
        cleaned["description"] = cleanedDescription(dict["description"] as? String)
        // Server-assigned ids inside settings and scheduled action rules.
        for key in ["settings", "scheduledActionsForRule"] {
            if let nested = cleaned[key] as? [Any] {
                cleaned[key] = PayloadBuilder.stripIDsRecursively(nested)
            }
        }
        return cleaned
    }

    private static func jsonFile(_ collection: TenantCollection, platform: ItemPlatform, name: String, dict: [String: Any]) -> Outcome {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            return .skipped(name: name, reason: "The object could not be encoded as JSON")
        }
        return .file(ExportFile(folder: folder(for: collection, platform: platform), baseName: name, fileExtension: "json", contents: data))
    }

    // MARK: - Script directives

    private static func shellScriptDirective(_ dict: [String: Any]) -> String {
        var pairs = ["runAsAccount=\((dict["runAsAccount"] as? String) ?? "system")"]
        if let minutes = (dict["executionFrequency"] as? String).flatMap(minutes(fromISODuration:)), minutes > 0 {
            pairs.append("frequency=\(minutes)")
        }
        if let retries = dict["retryCount"] as? Int, retries > 0 {
            pairs.append("retries=\(retries)")
        }
        if dict["blockExecutionNotifications"] as? Bool == true {
            pairs.append("hideNotifications=true")
        }
        return "# intune: " + pairs.joined(separator: " ")
    }

    private static func customAttributeDirective(_ dict: [String: Any]) -> String {
        var pairs = [
            "type=customAttribute",
            "attributeType=\((dict["customAttributeType"] as? String) ?? CustomAttributeValueType.string.rawValue)",
        ]
        if (dict["runAsAccount"] as? String) == "user" {
            pairs.append("runAsAccount=user")
        }
        return "# intune: " + pairs.joined(separator: " ")
    }

    /// Replaces any `# intune:` lines in the script header with `directive`,
    /// placed right after the shebang (or first when there is none).
    static func withDirective(_ directive: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let headerCount = min(lines.count, 15)
        let header = lines[0..<headerCount].filter {
            $0.trimmingCharacters(in: .whitespaces).firstMatch(of: /^#\s*intune:/) == nil
        }
        lines = Array(header) + lines[headerCount...]
        let insertAt = lines.first?.hasPrefix("#!") == true ? 1 : 0
        lines.insert(directive, at: insertAt)
        return lines.joined(separator: "\n")
    }

    /// Minutes from an ISO 8601 duration such as P1D, PT3H, PT45M or P1DT2H.
    static func minutes(fromISODuration value: String) -> Int? {
        guard let match = value.wholeMatch(of: /P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?/) else { return nil }
        let days = match.1.flatMap { Int($0) } ?? 0
        let hours = match.2.flatMap { Int($0) } ?? 0
        let minutes = match.3.flatMap { Int($0) } ?? 0
        let total = days * 1440 + hours * 60 + minutes
        return total > 0 ? total : nil
    }

    // MARK: - File names

    /// A file-system-safe name: no path separators or colons, no leading
    /// dots, bounded length.
    static func safeFileName(_ name: String) -> String {
        var result = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        if result.count > 120 { result = String(result.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return result.isEmpty ? "Untitled" : result
    }

    /// Relative path for `file`, numbered " (2)", " (3)", … when the name is
    /// already taken (case-insensitive, as on the default macOS file system).
    static func uniqueRelativePath(for file: ExportFile, taken: inout Set<String>) -> String {
        let base = safeFileName(file.baseName)
        var candidate = "\(file.folder)/\(base).\(file.fileExtension)"
        var counter = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(file.folder)/\(base) (\(counter)).\(file.fileExtension)"
            counter += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}
