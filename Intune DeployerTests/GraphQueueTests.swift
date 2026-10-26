import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Intune_Deployer

/// The Graph client's queue, raw lists and repeats, against a fake Graph.
@Suite("Graph queue and lists")
struct GraphQueueTests {
    /// Counts how many token requests are in progress at once; a request
    /// asks for its token inside its turn.
    private final class InFlight: BearerTokenSource, @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0
        private var most = 0
        var highest: Int { lock.withLock { most } }

        func token() async throws -> String {
            lock.withLock { now += 1; most = max(most, now) }
            try await Task.sleep(for: .milliseconds(150))
            lock.withLock { now -= 1 }
            return "token"
        }

        func forgetToken() async {}
    }

    @Test("At most 4 requests at a time; the others wait their turn")
    func fourAtATime() async throws {
        let inFlight = InFlight()
        let server = MockServer { _ in .json(200, #"{"value":[]}"#) }
        let client = graphClient(server, tokens: inFlight)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask { _ = try await client.getRaw("things/\(index)", version: .v1) }
            }
            try await group.waitForAll()
        }
        #expect(server.requests.count == 10)
        #expect(inFlight.highest == 4)
    }

    @Test("A raw list follows the next page and returns each object")
    func rawListPages() async throws {
        let server = MockServer { request in
            request.url.query()?.contains("skiptoken") == true
                ? .json(200, #"{"value":[{"id":"c"}]}"#)
                : .json(200, #"{"value":[{"id":"a"},{"id":"b"}],"@odata.nextLink":"https://graph.microsoft.com/beta/things?$skiptoken=2"}"#)
        }
        let objects = try await graphClient(server).listRaw("things", version: .beta)
        let ids = try objects.map { try #require(JSONSerialization.jsonObject(with: $0) as? [String: String])["id"] }
        #expect(ids == ["a", "b", "c"])
        #expect(server.requests.count == 2)
    }

    @Test("A raw list answer without a list is an error")
    func rawListWithoutValue() async throws {
        let server = MockServer { _ in .json(200, #"{"id":"not a list"}"#) }
        await #expect(throws: GraphError.self) {
            _ = try await graphClient(server).listRaw("things", version: .beta)
        }
    }

    /// Changed on purpose in step 8: a create was sent again after a 503.
    /// Now it isn't; running Plan again finds a created object by its tag.
    @Test("A create is not sent again after a 503")
    func createNotRepeatedAfter503() async throws {
        let server = MockServer { _ in .json(503, "{}", headers: ["Retry-After": "0"]) }
        await #expect(throws: GraphError.self) {
            _ = try await graphClient(server).post("things", version: .v1, body: Data("{}".utf8))
        }
        #expect(server.requests.map(\.method) == ["POST"])
    }

    @Test("Activity log entries say Intune, with the tenant's name")
    @MainActor
    func serviceIsIntune() async throws {
        let log = ActivityLog()
        let server = MockServer { _ in .json(200, "{}") }
        _ = try await graphClient(server, log: log, connection: "Lab").getRaw("me", version: .v1)
        let entry = try #require(log.entries.first)
        #expect(entry.service == "Intune")
        #expect(entry.connection == "Lab")
        #expect(entry.request?.maxAttempts == 4)
    }
}
