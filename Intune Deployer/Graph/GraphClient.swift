import Foundation
import JTKit
import OSLog

nonisolated enum GraphVersion: String, Sendable {
    case v1 = "v1.0"
    case beta

    var baseURL: URL {
        URL(string: "https://graph.microsoft.com/\(rawValue)")!
    }
}

nonisolated enum GraphError: LocalizedError {
    case http(status: Int, message: String?)
    case retriesExhausted(status: Int)
    case notJSON

    var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            "Graph returned HTTP \(status)\(message.map { ": \($0)" } ?? "")"
        case .retriesExhausted(let status):
            "Gave up after repeated transient failures (last status \(status))"
        case .notJSON:
            "Graph returned an unexpected response"
        }
    }
}

/// One page of a Graph collection; `@odata.nextLink` drives paging.
nonisolated struct GraphPage<T: Decodable & Sendable>: Decodable, Sendable {
    let value: [T]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

/// Small typed client for Microsoft Graph REST.
///
/// - Retries 429 (documented Retry-After) and transient 503/504 with
///   exponential backoff + jitter (Retry-After honoured when present).
/// - Caps in-flight requests at 4.
/// - Follows `@odata.nextLink` paging.
/// - Sends through JTKit's request recorder, which writes each attempt to
///   the activity log, redacted (JTKit's default bodies rule); each wait
///   before a retry is logged as a warning. Retries and the 4-at-a-time cap
///   stay here until JTKit has Graph (ROADMAP step 8).
actor GraphClient {
    typealias TokenProvider = @Sendable () async throws -> String

    private static let logger = Logger(subsystem: "be.jordythery.intune-deployer", category: "Graph")
    private static let maxAttempts = 5
    private static let maxConcurrent = 4

    private let tokenProvider: TokenProvider
    /// Graph requests; also the base for the app-content uploads to Azure
    /// Storage, which share its session, log and connection.
    nonisolated let recorder: RequestRecorder

    private var activeRequests = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter connection: the tenant's name, shown with each entry.
    init(tokenProvider: @escaping TokenProvider, activityLog: ActivityLog?, session: URLSession = .shared,
         connection: String? = nil) {
        self.tokenProvider = tokenProvider
        self.recorder = RequestRecorder(session: session, log: activityLog, category: "Graph",
                                        service: "Microsoft Graph", connection: connection)
    }

    // MARK: - Public API

    /// GET a single resource and decode it.
    func get<T: Decodable & Sendable>(_ type: T.Type, _ path: String, version: GraphVersion) async throws -> T {
        let data = try await send(method: "GET", url: url(for: path, version: version), body: nil)
        return try Self.decode(type, from: data)
    }

    /// GET a resource as raw JSON data (for untyped polling).
    func getRaw(_ path: String, version: GraphVersion) async throws -> Data {
        try await send(method: "GET", url: url(for: path, version: version), body: nil)
    }

    /// POST a JSON body; returns the (possibly empty) response body.
    @discardableResult
    func post(_ path: String, version: GraphVersion, body: Data) async throws -> Data {
        try await send(method: "POST", url: url(for: path, version: version), body: body)
    }

    /// PATCH a JSON body (partial update).
    @discardableResult
    func patch(_ path: String, version: GraphVersion, body: Data) async throws -> Data {
        try await send(method: "PATCH", url: url(for: path, version: version), body: body)
    }

    /// PUT a JSON body (full replace — Settings Catalog updates).
    @discardableResult
    func put(_ path: String, version: GraphVersion, body: Data) async throws -> Data {
        try await send(method: "PUT", url: url(for: path, version: version), body: body)
    }

    func delete(_ path: String, version: GraphVersion) async throws {
        _ = try await send(method: "DELETE", url: url(for: path, version: version), body: nil)
    }

    /// GET a collection, following @odata.nextLink until exhausted.
    func list<T: Decodable & Sendable>(_ type: T.Type, _ path: String, version: GraphVersion) async throws -> [T] {
        var results: [T] = []
        var nextURL: URL? = url(for: path, version: version)
        while let current = nextURL {
            let data = try await send(method: "GET", url: current, body: nil)
            let page = try Self.decode(GraphPage<T>.self, from: data)
            results.append(contentsOf: page.value)
            // Per docs: use the entire nextLink URL verbatim.
            nextURL = page.nextLink.flatMap(URL.init(string:))
        }
        return results
    }

    /// GET a collection as raw per-object JSON bodies (for diffing), following
    /// @odata.nextLink until exhausted.
    func listRaw(_ path: String, version: GraphVersion) async throws -> [Data] {
        var results: [Data] = []
        var nextURL: URL? = url(for: path, version: version)
        while let current = nextURL {
            let data = try await send(method: "GET", url: current, body: nil)
            guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = page["value"] as? [Any] else {
                throw GraphError.notJSON
            }
            for element in value {
                results.append(try JSONSerialization.data(withJSONObject: element))
            }
            nextURL = (page["@odata.nextLink"] as? String).flatMap(URL.init(string:))
        }
        return results
    }

    // MARK: - Core request path

    private func url(for path: String, version: GraphVersion) -> URL {
        Self.requestURL(for: path, version: version)
    }

    /// Builds a request URL from a relative path that may carry a query
    /// string (e.g. "me?$select=displayName"). `URL.appending(path:)` would
    /// percent-encode the "?" into the path segment, which Graph rejects
    /// with 400 "Resource not found for the segment".
    nonisolated static func requestURL(for path: String, version: GraphVersion) -> URL {
        if path.hasPrefix("https://") {
            return URL(string: path) ?? version.baseURL
        }
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var url = version.baseURL.appending(path: String(parts[0]))
        if parts.count == 2,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // Encode characters that are invalid in a query (spaces, quotes)
            // while keeping existing percent-escapes and &/= separators, so
            // callers may pre-encode values that contain & or +.
            let allowed = CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "%"))
            components.percentEncodedQuery = String(parts[1]).addingPercentEncoding(withAllowedCharacters: allowed)
            url = components.url ?? url
        }
        return url
    }

    private func send(method: String, url: URL, body: Data?) async throws -> Data {
        await acquireSlot()
        defer { releaseSlot() }

        var lastStatus = 0
        for attempt in 0..<Self.maxAttempts {
            let token = try await tokenProvider()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let start = ContinuousClock.now
            let data: Data
            let http: HTTPURLResponse
            do {
                (data, http) = try await recorder.send(request, attempt: attempt + 1, of: Self.maxAttempts)
            } catch let error as URLError where Self.isTransient(error) && attempt + 1 < Self.maxAttempts {
                // Connection hiccups are retried with the same backoff as 503s.
                logToSystem(method: method, url: url, status: nil, duration: (ContinuousClock.now - start).seconds)
                try await wait(Self.retryDelay(attempt: attempt, retryAfter: nil), reason: "Network error",
                               method: method, url: url, nextAttempt: attempt + 2)
                continue
            }
            logToSystem(method: method, url: url, status: http.statusCode, duration: (ContinuousClock.now - start).seconds)
            lastStatus = http.statusCode

            switch http.statusCode {
            case 200..<300:
                return data
            case 429, 503, 504:
                guard attempt + 1 < Self.maxAttempts else {
                    throw GraphError.retriesExhausted(status: http.statusCode)
                }
                try await wait(Self.retryDelay(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After")),
                               reason: "HTTP \(http.statusCode)", method: method, url: url, nextAttempt: attempt + 2)
            default:
                throw GraphError.http(status: http.statusCode, message: Self.errorMessage(from: data))
            }
        }
        throw GraphError.retriesExhausted(status: lastStatus)
    }

    nonisolated static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed:
            true
        default:
            false
        }
    }

    /// Retry-After wins when present (capped at 300s); otherwise jittered
    /// exponential backoff: random(0.5 … 2^(attempt+1)) seconds, capped at 60s.
    nonisolated static func retryDelay(attempt: Int, retryAfter: String?) -> Duration {
        if let retryAfter, let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return .seconds(min(seconds, 300))
        }
        let ceiling = min(pow(2, Double(attempt + 1)), 60)
        return .seconds(Double.random(in: 0.5...max(0.5, ceiling)))
    }

    /// Extracts Graph's error message without logging the full payload.
    nonisolated static func errorMessage(from data: Data) -> String? {
        struct GraphErrorBody: Decodable {
            struct Inner: Decodable {
                let code: String?
                let message: String?
            }
            let error: Inner
        }
        guard let body = try? JSONDecoder().decode(GraphErrorBody.self, from: data) else { return nil }
        let message = [body.error.code, body.error.message].compactMap(\.self).joined(separator: " — ")
        return message.isEmpty ? nil : message
    }

    nonisolated static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        // Graph timestamps may or may not carry fractional seconds
        // (e.g. "2024-01-01T00:02:43.5775965Z"), so try both ISO 8601 forms.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) {
                return date
            }
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date: \(string)")
        }
        return try decoder.decode(type, from: data)
    }

    // MARK: - Concurrency cap

    private func acquireSlot() async {
        if activeRequests < Self.maxConcurrent {
            activeRequests += 1
            return
        }
        await withCheckedContinuation { slotWaiters.append($0) }
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty {
            activeRequests -= 1
        } else {
            slotWaiters.removeFirst().resume()
        }
    }

    // MARK: - Logging

    /// The activity log entry comes from the recorder; this is the system log
    /// line. `status` is nil when no response arrived.
    private func logToSystem(method: String, url: URL, status: Int?, duration: TimeInterval) {
        let path = url.path()
        Self.logger.info("\(method, privacy: .public) \(path, privacy: .public) → \(status ?? -1) in \(String(format: "%.2fs", duration), privacy: .public)")
    }

    /// Waits before the next attempt, written to the activity log first as a
    /// warning, worded as JTKit's own client does. Cancelling stops it at once.
    private func wait(_ delay: Duration, reason: String, method: String, url: URL, nextAttempt: Int) async throws {
        let seconds = delay.seconds
        let shown = seconds < 10 && seconds.rounded() != seconds ? String(format: "%.1f", seconds) : String(format: "%.0f", seconds)
        await recorder.note(method, url.path(),
                            note: "\(reason): waiting \(shown) s, attempt \(nextAttempt) of \(Self.maxAttempts).",
                            category: "Retry", isWarning: true)
        do {
            try await Task.sleep(for: delay)
        } catch {
            await recorder.note(method, url.path(), note: "Cancelled while waiting.", category: "Retry")
            throw CancellationError()
        }
    }
}

nonisolated private extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
