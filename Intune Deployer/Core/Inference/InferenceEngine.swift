import Foundation

/// Scans a baseline source folder recursively and turns each supported file
/// into an `InferredItem` — no manifests, the file itself is the truth.
nonisolated enum InferenceEngine {
    /// Scans `root` and returns inferred items plus skipped files with reasons.
    /// `sourceID` feeds the stable item identity. Hidden files (including the
    /// app-managed .baseline.json) and bundle contents are skipped.
    static func scan(root: URL, sourceID: UUID) throws -> ScanResult {
        let fileManager = FileManager.default
        var result = ScanResult()

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }

        var fileURLs: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            fileURLs.append(url)
        }

        let rootPath = root.standardizedFileURL.path
        for url in fileURLs.sorted(by: { $0.path < $1.path }) {
            let relativePath = relativePath(of: url, underRootPath: rootPath)
            switch classify(url: url, relativePath: relativePath, sourceID: sourceID) {
            case .item(let item):
                result.items.append(item)
            case .skip(let reason):
                result.skipped.append(SkippedFile(relativePath: relativePath, reason: reason))
            }
        }
        return result
    }

    private enum Classification {
        case item(InferredItem)
        case skip(reason: String)
    }

    private static func relativePath(of url: URL, underRootPath rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(String(path.dropFirst(rootPath.count)).trimmingPrefix("/"))
    }

    private static func classify(url: URL, relativePath: String, sourceID: UUID) -> Classification {
        let ext = url.pathExtension.lowercased()
        let baseName = url.deletingPathExtension().lastPathComponent

        func makeItem(
            type: ItemType,
            displayName: String?,
            reason: String,
            tokens: [String] = [],
            scriptSettings: ScriptSettings? = nil,
            customAttributeType: CustomAttributeValueType? = nil
        ) -> Classification {
            .item(InferredItem(
                id: ItemIdentity.shortID(sourceID: sourceID, relativePath: relativePath),
                sourceID: sourceID,
                relativePath: relativePath,
                fileURL: url,
                type: type,
                displayName: displayName.flatMap { $0.isEmpty ? nil : $0 } ?? baseName,
                detectionReason: reason,
                tokens: tokens,
                scriptSettings: scriptSettings,
                customAttributeType: customAttributeType
            ))
        }

        switch ext {
        case "json":
            guard let data = try? Data(contentsOf: url) else {
                return .skip(reason: "Could not read file")
            }
            switch JSONInference.classify(data: data) {
            case .item(let detection):
                let text = String(data: data, encoding: .utf8) ?? ""
                return makeItem(
                    type: detection.type,
                    displayName: detection.displayName,
                    reason: detection.reason,
                    tokens: TokenScanner.tokens(in: text)
                )
            case .skip(let reason):
                return .skip(reason: reason)
            }

        case "mobileconfig":
            guard let data = try? Data(contentsOf: url) else {
                return .skip(reason: "Could not read file")
            }
            switch MobileConfigInference.classify(data: data) {
            case .item(let detection):
                return makeItem(
                    type: .customConfiguration,
                    displayName: detection.displayName,
                    reason: detection.reason,
                    tokens: TokenScanner.tokens(in: detection.scannableText ?? "")
                )
            case .skip(let reason):
                return .skip(reason: reason)
            }

        case "sh", "zsh":
            guard let text = readText(at: url) else {
                return .skip(reason: "Could not read file as text")
            }
            let directive = ScriptDirective.parse(scriptText: text)
            let tokens = TokenScanner.tokens(in: text)

            // Decide script vs custom attribute:
            // 1. header directive, 2. folder name, 3. default shell script.
            if directive.declaredType == .customAttribute {
                return makeItem(
                    type: .customAttribute,
                    displayName: baseName,
                    reason: "Header directive: # intune: type=customAttribute",
                    tokens: tokens,
                    customAttributeType: directive.attributeType ?? .string
                )
            }
            if directive.declaredType == nil, pathSuggestsCustomAttribute(relativePath) {
                return makeItem(
                    type: .customAttribute,
                    displayName: baseName,
                    reason: "Folder name indicates a custom attribute",
                    tokens: tokens,
                    customAttributeType: directive.attributeType ?? .string
                )
            }
            return makeItem(
                type: .shellScript,
                displayName: baseName,
                reason: directive.declaredType == .shellScript
                    ? "Header directive: # intune: type=shellScript"
                    : "Shell script by default (no directive, no custom-attribute folder)",
                tokens: tokens,
                scriptSettings: directive.scriptSettings
            )

        case "pkg", "dmg":
            return makeItem(
                type: .app,
                displayName: baseName,
                reason: "macOS app package (.\(ext)) — bundle details are read at plan time"
            )

        case "xml":
            return .skip(reason: "XML manifests from other tools are ignored")

        default:
            return .skip(reason: "Unsupported file type (.\(ext.isEmpty ? url.lastPathComponent : ext))")
        }
    }

    /// True if any folder in the relative path looks like a custom-attribute
    /// folder, e.g. "CustomAttributes", "Custom Attributes", "custom-attribute".
    private static func pathSuggestsCustomAttribute(_ relativePath: String) -> Bool {
        let folders = relativePath.split(separator: "/").dropLast()
        return folders.contains { component in
            let normalized = component.lowercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
            return normalized.contains("customattribute")
        }
    }

    private static func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }
}
