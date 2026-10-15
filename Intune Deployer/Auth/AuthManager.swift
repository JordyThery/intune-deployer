import AppKit
import Foundation
import MSAL
import Observation
import OSLog

/// A Sendable snapshot of a signed-in MSAL account.
nonisolated struct SignedInAccount: Sendable, Equatable {
    let username: String
    /// MSAL account identifier (home account id) used for silent requests.
    let identifier: String
    /// Home tenant of the signed-in account.
    let homeTenantID: String?
}

nonisolated enum AuthError: LocalizedError {
    case invalidClientID
    case missingTenantID
    case noPresentationWindow
    case missingAccount
    case tokenMissing

    var errorDescription: String? {
        switch self {
        case .invalidClientID:
            "This tenant profile has no valid client ID. Edit the profile and enter the Application (client) ID of the app registration in that tenant."
        case .missingTenantID:
            "This tenant profile has no tenant ID."
        case .noPresentationWindow:
            "No window available to present the sign-in sheet."
        case .missingAccount:
            "Not signed in to this tenant."
        case .tokenMissing:
            "MSAL returned no token."
        }
    }
}

/// Registration details shown in Settings and the README; identical for every
/// per-tenant app registration.
nonisolated enum AppRegistrationInfo {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "" }
    /// MSAL's default macOS redirect URI format: msauth.<bundle-id>://auth
    static var redirectURI: String { "msauth.\(bundleID)://auth" }
}

/// Delegated Microsoft Graph scopes used by the app, requested incrementally.
nonisolated enum GraphScopes {
    static let signIn = ["User.Read"]
    /// Read-only scopes for preflight and tenant inventory. Verified
    /// least-privileged per endpoint docs:
    /// - configurationPolicies / deviceConfigurations / compliance / filters:
    ///   DeviceManagementConfiguration.Read.All
    /// - deviceShellScripts / deviceCustomAttributeShellScripts:
    ///   DeviceManagementScripts.Read.All
    /// - applePushNotificationCertificate / depOnboardingSettings / MDM authority:
    ///   DeviceManagementServiceConfig.Read.All
    /// - mobileApps: DeviceManagementApps.Read.All
    static let tenantRead = [
        "User.Read",
        "DeviceManagementConfiguration.Read.All",
        "DeviceManagementScripts.Read.All",
        "DeviceManagementServiceConfig.Read.All",
        "DeviceManagementApps.Read.All",
    ]

    /// Planning additionally resolves group names (Group.Read.All is a
    /// documented valid permission for GET /groups).
    static let planRead = tenantRead + ["Group.Read.All"]

    /// Apply writes objects. Write permissions verified per endpoint docs:
    /// - configurationPolicies / deviceConfigurations / compliance / filters:
    ///   DeviceManagementConfiguration.ReadWrite.All
    /// - deviceShellScripts / deviceCustomAttributeShellScripts:
    ///   DeviceManagementScripts.ReadWrite.All
    /// Group.ReadWrite.All is requested only when the profile opts into
    /// creating missing groups.
    static func applyScopes(allowGroupCreation: Bool) -> [String] {
        var scopes = [
            "User.Read",
            "DeviceManagementConfiguration.ReadWrite.All",
            "DeviceManagementScripts.ReadWrite.All",
            "DeviceManagementApps.ReadWrite.All",
            "DeviceManagementServiceConfig.Read.All",
            "Group.Read.All",
        ]
        if allowGroupCreation {
            scopes.append("Group.ReadWrite.All")
        }
        return scopes
    }
}

/// Wraps MSAL for the per-tenant registration model: every tenant profile
/// carries its own client ID + tenant ID, and has its own signed-in account.
/// One MSALPublicClientApplication is kept per client ID; the keychain cache
/// is shared, so accounts survive relaunches.
@MainActor
@Observable
final class AuthManager {
    private static let logger = Logger(subsystem: "be.jordythery.intune-deployer", category: "Auth")
    private static let authorityBase = "https://login.microsoftonline.com"

    /// Signed-in account per tenant profile ID.
    private(set) var accountsByProfile: [UUID: SignedInAccount] = [:]
    /// Scopes granted on the most recent token per profile (shown in preflight).
    private(set) var grantedScopesByProfile: [UUID: [String]] = [:]
    private(set) var signingInProfileIDs: Set<UUID> = []

    private var applications: [String: MSALPublicClientApplication] = [:]
    /// One interactive prompt per profile: parallel Graph requests that all
    /// hit "interaction required" share a single consent flow.
    private var pendingInteractive: [UUID: Task<TokenOutcome, any Error>] = [:]

    func account(for profile: TenantProfile) -> SignedInAccount? {
        accountsByProfile[profile.id]
    }

    func isSignedIn(_ profile: TenantProfile) -> Bool {
        accountsByProfile[profile.id] != nil
    }

    func grantedScopes(for profile: TenantProfile) -> [String] {
        grantedScopesByProfile[profile.id] ?? []
    }

    // MARK: - Cache restore

    /// Restores this profile's cached account from the keychain, if any.
    func restoreAccount(for profile: TenantProfile) {
        guard accountsByProfile[profile.id] == nil,
              let application = try? application(for: profile) else { return }

        var restored: MSALAccount?
        if let identifier = profile.accountIdentifier {
            restored = try? application.account(forIdentifier: identifier)
        }
        if restored == nil {
            // Fall back to a cached account whose home tenant matches; the
            // registration is tenant-specific, so a single cached account for
            // this client ID also belongs to this tenant (covers profiles
            // configured with a verified domain instead of a GUID).
            let tenantID = profile.tenantID.trimmingCharacters(in: .whitespaces).lowercased()
            let accounts = (try? application.allAccounts()) ?? []
            restored = accounts.first { $0.homeAccountId?.tenantId?.lowercased() == tenantID }
                ?? (accounts.count == 1 ? accounts[0] : nil)
        }
        if let restored {
            accountsByProfile[profile.id] = SignedInAccount(
                username: restored.username ?? "unknown",
                identifier: restored.identifier ?? "",
                homeTenantID: restored.homeAccountId?.tenantId
            )
        }
    }

    // MARK: - Sign in / out

    /// Interactive sign-in against this profile's tenant. Returns the account
    /// so the caller can persist its identifier on the profile.
    @discardableResult
    func signIn(profile: TenantProfile, scopes: [String] = GraphScopes.tenantRead) async throws -> SignedInAccount {
        let application = try application(for: profile)
        guard let viewController = Self.presentationViewController() else {
            throw AuthError.noPresentationWindow
        }

        signingInProfileIDs.insert(profile.id)
        defer { signingInProfileIDs.remove(profile.id) }

        let webviewParameters = MSALWebviewParameters(authPresentationViewController: viewController)
        let parameters = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webviewParameters)
        parameters.promptType = .selectAccount
        parameters.authority = try authority(for: profile)

        let outcome = try await Self.acquireInteractive(application: application, parameters: parameters)
        accountsByProfile[profile.id] = outcome.account
        grantedScopesByProfile[profile.id] = outcome.grantedScopes
        Self.logger.info("Signed in to \(profile.displayName, privacy: .public) as \(outcome.account.username, privacy: .private(mask: .hash))")
        return outcome.account
    }

    func signOut(profile: TenantProfile) async {
        defer {
            accountsByProfile[profile.id] = nil
            grantedScopesByProfile[profile.id] = nil
        }
        guard let application = try? application(for: profile),
              let identifier = accountsByProfile[profile.id]?.identifier,
              let msalAccount = try? application.account(forIdentifier: identifier) else {
            return
        }
        try? application.remove(msalAccount)
    }

    // MARK: - Tokens

    /// Access token for this profile's tenant: silent first, interactive
    /// fallback when MSAL reports that user interaction is required.
    func accessToken(profile: TenantProfile, scopes: [String]) async throws -> String {
        let application = try application(for: profile)
        guard let identifier = accountsByProfile[profile.id]?.identifier,
              let msalAccount = try? application.account(forIdentifier: identifier) else {
            throw AuthError.missingAccount
        }

        let parameters = MSALSilentTokenParameters(scopes: scopes, account: msalAccount)
        parameters.authority = try authority(for: profile)

        do {
            let outcome = try await Self.acquireSilent(application: application, parameters: parameters)
            grantedScopesByProfile[profile.id] = outcome.grantedScopes
            return outcome.accessToken
        } catch let error as NSError where error.domain == MSALErrorDomain
            && error.code == MSALError.interactionRequired.rawValue {
            // e.g. first use of a new scope: consent needed — go interactive,
            // sharing one prompt between concurrent requests.
            if let pending = pendingInteractive[profile.id] {
                return try await pending.value.accessToken
            }
            let authority = try authority(for: profile)
            let task = Task { @MainActor in
                guard let viewController = Self.presentationViewController() else {
                    throw AuthError.noPresentationWindow
                }
                let webviewParameters = MSALWebviewParameters(authPresentationViewController: viewController)
                let interactive = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webviewParameters)
                interactive.authority = authority
                return try await Self.acquireInteractive(application: application, parameters: interactive)
            }
            pendingInteractive[profile.id] = task
            defer { pendingInteractive[profile.id] = nil }
            let outcome = try await task.value
            accountsByProfile[profile.id] = outcome.account
            grantedScopesByProfile[profile.id] = outcome.grantedScopes
            return outcome.accessToken
        }
    }

    // MARK: - MSAL plumbing

    private func application(for profile: TenantProfile) throws -> MSALPublicClientApplication {
        let clientID = profile.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: clientID) != nil else { throw AuthError.invalidClientID }
        if let cached = applications[clientID] {
            return cached
        }
        let config = MSALPublicClientApplicationConfig(
            clientId: clientID,
            redirectUri: AppRegistrationInfo.redirectURI,
            authority: try authority(for: profile)
        )
        let application = try MSALPublicClientApplication(configuration: config)
        applications[clientID] = application
        return application
    }

    private func authority(for profile: TenantProfile) throws -> MSALAADAuthority {
        let tenantID = profile.tenantID.trimmingCharacters(in: .whitespaces)
        guard !tenantID.isEmpty, let url = URL(string: "\(Self.authorityBase)/\(tenantID)") else {
            throw AuthError.missingTenantID
        }
        return try MSALAADAuthority(url: url)
    }

    private struct TokenOutcome: Sendable {
        let accessToken: String
        let grantedScopes: [String]
        let account: SignedInAccount
    }

    private static func acquireInteractive(
        application: MSALPublicClientApplication,
        parameters: MSALInteractiveTokenParameters
    ) async throws -> TokenOutcome {
        try await withCheckedThrowingContinuation { continuation in
            application.acquireToken(with: parameters) { result, error in
                continuation.resume(with: Self.outcome(result: result, error: error))
            }
        }
    }

    private static func acquireSilent(
        application: MSALPublicClientApplication,
        parameters: MSALSilentTokenParameters
    ) async throws -> TokenOutcome {
        try await withCheckedThrowingContinuation { continuation in
            application.acquireTokenSilent(with: parameters) { result, error in
                continuation.resume(with: Self.outcome(result: result, error: error))
            }
        }
    }

    nonisolated private static func outcome(
        result: MSALResult?,
        error: (any Error)?
    ) -> Result<TokenOutcome, any Error> {
        if let result {
            return .success(TokenOutcome(
                accessToken: result.accessToken,
                grantedScopes: result.scopes,
                account: SignedInAccount(
                    username: result.account.username ?? "unknown",
                    identifier: result.account.identifier ?? "",
                    homeTenantID: result.account.homeAccountId?.tenantId
                )
            ))
        }
        return .failure(error ?? AuthError.tokenMissing)
    }

    /// MSAL needs an NSViewController whose view is attached to a window.
    ///
    /// IMPORTANT: the anchor must be the FRONTMOST (key) window. Anchoring to
    /// the main window while one of our sheets is open makes macOS queue the
    /// auth sheet behind it — it never appears and token acquisition hangs.
    /// SwiftUI sheet windows may lack a contentViewController, so each window
    /// gets a zero-size host controller as fallback before moving on.
    private static func presentationViewController() -> NSViewController? {
        var candidates: [NSWindow] = []
        if let key = NSApp.keyWindow { candidates.append(key) }
        if let main = NSApp.mainWindow, main !== NSApp.keyWindow { candidates.append(main) }
        candidates.append(contentsOf: NSApp.windows.filter { $0.isVisible && !candidates.contains($0) })

        for window in candidates {
            if let viewController = window.contentViewController {
                return viewController
            }
            if let contentView = window.contentView {
                let host = NSViewController()
                host.view = NSView(frame: .zero)
                contentView.addSubview(host.view)
                return host
            }
        }
        return nil
    }
}
