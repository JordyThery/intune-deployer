import Foundation
import JTKit

/// Stores the optional GitHub personal access token in the Keychain —
/// needed for private repositories; also raises the API rate limit.
/// Never persisted in UserDefaults or files, never marked synchronizable
/// (so it cannot sync to iCloud Keychain).
///
/// Through JTKit's Keychain store, under the service and account the app has
/// always used, "when unlocked", so a saved token keeps being found. Trimming
/// and "empty deletes" are the app's own rules.
nonisolated enum GitHubTokenStore {
    static let keychain = KeychainSecretStore(service: "be.jordythery.intune-deployer.github", accessibility: .whenUnlocked)
    static let account = "personal-access-token"

    /// - Parameter store: the Keychain; a fake in tests.
    static func load(from store: any SecretStore = keychain) -> String? {
        guard let token = store.secret(for: account), !token.isEmpty else { return nil }
        return token
    }

    /// Returns false when the Keychain rejected the write. An empty token
    /// (after trimming) deletes the saved one.
    @discardableResult
    static func save(_ token: String, to store: any SecretStore = keychain) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(from: store)
            return true
        }
        return store.setSecret(trimmed, for: account)
    }

    static func delete(from store: any SecretStore = keychain) {
        store.setSecret(nil, for: account)
    }
}
