import Foundation
import JTKitMSAL
import Observation
import OSLog

/// A Sendable snapshot of a signed-in Microsoft account.
nonisolated struct SignedInAccount: Sendable, Equatable {
    let username: String
    /// MSAL account identifier (home account id) used for silent requests.
    let identifier: String

    init(username: String, identifier: String) {
        self.username = username
        self.identifier = identifier
    }

    init(_ account: MicrosoftAccount) {
        self.init(username: account.username, identifier: account.identifier)
    }
}

/// Registration details shown in Settings and the README; identical for every
/// per-tenant app registration.
nonisolated enum AppRegistrationInfo {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "" }
    /// MSAL's default macOS redirect URI format: msauth.<bundle-id>://auth
    static var redirectURI: String { MicrosoftSignIn.defaultRedirectURI }
}

/// Delegated Microsoft Graph scopes used by the app, requested incrementally.
nonisolated enum GraphScopes {
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

/// The per-tenant sign-in state the screens show, on JTKit's Microsoft
/// sign-in (`JTKitMSAL`): every tenant profile carries its own client ID +
/// tenant ID, and has its own signed-in account. One `MicrosoftSignIn` is
/// kept per client ID; MSAL's Keychain cache is shared, so accounts survive
/// relaunches.
@MainActor
@Observable
final class AuthManager {
    private static let logger = Logger(subsystem: "be.jordythery.intune-deployer", category: "Auth")

    /// Signed-in account per tenant profile ID.
    private(set) var accountsByProfile: [UUID: SignedInAccount] = [:]
    /// Scopes granted on the most recent token per profile (shown in preflight).
    private(set) var grantedScopesByProfile: [UUID: [String]] = [:]
    private(set) var signingInProfileIDs: Set<UUID> = []

    private var signIns: [String: MicrosoftSignIn] = [:]

    func account(for profile: TenantProfile) -> SignedInAccount? {
        accountsByProfile[profile.id]
    }

    func isSignedIn(_ profile: TenantProfile) -> Bool {
        accountsByProfile[profile.id] != nil
    }

    func grantedScopes(for profile: TenantProfile) -> [String] {
        grantedScopesByProfile[profile.id] ?? []
    }

    /// The person closed Microsoft's sign-in window.
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        MicrosoftSignIn.isCancellation(error)
    }

    // MARK: - Cache restore

    /// Restores this profile's cached account from the keychain, if any: the
    /// saved one, else one whose home tenant matches, else the only one
    /// (covers profiles configured with a verified domain instead of a GUID).
    func restoreAccount(for profile: TenantProfile) {
        guard accountsByProfile[profile.id] == nil,
              let microsoft = try? signIn(for: profile),
              let account = microsoft.savedAccount(identifier: profile.accountIdentifier, tenantID: profile.tenantID) else { return }
        accountsByProfile[profile.id] = SignedInAccount(account)
    }

    // MARK: - Sign in / out

    /// Interactive sign-in against this profile's tenant. Returns the account
    /// so the caller can persist its identifier on the profile.
    @discardableResult
    func signIn(profile: TenantProfile, scopes: [String] = GraphScopes.tenantRead) async throws -> SignedInAccount {
        let microsoft = try signIn(for: profile)
        signingInProfileIDs.insert(profile.id)
        defer { signingInProfileIDs.remove(profile.id) }

        let token = try await microsoft.signIn(tenantID: profile.tenantID, scopes: scopes)
        let account = SignedInAccount(token.account)
        accountsByProfile[profile.id] = account
        grantedScopesByProfile[profile.id] = token.scopes
        Self.logger.info("Signed in to \(profile.displayName, privacy: .public) as \(account.username, privacy: .private(mask: .hash))")
        return account
    }

    func signOut(profile: TenantProfile) async {
        defer {
            accountsByProfile[profile.id] = nil
            grantedScopesByProfile[profile.id] = nil
        }
        guard let microsoft = try? signIn(for: profile),
              let identifier = accountsByProfile[profile.id]?.identifier,
              let account = microsoft.account(identifier: identifier) else { return }
        microsoft.signOut(account)
    }

    // MARK: - Tokens

    /// Access token for this profile's tenant: silent first, Microsoft's
    /// sign-in window when MSAL needs it (one window at a time, see
    /// `MicrosoftSignIn`).
    /// - Parameter forceRefresh: a new token, after Graph answered 401.
    func accessToken(profile: TenantProfile, scopes: [String], forceRefresh: Bool = false) async throws -> String {
        let microsoft = try signIn(for: profile)
        guard let identifier = accountsByProfile[profile.id]?.identifier,
              let account = microsoft.account(identifier: identifier) else {
            throw MicrosoftSignInError.notSignedIn
        }
        let token = try await microsoft.token(for: account, tenantID: profile.tenantID, scopes: scopes,
                                              forceRefresh: forceRefresh)
        accountsByProfile[profile.id] = SignedInAccount(token.account)
        grantedScopesByProfile[profile.id] = token.scopes
        return token.accessToken
    }

    // MARK: - Private

    /// One sign-in per client ID (an app registration).
    private func signIn(for profile: TenantProfile) throws -> MicrosoftSignIn {
        let clientID = try MicrosoftSignIn.validatedClientID(profile.clientID)
        if let cached = signIns[clientID] {
            return cached
        }
        let microsoft = try MicrosoftSignIn(clientID: clientID)
        signIns[clientID] = microsoft
        return microsoft
    }
}
