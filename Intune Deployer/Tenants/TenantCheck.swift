import Foundation

/// The tenant of an access token, checked before anything is sent with it
/// (bug 5 of the JTKit step 11 survey): a profile's sign-in could otherwise
/// be another tenant's account, and every write would land there.
nonisolated enum TenantCheck {
    enum Failure: LocalizedError, Equatable {
        case unreadable
        case otherTenant(profile: String)
        case domainNotInTenant(domain: String, profile: String)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "The sign-in's token doesn't say which tenant it is for, so nothing was sent."
            case .otherTenant(let profile):
                "The signed-in account's token is for another tenant than “\(profile)”, so nothing was sent. Sign out of \(profile) and sign in with an account of that tenant."
            case .domainNotInTenant(let domain, let profile):
                "The signed-in tenant doesn't have “\(domain)” as a verified domain, so nothing was sent to “\(profile)”. Check the tenant ID in Settings › Connections."
            }
        }
    }

    /// The `tid` claim of a JWT access token, lowercased; nil when it has none.
    static func tenantID(ofAccessToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tenant = claims["tid"] as? String else { return nil }
        return tenant.lowercased()
    }

    /// Throws unless the token is for the `expected` tenant ID.
    static func require(_ token: String, isFor expected: String, profile: TenantProfile) throws {
        guard let tenant = tenantID(ofAccessToken: token) else { throw Failure.unreadable }
        guard tenant == expected.lowercased() else { throw Failure.otherTenant(profile: profile.displayName) }
    }
}
