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

    /// - Parameter realTenantSession: the live checks' guarded network (JTKit
    ///   `LiveCheckNetwork`); by default the real network, under tests a
    ///   refusing one.
    init(auth: AuthManager, activityLog: ActivityLog, demo: DemoMode? = nil, realTenantSession: URLSession? = nil) {
        self.auth = auth
        self.activityLog = activityLog
        self.demo = demo
        self.realTenantSession = realTenantSession
            ?? (UnderTest.isActive ? SavedTenantGuard.shared.refusingSession(kind: "Graph") : .shared)
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
    func client(for profile: TenantProfile, scopes: [String] = GraphScopes.tenantRead) -> Graph.Client {
        let auth = auth
        let tokens = MicrosoftTokenSource { forceRefresh in
            try await auth.accessToken(profile: profile, scopes: scopes, forceRefresh: forceRefresh)
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
            "description": "Managed by Intune Deployer \(ItemIdentity.tag(forShortID: "0de0a1f1"))",
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
