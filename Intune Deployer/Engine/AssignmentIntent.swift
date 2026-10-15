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

    enum FilterMode: String, Codable, CaseIterable, Sendable {
        case include
        case exclude
    }

    var mode: Mode = .none
    /// Static Entra security group, resolved by display name at plan time.
    var groupName: String = ""
    /// Assignment filter, referenced by display name; empty = no filter.
    var filterName: String = ""
    var filterMode: FilterMode = .include

}

/// The built-in macOS ADE enrollment filter template the app can create when a
/// referenced filter is missing and the user asked for the template.
nonisolated enum BuiltInFilterTemplate {
    static let name = "macOS - ADE Enrolled Devices"
    /// Rule contains a variable substituted per tenant at plan time.
    static let rule = #"(device.enrollmentProfileName -eq "{{EnrollmentProfileName}}")"#
    static let requiredToken = "EnrollmentProfileName"
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
}
