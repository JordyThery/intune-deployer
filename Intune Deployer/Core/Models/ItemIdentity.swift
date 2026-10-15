import CryptoKit
import Foundation

/// Stable item identity: `sourceID + relative path`, hashed to a short ID.
///
/// On create and update, the tag `[IntuneDeployer:<shortID>]` is written into
/// the Intune object's description so re-runs can match tenant objects and
/// update rather than duplicate. Objects without the tag are never touched.
/// The legacy `[gw:…]` tag from early builds is still recognised when reading.
nonisolated enum ItemIdentity {
    /// Self-explanatory marker, visible in the Intune portal.
    static let tagPrefix = "IntuneDeployer"

    /// Lowercase 8-hex-digit prefix of SHA-256 over "sourceID|relativePath".
    /// The path is Unicode-normalised so NFC/NFD variants of the same file
    /// name produce the same identity.
    static func shortID(sourceID: UUID, relativePath: String) -> String {
        let normalizedPath = relativePath.precomposedStringWithCanonicalMapping
        let input = "\(sourceID.uuidString.lowercased())|\(normalizedPath)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The tag appended to the Intune object's description,
    /// e.g. `[IntuneDeployer:3f9a1c2e]`.
    static func tag(forShortID shortID: String) -> String {
        "[\(tagPrefix):\(shortID)]"
    }

    /// Extracts a short ID from a description containing one of our tags
    /// (current or legacy format). Regex built locally: not Sendable.
    static func shortID(inDescription description: String) -> String? {
        let tagPattern = /\[(?:IntuneDeployer|gw):([0-9a-f]{8})\]/
        guard let match = description.firstMatch(of: tagPattern) else {
            return nil
        }
        return String(match.1)
    }
}
