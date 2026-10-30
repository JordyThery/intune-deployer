import Foundation
import JTKit
import JTKitMSAL
import Observation

/// Runtime state for the currently selected tenant profile: a Graph client
/// bound to that tenant's authority, the preflight report and the inventory
/// of existing tenant objects.
@MainActor
@Observable
final class TenantSession {
    private let auth: AuthManager
    let activityLog: ActivityLog
    /// The app's demo mode; nil without demo mode.
    @ObservationIgnored private let demo: DemoMode?
    @ObservationIgnored private var demoTenantPrepared = false

    private(set) var preflightChecks: [PreflightCheck]?
    private(set) var isRunningPreflight = false

    private(set) var inventory: [TenantCollection: [TenantObject]] = [:]
    private(set) var inventoryErrors: [TenantCollection: String] = [:]
    private(set) var isLoadingInventory = false

    // Deploy state (managed by TenantSession+Deploy).
    var currentPlan: Plan?
    var planError: String?
    var isPlanning = false
    var applyResults: [ApplyResult]?
    var isApplying = false

    // Export state (managed by TenantSession+Export).
    var isExporting = false

    /// Incremented by reset(); long-running loads compare it before writing
    /// results so a tenant switch discards stale data.
    var generation = 0

    /// A real tenant's network: the real one; under tests one that refuses
    /// and records every request (`SavedTenantGuard`), or the release
    /// check's guarded network for its live checks.
    @ObservationIgnored private let realTenantSession: URLSession

    /// A token for a profile and permissions (`forceRefresh` after a 401):
    /// the app's sign-in; tests give their own.
    typealias TokenProvider = @MainActor @Sendable (TenantProfile, [String], Bool) async throws -> String
    @ObservationIgnored private let tokenProvider: TokenProvider?

    /// The tenant each profile's tokens were confirmed for (a profile with a
    /// verified domain instead of a tenant ID is confirmed once, before its
    /// first write), keyed by profile ID and tenant field.
    @ObservationIgnored private var confirmedTenantIDs: [String: String] = [:]

    /// - Parameters:
    ///   - realTenantSession: the live checks' guarded network (JTKit
    ///     `LiveCheckNetwork`); by default the real network, under tests a
    ///     refusing one.
    ///   - tokenProvider: tests only; by default the app's sign-in.
    init(auth: AuthManager, activityLog: ActivityLog, demo: DemoMode? = nil, realTenantSession: URLSession? = nil,
         tokenProvider: TokenProvider? = nil) {
        self.auth = auth
        self.activityLog = activityLog
        self.demo = demo
        self.realTenantSession = realTenantSession
            ?? (UnderTest.isActive ? SavedTenantGuard.shared.refusingSession(kind: "Graph") : .shared)
        self.tokenProvider = tokenProvider
    }

    /// Clears per-tenant state when the selected profile changes.
    func reset() {
        generation += 1
        preflightChecks = nil
        inventory = [:]
        inventoryErrors = [:]
        currentPlan = nil
        planError = nil
        applyResults = nil
    }

    /// JTKit's Graph client for the tenant, with tokens from this Mac's
    /// sign-in for these permissions (a fresh one after Graph answered 401).
    ///
    /// The demo tenant's client sends everything (uploads included, which
    /// use its session) to JTKit's demo network, answered inside the app by
    /// the demo tenant; without demo mode, to a network that answers nothing.
    /// A real tenant's never does.
    ///
    /// Every token of a real tenant is checked before anything is sent with
    /// it: its tenant (`tid`) must be the profile's tenant ID, or, for a
    /// profile with a verified domain, the tenant confirmed for that domain
    /// (`writeClient`). Otherwise the request fails and nothing is sent
    /// (bug 5 of the JTKit step 11 survey).
    func client(for profile: TenantProfile, scopes: [String] = GraphScopes.tenantRead) -> Graph.Client {
        let auth = auth
        let provider = tokenProvider
        let expected = profile.isDemo ? nil : expectedTenantID(for: profile)
        let tokens = MicrosoftTokenSource { @MainActor forceRefresh in
            let token = if let provider {
                try await provider(profile, scopes, forceRefresh)
            } else {
                try await auth.accessToken(profile: profile, scopes: scopes, forceRefresh: forceRefresh)
            }
            if let expected { try TenantCheck.require(token, isFor: expected, profile: profile) }
            return token
        }
        let session: URLSession
        if profile.isDemo {
            prepareDemoTenant()
            session = demo?.microsoftSignIn().session ?? DemoNetwork(servers: [:]).session
        } else {
            session = realTenantSession
        }
        return Graph.Client(tokens: tokens, access: .delegated,
                            recorder: Graph.recorder(session: session, log: activityLog, connection: profile.displayName))
    }

    // MARK: - The tenant check (bug 5)

    /// The tenant ID every token must be for: the profile's tenant ID, or
    /// the one confirmed for its domain; nil until a domain is confirmed.
    private func expectedTenantID(for profile: TenantProfile) -> String? {
        let tenant = profile.tenantID.trimmingCharacters(in: .whitespaces).lowercased()
        if UUID(uuidString: tenant) != nil { return tenant }
        return confirmedTenantIDs["\(profile.id)|\(tenant)"]
    }

    /// A client for writes: its tokens are checked against the profile's
    /// tenant before anything is sent. A profile with a verified domain is
    /// confirmed first: the token's tenant must list that domain
    /// (`organization`'s verified domains), read with that token.
    func writeClient(for profile: TenantProfile, scopes: [String]) async throws -> Graph.Client {
        let tenant = profile.tenantID.trimmingCharacters(in: .whitespaces).lowercased()
        guard !profile.isDemo, UUID(uuidString: tenant) == nil, expectedTenantID(for: profile) == nil else {
            return client(for: profile, scopes: scopes)
        }
        let token = if let tokenProvider {
            try await tokenProvider(profile, scopes, false)
        } else {
            try await auth.accessToken(profile: profile, scopes: scopes)
        }
        guard let tokenTenant = TenantCheck.tenantID(ofAccessToken: token) else { throw TenantCheck.Failure.unreadable }
        confirmedTenantIDs["\(profile.id)|\(tenant)"] = tokenTenant
        let checking = client(for: profile, scopes: scopes)
        nonisolated struct Organization: Decodable, Sendable {
            nonisolated struct Domain: Decodable, Sendable { let name: String }
            let id: String
            let verifiedDomains: [Domain]?
        }
        do {
            let organizations = try await checking.list(Organization.self, "organization?$select=id,verifiedDomains", version: .v1)
            guard let organization = organizations.first, organization.id.lowercased() == tokenTenant,
                  organization.verifiedDomains?.contains(where: { $0.name.lowercased() == tenant }) == true else {
                throw TenantCheck.Failure.domainNotInTenant(domain: profile.tenantID, profile: profile.displayName)
            }
        } catch {
            confirmedTenantIDs["\(profile.id)|\(tenant)"] = nil
            throw error
        }
        return checking
    }

    // MARK: - Demo tenant

    /// Once per launch: a tagged object that no baseline item matches, as
    /// left behind by an earlier deploy, so a Plan on the demo tenant also
    /// shows a deletion.
    private func prepareDemoTenant() {
        guard let demo, !demoTenantPrepared else { return }
        demoTenantPrepared = true
        let leftOver: [String: Any] = [
            "@odata.type": "#microsoft.graph.macOSCustomConfiguration",
            "displayName": "Contoso – Legacy Wi-Fi",
            "description": "Managed by Intune Deployer \(ItemIdentity.tag(forShortID: "0de0a1f1", profileID: TenantProfile.demo.id))",
            "payloadName": "Legacy Wi-Fi",
            "payloadFileName": "legacy-wifi.mobileconfig",
            "payload": Data("<plist version=\"1.0\"><dict/></plist>".utf8).base64EncodedString(),
            "id": DemoSamples.uuid(0xe7a1),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: leftOver) {
            demo.intuneServer.add([data], to: TenantCollection.deviceConfigurations.listPath)
        }
    }

    /// The demo tenant's catalog can't know a baseline's settings: before a
    /// Plan, it learns the ones the selected Settings Catalog items use, so
    /// the Plan's check of setting IDs passes (a typo in an ID isn't caught
    /// in demo mode). Names are made from the IDs.
    func addToDemoCatalog(settingsIn payloads: [Data]) {
        guard let demo else { return }
        let ids = payloads.reduce(into: Set<String>()) { $0.formUnion(PlanEngine.settingDefinitionIDs(in: $1)) }
        demo.intuneServer.add(definitions: ids.sorted().map { id in
            let name = id.split(separator: "_").last.map(String.init) ?? id
            return DemoSettingDefinition(id: id, displayName: name)
        })
    }

    // MARK: - Preflight

    func runPreflight(for profile: TenantProfile) async {
        isRunningPreflight = true
        defer { isRunningPreflight = false }
        let startedGeneration = generation

        // Acquire a token first so the granted scopes reflect reality after a
        // relaunch (they are only populated by a token response).
        _ = try? await auth.accessToken(profile: profile, scopes: GraphScopes.tenantRead)

        let service = PreflightService(client: client(for: profile))
        let checks = await service.run(
            grantedScopes: auth.grantedScopes(for: profile),
            requiredScopes: GraphScopes.tenantRead
        )
        guard generation == startedGeneration else { return }
        preflightChecks = checks
    }

    // MARK: - Inventory

    /// Lists existing tenant objects of all managed types.
    func loadInventory(for profile: TenantProfile) async {
        isLoadingInventory = true
        defer { isLoadingInventory = false }
        let startedGeneration = generation

        let client = client(for: profile)
        inventoryErrors = [:]

        // Collections load in parallel; the client caps HTTP concurrency.
        await withTaskGroup(of: (TenantCollection, Result<[TenantObject], any Error>).self) { group in
            for collection in TenantCollection.allCases {
                group.addTask {
                    do {
                        let objects = try await client.list(
                            TenantObject.self,
                            collection.listPath,
                            version: collection.version
                        )
                        return (collection, .success(objects))
                    } catch {
                        return (collection, .failure(error))
                    }
                }
            }
            for await (collection, result) in group {
                guard generation == startedGeneration else { continue }
                switch result {
                case .success(var objects):
                    // mobileApps is a mixed collection; show only managed macOS types.
                    if collection == .apps {
                        objects = objects.filter {
                            TenantCollection.managedAppODataTypes.contains($0.odataType ?? "")
                        }
                    }
                    inventory[collection] = objects.sorted {
                        $0.resolvedName.localizedCaseInsensitiveCompare($1.resolvedName) == .orderedAscending
                    }
                case .failure(let error):
                    inventory[collection] = nil
                    inventoryErrors[collection] = error.localizedDescription
                }
            }
        }
    }
}
