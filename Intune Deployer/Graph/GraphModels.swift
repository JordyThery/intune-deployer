import Foundation

/// A generic Intune object as returned by the list endpoints — just enough
/// for inventory display and identity-tag matching.
nonisolated struct TenantObject: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    /// Settings Catalog policies use `name`; everything else `displayName`.
    let name: String?
    let displayName: String?
    let description: String?
    let odataType: String?
    let lastModifiedDateTime: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, displayName, description, lastModifiedDateTime
        case odataType = "@odata.type"
    }

    var resolvedName: String {
        displayName ?? name ?? id
    }

    /// Our identity tag short ID if this object was created by this app.
    var taggedShortID: String? {
        description.flatMap(ItemIdentity.shortID(inDescription:))
    }
}

/// The Intune object collections the app manages, with their verified
/// Graph list endpoints.
///
/// Verified against Microsoft Learn (Oct 2026):
/// - configurationPolicies: beta only; objects use `name`.
///   learn.microsoft.com/graph/api/intune-deviceconfigv2-devicemanagementconfigurationpolicy-list
/// - deviceConfigurations: v1.0 (macOSCustomConfiguration documented in v1.0).
/// - deviceCompliancePolicies: v1.0 (macOSCompliancePolicy).
/// - deviceShellScripts / deviceCustomAttributeShellScripts: beta only;
///   permission DeviceManagementScripts.Read.All.
/// - assignmentFilters: beta only; DeviceManagementConfiguration.Read.All.
nonisolated enum TenantCollection: String, CaseIterable, Sendable, Identifiable {
    case settingsCatalog
    case deviceConfigurations
    case compliancePolicies
    case shellScripts
    case customAttributes
    case assignmentFilters
    /// macOS .pkg/.dmg apps (beta: macOSPkgApp/macOSDmgApp).
    case apps

    var id: String { rawValue }

    var listPath: String {
        switch self {
        case .settingsCatalog: "deviceManagement/configurationPolicies"
        case .deviceConfigurations: "deviceManagement/deviceConfigurations"
        case .compliancePolicies: "deviceManagement/deviceCompliancePolicies"
        case .shellScripts: "deviceManagement/deviceShellScripts"
        case .customAttributes: "deviceManagement/deviceCustomAttributeShellScripts"
        case .assignmentFilters: "deviceManagement/assignmentFilters"
        case .apps: "deviceAppManagement/mobileApps"
        }
    }

    var version: GraphVersion {
        switch self {
        case .settingsCatalog, .shellScripts, .customAttributes, .assignmentFilters, .apps: .beta
        case .deviceConfigurations, .compliancePolicies: .v1
        }
    }

    var displayName: String {
        switch self {
        case .settingsCatalog: "Settings Catalog"
        case .deviceConfigurations: "Device Configurations"
        case .compliancePolicies: "Compliance Policies"
        case .shellScripts: "Shell Scripts"
        case .customAttributes: "Custom Attributes"
        case .assignmentFilters: "Assignment Filters"
        case .apps: "macOS Apps"
        }
    }

    var symbolName: String {
        switch self {
        case .settingsCatalog: ItemType.settingsCatalog.symbolName
        case .deviceConfigurations: ItemType.customConfiguration.symbolName
        case .compliancePolicies: ItemType.compliancePolicy.symbolName
        case .shellScripts: ItemType.shellScript.symbolName
        case .customAttributes: ItemType.customAttribute.symbolName
        case .assignmentFilters: ItemType.assignmentFilter.symbolName
        case .apps: ItemType.app.symbolName
        }
    }

    /// The managed macOS app types within the mixed mobileApps collection.
    static let managedAppODataTypes: Set<String> = [
        "#microsoft.graph.macOSPkgApp",
        "#microsoft.graph.macOSDmgApp",
    ]
}
