import Foundation
import JTKit
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

/// How a real (non-demo) tenant may sign in under tests (JTKit ROADMAP step 11).
enum UnderTestSignIn {
    /// Not under tests: MSAL as always.
    case off
    /// Under tests: every saved tenant is refused before MSAL is reached,
    /// and the attempt written down.
    case refuseAll(SavedTenantGuard)
    /// The release check's live checks: only the profile of exactly this
    /// Entra tenant ID, with its account matched strictly by tenant (no
    /// "only account" fallback) and tokens from MSAL's cache only. When MSAL
    /// needs its window the token fails (`interactionRequired`); a window is
    /// never opened. Every other tenant is refused as above.
    case liveCheck(tenantID: String, guard: SavedTenantGuard)
}

/// The per-tenant sign-in state the screens show, on JTKit's Microsoft
/// sign-in (`JTKitMSAL`): every tenant profile carries its own client ID +
/// tenant ID, and has its own signed-in account. One `MicrosoftSignIn` is
/// kept per client ID; MSAL's Keychain cache is shared, so accounts survive
/// relaunches.
///
/// The demo tenant ("Contoso Intune (Demo)", `TenantProfile.isDemo`) never
/// reaches MSAL: in demo mode it is signed in with demo mode's fixed token and
/// account (`DemoMode.microsoftSignIn()`), without a sign-in window, and
/// MSAL's Keychain cache and the real signed-in accounts are neither read nor
/// written. Without demo mode it is never signed in.
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
    @ObservationIgnored private let makeSignIn: @MainActor (String) throws -> MicrosoftSignIn
    @ObservationIgnored private let demo: DemoMode?
    /// Permissions the demo tenant was asked for: granted as asked, step by
    /// step, like consent in a real tenant.
    private var demoScopes: [String] = GraphScopes.tenantRead
    @ObservationIgnored let underTest: UnderTestSignIn

    /// - Parameters:
    ///   - demo: the app's demo mode; nil without demo mode.
    ///   - makeSignIn: MSAL's sign-in for a client ID; a trap in tests.
    ///   - underTest: under tests every saved tenant is refused by default.
    init(demo: DemoMode? = nil,
         makeSignIn: @escaping @MainActor (String) throws -> MicrosoftSignIn = { try MicrosoftSignIn(clientID: $0) },
         underTest: UnderTestSignIn = UnderTest.isActive ? .refuseAll(.shared) : .off) {
        self.demo = demo
        self.makeSignIn = makeSignIn
        self.underTest = underTest
    }

    /// Under tests: nil when this tenant may be reached (the live checks'
    /// tenant), else the guard that refuses it. Never for the demo tenant.
    private func refusingGuard(for profile: TenantProfile) -> SavedTenantGuard? {
        switch underTest {
        case .off: nil
        case .refuseAll(let savedTenantGuard): savedTenantGuard
        case .liveCheck(let tenantID, let savedTenantGuard):
            profile.tenantID.trimmingCharacters(in: .whitespaces).lowercased() == tenantID.lowercased() ? nil : savedTenantGuard
        }
    }

    /// The guard of this mode, nil when not under tests.
    private var underTestGuard: SavedTenantGuard? {
        switch underTest {
        case .off: nil
        case .refuseAll(let savedTenantGuard), .liveCheck(_, let savedTenantGuard): savedTenantGuard
        }
    }

    private var isLiveCheck: Bool {
        if case .liveCheck = underTest { return true }
        return false
    }

    /// The demo tenant's account, while there is a demo mode.
    private var demoAccount: SignedInAccount? {
        guard let demo else { return nil }
        return SignedInAccount(username: demo.microsoftSignIn().username, identifier: "demo")
    }

    func account(for profile: TenantProfile) -> SignedInAccount? {
        if profile.isDemo { return demoAccount }
        return accountsByProfile[profile.id]
    }

    func isSignedIn(_ profile: TenantProfile) -> Bool {
        account(for: profile) != nil
    }

    func grantedScopes(for profile: TenantProfile) -> [String] {
        if profile.isDemo { return demoAccount == nil ? [] : demoScopes }
        return grantedScopesByProfile[profile.id] ?? []
    }

    /// The person closed Microsoft's sign-in window.
    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        MicrosoftSignIn.isCancellation(error)
    }

    // MARK: - Cache restore

    /// Restores this profile's cached account from the keychain, if any: the
    /// saved one, else (for a tenant ID) the one account whose home tenant is
    /// exactly that tenant. Never "the only account" whatever its tenant
    /// (bug 5): a guest account is found by its saved identifier, and every
    /// token is checked against the profile's tenant before anything is sent.
    func restoreAccount(for profile: TenantProfile) {
        guard !profile.isDemo, accountsByProfile[profile.id] == nil else { return }
        if let refusing = refusingGuard(for: profile) {
            refusing.record("restore the saved sign-in of a saved tenant")
            return
        }
        guard let microsoft = try? signIn(for: profile) else { return }
        // The live checks: exactly this tenant's account, never another's.
        let account: MicrosoftAccount?
        if isLiveCheck {
            account = microsoft.account(strictlyFor: profile.tenantID, identifier: profile.accountIdentifier)
        } else if let identifier = profile.accountIdentifier, let saved = microsoft.account(identifier: identifier) {
            account = saved
        } else if UUID(uuidString: profile.tenantID.trimmingCharacters(in: .whitespaces)) != nil {
            account = microsoft.account(strictlyFor: profile.tenantID, identifier: nil)
        } else {
            account = nil
        }
        guard let account else { return }
        accountsByProfile[profile.id] = SignedInAccount(account)
    }

    // MARK: - Sign in / out

    /// Interactive sign-in against this profile's tenant. Returns the account
    /// so the caller can persist its identifier on the profile.
    @discardableResult
    func signIn(profile: TenantProfile, scopes: [String] = GraphScopes.tenantRead) async throws -> SignedInAccount {
        if profile.isDemo {
            guard let account = demoAccount else { throw MicrosoftSignInError.notSignedIn }
            return account
        }
        // Under tests Microsoft's window is never opened, not even for the
        // live checks' tenant.
        if case .off = underTest {} else {
            underTestGuard?.record("interactive sign-in")
            throw UnderTestRefusal()
        }
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
        guard !profile.isDemo else { return }
        // Under tests MSAL's cache is never changed. A tenant without a
        // signed-in account (one just deleted in Settings) has nothing to
        // sign out of: nothing would reach MSAL.
        if case .off = underTest {} else {
            guard accountsByProfile[profile.id] != nil else { return }
            underTestGuard?.record("sign out of a saved tenant")
            return
        }
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
        if profile.isDemo {
            guard let demo else { throw MicrosoftSignInError.notSignedIn }
            demoScopes += scopes.filter { !demoScopes.contains($0) }
            return demo.microsoftSignIn().accessToken
        }
        if let refusing = refusingGuard(for: profile) {
            refusing.record("token for a saved tenant")
            throw UnderTestRefusal()
        }
        let microsoft = try signIn(for: profile)
        guard let identifier = accountsByProfile[profile.id]?.identifier,
              let account = microsoft.account(identifier: identifier) else {
            throw MicrosoftSignInError.notSignedIn
        }
        // The live checks: MSAL's cache only, never the window.
        let token = isLiveCheck
            ? try await microsoft.silentToken(for: account, tenantID: profile.tenantID, scopes: scopes, forceRefresh: forceRefresh)
            : try await microsoft.token(for: account, tenantID: profile.tenantID, scopes: scopes, forceRefresh: forceRefresh)
        accountsByProfile[profile.id] = SignedInAccount(token.account)
        grantedScopesByProfile[profile.id] = token.scopes
        return token.accessToken
    }

    // MARK: - Private

    /// One sign-in per client ID (an app registration). Never for the demo
    /// tenant: MSAL isn't set up for it.
    private func signIn(for profile: TenantProfile) throws -> MicrosoftSignIn {
        guard !profile.isDemo else { throw MicrosoftSignInError.notSignedIn }
        let clientID = try MicrosoftSignIn.validatedClientID(profile.clientID)
        if let cached = signIns[clientID] {
            return cached
        }
        let microsoft = try makeSignIn(clientID)
        signIns[clientID] = microsoft
        return microsoft
    }
}
