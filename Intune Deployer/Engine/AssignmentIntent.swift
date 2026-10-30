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

// MARK: - Assignments as Graph sends and returns them

/// The entries of an `/assign` body (they replace the object's assignments),
/// built in one place so Plan compares exactly what Apply would send.
nonisolated enum AssignmentBody {
    /// Scripts use deviceManagementScriptAssignments, apps
    /// mobileAppAssignments, other collections assignments.
    /// TODO(verify): the configurationPolicies assign body shape follows the
    /// documented sibling actions; its own doc page is unpublished.
    static func parameterName(for collection: TenantCollection) -> String {
        switch collection {
        case .shellScripts, .customAttributes: "deviceManagementScriptAssignments"
        case .apps: "mobileAppAssignments"
        default: "assignments"
        }
    }

    /// Throws when a group or filter created during this Apply has no ID yet.
    static func entries(_ assignments: [ResolvedAssignment], collection: TenantCollection,
                        createdGroupIDs: [String: String] = [:], createdFilterIDs: [String: String] = [:]) throws -> [[String: Any]] {
        // App exclusions apply per install intent (the portal lists them per
        // section), so each is sent once for every intent the includes use.
        // TODO(verify): exclusions alongside mixed Required/Available
        // includes have not been tested against a live tenant.
        var includeIntents: [AssignmentIntent.AppIntent] = []
        for assignment in assignments where !assignment.isExclusion && !includeIntents.contains(assignment.appIntent) {
            includeIntents.append(assignment.appIntent)
        }
        let exclusionIntents = includeIntents.isEmpty ? [.required] : includeIntents

        var entries: [[String: Any]] = []
        for assignment in assignments {
            let target = try target(assignment, createdGroupIDs: createdGroupIDs, createdFilterIDs: createdFilterIDs)
            // Apps carry an install intent; every other collection only a target.
            switch collection {
            case .apps:
                for intent in assignment.isExclusion ? exclusionIntents : [assignment.appIntent] {
                    entries.append([
                        "@odata.type": "#microsoft.graph.mobileAppAssignment",
                        "intent": intent.rawValue,
                        "target": target,
                    ])
                }
            default:
                entries.append(["target": target])
            }
        }
        return entries
    }

    /// The Graph assignment target for one resolved include or exclusion.
    static func target(_ assignment: ResolvedAssignment, createdGroupIDs: [String: String],
                       createdFilterIDs: [String: String]) throws -> [String: Any] {
        var target: [String: Any]
        switch assignment.target {
        case .allDevices:
            target = ["@odata.type": "#microsoft.graph.allDevicesAssignmentTarget"]
        case .allUsers:
            target = ["@odata.type": "#microsoft.graph.allLicensedUsersAssignmentTarget"]
        case .group(let id, let name):
            guard let groupID = id ?? createdGroupIDs[name] else {
                throw PayloadError.unsupportedItem("Group “\(name)” was not created")
            }
            target = [
                "@odata.type": assignment.isExclusion
                    ? "#microsoft.graph.exclusionGroupAssignmentTarget"
                    : "#microsoft.graph.groupAssignmentTarget",
                "groupId": groupID,
            ]
        }
        if let filter = assignment.filter, !assignment.isExclusion {
            let filterID: String?
            switch filter {
            case .existing(let id): filterID = id
            case .pendingCreation(let name): filterID = createdFilterIDs[name]
            }
            guard let filterID else {
                throw PayloadError.unsupportedItem("Assignment filter was not created")
            }
            target["deviceAndAppManagementAssignmentFilterId"] = filterID
            target["deviceAndAppManagementAssignmentFilterType"] = assignment.filterMode.rawValue
        }
        return target
    }
}

/// One assignment, compared the same way whether built for `/assign` or
/// read from the tenant (bug 1 of the JTKit step 11 survey): target type,
/// group, filter and its mode, and (apps) install intent. Case and Graph's
/// "no filter" forms don't count.
nonisolated struct AssignmentEntry: Hashable, Sendable {
    var targetType: String
    var groupID: String?
    var filterID: String?
    var filterType: String?
    var intent: String?

    /// An `/assign` entry or an assignment as Graph returns it; nil without a target.
    init?(graph value: Any) {
        guard let entry = value as? [String: Any], let target = entry["target"] as? [String: Any],
              let type = target["@odata.type"] as? String else { return nil }
        targetType = type.lowercased()
        groupID = (target["groupId"] as? String)?.lowercased()
        let filter = (target["deviceAndAppManagementAssignmentFilterId"] as? String)?.lowercased()
        if let filter, !filter.isEmpty, filter != "00000000-0000-0000-0000-000000000000" {
            filterID = filter
            filterType = (target["deviceAndAppManagementAssignmentFilterType"] as? String)?.lowercased()
        }
        intent = (entry["intent"] as? String)?.lowercased()
    }

    /// The entries Apply would send, nil while a group or filter is still to
    /// be created (they can't match what's there).
    static func desired(_ assignments: [ResolvedAssignment], collection: TenantCollection) -> Set<AssignmentEntry>? {
        guard let entries = try? AssignmentBody.entries(assignments, collection: collection) else { return nil }
        return Set(entries.compactMap { AssignmentEntry(graph: $0) })
    }
}
