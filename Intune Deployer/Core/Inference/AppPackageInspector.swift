import Foundation
import os
import OSLog

/// Bundle metadata read from a .pkg, .dmg or .ipa, used to build the Intune app.
nonisolated struct AppPackageInfo: Sendable, Hashable {
    struct IncludedApp: Sendable, Hashable {
        let bundleID: String
        let bundleVersion: String
    }

    var primaryBundleID: String
    var primaryBundleVersion: String
    var includedApps: [IncludedApp]

    // iOS (.ipa) fields; nil for macOS packages.
    /// CFBundleVersion (the build number).
    var buildNumber: String?
    /// MinimumOSVersion from the app's Info.plist.
    var minimumOSVersion: String?
    /// UIDeviceFamily: 1 = iPhone/iPod, 2 = iPad.
    var supportsIPhone: Bool?
    var supportsIPad: Bool?
    /// ExpirationDate of the embedded provisioning profile; Intune requires
    /// it, and nil means the .ipa is unsigned.
    var provisioningExpiration: Date?
}

nonisolated enum AppInspectionError: LocalizedError, Equatable {
    case toolFailed(String)
    case noMetadata(String)
    /// Reading the package took longer than its time limit (`seconds`).
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .toolFailed(let message): "Couldn’t open the package: \(message)"
        case .noMetadata(let message): message
        case .timedOut(let seconds):
            "Reading the package took longer than \(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide))), so it was stopped. Check that it opens in Finder, then run Plan again."
        }
    }
}

/// Reads bundle identifier/version information from app packages.
///
/// - .pkg: a flat package is a xar archive; `Distribution` (product archive)
///   or `PackageInfo` (component package) XML carries identifier + version
///   (Apple Distribution XML Reference / flat package format).
/// - .dmg: mounted read-only via hdiutil; the first .app bundle's Info.plist
///   provides CFBundleIdentifier + CFBundleShortVersionString.
/// - .ipa: a zip; Payload/<App>.app/Info.plist provides the bundle metadata
///   and embedded.mobileprovision the provisioning expiry.
///
/// Callers must pass a file inside the app's sandbox container (copy it first) so
/// the spawned helper tools can read it.
nonisolated enum AppPackageInspector {
    private static let logger = Logger(subsystem: "be.jordythery.intune-deployer", category: "AppInspector")

    static func inspect(packageAt url: URL) throws -> AppPackageInfo {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let timeout = timeout(forSize: size)
        switch url.pathExtension.lowercased() {
        case "pkg":
            return try inspectPkg(at: url, timeout: timeout)
        case "dmg":
            return try inspectDmg(at: url, timeout: timeout)
        case "ipa":
            return try inspectIpa(at: url, timeout: timeout)
        default:
            throw AppInspectionError.noMetadata("Unsupported package type .\(url.pathExtension)")
        }
    }

    // MARK: - .pkg (xar)

    private static func inspectPkg(at url: URL, timeout: TimeInterval) throws -> AppPackageInfo {
        let workDir = url.deletingLastPathComponent().appending(path: "xar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // List the archive, then extract only the metadata XML files
        // (xar matches literal paths, so nested PackageInfo entries must be
        // named explicitly).
        let listing = try run("/usr/bin/xar", ["-t", "-f", url.path], timeout: timeout)
        let metadataPaths = listing
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0 == "Distribution" || $0.hasSuffix("/PackageInfo") || $0 == "PackageInfo" }
            // Archive-listed paths are untrusted: never extract outside workDir.
            .filter { !$0.split(separator: "/").contains("..") && !$0.hasPrefix("/") }
        guard !metadataPaths.isEmpty else {
            throw AppInspectionError.noMetadata("The .pkg contains no Distribution or PackageInfo metadata")
        }
        try run("/usr/bin/xar", ["-x", "-f", url.path, "-C", workDir.path] + metadataPaths, timeout: timeout)

        if let data = try? Data(contentsOf: workDir.appending(path: "Distribution")), !data.isEmpty {
            return try parseDistribution(data)
        }
        for path in metadataPaths where path.hasSuffix("PackageInfo") {
            if let data = try? Data(contentsOf: workDir.appending(path: path)), !data.isEmpty {
                return try parsePackageInfo(data)
            }
        }
        throw AppInspectionError.noMetadata("The .pkg metadata couldn’t be read")
    }

    /// Product archive Distribution XML: `product id/version`, `pkg-ref`
    /// version attributes and `bundle-version > bundle` entries.
    static func parseDistribution(_ data: Data) throws -> AppPackageInfo {
        let document = try XMLDocument(data: data)
        let includedApps = bundleEntries(in: document)

        // Preferred: the <product id="…" version="…"> element.
        if let product = try document.nodes(forXPath: "//product").first as? XMLElement,
           let id = product.attribute(forName: "id")?.stringValue,
           let version = product.attribute(forName: "version")?.stringValue {
            return AppPackageInfo(primaryBundleID: id, primaryBundleVersion: version, includedApps: fallback(includedApps, id: id, version: version))
        }
        // Else: first app bundle, else first versioned pkg-ref.
        if let first = includedApps.first {
            return AppPackageInfo(primaryBundleID: first.bundleID, primaryBundleVersion: first.bundleVersion, includedApps: includedApps)
        }
        if let ref = try document.nodes(forXPath: "//pkg-ref[@version]").first as? XMLElement,
           let id = ref.attribute(forName: "id")?.stringValue,
           let version = ref.attribute(forName: "version")?.stringValue {
            return AppPackageInfo(primaryBundleID: id, primaryBundleVersion: version, includedApps: fallback([], id: id, version: version))
        }
        throw AppInspectionError.noMetadata("Distribution XML has no product, bundle or versioned pkg-ref entries")
    }

    /// Component package PackageInfo XML: `pkg-info identifier/version` and
    /// `bundle-version > bundle` entries.
    static func parsePackageInfo(_ data: Data) throws -> AppPackageInfo {
        let document = try XMLDocument(data: data)
        let includedApps = bundleEntries(in: document)

        if let info = try document.nodes(forXPath: "//pkg-info").first as? XMLElement,
           let id = info.attribute(forName: "identifier")?.stringValue,
           let version = info.attribute(forName: "version")?.stringValue {
            return AppPackageInfo(primaryBundleID: id, primaryBundleVersion: version, includedApps: fallback(includedApps, id: id, version: version))
        }
        if let first = includedApps.first {
            return AppPackageInfo(primaryBundleID: first.bundleID, primaryBundleVersion: first.bundleVersion, includedApps: includedApps)
        }
        throw AppInspectionError.noMetadata("PackageInfo XML has no pkg-info or bundle entries")
    }

    /// `<bundle id="…" CFBundleShortVersionString="…" path="….app"/>` rows.
    private static func bundleEntries(in document: XMLDocument) -> [AppPackageInfo.IncludedApp] {
        let nodes = (try? document.nodes(forXPath: "//bundle")) ?? []
        var seen = Set<String>()
        var apps: [AppPackageInfo.IncludedApp] = []
        for case let element as XMLElement in nodes {
            guard let id = element.attribute(forName: "id")?.stringValue,
                  let version = element.attribute(forName: "CFBundleShortVersionString")?.stringValue
                      ?? element.attribute(forName: "CFBundleVersion")?.stringValue else { continue }
            // Only actual .app bundles (not .appex and other extensions).
            let path = element.attribute(forName: "path")?.stringValue ?? ""
            guard path.isEmpty || path.hasSuffix(".app") else { continue }
            guard seen.insert(id).inserted else { continue }
            apps.append(AppPackageInfo.IncludedApp(bundleID: id, bundleVersion: version))
        }
        return apps
    }

    private static func fallback(_ apps: [AppPackageInfo.IncludedApp], id: String, version: String) -> [AppPackageInfo.IncludedApp] {
        apps.isEmpty ? [AppPackageInfo.IncludedApp(bundleID: id, bundleVersion: version)] : apps
    }

    // MARK: - .dmg (hdiutil)

    private static func inspectDmg(at url: URL, timeout: TimeInterval) throws -> AppPackageInfo {
        // Mount at a known path so the image is always detached, even when
        // parsing fails afterwards.
        let mountURL = url.deletingLastPathComponent().appending(path: "mount-\(UUID().uuidString)")
        _ = try run(
            "/usr/bin/hdiutil",
            ["attach", url.path, "-nobrowse", "-readonly", "-noverify", "-mountpoint", mountURL.path],
            timeout: timeout
        )
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mountURL.path, "-quiet", "-force"])
        }
        let entries = (try? FileManager.default.contentsOfDirectory(at: mountURL, includingPropertiesForKeys: nil)) ?? []
        guard let appBundle = entries.first(where: { $0.pathExtension == "app" }) else {
            throw AppInspectionError.noMetadata("The disk image contains no .app bundle at its root")
        }
        let infoPlistURL = appBundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else {
            throw AppInspectionError.noMetadata("Couldn’t read \(appBundle.lastPathComponent)’s Info.plist")
        }
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? "1.0"
        let app = AppPackageInfo.IncludedApp(bundleID: bundleID, bundleVersion: version)
        return AppPackageInfo(primaryBundleID: bundleID, primaryBundleVersion: version, includedApps: [app])
    }

    // MARK: - .ipa (zip)

    /// An .ipa is a zip with `Payload/<Name>.app/`; the app's Info.plist
    /// carries the bundle metadata and `embedded.mobileprovision` the
    /// provisioning profile (a CMS blob with a readable plist inside).
    private static func inspectIpa(at url: URL, timeout: TimeInterval) throws -> AppPackageInfo {
        let workDir = url.deletingLastPathComponent().appending(path: "ipa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        try run("/usr/bin/ditto", ["-x", "-k", url.path, workDir.path], timeout: timeout)
        // Archives can contain symlinks with arbitrary targets; reads below
        // must never follow one outside the work directory.
        removeSymlinks(in: workDir)

        let payload = workDir.appending(path: "Payload")
        let entries = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        guard let appBundle = entries.first(where: {
            $0.pathExtension == "app"
                && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
        }) else {
            throw AppInspectionError.noMetadata("The .ipa contains no Payload/<App>.app bundle")
        }

        // iOS bundles keep Info.plist at the bundle root (no Contents/).
        guard let data = try? Data(contentsOf: appBundle.appending(path: "Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else {
            throw AppInspectionError.noMetadata("Couldn’t read \(appBundle.lastPathComponent)’s Info.plist")
        }
        let buildNumber = info["CFBundleVersion"] as? String
        let version = (info["CFBundleShortVersionString"] as? String) ?? buildNumber ?? "1.0"
        let deviceFamilies = (info["UIDeviceFamily"] as? [Int]) ?? [1, 2]

        var result = AppPackageInfo(
            primaryBundleID: bundleID,
            primaryBundleVersion: version,
            includedApps: [AppPackageInfo.IncludedApp(bundleID: bundleID, bundleVersion: version)]
        )
        result.buildNumber = buildNumber
        result.minimumOSVersion = info["MinimumOSVersion"] as? String
        result.supportsIPhone = deviceFamilies.contains(1)
        result.supportsIPad = deviceFamilies.contains(2)
        result.provisioningExpiration = (try? Data(contentsOf: appBundle.appending(path: "embedded.mobileprovision")))
            .flatMap(provisioningExpiration(in:))
        return result
    }

    /// Deletes any symlinks an extracted archive contained (same precaution
    /// as for downloaded repositories).
    private static func removeSymlinks(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                try? FileManager.default.removeItem(at: url)
                enumerator.skipDescendants()
            }
        }
    }

    /// How long a helper tool may take for a package of this size: five
    /// minutes, plus a minute per GB, so a large package on a slow disk
    /// still opens.
    static func timeout(forSize bytes: Int) -> TimeInterval {
        300 + 60 * (Double(max(bytes, 0)) / 1_000_000_000).rounded(.up)
    }

    /// ExpirationDate from a provisioning profile: the profile is a signed
    /// CMS blob, so the plist is located by its XML markers.
    static func provisioningExpiration(in data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            return nil
        }
        let plistData = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["ExpirationDate"] as? Date
    }

    // MARK: - Helpers

    /// Runs a helper tool with stderr merged into stdout, collecting its
    /// output as it comes so large output cannot deadlock the process.
    /// Nothing can be typed into it (a disk image's license agreement would
    /// wait for an answer), and it is stopped after `timeout` seconds.
    /// - Parameter killGracePeriod: how long it gets to stop after the time
    ///   limit before it's killed.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 300,
                    killGracePeriod: TimeInterval = 5) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Output is collected as it comes, so a helper (or a child it left
        // behind) that keeps the pipe open can't block the read.
        let output = OSAllocatedUnfairLock(initialState: Data())
        let ended = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                ended.signal()
            } else {
                output.withLock { $0.append(chunk) }
            }
        }
        try process.run()
        // At the time limit: asked to stop, then, after a grace period,
        // killed (hdiutil in the middle of a mount can ignore the request).
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let deadline = DispatchWorkItem { [process] in
            guard process.isRunning else { return }
            stopped.withLock { $0 = true }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + killGracePeriod) { [process] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        _ = ended.wait(timeout: .now() + 2)
        pipe.fileHandleForReading.readabilityHandler = nil
        let text = String(decoding: output.withLock { $0 }, as: UTF8.self)
        // A process the time limit stopped timed out, whatever its exit
        // status (a tool can catch the request and exit normally); one that
        // finished before the limit came is never asked to stop.
        if stopped.withLock({ $0 }) {
            throw AppInspectionError.timedOut(seconds: Int(timeout.rounded()))
        }
        guard process.terminationStatus == 0 else {
            logger.error("\(tool, privacy: .public) failed: \(text, privacy: .public)")
            throw AppInspectionError.toolFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }

}
