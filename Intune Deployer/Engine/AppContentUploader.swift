import Foundation
import JTKit
import OSLog

nonisolated enum AppUploadError: LocalizedError {
    case stateTimeout(String)
    case stateFailed(String)
    case missingID(String)
    case azure(Int)

    var errorDescription: String? {
        switch self {
        case .stateTimeout(let step): "Timed out waiting for \(step)"
        case .stateFailed(let state): "Intune reported upload state “\(state)”"
        case .missingID(let step): "Graph returned no ID for the \(step)"
        case .azure(let status): "Azure Storage upload failed with HTTP \(status)"
        }
    }
}

/// Executes the Graph mobile-app content upload flow (all endpoints verified
/// against the beta docs; the Azure block mechanics against production
/// open-source uploaders):
///
/// 1. POST contentVersions → content version id
/// 2. POST files {name, size, sizeEncrypted, manifest: null, isDependency: false}
/// 3. Poll file until azureStorageUriRequestSuccess
/// 4. PUT 6 MiB blocks to the SAS URI, then the block list (renewUpload on expiry)
/// 5. POST commit {fileEncryptionInfo}
/// 6. Poll file until commitFileSuccess
/// 7. PATCH app {committedContentVersion}, then wait for publishingState ==
///    "published" (assign is rejected with 400 before that).
nonisolated struct AppContentUploader: Sendable {
    private static let logger = Logger(subsystem: "be.jordythery.intune-deployer", category: "AppUpload")
    private static let blockSize = 6 * 1024 * 1024

    /// The OTA-install-style manifest an iosLobApp content file is registered
    /// with. The template (placeholders included) matches Microsoft's LOB
    /// upload sample; the service fills in the URL and ignores the literal
    /// subtitle. TODO(verify): the plist content is sample practice, not
    /// documented on the mobileAppContentFile page.
    static func iosManifest(bundleID: String, bundleVersion: String, title: String) -> Data {
        func xmlEscaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>items</key><array><dict><key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>{UrlPlaceHolder}</string></dict></array><key>metadata</key><dict><key>AppRestrictionPolicyTemplate</key> <string>http://management.microsoft.com/PolicyTemplates/AppRestrictions/iOS/v1</string><key>AppRestrictionTechnology</key><string>Windows Intune Application Restrictions Technology for iOS</string><key>IntuneMAMVersion</key><string></string><key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array><key>MinimumOSVersion</key><string>9.0</string><key>bundle-identifier</key><string>\(xmlEscaped(bundleID))</string><key>bundle-version</key><string>\(xmlEscaped(bundleVersion))</string><key>kind</key><string>software</string><key>subtitle</key><string>LaunchMeSubtitle</string><key>title</key><string>\(xmlEscaped(title))</string></dict></dict></array></dict></plist>
        """
        return Data(xml.utf8)
    }

    let client: GraphClient
    let appID: String
    /// e.g. "#microsoft.graph.macOSPkgApp" — used for the final PATCH.
    let appODataType: String
    /// iOS uploads register the content file with an OTA-style manifest
    /// plist; macOS uploads send none.
    var manifest: Data?

    private var appPath: String { "deviceAppManagement/mobileApps/\(appID)" }

    func upload(fileName: String, fileData: Data) async throws {
        // 1. Content version (doc-sanctioned base-type cast).
        let versionResponse = try await client.post(
            "\(appPath)/microsoft.graph.mobileLobApp/contentVersions",
            version: .beta,
            body: try JSONSerialization.data(withJSONObject: ["@odata.type": "#microsoft.graph.mobileAppContent"])
        )
        let contentVersionID = try requireID(in: versionResponse, step: "content version")

        // 2. Encrypt and register the content file.
        let encrypted = try AppEncryptor.encrypt(fileData)
        let filesPath = "\(appPath)/microsoft.graph.mobileLobApp/contentVersions/\(contentVersionID)/files"
        let fileBody: [String: Any] = [
            "@odata.type": "#microsoft.graph.mobileAppContentFile",
            "name": fileName,
            "size": fileData.count,
            "sizeEncrypted": encrypted.encrypted.count,
            "manifest": manifest.map { $0.base64EncodedString() as Any } ?? NSNull(),
            "isDependency": false,
        ]
        let fileResponse = try await client.post(filesPath, version: .beta, body: try JSONSerialization.data(withJSONObject: fileBody))
        let fileID = try requireID(in: fileResponse, step: "content file")
        let filePath = "\(filesPath)/\(fileID)"

        // 3. Wait for the Azure Storage SAS URI.
        let storageURI = try await pollFile(
            path: filePath,
            until: "azureStorageUriRequestSuccess",
            failures: ["azureStorageUriRequestFailed", "azureStorageUriRequestTimedOut", "error"],
            attempts: 40,
            extract: { $0["azureStorageUri"] as? String }
        )

        // 4. Chunked block upload + block list.
        try await uploadContent(fileName: fileName, fileSize: fileData.count, storageURI: storageURI,
                                data: encrypted.encrypted, renewPath: filePath)

        // 5. Commit with the encryption info.
        try await client.post(
            "\(filePath)/commit",
            version: .beta,
            body: try JSONSerialization.data(withJSONObject: ["fileEncryptionInfo": encrypted.fileEncryptionInfoJSON])
        )

        // 6. Wait for the commit to process.
        _ = try await pollFile(
            path: filePath,
            until: "commitFileSuccess",
            failures: ["commitFileFailed", "commitFileTimedOut", "error"],
            attempts: 60,
            extract: { _ in "done" }
        )

        // 7. Point the app at the committed version and wait for publishing.
        try await client.patch(
            appPath,
            version: .beta,
            body: try JSONSerialization.data(withJSONObject: [
                "@odata.type": appODataType,
                "committedContentVersion": contentVersionID,
            ])
        )
        try await waitUntilPublished()
    }

    // MARK: - Polling

    private func pollFile(
        path: String,
        until successState: String,
        failures: [String],
        attempts: Int,
        extract: ([String: Any]) -> String?
    ) async throws -> String {
        for _ in 0..<attempts {
            let data = try await client.getRaw(path, version: .beta)
            let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let state = object["uploadState"] as? String ?? ""
            if state == successState, let value = extract(object) {
                return value
            }
            if failures.contains(state) {
                throw AppUploadError.stateFailed(state)
            }
            try await Task.sleep(for: .seconds(5))
        }
        throw AppUploadError.stateTimeout(successState)
    }

    private func waitUntilPublished() async throws {
        for _ in 0..<60 {
            let data = try await client.getRaw("\(appPath)?$select=publishingState", version: .beta)
            let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if object["publishingState"] as? String == "published" {
                return
            }
            try await Task.sleep(for: .seconds(5))
        }
        throw AppUploadError.stateTimeout("publishingState == published")
    }

    // MARK: - Azure Storage

    /// The recorder for Azure Storage: the Graph client's session, log and
    /// connection, under its own source. The upload address carries its
    /// signature (`sig=`), which JTKit hides; the contents are never recorded.
    private var storageRecorder: RequestRecorder {
        var recorder = client.recorder
        recorder.category = "Upload"
        recorder.service = "Azure Storage"
        return recorder
    }

    /// Uploads the blocks and writes one summary entry for the file (name,
    /// size, blocks, duration, result). A block or block list request gets an
    /// entry of its own only when it fails.
    private func uploadContent(fileName: String, fileSize: Int, storageURI: String, data: Data, renewPath: String) async throws {
        let recorder = storageRecorder
        let blocks = (data.count + Self.blockSize - 1) / Self.blockSize
        let size = Int64(fileSize).formatted(.byteCount(style: .file))
        let summary = "\(size) in \(blocks) block\(blocks == 1 ? "" : "s")"
        let started = ContinuousClock.now
        func elapsed() -> TimeInterval {
            let duration = ContinuousClock.now - started
            return TimeInterval(duration.components.seconds) + TimeInterval(duration.components.attoseconds) / 1e18
        }
        do {
            try await uploadBlocks(to: storageURI, data: data, renewPath: renewPath, recorder: recorder)
            await recorder.note("Upload", fileName, note: "\(summary): uploaded.", duration: elapsed())
        } catch is CancellationError {
            await recorder.note("Upload", fileName, note: "\(summary): cancelled.", duration: elapsed(), isWarning: true)
            throw CancellationError()
        } catch {
            await recorder.note("Upload", fileName, note: "\(summary): failed. \(Redaction.text(error.localizedDescription))",
                                duration: elapsed(), failed: true)
            throw error
        }
    }

    private func uploadBlocks(to initialStorageURI: String, data: Data, renewPath: String, recorder: RequestRecorder) async throws {
        var storageURI = initialStorageURI
        var blockIDs: [String] = []
        var index = 0
        var offset = 0
        var lastRenewal = ContinuousClock.now

        while offset < data.count {
            // SAS URIs expire; renew proactively every ~7 minutes on long
            // uploads and continue with the refreshed URI.
            if ContinuousClock.now - lastRenewal > .seconds(420) {
                try await client.post(renewPath + "/renewUpload", version: .beta, body: Data("{}".utf8))
                storageURI = try await pollFile(
                    path: renewPath,
                    until: "azureStorageUriRenewalSuccess",
                    failures: ["azureStorageUriRenewalFailed", "azureStorageUriRenewalTimedOut", "error"],
                    attempts: 20,
                    extract: { $0["azureStorageUri"] as? String }
                )
                lastRenewal = ContinuousClock.now
            }

            let end = min(offset + Self.blockSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            let blockID = Data(String(format: "block-%04d", index).utf8).base64EncodedString()
            blockIDs.append(blockID)

            guard let encodedID = blockID.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  let url = URL(string: "\(storageURI)&comp=block&blockid=\(encodedID)") else {
                throw AppUploadError.azure(-1)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
            request.httpBody = chunk
            let (_, http) = try await recorder.send(request, recordsOnlyFailures: true)
            guard (200..<300).contains(http.statusCode) else {
                throw AppUploadError.azure(http.statusCode)
            }

            offset = end
            index += 1
        }

        // Finalize the blob with the ordered block list.
        let blockList = "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList>"
            + blockIDs.map { "<Latest>\($0)</Latest>" }.joined()
            + "</BlockList>"
        guard let url = URL(string: "\(storageURI)&comp=blocklist") else {
            throw AppUploadError.azure(-1)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(blockList.utf8)
        let (_, http) = try await recorder.send(request, recordsOnlyFailures: true)
        guard (200..<300).contains(http.statusCode) else {
            throw AppUploadError.azure(http.statusCode)
        }
        Self.logger.info("Uploaded \(blockIDs.count) block(s), \(data.count) bytes")
    }

    private func requireID(in response: Data, step: String) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let id = object["id"] as? String else {
            throw AppUploadError.missingID(step)
        }
        return id
    }
}
