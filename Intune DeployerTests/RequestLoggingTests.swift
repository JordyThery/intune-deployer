import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Intune_Deployer

/// What reaches the activity log from GitHub and from the app-content upload
/// to Azure Storage: no tokens, no upload signature, no contents.
@Suite("Request logging")
@MainActor
struct RequestLoggingTests {
    private nonisolated static let storageURI = "https://store.blob.core.windows.net/c/blob?sv=2019-02-02&sr=b&sig=SAS-SIGNATURE%3D&se=2026-10-26&sp=rw"
    private nonisolated static let token = "ghp_16C7e42F292c6912E7710c838347Ae178B4a"

    private func transcripts(_ log: ActivityLog) -> String {
        log.entries.map { ActivityLogExport.transcript(of: $0) }.joined(separator: "\n")
    }

    // MARK: - GitHub

    @Test func gitHubRequestsAreLoggedWithoutTheToken() async throws {
        let server = MockServer { request in
            if request.path.hasSuffix("/releases") {
                return .json(401, #"{"message":"Bad credentials \#(Self.token)"}"#)
            }
            return .json(200, #"{"default_branch":"main","html_url":"https://github.com/o/r","license":null}"#)
        }
        let log = ActivityLog()
        let recorder = RequestRecorder(session: server.session, log: log, category: "GitHub", service: "GitHub")

        let info = try await GitHubClient.fetchRepoInfo(owner: "o", repo: "r", token: Self.token, recorder: recorder)
        #expect(info.defaultBranch == "main")
        await #expect(throws: GitHubError.self) {
            _ = try await GitHubClient.fetchReleases(owner: "o", repo: "r", token: Self.token, recorder: recorder)
        }

        #expect(server.requests.first?.header("Authorization") == "Bearer \(Self.token)", "the token is sent")
        #expect(log.entries.count == 2)
        #expect(log.entries.allSatisfy { $0.category == "GitHub" && $0.service == "GitHub" })
        #expect(!transcripts(log).contains(Self.token))
    }

    @Test func archiveDownloadIsLoggedWithoutContentsOrCodeloadToken() async throws {
        let codeload = try #require(URL(string: "https://codeload.github.com/o/r/legacy.zip/refs/heads/main?token=EPHEMERAL"))
        let server = MockServer { request in
            request.url.host() == "api.github.com"
                ? .redirect(302, to: codeload)
                : MockResponse(status: 200, headers: ["Content-Type": "application/zip"], body: Data("not a zip".utf8))
        }
        let log = ActivityLog()
        let recorder = RequestRecorder(session: server.session, log: log, category: "GitHub")
        let destination = FileManager.default.temporaryDirectory.appending(path: "gh-\(UUID().uuidString)/content")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        // the fake archive can't be extracted; only the download matters here
        await #expect(throws: GitHubError.self) {
            _ = try await GitHubClient.downloadAndExtract(owner: "o", repo: "r", ref: "main", into: destination,
                                                         token: Self.token, recorder: recorder)
        }
        #expect(server.requests.last?.url == codeload, "the redirect was followed")
        let entry = try #require(log.entries.first)
        #expect(entry.status == 200)
        #expect(entry.request?.bodyNote == "Downloaded file not recorded.")
        let text = transcripts(log)
        #expect(!text.contains("EPHEMERAL"))
        #expect(!text.contains(Self.token))
        #expect(!text.contains("not a zip"))
    }

    // MARK: - App-content upload

    /// A fake Graph and Azure Storage for one upload; `blockStatus` is the
    /// answer to every block.
    private func uploadServer(blockStatus: Int) -> MockServer {
        let committed = Locked(false)
        return MockServer { request in
            if request.url.host() == "store.blob.core.windows.net" {
                return MockResponse(status: request.queryValue("comp") == "block" ? blockStatus : 201, headers: [:], body: Data())
            }
            let path = request.path
            switch request.method {
            case "POST" where path.hasSuffix("/contentVersions"):
                return .json(201, #"{"id":"cv1"}"#)
            case "POST" where path.hasSuffix("/files"):
                return .json(201, #"{"id":"f1"}"#)
            case "POST" where path.hasSuffix("/commit"):
                committed.value = true
                return .json(200, "{}")
            case "PATCH":
                return MockResponse(status: 204, headers: [:], body: Data())
            case "GET" where path.hasSuffix("/files/f1"):
                return committed.value
                    ? .json(200, #"{"uploadState":"commitFileSuccess"}"#)
                    : .json(200, #"{"uploadState":"azureStorageUriRequestSuccess","azureStorageUri":"\#(Self.storageURI)"}"#)
            case "GET":
                return .json(200, #"{"publishingState":"published"}"#)
            default:
                return .json(404, "{}")
            }
        }
    }

    private func uploader(_ server: MockServer, log: ActivityLog) -> AppContentUploader {
        let client = GraphClient(tokenProvider: { "graph-token" }, activityLog: log, session: server.session, connection: "Lab")
        return AppContentUploader(client: client, appID: "app1", appODataType: "#microsoft.graph.macOSPkgApp")
    }

    @Test func uploadWritesOneSummaryEntryAndNoBlockEntries() async throws {
        let server = uploadServer(blockStatus: 201)
        let log = ActivityLog()
        let contents = Data(repeating: 0x41, count: 1024)
        try await uploader(server, log: log).upload(fileName: "Tool.pkg", fileData: contents)

        #expect(server.requests.contains { $0.url.host() == "store.blob.core.windows.net" }, "the blocks were sent")
        let uploads = log.entries.filter { $0.category == "Upload" }
        #expect(uploads.count == 1)
        let summary = try #require(uploads.first)
        #expect(summary.detail == "Tool.pkg")
        #expect(summary.note?.contains("1 block: uploaded.") == true)
        #expect(summary.note?.contains(Int64(1024).formatted(.byteCount(style: .file))) == true)
        #expect(summary.duration != nil)
        #expect(!summary.isFailure)
        #expect(summary.service == "Azure Storage")
        #expect(summary.connection == "Lab")
        let text = transcripts(log)
        #expect(!text.contains("SAS-SIGNATURE"))
        #expect(!text.contains("graph-token"))
    }

    @Test func aFailedBlockGetsItsOwnEntryWithTheSignatureHidden() async throws {
        let server = uploadServer(blockStatus: 500)
        let log = ActivityLog()
        await #expect(throws: AppUploadError.self) {
            try await uploader(server, log: log).upload(fileName: "Tool.pkg", fileData: Data(repeating: 0x41, count: 1024))
        }

        let uploads = log.entries.filter { $0.category == "Upload" }
        #expect(uploads.count == 2)
        let block = try #require(uploads.first { $0.operation == "PUT" })
        #expect(block.status == 500)
        #expect(block.request?.url.contains("sig=\(Redaction.placeholder)") == true)
        #expect(block.request?.requestBody == nil, "the contents are never recorded")
        let summary = try #require(uploads.first { $0.operation == "Upload" })
        #expect(summary.isFailure)
        #expect(summary.note?.contains("failed") == true)
        #expect(!transcripts(log).contains("SAS-SIGNATURE"))
    }
}

/// A value shared between a test and the fake server's handler.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
