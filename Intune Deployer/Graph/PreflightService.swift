import Foundation

/// One row in the preflight checklist.
nonisolated struct PreflightCheck: Identifiable, Sendable {
    enum Status: Sendable {
        case ok
        case warning
        case failed

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
/// - GET /v1.0/me ($select) — User.Read
/// - GET /v1.0/organization — tenant id + display name
/// - GET /v1.0/organization/{id}?$select=mobileDeviceManagementAuthority —
///   documented in the Intune organization doc; DeviceManagementServiceConfig.Read.All
/// - GET /v1.0/deviceManagement/applePushNotificationCertificate —
///   DeviceManagementServiceConfig.Read.All
/// - GET /beta/deviceManagement/depOnboardingSettings —
///   DeviceManagementServiceConfig.Read.All
nonisolated struct PreflightService: Sendable {
    let client: GraphClient

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
                message: "Could not read the account or tenant: \(error.localizedDescription)"
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
                        : "MDM authority is \u{201C}\(authority)\u{201D} — must be Intune before deploying",
                    guidance: authority.lowercased() == "intune" ? nil
                        : "Set the MDM authority in the Intune admin center (Tenant administration).",
                    link: URL(string: "https://intune.microsoft.com")
                ))
            } catch {
                checks.append(PreflightCheck(
                    id: "mdmAuthority",
                    title: "MDM authority",
                    status: .warning,
                    message: "Could not read the MDM authority: \(error.localizedDescription)"
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
                    message: "\(cert.appleIdentifier ?? "unknown Apple ID") — expires \(expiry.formatted(date: .abbreviated, time: .omitted)) (\(days) days)",
                    guidance: days > 30 ? nil
                        : "Renew at identity.apple.com using the SAME Apple ID, then upload in Intune. Renewal is a manual step at Apple.",
                    link: URL(string: "https://identity.apple.com")
                ))
            } else {
                checks.append(PreflightCheck(
                    id: "apns",
                    title: "Apple MDM push certificate",
                    status: .failed,
                    message: "Certificate present but no expiry returned (status: \(cert.certificateUploadStatus ?? "unknown"))"
                ))
            }
        } catch {
            checks.append(PreflightCheck(
                id: "apns",
                title: "Apple MDM push certificate",
                status: .failed,
                message: "No Apple MDM push certificate found — macOS devices cannot enroll",
                guidance: "Create one in Intune (Tenant administration → Connectors → Apple) with a company Apple ID. This requires manual steps at Apple.",
                link: URL(string: "https://intune.microsoft.com")
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
                    message: "No Automated Device Enrollment tokens — fine if devices enroll another way",
                    guidance: "Connect Apple Business Manager in Intune if you use ADE.",
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
                                : "Renew the token in Apple Business Manager, then upload it in Intune. Renewal is a manual step at Apple.",
                            link: URL(string: "https://business.apple.com")
                        ))
                    }
                }
            }
        } catch {
            checks.append(PreflightCheck(
                id: "ade",
                title: "ADE enrollment tokens",
                status: .warning,
                message: "Could not read ADE tokens: \(error.localizedDescription)"
            ))
        }

        return checks
    }
}
