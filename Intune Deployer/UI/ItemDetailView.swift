import SwiftUI

/// Detail column: detected type and why, tokens, script options and a
/// pretty-printed preview of the file.
struct ItemDetailView: View {
    @Environment(SourceStore.self) private var store
    @Environment(TenantStore.self) private var tenantStore
    let item: InferredItem

    @State private var previewText: String?
    @State private var previewError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                detectionSection
                if !item.tokens.isEmpty {
                    tokensSection
                }
                if let settings = item.scriptSettings {
                    scriptSettingsSection(settings)
                }
                if let attributeType = item.customAttributeType {
                    LabeledContent("Attribute Type", value: attributeType.rawValue)
                }
                if let profile = tenantStore.selectedProfile {
                    AssignmentEditorView(item: item, profile: profile)
                }
                if let source = itemSource, source.isGitHub {
                    attributionSection(source)
                }
                previewSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: item.id) {
            await loadPreview()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: item.type.symbolName)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.title2.bold())
                Text(item.type.displayName)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detectionSection: some View {
        GroupBox("Detection") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Detected because", value: item.detectionReason)
                LabeledContent("File", value: item.relativePath)
                LabeledContent("Item ID", value: item.id)
                    .help("Stable identity used for the \(ItemIdentity.tag(forShortID: item.id)) identity tag")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.callout)
        }
    }

    private var tokensSection: some View {
        GroupBox("Variables") {
            VStack(alignment: .leading, spacing: 6) {
                Text("These placeholders are substituted per tenant at plan time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    ForEach(item.tokens, id: \.self) { token in
                        Text("{{\(token)}}")
                            .font(.callout.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scriptSettingsSection(_ settings: ScriptSettings) -> some View {
        GroupBox("Script Options") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Run as", value: settings.runAsAccount.rawValue)
                LabeledContent("Frequency", value: settings.frequencyMinutes.map { "every \($0) min" } ?? "run once")
                LabeledContent("Retries", value: settings.retries.map(String.init) ?? "none")
                LabeledContent("Hide notifications", value: settings.hideNotifications ? "yes" : "no")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.callout)
        }
    }

    private var itemSource: BaselineSource? {
        store.sources.first { $0.id == item.sourceID }
    }

    /// Source URL and license, shown for items from GitHub sources.
    private func attributionSection(_ source: BaselineSource) -> some View {
        GroupBox("Source & License") {
            VStack(alignment: .leading, spacing: 6) {
                if let spec = source.gitHubSpec, let url = spec.repoURL {
                    LabeledContent("Repository") {
                        Link("\(spec.owner)/\(spec.repo)", destination: url)
                    }
                }
                if let tag = source.gitHub?.syncedTag {
                    LabeledContent("Release", value: tag)
                } else if let branch = source.gitHub?.defaultBranch {
                    LabeledContent("Branch", value: branch)
                }
                LabeledContent("License", value: source.gitHub?.licenseSPDX
                    ?? source.gitHub?.licenseName
                    ?? "unknown — check the repository")
                Text("Review third-party baseline content before deploying it to production.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.callout)
        }
    }

    private var previewSection: some View {
        GroupBox("Preview") {
            Group {
                if let previewError {
                    Label(previewError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if let previewText {
                    Text(previewText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loadPreview() async {
        previewText = nil
        previewError = nil
        // App packages are binary and can be very large — no text preview.
        guard item.type != .app else {
            previewText = "App package — bundle details are read at plan time."
            return
        }
        do {
            let data = try store.fileContents(of: item)
            previewText = Self.formatted(data: data, pathExtension: item.fileURL.pathExtension.lowercased())
        } catch {
            previewError = "Could not load preview: \(error.localizedDescription)"
        }
    }

    private static let previewCharacterLimit = 200_000

    /// Pretty-prints JSON and plists; shows scripts and anything else as-is.
    nonisolated private static func formatted(data: Data, pathExtension: String) -> String {
        var text: String
        switch pathExtension {
        case "json":
            if let object = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
               let string = String(data: pretty, encoding: .utf8) {
                text = string
            } else {
                text = String(data: data, encoding: .utf8) ?? "(binary data)"
            }
        case "mobileconfig":
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
               let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
               let string = String(data: xml, encoding: .utf8) {
                text = string
            } else {
                text = String(data: data, encoding: .utf8) ?? "(binary data)"
            }
        default:
            text = String(data: data, encoding: .utf8) ?? "(binary file)"
        }
        if text.count > previewCharacterLimit {
            text = String(text.prefix(previewCharacterLimit)) + "\n… (truncated)"
        }
        return text
    }
}
