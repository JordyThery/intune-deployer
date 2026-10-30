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

    /// The tag naming the tenant profile that deployed an object, written
    /// after the item's tag, e.g. `[IntuneDeployerProfile:7c01a9e2]`: the
    /// first 8 hex digits of SHA-256 over the profile's ID. Orphans and Remove
    /// Baseline only cover objects of the profile in use (bug 2 of the JTKit
    /// step 11 survey). A separate tag, so older builds still read the item tag.
    static let profileTagPrefix = "IntuneDeployerProfile"

    static func profileMarker(for profileID: UUID) -> String {
        let digest = SHA256.hash(data: Data(profileID.uuidString.lowercased().utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func profileTag(for profileID: UUID) -> String {
        "[\(profileTagPrefix):\(profileMarker(for: profileID))]"
    }

    /// The item tag and, when deploying for a profile, its profile tag.
    static func tag(forShortID shortID: String, profileID: UUID?) -> String {
        guard let profileID else { return tag(forShortID: shortID) }
        return "\(tag(forShortID: shortID)) \(profileTag(for: profileID))"
    }

    /// The profile marker in a description, nil for objects deployed before
    /// profile tags (or by an older build).
    static func profileMarker(inDescription description: String) -> String? {
        let pattern = /\[IntuneDeployerProfile:([0-9a-f]{8})\]/
        return description.firstMatch(of: pattern).map { String($0.1) }
    }

    /// Whether a tagged object belongs to this profile: its profile tag is the
    /// profile's; without one (deployed before profile tags) only when its
    /// name carries the profile's naming prefix, which a profile without a
    /// prefix never claims.
    static func belongs(description: String?, displayName: String, to profile: TenantProfile) -> Bool {
        if let marker = description.flatMap(profileMarker(inDescription:)) {
            return marker == profileMarker(for: profile.id)
        }
        let prefix = profile.namingPrefix.trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { return false }
        return displayName == prefix || displayName.hasPrefix("\(prefix) ")
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
