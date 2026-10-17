import Foundation

/// The device platform an item targets. JSON files state their own platform;
/// `.mobileconfig` profiles default to macOS (overridable per item), `.ipa`
/// packages are always iOS/iPadOS, and everything else is macOS.
nonisolated enum ItemPlatform: String, Codable, Sendable, CaseIterable, Hashable {
    case macOS
    case iOSiPadOS

    var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .iOSiPadOS: "iOS/iPadOS"
        }
    }

    /// The devicePlatformType value assignment filters use.
    var filterPlatformValue: String {
        switch self {
        case .macOS: "macOS"
        case .iOSiPadOS: "iOS"
        }
    }
}

/// The kinds of Intune objects this app can infer from plain files.
nonisolated enum ItemType: String, Codable, CaseIterable, Sendable, Hashable {
    case settingsCatalog
    case customConfiguration
    case compliancePolicy
    case assignmentFilter
    case shellScript
    case customAttribute
    /// macOS app packages (.pkg / .dmg).
    case app

    var displayName: String {
        switch self {
        case .settingsCatalog: "Settings Catalog"
        case .customConfiguration: "Custom Configuration"
        case .compliancePolicy: "Compliance Policy"
        case .assignmentFilter: "Assignment Filter"
        case .shellScript: "Shell Script"
        case .customAttribute: "Custom Attribute"
        case .app: "App"
        }
    }

    /// Whether Intune supports assignment filters on this object type.
    /// Shell scripts and custom attributes do not (see "Platforms and policy
    /// types supported by assignment filters" on Microsoft Learn), and
    /// assignment filters cannot themselves be assigned.
    var supportsAssignmentFilters: Bool {
        switch self {
        case .shellScript, .customAttribute, .assignmentFilter: false
        case .settingsCatalog, .customConfiguration, .compliancePolicy, .app: true
        }
    }

    /// SF Symbol used in lists and the detail header.
    var symbolName: String {
        switch self {
        case .settingsCatalog: "slider.horizontal.3"
        case .customConfiguration: "doc.badge.gearshape"
        case .compliancePolicy: "checkmark.shield"
        case .assignmentFilter: "line.3.horizontal.decrease.circle"
        case .shellScript: "terminal"
        case .customAttribute: "tag"
        case .app: "shippingbox"
        }
    }
}
