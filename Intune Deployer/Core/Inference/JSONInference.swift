import Foundation

/// Classifies a `.json` file into an Intune item type by inspecting the JSON
/// itself — `@odata.type` when present, otherwise the JSON shape.
///
/// Accepts raw Graph exports and Micke-K IntuneManagement exports (Graph JSON
/// with extra keys such as `assignments`). Unknown/read-only keys are kept at
/// this stage; they are stripped when the deployment payload is built.
nonisolated enum JSONInference {
    struct Detection: Sendable {
        let type: ItemType
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
            return classify(odataType: odataType, displayName: displayName)
        }

        // No @odata.type — infer from shape.
        // Settings Catalog policies (deviceManagement/configurationPolicies)
        // are a concrete type, so Graph exports often omit @odata.type.
        if dict["settings"] != nil, dict["platforms"] != nil, dict["technologies"] != nil {
            return .item(Detection(
                type: .settingsCatalog,
                displayName: displayName,
                reason: "JSON shape: settings + platforms + technologies"
            ))
        }
        if dict["rule"] is String, dict["platform"] != nil {
            return .item(Detection(
                type: .assignmentFilter,
                displayName: displayName,
                reason: "JSON shape: rule + platform (assignment filter)"
            ))
        }
        return .skip(reason: "Unrecognised JSON shape (no @odata.type and no known key pattern)")
    }

    private static func classify(odataType: String, displayName: String?) -> Outcome {
        let lower = odataType.lowercased()
        func detection(_ type: ItemType) -> Outcome {
            .item(Detection(type: type, displayName: displayName, reason: "@odata.type is \(odataType)"))
        }

        if lower.contains("macoscustomconfiguration") {
            return detection(.customConfiguration)
        }
        if lower.contains("macoscompliancepolicy") {
            return detection(.compliancePolicy)
        }
        if lower.contains("compliancepolicy") {
            return .skip(reason: "Compliance policy for a non-macOS platform (\(odataType))")
        }
        if lower.contains("devicemanagementconfigurationpolicy") {
            return detection(.settingsCatalog)
        }
        if lower.contains("assignmentfilter") {
            return detection(.assignmentFilter)
        }
        return .skip(reason: "Unsupported @odata.type: \(odataType)")
    }
}
