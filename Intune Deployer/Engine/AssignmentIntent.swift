import Foundation

/// How a selected item should be assigned in a tenant. Abstract — resolved to
/// concrete group/filter IDs at plan time.
nonisolated struct AssignmentIntent: Codable, Hashable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case none
        case allDevices
        case allUsers
        case group

        var displayName: String {
            switch self {
            case .none: "Leave unchanged"
            case .allDevices: "All devices"
            case .allUsers: "All users"
            case .group: "Static Entra group"
            }
        }
    }

    enum FilterMode: String, Codable, Sendable {
        case include
        case exclude
    }

    /// App install intent (apps only; other types install unconditionally).
    enum AppIntent: String, Codable, CaseIterable, Sendable {
        case required
        case available

        var displayName: String {
            switch self {
            case .required: "Required"
            case .available: "Available in Company Portal"
            }
        }
    }

    var mode: Mode = .none
    /// Static Entra security group, resolved by display name at plan time.
    var groupName: String = ""
    /// Assignment filter, referenced by display name; empty = no filter.
    var filterName: String = ""
    var filterMode: FilterMode = .include
    /// Install intent for app items; ignored for every other type.
    var appIntent: AppIntent = .required

    init() {}

    /// Tolerant decoding so intents saved by earlier builds (without
    /// appIntent) keep loading.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .none
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName) ?? ""
        filterName = try container.decodeIfPresent(String.self, forKey: .filterName) ?? ""
        filterMode = try container.decodeIfPresent(FilterMode.self, forKey: .filterMode) ?? .include
        appIntent = try container.decodeIfPresent(AppIntent.self, forKey: .appIntent) ?? .required
    }

    /// One-line description for menus and the "type default" hint.
    var summary: String {
        var text = switch mode {
        case .none: Mode.none.displayName
        case .allDevices, .allUsers: mode.displayName
        case .group: groupName.isEmpty ? "group (no name set)" : "group “\(groupName)”"
        }
        if mode != .none, !filterName.isEmpty {
            text += filterMode == .include ? ", filter “\(filterName)”" : ", excluding filter “\(filterName)”"
        }
        if mode != .none, appIntent == .available {
            text += ", available in Company Portal"
        }
        return text
    }
}

/// The built-in ADE enrollment filter templates (one per platform) the app
/// can create when a referenced filter is missing.
nonisolated enum BuiltInFilterTemplate {
    /// Rule contains a variable substituted per tenant at plan time.
    static let rule = #"(device.enrollmentProfileName -eq "{{EnrollmentProfileName}}")"#
    static let requiredToken = "EnrollmentProfileName"

    static func name(for platform: ItemPlatform) -> String {
        switch platform {
        case .macOS: "macOS - ADE Enrolled Devices"
        case .iOSiPadOS: "iOS/iPadOS - ADE Enrolled Devices"
        }
    }

    /// The template platform a filter name refers to, nil when it is not a
    /// template name.
    static func platform(forName name: String) -> ItemPlatform? {
        ItemPlatform.allCases.first { self.name(for: $0).caseInsensitiveCompare(name) == .orderedSame }
    }
}

// MARK: - Resolved forms (plan output)

/// A fully resolved assignment ready to be posted to the /assign action.
nonisolated struct ResolvedAssignment: Sendable, Hashable {
    enum Target: Sendable, Hashable {
        case allDevices
        case allUsers
        /// groupID is nil when the group will be created during this apply.
        case group(id: String?, name: String)
    }

    enum FilterResolution: Sendable, Hashable {
        /// Filter exists in the tenant.
        case existing(id: String)
        /// Filter is created by this plan (as a selected item or template);
        /// its ID becomes known during apply.
        case pendingCreation(name: String)
    }

    var target: Target
    var filter: FilterResolution?
    var filterMode: AssignmentIntent.FilterMode = .include
    /// Only meaningful for app assignments.
    var appIntent: AssignmentIntent.AppIntent = .required
}
