import Foundation
import JTKit

/// A tenant profile: which Entra tenant to deploy to and how.
///
/// Each target tenant gets its OWN app registration (public client, no
/// secret), so client ID and tenant ID travel together here. The profile also
/// remembers which signed-in account (MSAL identifier) to use for this tenant.
/// Stored as JSON in Application Support; exportable from the tenant view.
nonisolated struct TenantProfile: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var displayName: String
    /// Application (client) ID of the app registration in this tenant.
    var clientID: String
    /// Entra tenant ID (GUID) or verified domain.
    var tenantID: String
    /// Prepended to object names on deploy, e.g. "[CONTOSO]".
    var namingPrefix: String
    /// Values for `{{Token}}` placeholders, substituted at plan time.
    var variables: [String: String]
    /// Item IDs (inference short IDs) selected for this tenant.
    var selectedItemIDs: Set<String>
    /// Per-item assignment intents, keyed by item ID.
    var assignments: [String: AssignmentIntent]
    /// Default assignment intents per item type, used for items without their
    /// own intent. Assignment filters cannot be assigned and have no default.
    var defaultAssignments: [ItemType: AssignmentIntent]
    /// Whether Apply may create missing static Entra groups
    /// (requires consenting to Group.ReadWrite.All).
    var allowGroupCreation: Bool
    /// MSAL account identifier last used to sign in to this tenant.
    var accountIdentifier: String?

    init(
        id: UUID = UUID(),
        displayName: String = "",
        clientID: String = "",
        tenantID: String = "",
        namingPrefix: String = "",
        variables: [String: String] = [:],
        selectedItemIDs: Set<String> = [],
        assignments: [String: AssignmentIntent] = [:],
        defaultAssignments: [ItemType: AssignmentIntent] = [:],
        allowGroupCreation: Bool = false,
        accountIdentifier: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.clientID = clientID
        self.tenantID = tenantID
        self.namingPrefix = namingPrefix
        self.variables = variables
        self.selectedItemIDs = selectedItemIDs
        self.assignments = assignments
        self.defaultAssignments = defaultAssignments
        self.allowGroupCreation = allowGroupCreation
        self.accountIdentifier = accountIdentifier
    }

    /// The keys in tenants.json and exported profiles. Never rename them.
    private enum CodingKeys: String, CodingKey {
        case id, displayName, clientID, tenantID, namingPrefix, variables, selectedItemIDs,
             assignments, defaultAssignments, allowGroupCreation, accountIdentifier
    }

    /// Tolerant decoding so profiles saved by earlier builds (without
    /// clientID/accountIdentifier) keep loading.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        tenantID = try container.decode(String.self, forKey: .tenantID)
        namingPrefix = try container.decodeIfPresent(String.self, forKey: .namingPrefix) ?? ""
        variables = try container.decodeIfPresent([String: String].self, forKey: .variables) ?? [:]
        selectedItemIDs = try container.decodeIfPresent(Set<String>.self, forKey: .selectedItemIDs) ?? []
        assignments = try container.decodeIfPresent([String: AssignmentIntent].self, forKey: .assignments) ?? [:]
        defaultAssignments = try container.decodeIfPresent([ItemType: AssignmentIntent].self, forKey: .defaultAssignments) ?? [:]
        allowGroupCreation = try container.decodeIfPresent(Bool.self, forKey: .allowGroupCreation) ?? false
        accountIdentifier = try container.decodeIfPresent(String.self, forKey: .accountIdentifier)
    }

    /// The same keys and shape as before. The chosen items are written in
    /// sorted order, so tenants.json only changes when its content does.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(clientID, forKey: .clientID)
        try container.encode(tenantID, forKey: .tenantID)
        try container.encode(namingPrefix, forKey: .namingPrefix)
        try container.encode(variables, forKey: .variables)
        try container.encode(selectedItemIDs.sorted(), forKey: .selectedItemIDs)
        try container.encode(assignments, forKey: .assignments)
        try container.encode(defaultAssignments, forKey: .defaultAssignments)
        try container.encode(allowGroupCreation, forKey: .allowGroupCreation)
        try container.encodeIfPresent(accountIdentifier, forKey: .accountIdentifier)
    }

    var hasValidClientID: Bool {
        UUID(uuidString: clientID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    /// The intent used at plan time: an explicit per-item intent wins, then
    /// the per-type default, then "leave unchanged". A stored intent — even
    /// "leave unchanged" — overrides the type default. Assignment filters
    /// cannot be assigned, so any intent stored for one is ignored.
    func effectiveAssignment(for itemID: String, type: ItemType) -> AssignmentIntent {
        guard type != .assignmentFilter else { return AssignmentIntent() }
        if let explicit = assignments[itemID] { return explicit }
        return defaultAssignments[type] ?? AssignmentIntent()
    }
}

/// What JTKit's Settings › Connections shows and changes: the name, tenant ID
/// and client ID. Everything else is the tenant's baseline, set in the main
/// window.
nonisolated extension TenantProfile: ConnectionRecord {
    var connection: Connection {
        get {
            Connection(id: id, name: displayName, service: .intune, signIn: .microsoftInteractive,
                       clientID: clientID, tenantID: tenantID)
        }
        set {
            displayName = newValue.name
            clientID = newValue.clientID
            tenantID = newValue.tenantID
        }
    }
}
