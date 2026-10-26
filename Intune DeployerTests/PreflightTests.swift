import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Intune_Deployer

/// The preflight checklist, against a fake Graph: what each answer turns into.
@Suite("Preflight")
struct PreflightTests {
    private static func date(inDays days: Int) -> String {
        ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(Double(days) * 86_400))
    }

    /// Answers for a healthy tenant; a test replaces the ones it is about,
    /// keyed by the path after the version.
    private static let healthy: [String: MockResponse] = [
        "me": .json(200, #"{"displayName":"Jordy","userPrincipalName":"admin@contoso.com"}"#),
        "organization": .json(200, #"{"value":[{"id":"org-1","displayName":"Contoso"}]}"#),
        "organization/org-1": .json(200, #"{"id":"org-1","mobileDeviceManagementAuthority":"intune"}"#),
        "deviceManagement/applePushNotificationCertificate":
            .json(200, #"{"appleIdentifier":"mdm@contoso.com","expirationDateTime":"\#(date(inDays: 90))"}"#),
        "deviceManagement/depOnboardingSettings":
            .json(200, #"{"value":[{"id":"tok-1","tokenName":"Main","tokenExpirationDateTime":"\#(date(inDays: 200))"}]}"#),
    ]

    private static let required = ["User.Read", "DeviceManagementConfiguration.Read.All"]

    private func run(_ overrides: [String: MockResponse] = [:], granted: [String] = required)
        async -> (checks: [PreflightCheck], server: MockServer) {
        let answers = Self.healthy.merging(overrides) { $1 }
        let server = MockServer { request in
            let path = request.path.replacing(/^\/(v1\.0|beta)\//, with: "")
            return answers[path] ?? .json(404, #"{"error":{"code":"NotFound","message":"No such thing"}}"#)
        }
        let client = graphClient(server)
        let checks = await PreflightService(client: client).run(grantedScopes: granted, requiredScopes: Self.required)
        return (checks, server)
    }

    private func check(_ id: String, in checks: [PreflightCheck]) throws -> PreflightCheck {
        try #require(checks.first { $0.id == id })
    }

    @Test("A healthy tenant: every row OK, in order")
    func healthyTenant() async throws {
        let (checks, server) = await run()
        #expect(checks.map(\.id) == ["account", "mdmAuthority", "scopes", "apns", "ade-tok-1"])
        #expect(checks.allSatisfy { $0.status == .ok })
        #expect(try check("account", in: checks).message == "admin@contoso.com in Contoso (org-1)")
        #expect(try check("mdmAuthority", in: checks).message == "Set to Intune")
        #expect(try check("scopes", in: checks).message == "All required read scopes granted")
        #expect(try check("ade-tok-1", in: checks).title == "ADE token \u{201C}Main\u{201D}")

        let sent = server.requests.map { "\($0.method) \($0.url.path())" }
        #expect(sent == [
            "GET /v1.0/me",
            "GET /v1.0/organization",
            "GET /v1.0/organization/org-1",
            "GET /v1.0/deviceManagement/applePushNotificationCertificate",
            "GET /beta/deviceManagement/depOnboardingSettings",
        ])
        #expect(server.requests.first?.queryValue("$select") == "displayName,userPrincipalName")
        #expect(server.requests[2].queryValue("$select") == "id,mobileDeviceManagementAuthority")
    }

    @Test("The account can't be read: failed, and the MDM authority is skipped")
    func accountUnreadable() async throws {
        let (checks, _) = await run(["me": .json(401, #"{"error":{"code":"InvalidAuthenticationToken","message":"Expired"}}"#)])
        #expect(checks.map(\.id) == ["account", "scopes", "apns", "ade-tok-1"])
        let account = try check("account", in: checks)
        #expect(account.status == .failed)
        #expect(account.message.hasPrefix("Could not read the account or tenant: "))
    }

    @Test("An MDM authority other than Intune fails, with guidance")
    func otherAuthority() async throws {
        let (checks, _) = await run(["organization/org-1": .json(200, #"{"id":"org-1","mobileDeviceManagementAuthority":"office365"}"#)])
        let row = try check("mdmAuthority", in: checks)
        #expect(row.status == .failed)
        #expect(row.message == "MDM authority is \u{201C}office365\u{201D} — must be Intune before deploying")
        #expect(row.guidance == "Set the MDM authority in the Intune admin center (Tenant administration).")
    }

    @Test("An unreadable MDM authority is a warning")
    func authorityUnreadable() async throws {
        let (checks, _) = await run(["organization/org-1": .json(403, #"{"error":{"code":"Forbidden","message":"No"}}"#)])
        let row = try check("mdmAuthority", in: checks)
        #expect(row.status == .warning)
        #expect(row.message.hasPrefix("Could not read the MDM authority: "))
    }

    @Test("Missing permissions are a warning; capitals don't matter")
    func missingScopes() async throws {
        let (checks, _) = await run(granted: ["user.read"])
        let row = try check("scopes", in: checks)
        #expect(row.status == .warning)
        #expect(row.message == "Missing: DeviceManagementConfiguration.Read.All")
        #expect(row.guidance == "Sign in again to consent to the missing scopes, or ask an admin to grant consent.")
    }

    @Test("Push certificate: under 30 days a warning, expired failed",
          arguments: [(10, PreflightCheck.Status.warning), (-5, .failed), (90, .ok)])
    func pushCertificateExpiry(days: Int, status: PreflightCheck.Status) async throws {
        let (checks, _) = await run(["deviceManagement/applePushNotificationCertificate":
            .json(200, #"{"appleIdentifier":"mdm@contoso.com","expirationDateTime":"\#(Self.date(inDays: days))"}"#)])
        let row = try check("apns", in: checks)
        #expect(row.status == status)
        #expect(row.message.hasPrefix("mdm@contoso.com — expires "))
        #expect((row.guidance != nil) == (status != .ok))
    }

    @Test("No push certificate fails: Macs can't enroll")
    func noPushCertificate() async throws {
        let (checks, _) = await run(["deviceManagement/applePushNotificationCertificate": .json(404, "{}")])
        let row = try check("apns", in: checks)
        #expect(row.status == .failed)
        #expect(row.message == "No Apple MDM push certificate found — macOS devices cannot enroll")
    }

    @Test("A push certificate without an expiry date fails")
    func pushCertificateWithoutExpiry() async throws {
        let (checks, _) = await run(["deviceManagement/applePushNotificationCertificate": .json(200, #"{"appleIdentifier":"x"}"#)])
        let row = try check("apns", in: checks)
        #expect(row.status == .failed)
        #expect(row.message == "Certificate present but no expiry returned (status: unknown)")
    }

    @Test("No ADE tokens is a warning")
    func noADETokens() async throws {
        let (checks, _) = await run(["deviceManagement/depOnboardingSettings": .json(200, #"{"value":[]}"#)])
        let row = try check("ade", in: checks)
        #expect(row.status == .warning)
        #expect(row.message == "No Automated Device Enrollment tokens — fine if devices enroll another way")
    }

    @Test("One row per ADE token with an expiry; the name falls back to the Apple ID, then the ID")
    func adeTokens() async throws {
        let body = #"""
        {"value":[
          {"id":"a","appleIdentifier":"abm@contoso.com","tokenExpirationDateTime":"\#(Self.date(inDays: 10))"},
          {"id":"b","tokenExpirationDateTime":"\#(Self.date(inDays: -1))"},
          {"id":"c","tokenName":"No expiry"}
        ]}
        """#
        let (checks, _) = await run(["deviceManagement/depOnboardingSettings": .json(200, body)])
        #expect(checks.filter { $0.id.hasPrefix("ade") }.map(\.id) == ["ade-a", "ade-b"])
        let first = try check("ade-a", in: checks)
        #expect(first.title == "ADE token \u{201C}abm@contoso.com\u{201D}")
        #expect(first.status == .warning)
        let second = try check("ade-b", in: checks)
        #expect(second.title == "ADE token \u{201C}b\u{201D}")
        #expect(second.status == .failed)
    }

    @Test("Unreadable ADE tokens are a warning")
    func adeUnreadable() async throws {
        let (checks, _) = await run(["deviceManagement/depOnboardingSettings": .json(403, #"{"error":{"code":"Forbidden","message":"No"}}"#)])
        let row = try check("ade", in: checks)
        #expect(row.status == .warning)
        #expect(row.message.hasPrefix("Could not read ADE tokens: "))
    }
}
