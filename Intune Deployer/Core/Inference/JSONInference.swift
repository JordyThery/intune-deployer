import Foundation

/// Classifies a `.json` file into an Intune item type by inspecting the JSON
/// itself — `@odata.type` when present, otherwise the JSON shape. The file
/// also states its platform (macOS or iOS/iPadOS); other platforms are
/// reported as unsupported.
///
/// Accepts raw Graph exports and Micke-K IntuneManagement exports (Graph JSON
/// with extra keys such as `assignments`). Unknown/read-only keys are kept at
/// this stage; they are stripped when the deployment payload is built.
nonisolated enum JSONInference {
    struct Detection: Sendable {
        let type: ItemType
        let platform: ItemPlatform
        let displayName: String?
        let reason: String
    }

    enum Outcome: Sendable {
        case item(Detection)
        case skip(reason: String)
    }

    static func classify(data: Data) -> Outcome {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .skip(reason: "Not valid JSON")
        }
        guard let dict = object as? [String: Any] else {
            return .skip(reason: "Top-level JSON is not an object")
        }

        let displayName = (dict["name"] as? String) ?? (dict["displayName"] as? String)

        if let odataType = dict["@odata.type"] as? String {
            return classify(odataType: odataType, dict: dict, displayName: displayName)
        }

        // No @odata.type — infer from shape.
        // Settings Catalog policies (deviceManagement/configurationPolicies)
        // are a concrete type, so Graph exports often omit @odata.type.
        if dict["settings"] != nil, dict["platforms"] != nil, dict["technologies"] != nil {
            guard let platform = settingsCatalogPlatform(dict) else {
                return .skip(reason: "Settings Catalog policy for an unsupported platform (\(dict["platforms"] as? String ?? "unknown"))")
            }
            return .item(Detection(
                type: .settingsCatalog,
                platform: platform,
                displayName: displayName,
                reason: "JSON shape: settings + platforms + technologies"
            ))
        }
        if dict["rule"] is String, dict["platform"] != nil {
            guard let platform = filterPlatform(dict) else {
                return .skip(reason: "Assignment filter for an unsupported platform (\(dict["platform"] as? String ?? "unknown"))")
            }
            return .item(Detection(
                type: .assignmentFilter,
                platform: platform,
                displayName: displayName,
                reason: "JSON shape: rule + platform (assignment filter)"
            ))
        }
        return .skip(reason: "Unrecognised JSON shape (no @odata.type and no known key pattern)")
    }

    private static func classify(odataType: String, dict: [String: Any], displayName: String?) -> Outcome {
        let lower = odataType.lowercased()
        func detection(_ type: ItemType, _ platform: ItemPlatform) -> Outcome {
            .item(Detection(type: type, platform: platform, displayName: displayName, reason: "@odata.type is \(odataType)"))
        }

        if lower.contains("macoscustomconfiguration") {
            return detection(.customConfiguration, .macOS)
        }
        if lower.contains("ioscustomconfiguration") {
            return detection(.customConfiguration, .iOSiPadOS)
        }
        if lower.contains("macoscompliancepolicy") {
            return detection(.compliancePolicy, .macOS)
        }
        if lower.contains("ioscompliancepolicy") {
            return detection(.compliancePolicy, .iOSiPadOS)
        }
        if lower.contains("compliancepolicy") {
            return .skip(reason: "Compliance policy for an unsupported platform (\(odataType))")
        }
        if lower.contains("devicemanagementconfigurationpolicy") {
            guard let platform = settingsCatalogPlatform(dict) else {
                return .skip(reason: "Settings Catalog policy for an unsupported platform (\(dict["platforms"] as? String ?? "unknown"))")
            }
            return detection(.settingsCatalog, platform)
        }
        if lower.contains("assignmentfilter") {
            guard let platform = filterPlatform(dict) else {
                return .skip(reason: "Assignment filter for an unsupported platform (\(dict["platform"] as? String ?? "unknown"))")
            }
            return detection(.assignmentFilter, platform)
        }
        return .skip(reason: "Unsupported @odata.type: \(odataType)")
    }

    /// Platform from a Settings Catalog `platforms` value; a missing value
    /// defaults to macOS (the payload builder fills it in with a warning).
    private static func settingsCatalogPlatform(_ dict: [String: Any]) -> ItemPlatform? {
        let value = dict["platforms"] as? String
        guard let value, !value.isEmpty else { return .macOS }
        return ItemPlatform.fromPlatforms(value)
    }

    /// Platform from an assignment filter `platform` value; a missing value
    /// defaults to macOS (the payload builder fills it in with a warning).
    private static func filterPlatform(_ dict: [String: Any]) -> ItemPlatform? {
        let value = dict["platform"] as? String
        guard let value, !value.isEmpty else { return .macOS }
        return ItemPlatform.fromFilterValue(value)
    }
}
