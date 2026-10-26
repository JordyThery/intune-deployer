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
        #expect(try MicrosoftSignIn.validatedClientID(" e445f0a6-0000-0000-0000-000000000000\n")
            == "e445f0a6-0000-0000-0000-000000000000")
        #expect(throws: MicrosoftSignInError.self) { try MicrosoftSignIn.validatedClientID("my-app") }
        #expect(throws: MicrosoftSignInError.self) { try MicrosoftSignIn.validatedClientID("") }
    }

    @Test("The sign-in address takes a tenant ID or a domain; an empty one is refused")
    func authority() throws {
        #expect(try MicrosoftSignIn.authorityURL(tenantID: "c0ffee00-0000-0000-0000-000000000000").absoluteString
            == "https://login.microsoftonline.com/c0ffee00-0000-0000-0000-000000000000")
        #expect(try MicrosoftSignIn.authorityURL(tenantID: " contoso.com ").absoluteString
            == "https://login.microsoftonline.com/contoso.com")
        #expect(throws: MicrosoftSignInError.self) { try MicrosoftSignIn.authorityURL(tenantID: "  ") }
    }

    private struct Account: Equatable {
        let name: String
        let tenant: String?
    }

    @Test("At launch, a saved account is found by its tenant (capitals ignored), else the only one")
    func cachedAccount() {
        let a = Account(name: "a", tenant: "AAAA")
        let b = Account(name: "b", tenant: "bbbb")
        #expect(MicrosoftSignIn.cachedAccount(in: [a, b], tenantID: " aaaa", homeTenant: \.tenant) == a)
        #expect(MicrosoftSignIn.cachedAccount(in: [b], tenantID: "contoso.com", homeTenant: \.tenant) == b,
                "a single account for this app belongs to this tenant (a domain doesn't match a tenant ID)")
        #expect(MicrosoftSignIn.cachedAccount(in: [a, b], tenantID: "contoso.com", homeTenant: \.tenant) == nil)
        #expect(MicrosoftSignIn.cachedAccount(in: [Account](), tenantID: "aaaa", homeTenant: \.tenant) == nil)
    }
}
