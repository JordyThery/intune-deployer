import Foundation
import Security
import Testing

/// The Keychain groups in the signed app, as the tests' host app runs with them.
struct KeychainGroupTests {
    private func signedKeychainGroups() throws -> [String] {
        let task = try #require(SecTaskCreateFromSelf(nil))
        let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)
        return try #require(value as? [String])
    }

    /// The first group is where a new data-protection Keychain item goes when
    /// it names none, so the app's own group comes first and new items never
    /// land in MSAL's shared group. MSAL names its own group, so its sign-in
    /// cache is found either way.
    @Test func theAppsOwnGroupComesBeforeMSALs() throws {
        let groups = try signedKeychainGroups()
        #expect(groups.count == 2)
        #expect(groups.first?.hasSuffix(".be.jordythery.intune-deployer") == true, "\(groups)")
        #expect(groups.last?.hasSuffix(".com.microsoft.identity.universalstorage") == true, "\(groups)")
    }
}
