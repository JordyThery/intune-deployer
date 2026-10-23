import Foundation

/// How a selected item should be assigned in a tenant: a list of include and
/// exclude targets. An empty list means "leave assignments unchanged".
/// Abstract — resolved to concrete group/filter IDs at plan time.
nonisolated struct AssignmentIntent: Codable, Hashable, Sendable {
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

    var targets: [AssignmentTarget] = []

    /// True when the app leaves the object's assignments untouched.
    var leavesUnchanged: Bool { targets.isEmpty }

    init(targets: [AssignmentTarget] = []) {
        self.targets = targets
    }

    /// One include target.
    static func single(_ scope: AssignmentTarget.Scope) -> AssignmentIntent {
        AssignmentIntent(targets: [AssignmentTarget(scope: scope)])
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case targets
        // Single-target format written by earlier builds.
        case mode, groupName, filterName, filterMode, appIntent
    }

    /// Reads the target list, or converts the single-target format of earlier
    /// builds into a one-entry list ("none" becomes an empty list).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let targets = try container.decodeIfPresent([AssignmentTarget].self, forKey: .targets) {
            self.targets = targets
            return
        }
        let mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "none"
        guard let scope = AssignmentTarget.Scope(rawValue: mode) else {
            self.targets = []
            return
        }
        var target = AssignmentTarget(scope: scope)
        target.groupName = try container.decodeIfPresent(String.self, forKey: .groupName) ?? ""
        target.filterName = try container.decodeIfPresent(String.self, forKey: .filterName) ?? ""
        target.filterMode = try container.decodeIfPresent(FilterMode.self, forKey: .filterMode) ?? .include
        target.appIntent = try container.decodeIfPresent(AppIntent.self, forKey: .appIntent) ?? .required
        self.targets = [target]
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targets, forKey: .targets)
    }

    /// One-line description for menus and the "type default" hint.
    var summary: String {
        guard !targets.isEmpty else { return "Leave unchanged" }
        return targets.map(\.summary).joined(separator: "; ")
    }
}

/// One assignment target. Includes can target All devices, All users or a
/// group, with an optional filter and (for apps) an install intent;
/// exclusions can only target groups and carry no filter (Intune rules).
nonisolated struct AssignmentTarget: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case include
        case exclude

        var displayName: String {
            switch self {
            case .include: "Include"
            case .exclude: "Exclude"
            }
        }
    }

    enum Scope: String, Codable, CaseIterable, Sendable {
        case allDevices
        case allUsers
        case group

        var displayName: String {
            switch self {
            case .allDevices: "All devices"
            case .allUsers: "All users"
            case .group: "Group"
            }
        }
    }

    var kind: Kind = .include
    var scope: Scope = .allDevices
    /// Static Entra security group, resolved by display name at plan time.
    var groupName: String = ""
    /// Assignment filter, referenced by display name; empty = no filter.
    var filterName: String = ""
    var filterMode: AssignmentIntent.FilterMode = .include
    /// Install intent for app items; ignored for every other type.
    var appIntent: AssignmentIntent.AppIntent = .required

    init(kind: Kind = .include, scope: Scope = .allDevices, groupName: String = "") {
        self.kind = kind
        self.scope = scope
        self.groupName = groupName
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .include
        scope = try container.decodeIfPresent(Scope.self, forKey: .scope) ?? .allDevices
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName) ?? ""
        filterName = try container.decodeIfPresent(String.self, forKey: .filterName) ?? ""
        filterMode = try container.decodeIfPresent(AssignmentIntent.FilterMode.self, forKey: .filterMode) ?? .include
        appIntent = try container.decodeIfPresent(AssignmentIntent.AppIntent.self, forKey: .appIntent) ?? .required
    }

    var trimmedGroupName: String {
        groupName.trimmingCharacters(in: .whitespaces)
    }

    var trimmedFilterName: String {
        filterName.trimmingCharacters(in: .whitespaces)
    }

    var summary: String {
        var text = switch scope {
        case .allDevices, .allUsers: scope.displayName
        case .group: groupName.isEmpty ? "group (no name set)" : "group “\(groupName)”"
        }
        if kind == .exclude {
            return "excluding \(text)"
        }
        if !filterName.isEmpty {
            text += filterMode == .include ? ", filter “\(filterName)”" : ", excluding filter “\(filterName)”"
        }
        if appIntent == .available {
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
    /// Exclusion targets are always groups and never carry a filter.
    var isExclusion: Bool = false
}
