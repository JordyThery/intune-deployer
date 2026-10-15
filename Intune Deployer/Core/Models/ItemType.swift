import Foundation

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
        case .app: "macOS App"
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
