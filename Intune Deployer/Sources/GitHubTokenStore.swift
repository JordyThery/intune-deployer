import Foundation
import JTKit

/// Stores the optional GitHub personal access token in the Keychain:
/// needed for private repositories; it also raises the API rate limit.
/// Never persisted in UserDefaults or files, never marked synchronizable
/// (so it cannot sync to iCloud Keychain).
///
/// Through JTKit's Keychain store, under the service and account the app has
/// always used, "when unlocked", so a saved token keeps being found. Trimming
/// and "empty deletes" are the app's own rules.
nonisolated enum GitHubTokenStore {
    static let keychain = KeychainSecretStore(service: "be.jordythery.intune-deployer.github", accessibility: .whenUnlocked)
    static let account = "personal-access-token"

    /// Where the app keeps the token: the Keychain; under tests (the unit
    /// tests' host and a sandbox run) a store in memory that starts empty,
    /// so the real token is never read or written while tests run.
    static let appStore: any SecretStore = TestRun.isActive ? SandboxSecretStore() : keychain

    /// - Parameter store: the app's store; a fake in tests.
    static func load(from store: any SecretStore = appStore) -> String? {
        guard let token = store.secret(for: account), !token.isEmpty else { return nil }
        return token
    }

    /// Returns false when the Keychain rejected the write. An empty token
    /// (after trimming) deletes the saved one.
    @discardableResult
    static func save(_ token: String, to store: any SecretStore = appStore) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return delete(from: store)
        }
        return store.setSecret(trimmed, for: account)
    }

    /// Returns false when the Keychain rejected the delete.
    @discardableResult
    static func delete(from store: any SecretStore = appStore) -> Bool {
        store.setSecret(nil, for: account)
    }

    /// What Settings › GitHub says after Save Token or Remove Token.
    static func status(saving token: String, succeeded: Bool) -> String {
        let removing = token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if succeeded { return removing ? "Token removed" : "Token saved to the Keychain" }
        return removing
            ? "The Keychain didn’t remove the token. Try again, or remove it in Keychain Access."
            : "The Keychain didn’t save the token. Unlock the login Keychain and try again."
    }
}
