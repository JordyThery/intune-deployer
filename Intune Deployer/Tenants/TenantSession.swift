import Foundation
import JTKit
import Observation

/// Runtime state for the currently selected tenant profile: a Graph client
/// bound to that tenant's authority, the preflight report and the inventory
/// of existing tenant objects.
@MainActor
@Observable
final class TenantSession {
    private let auth: AuthManager
    let activityLog: ActivityLog

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

    init(auth: AuthManager, activityLog: ActivityLog) {
        self.auth = auth
        self.activityLog = activityLog
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

    func client(for profile: TenantProfile, scopes: [String] = GraphScopes.tenantRead) -> GraphClient {
        let auth = auth
        return GraphClient(
            tokenProvider: { @Sendable in
                try await auth.accessToken(profile: profile, scopes: scopes)
            },
            activityLog: activityLog
        )
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
