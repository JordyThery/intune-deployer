import Foundation
import JTKit

/// The tenant of an access token, checked before anything is sent with it:
/// a profile's sign-in could otherwise
/// be another tenant's account, and every write would land there.
nonisolated enum TenantCheck {
    enum Failure: LocalizedError, Equatable {
        case unreadable
        case otherTenant(profile: String)
        case domainNotInTenant(domain: String, profile: String)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "The sign-in’s token doesn’t say which tenant it is for, so nothing was sent."
            case .otherTenant(let profile):
                "The signed-in account belongs to a different tenant than “\(profile)”, so nothing was sent. Sign out of “\(profile)” and sign in with an account from that tenant."
            case .domainNotInTenant(let domain, let profile):
                "The signed-in tenant doesn’t have “\(domain)” as a verified domain, so nothing was sent to “\(profile)”. Check the tenant ID in Settings › Connections."
            }
        }
    }

    /// Throws unless the token is for the `expected` tenant ID.
    static func require(_ token: String, isFor expected: String, profile: TenantProfile) throws {
        guard let tenant = EntraToken.tenantID(ofAccessToken: token) else { throw Failure.unreadable }
        guard tenant == expected.lowercased() else { throw Failure.otherTenant(profile: profile.displayName) }
    }
}
