import Foundation
import JTKit

/// One row in the preflight checklist.
nonisolated struct PreflightCheck: Identifiable, Sendable {
    enum Status: Sendable {
        case ok
        case warning
        case failed

        /// What VoiceOver says for the row's icon.
        var accessibilityName: String {
            switch self {
            case .ok: "OK"
            case .warning: "Warning"
            case .failed: "Failed"
            }
        }

        var symbolName: String {
            switch self {
            case .ok: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .failed: "xmark.circle.fill"
            }
        }
    }

    let id: String
    let title: String
    let status: Status
    let message: String
    /// Optional remediation guidance (APNs/ADE renewals are manual at Apple).
    let guidance: String?
    let link: URL?

    init(id: String, title: String, status: Status, message: String, guidance: String? = nil, link: URL? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.message = message
        self.guidance = guidance
        self.link = link
    }
}

/// Read-only preflight checks run before the first plan against a tenant.
///
/// Endpoints verified against Microsoft Learn (Oct 2026):
/// - GET /v1.0/me ($select): User.Read
/// - GET /v1.0/organization: tenant id + display name
/// - GET /v1.0/organization/{id}?$select=mobileDeviceManagementAuthority:
///   documented in the Intune organization doc; DeviceManagementServiceConfig.Read.All
/// - GET /v1.0/deviceManagement/applePushNotificationCertificate:
///   DeviceManagementServiceConfig.Read.All
/// - GET /beta/deviceManagement/depOnboardingSettings:
///   DeviceManagementServiceConfig.Read.All
nonisolated struct PreflightService: Sendable {
    let client: Graph.Client

    private struct MeResponse: Decodable, Sendable {
        let displayName: String?
        let userPrincipalName: String?
    }

    private struct Organization: Decodable, Sendable {
        let id: String
        let displayName: String?
        let mobileDeviceManagementAuthority: String?
    }

    private struct ApplePushCertificate: Decodable, Sendable {
        let appleIdentifier: String?
        let expirationDateTime: Date?
        let certificateUploadStatus: String?
    }

    private struct DepOnboardingSetting: Decodable, Sendable {
        let id: String
        let tokenName: String?
        let appleIdentifier: String?
        let tokenExpirationDateTime: Date?
    }

    func run(grantedScopes: [String], requiredScopes: [String]) async -> [PreflightCheck] {
        var checks: [PreflightCheck] = []

        // 1. Signed-in account and tenant.
        var organizationID: String?
        do {
            let me = try await client.get(MeResponse.self, "me?$select=displayName,userPrincipalName", version: .v1)
            let orgs = try await client.list(Organization.self, "organization", version: .v1)
            let org = orgs.first
            organizationID = org?.id
            checks.append(PreflightCheck(
                id: "account",
                title: "Signed-in account",
                status: .ok,
                message: "\(me.userPrincipalName ?? me.displayName ?? "Unknown user") in \(org?.displayName ?? "unknown tenant") (\(org?.id ?? "?"))"
            ))
        } catch {
            checks.append(PreflightCheck(
                id: "account",
                title: "Signed-in account",
                status: .failed,
                message: "Couldn’t read the account or tenant: \(error.localizedDescription)"
            ))
        }

        // 2. MDM authority (property from the Intune organization resource).
        if let organizationID {
            do {
                let detailed = try await client.get(
                    Organization.self,
                    "organization/\(organizationID)?$select=id,mobileDeviceManagementAuthority",
                    version: .v1
                )
                let authority = detailed.mobileDeviceManagementAuthority ?? "unknown"
                checks.append(PreflightCheck(
                    id: "mdmAuthority",
                    title: "MDM authority",
                    status: authority.lowercased() == "intune" ? .ok : .failed,
                    message: authority.lowercased() == "intune"
                        ? "Set to Intune"
                        : "MDM authority is \u{201C}\(authority)\u{201D}. It must be Intune before deploying.",
                    guidance: authority.lowercased() == "intune" ? nil
                        : "Set the MDM authority in the Intune admin center (Tenant administration).",
                    link: URL(string: "https://intune.microsoft.com")
                ))
            } catch {
                checks.append(PreflightCheck(
                    id: "mdmAuthority",
                    title: "MDM authority",
                    status: .warning,
                    message: "Couldn’t read the MDM authority: \(error.localizedDescription)"
                ))
            }
        }

        // 3. Granted scopes vs required.
        let missing = requiredScopes.filter { required in
            !grantedScopes.contains { $0.caseInsensitiveCompare(required) == .orderedSame }
        }
        checks.append(PreflightCheck(
            id: "scopes",
            title: "Granted permissions",
            status: missing.isEmpty ? .ok : .warning,
            message: missing.isEmpty
                ? "All required read scopes granted"
                : "Missing: \(missing.joined(separator: ", "))",
            guidance: missing.isEmpty ? nil
                : "Sign in again to consent to the missing scopes, or ask an admin to grant consent."
        ))

        // 4. Apple MDM push certificate.
        do {
            let cert = try await client.get(
                ApplePushCertificate.self,
                "deviceManagement/applePushNotificationCertificate",
                version: .v1
            )
            if let expiry = cert.expirationDateTime {
                let days = Calendar.current.dateComponents([.day], from: .now, to: expiry).day ?? 0
                checks.append(PreflightCheck(
                    id: "apns",
                    title: "Apple MDM push certificate",
                    status: days > 30 ? .ok : (days > 0 ? .warning : .failed),
                    message: "\(cert.appleIdentifier ?? "unknown Apple Account"), expires \(expiry.formatted(date: .abbreviated, time: .omitted)) (\(days) days)",
                    guidance: days > 30 ? nil
                        : "Renew it at identity.apple.com with the same Apple Account, then upload it in Intune.",
                    link: URL(string: "https://identity.apple.com")
                ))
            } else {
                checks.append(PreflightCheck(
                    id: "apns",
                    title: "Apple MDM push certificate",
                    status: .failed,
                    message: "A certificate is present, but Intune returned no expiry (status: \(cert.certificateUploadStatus ?? "unknown"))."
                ))
            }
        } catch let error as Graph.APIError where error.status == 404 {
            // Only "not found" means there is none.
            checks.append(PreflightCheck(
                id: "apns",
                title: "Apple MDM push certificate",
                status: .failed,
                message: "No Apple MDM push certificate found. Apple devices can’t enroll.",
                guidance: "Create one in the Intune admin center (Tenant administration › Connectors and tokens › Apple MDM Push Certificate) with an organizational Apple Account.",
                link: URL(string: "https://intune.microsoft.com")
            ))
        } catch {
            checks.append(PreflightCheck(
                id: "apns",
                title: "Apple MDM push certificate",
                status: .warning,
                message: "Couldn’t read the Apple MDM push certificate: \(error.localizedDescription)"
            ))
        }

        // 5. ADE / enrollment program tokens.
        do {
            let tokens = try await client.list(
                DepOnboardingSetting.self,
                "deviceManagement/depOnboardingSettings",
                version: .beta
            )
            if tokens.isEmpty {
                checks.append(PreflightCheck(
                    id: "ade",
                    title: "ADE enrollment tokens",
                    status: .warning,
                    message: "No Automated Device Enrollment tokens. That’s fine if devices enroll another way.",
                    guidance: "Connect Apple Business in Intune if you use ADE.",
                    link: URL(string: "https://business.apple.com")
                ))
            } else {
                for token in tokens {
                    let name = token.tokenName ?? token.appleIdentifier ?? token.id
                    if let expiry = token.tokenExpirationDateTime {
                        let days = Calendar.current.dateComponents([.day], from: .now, to: expiry).day ?? 0
                        checks.append(PreflightCheck(
                            id: "ade-\(token.id)",
                            title: "ADE token \u{201C}\(name)\u{201D}",
                            status: days > 30 ? .ok : (days > 0 ? .warning : .failed),
                            message: "Expires \(expiry.formatted(date: .abbreviated, time: .omitted)) (\(days) days)",
                            guidance: days > 30 ? nil
                                : "Renew the token in Apple Business, then upload it in Intune.",
                            link: URL(string: "https://business.apple.com")
                        ))
                    } else {
                        // A token without an expiry can't be checked: say so.
                        checks.append(PreflightCheck(
                            id: "ade-\(token.id)",
                            title: "ADE token \u{201C}\(name)\u{201D}",
                            status: .warning,
                            message: "Intune returned no expiry date for this token.",
                            guidance: "Check the token in the Intune admin center (Tenant administration › Connectors and tokens › Enrollment program tokens).",
                            link: URL(string: "https://intune.microsoft.com")
                        ))
                    }
                }
            }
        } catch {
            checks.append(PreflightCheck(
                id: "ade",
                title: "ADE enrollment tokens",
                status: .warning,
                message: "Couldn’t read the ADE tokens: \(error.localizedDescription)"
            ))
        }

        return checks
    }
}
