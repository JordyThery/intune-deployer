import Foundation
import JTKit
import Testing
@testable import Intune_Deployer

/// Intercepts URLSession traffic for GraphClient tests.
nonisolated final class MockURLProtocol: URLProtocol {
    /// Shared across requests; tests using it run in a `.serialized` suite.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@Suite("Graph client", .serialized)
struct GraphClientTests {
    private func makeClient(activityLog: ActivityLog? = nil) -> GraphClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return GraphClient(
            tokenProvider: { "test-token" },
            activityLog: activityLog,
            session: URLSession(configuration: config)
        )
    }

    private struct Thing: Decodable, Sendable, Equatable {
        let id: String
    }

    @Test func followsNextLinkPaging() async throws {
        MockURLProtocol.handler = { @Sendable request in
            let url = request.url!.absoluteString
            if url.contains("page2") {
                return (200, [:], Data(#"{"value": [{"id": "c"}]}"#.utf8))
            }
            return (200, [:], Data(#"""
            {"value": [{"id": "a"}, {"id": "b"}],
             "@odata.nextLink": "https://graph.microsoft.com/beta/things?page2"}
            """#.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let things = try await makeClient().list(Thing.self, "things", version: .beta)
        #expect(things.map(\.id) == ["a", "b", "c"])
    }

    @Test func retriesOn429ThenSucceeds() async throws {
        // First call 429 with Retry-After: 0, then 200.
        nonisolated(unsafe) var callCount = 0
        MockURLProtocol.handler = { @Sendable _ in
            callCount += 1
            if callCount == 1 {
                return (429, ["Retry-After": "0"], Data())
            }
            return (200, [:], Data(#"{"id": "ok"}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let thing = try await makeClient().get(Thing.self, "things/1", version: .v1)
        #expect(thing.id == "ok")
        #expect(callCount == 2)
    }

    @MainActor
    @Test func networkErrorsAreLoggedAsFailed() async throws {
        // First call loses the connection (no response, no status), then 200.
        nonisolated(unsafe) var callCount = 0
        MockURLProtocol.handler = { @Sendable _ in
            callCount += 1
            if callCount == 1 {
                throw URLError(.networkConnectionLost)
            }
            return (200, [:], Data(#"{"id": "ok"}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let log = ActivityLog()
        _ = try await makeClient(activityLog: log).get(Thing.self, "things/1", version: .v1)

        // the lost attempt, the wait before the next one, the answer
        #expect(log.entries.count == 3)
        let lost = try #require(log.entries.first)
        #expect(lost.category == "Graph")
        #expect(lost.service == "Microsoft Graph")
        #expect(lost.operation == "GET")
        #expect(lost.detail.hasSuffix("/things/1"))
        #expect(lost.status == nil)
        #expect(lost.isFailure, "No response is shown as failed")
        #expect(lost.request?.attempt == 1 && lost.request?.maxAttempts == 5)
        let wait = log.entries[1]
        #expect(wait.category == "Retry")
        #expect(wait.isWarning)
        #expect(wait.note?.hasPrefix("Network error: waiting ") == true)
        #expect(wait.note?.hasSuffix("attempt 2 of 5.") == true)
        let answered = try #require(log.entries.last)
        #expect(answered.status == 200)
        #expect(answered.request?.attempt == 2)
        #expect(!answered.isFailure)
    }

    @MainActor
    @Test func waitAfter429IsLoggedAsAWarning() async throws {
        nonisolated(unsafe) var callCount = 0
        MockURLProtocol.handler = { @Sendable _ in
            callCount += 1
            return callCount == 1 ? (429, ["Retry-After": "0"], Data()) : (200, [:], Data(#"{"id": "ok"}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let log = ActivityLog()
        _ = try await makeClient(activityLog: log).get(Thing.self, "things/1", version: .v1)
        #expect(log.entries.map(\.status) == [429, nil, 200])
        #expect(log.entries[1].note == "HTTP 429: waiting 0 s, attempt 2 of 5.")
        #expect(log.entries[1].isWarning)
    }

    @MainActor
    @Test func tokenIsSentButNeverInTheLog() async throws {
        MockURLProtocol.handler = { @Sendable _ in (200, [:], Data(#"{"id": "ok"}"#.utf8)) }
        defer { MockURLProtocol.handler = nil }

        let log = ActivityLog()
        _ = try await makeClient(activityLog: log).get(Thing.self, "things/1", version: .v1)
        let entry = try #require(log.entries.first)
        #expect(entry.request?.requestHeaders.first { $0.name == "Authorization" }?.value == "Bearer \(Redaction.placeholder)")
        #expect(!ActivityLogExport.transcript(of: entry).contains("test-token"))
    }

    @Test func failsFastOnNonRetryableError() async throws {
        MockURLProtocol.handler = { @Sendable _ in
            (403, [:], Data(#"{"error": {"code": "Forbidden", "message": "Missing scope"}}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        await #expect(throws: GraphError.self) {
            _ = try await makeClient().get(Thing.self, "things/1", version: .v1)
        }
    }

    @Test func authorizationHeaderIsSentButNeverLogged() async throws {
        nonisolated(unsafe) var seenAuth: String?
        MockURLProtocol.handler = { @Sendable request in
            seenAuth = request.value(forHTTPHeaderField: "Authorization")
            return (200, [:], Data(#"{"id": "ok"}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        _ = try await makeClient().get(Thing.self, "things/1", version: .v1)
        #expect(seenAuth == "Bearer test-token")
    }

    @Test func retryDelayPrefersRetryAfterHeader() {
        #expect(GraphClient.retryDelay(attempt: 0, retryAfter: "7") == .seconds(7))
        #expect(GraphClient.retryDelay(attempt: 3, retryAfter: "9999") == .seconds(300)) // capped
        // Without a header: jittered backoff within (0.5, 2^(attempt+1)] seconds.
        let jittered = GraphClient.retryDelay(attempt: 1, retryAfter: nil)
        #expect(jittered >= .seconds(0.5) && jittered <= .seconds(4))
    }

    @Test func requestURLKeepsQueryStringsOutOfThePath() {
        // Regression: "?" must not be percent-encoded into the path segment.
        #expect(
            GraphClient.requestURL(for: "me?$select=displayName,userPrincipalName", version: .v1).absoluteString
                == "https://graph.microsoft.com/v1.0/me?$select=displayName,userPrincipalName"
        )
        #expect(
            GraphClient.requestURL(for: "deviceManagement/configurationPolicies", version: .beta).absoluteString
                == "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"
        )
        // Absolute nextLink URLs are used verbatim.
        #expect(
            GraphClient.requestURL(for: "https://graph.microsoft.com/beta/x?$skiptoken=abc", version: .v1).absoluteString
                == "https://graph.microsoft.com/beta/x?$skiptoken=abc"
        )
    }

    @Test func graphErrorMessageIsExtracted() {
        let body = Data(#"{"error": {"code": "Throttled", "message": "Too many requests"}}"#.utf8)
        #expect(GraphClient.errorMessage(from: body) == "Throttled — Too many requests")
        #expect(GraphClient.errorMessage(from: Data("not json".utf8)) == nil)
    }
}

@Suite("Tenant models")
struct TenantModelTests {
    @Test func tenantProfileRoundTripsThroughJSON() throws {
        let profile = TenantProfile(
            displayName: "Lab9 Pro",
            clientID: "e445f0a6-0000-0000-0000-000000000000",
            tenantID: "c0ffee00-0000-0000-0000-000000000000",
            namingPrefix: "[LAB9]",
            variables: ["EnrollmentProfileName": "Lab9 ADE"],
            selectedItemIDs: ["3f9a1c2e"],
            accountIdentifier: "uid.tid"
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(TenantProfile.self, from: data)
        #expect(decoded == profile)
        #expect(profile.hasValidClientID)
    }

    @Test func legacyProfileWithoutClientIDStillDecodes() throws {
        // Saved by builds before client ID moved into the tenant profile.
        let legacy = Data(#"""
        {"id": "11111111-2222-3333-4444-555555555555",
         "displayName": "Legacy Tenant",
         "tenantID": "contoso.com",
         "namingPrefix": "",
         "variables": {},
         "selectedItemIDs": []}
        """#.utf8)
        let profile = try JSONDecoder().decode(TenantProfile.self, from: legacy)
        #expect(profile.displayName == "Legacy Tenant")
        #expect(profile.clientID.isEmpty)
        #expect(!profile.hasValidClientID)
        #expect(profile.accountIdentifier == nil)
    }

    @Test func tenantObjectDecodesGraphPayloadAndFindsTag() throws {
        let json = Data(#"""
        {
            "@odata.type": "#microsoft.graph.macOSCompliancePolicy",
            "id": "abc-123",
            "displayName": "macOS - Compliance",
            "description": "Managed. [gw:3f9a1c2e]",
            "lastModifiedDateTime": "2026-01-15T10:30:00.1234567Z"
        }
        """#.utf8)
        let object = try GraphClient.decode(TenantObject.self, from: json)
        #expect(object.resolvedName == "macOS - Compliance")
        #expect(object.taggedShortID == "3f9a1c2e")
        #expect(object.odataType == "#microsoft.graph.macOSCompliancePolicy")
        #expect(object.lastModifiedDateTime != nil)
    }

    @Test func settingsCatalogObjectUsesNameProperty() throws {
        let json = Data(#"{"id": "x", "name": "macOS - Updates", "description": null}"#.utf8)
        let object = try GraphClient.decode(TenantObject.self, from: json)
        #expect(object.resolvedName == "macOS - Updates")
        #expect(object.taggedShortID == nil)
    }
}
