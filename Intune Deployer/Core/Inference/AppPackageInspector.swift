import Foundation
import OSLog

/// Bundle metadata read from a .pkg or .dmg, used to build the Intune app.
nonisolated struct AppPackageInfo: Sendable, Hashable {
    struct IncludedApp: Sendable, Hashable {
        let bundleID: String
        let bundleVersion: String
    }

    var primaryBundleID: String
    var primaryBundleVersion: String
    var includedApps: [IncludedApp]
}

nonisolated enum AppInspectionError: LocalizedError {
    case toolFailed(String)
    case noMetadata(String)

    var errorDescription: String? {
        switch self {
        case .toolFailed(let message): "Could not open the package: \(message)"
        case .noMetadata(let message): message
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
///
/// Callers must pass a file INSIDE our sandbox container (copy it first) so
/// the spawned helper tools can read it.
nonisolated enum AppPackageInspector {
    private static let logger = Logger(subsystem: "be.jordythery.intune-deployer", category: "AppInspector")

    static func inspect(packageAt url: URL) throws -> AppPackageInfo {
        switch url.pathExtension.lowercased() {
        case "pkg":
            return try inspectPkg(at: url)
        case "dmg":
            return try inspectDmg(at: url)
        default:
            throw AppInspectionError.noMetadata("Unsupported package type .\(url.pathExtension)")
        }
    }

    // MARK: - .pkg (xar)

    private static func inspectPkg(at url: URL) throws -> AppPackageInfo {
        let workDir = url.deletingLastPathComponent().appending(path: "xar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // List the archive, then extract only the metadata XML files
        // (xar matches literal paths, so nested PackageInfo entries must be
        // named explicitly).
        let listing = try run("/usr/bin/xar", ["-t", "-f", url.path])
        let metadataPaths = listing
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0 == "Distribution" || $0.hasSuffix("/PackageInfo") || $0 == "PackageInfo" }
        guard !metadataPaths.isEmpty else {
            throw AppInspectionError.noMetadata("The .pkg contains no Distribution or PackageInfo metadata")
        }
        try run("/usr/bin/xar", ["-x", "-f", url.path, "-C", workDir.path] + metadataPaths)

        if let data = try? Data(contentsOf: workDir.appending(path: "Distribution")), !data.isEmpty {
            return try parseDistribution(data)
        }
        for path in metadataPaths where path.hasSuffix("PackageInfo") {
            if let data = try? Data(contentsOf: workDir.appending(path: path)), !data.isEmpty {
                return try parsePackageInfo(data)
            }
        }
        throw AppInspectionError.noMetadata("The .pkg metadata could not be read")
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

    private static func inspectDmg(at url: URL) throws -> AppPackageInfo {
        // Mount at a known path so the image is always detached, even when
        // parsing fails afterwards.
        let mountURL = url.deletingLastPathComponent().appending(path: "mount-\(UUID().uuidString)")
        _ = try run(
            "/usr/bin/hdiutil",
            ["attach", url.path, "-nobrowse", "-readonly", "-noverify", "-mountpoint", mountURL.path]
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
            throw AppInspectionError.noMetadata("Could not read \(appBundle.lastPathComponent)'s Info.plist")
        }
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? "1.0"
        let app = AppPackageInfo.IncludedApp(bundleID: bundleID, bundleVersion: version)
        return AppPackageInfo(primaryBundleID: bundleID, primaryBundleVersion: version, includedApps: [app])
    }

    // MARK: - Helpers

    /// Runs a helper tool with stderr merged into stdout, draining the pipe
    /// before waiting so large output cannot deadlock the process.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            logger.error("\(tool, privacy: .public) failed: \(output, privacy: .public)")
            throw AppInspectionError.toolFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
