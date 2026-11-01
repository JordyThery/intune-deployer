import Foundation
import JTKitMSAL
import Testing
@testable import Intune_Deployer

/// The sign-in rules that don't need Microsoft's sign-in window: which
/// permissions each action asks for, the addresses, and which saved account
/// belongs to a tenant. The addresses and the account rule moved to JTKitMSAL
/// in step 8, unchanged; the window itself is tested there against a fake MSAL.
@Suite("Sign-in")
struct SignInTests {
    @Test("Preflight, inventory and export ask for read permissions only")
    func readScopes() {
        #expect(GraphScopes.tenantRead == [
            "User.Read",
            "DeviceManagementConfiguration.Read.All",
            "DeviceManagementScripts.Read.All",
            "DeviceManagementServiceConfig.Read.All",
            "DeviceManagementApps.Read.All",
        ])
    }

    @Test("Plan also reads groups")
    func planScopes() {
        #expect(GraphScopes.planRead == GraphScopes.tenantRead + ["Group.Read.All"])
    }

    @Test("Apply asks for write permissions; creating groups only when the tenant allows it")
    func applyScopes() {
        let apply = [
            "User.Read",
            "DeviceManagementConfiguration.ReadWrite.All",
            "DeviceManagementScripts.ReadWrite.All",
            "DeviceManagementApps.ReadWrite.All",
            "DeviceManagementServiceConfig.Read.All",
            "Group.Read.All",
        ]
        #expect(GraphScopes.applyScopes(allowGroupCreation: false) == apply)
        #expect(GraphScopes.applyScopes(allowGroupCreation: true) == apply + ["Group.ReadWrite.All"])
    }

    @Test("The redirect address is built from the bundle ID")
    func redirect() {
        #expect(AppRegistrationInfo.redirectURI == "msauth.be.jordythery.intune-deployer://auth")
    }

    @Test("The client ID is trimmed and must be a UUID")
    func clientID() throws {
        #expect(try MicrosoftSignIn.validatedClientID(" 00000000-0000-0000-0000-00000000c11e\n")
            == "00000000-0000-0000-0000-00000000c11e")
        #expect(throws: MicrosoftSignInError.self) { try MicrosoftSignIn.validatedClientID("my-app") }
        #expect(throws: MicrosoftSignInError.self) { try MicrosoftSignIn.validatedClientID("") }
    }

    @Test("The sign-in address takes a tenant ID or a domain; an empty one is refused")
    func authority() throws {
        #expect(try MicrosoftSignIn.authorityURL(tenantID: "c0ffee00-0000-0000-0000-000000000000").absoluteString
            == "https://login.microsoftonline.com/c0ffee00-0000-0000-0000-000000000000")
        #expect(try MicrosoftSignIn.authorityURL(tenantID: " contoso.example ").absoluteString
            == "https://login.microsoftonline.com/contoso.example")
        #expect(throws: MicrosoftSignInError.self) { try MicrosoftSignIn.authorityURL(tenantID: "  ") }
    }

    private struct Account: Equatable {
        let name: String
        let tenant: String?
    }

    /// `AuthManager.restoreAccount` uses the strict rule (its saved identifier
    /// aside): MSAL's window can't be faked from the app's tests, so the rule
    /// itself is checked here.
    @Test("At launch, an account is restored only by its exact home tenant, never as the only account")
    func strictlyCachedAccount() {
        let a = Account(name: "a", tenant: "AAAA")
        let b = Account(name: "b", tenant: "bbbb")
        #expect(MicrosoftSignIn.strictlyCachedAccount(in: [a, b], tenantID: " aaaa", homeTenant: { $0.tenant }) == a)
        #expect(MicrosoftSignIn.strictlyCachedAccount(in: [b], tenantID: "aaaa", homeTenant: { $0.tenant }) == nil,
                "the only account on the Mac isn't this tenant's")
        #expect(MicrosoftSignIn.strictlyCachedAccount(in: [b], tenantID: "contoso.example", homeTenant: { $0.tenant }) == nil)
        let twin = Account(name: "a2", tenant: "aaaa")
        #expect(MicrosoftSignIn.strictlyCachedAccount(in: [a, twin], tenantID: "aaaa", homeTenant: { $0.tenant }) == nil,
                "two accounts of the tenant: which one is meant can't be told")
        #expect(MicrosoftSignIn.strictlyCachedAccount(in: [Account](), tenantID: "aaaa", homeTenant: { $0.tenant }) == nil)
    }
}
