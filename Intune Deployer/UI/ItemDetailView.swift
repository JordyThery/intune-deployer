import SwiftUI

/// Detail column: detected type and why, tokens, script options and a
/// pretty-printed preview of the file.
struct ItemDetailView: View {
    @Environment(SourceStore.self) private var store
    @Environment(TenantStore.self) private var tenantStore
    let item: InferredItem

    @AppStorage("enableItemEditing") private var editingEnabled = false
    @State private var previewText: String?
    @State private var previewError: String?
    @State private var isEditing = false
    @State private var showOriginal = false
    @State private var confirmingRevert = false

    private var currentEdit: ItemEdit? {
        store.edits.edit(for: item.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                detectionSection
                if editingEnabled || currentEdit != nil, item.type != .app {
                    editSection
                }
                if !item.tokens.isEmpty {
                    tokensSection
                }
                if let settings = item.scriptSettings {
                    scriptSettingsSection(settings)
                }
                if let attributeType = item.customAttributeType {
                    LabeledContent("Attribute type", value: attributeType.rawValue)
                }
                // Assignment filters cannot themselves be assigned.
                if let profile = tenantStore.selectedProfile, item.type != .assignmentFilter {
                    AssignmentEditorView(items: [item], profile: profile)
                }
                if let source = itemSource, source.isGitHub {
                    attributionSection(source)
                }
                previewSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: previewRevision) {
            await loadPreview()
        }
        .onChange(of: item.id) { showOriginal = false }
        .sheet(isPresented: $isEditing) {
            ItemEditorView(item: item)
        }
        .confirmationDialog(
            "Revert “\(item.displayName)” to the source file?",
            isPresented: $confirmingRevert,
            titleVisibility: .visible
        ) {
            Button("Revert", role: .destructive) { revertEdit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The in-app edit is discarded; the file's content deploys again. Objects already in a tenant are not changed until the next Apply.")
        }
    }

    /// Reloads the preview when the item, the edit, or the shown variant
    /// changes.
    private var previewRevision: String {
        "\(item.id)|\(showOriginal)|\(currentEdit?.modified.timeIntervalSinceReferenceDate ?? 0)"
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: item.type.symbolName)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.title2.bold())
                HStack(spacing: 6) {
                    Text(item.type.displayName)
                    if let edit = currentEdit {
                        Text(edit.hasConflict ? "Edited · source changed" : "Edited")
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(edit.hasConflict ? .yellow.opacity(0.3) : .blue.opacity(0.15),
                                        in: Capsule())
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - In-app edit

    private var editSection: some View {
        GroupBox("In-App Edit") {
            VStack(alignment: .leading, spacing: 8) {
                if let edit = currentEdit {
                    if edit.hasConflict {
                        Label("The source file changed since this edit. The edit still deploys; compare using the Original preview below.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("Last edited", value: edit.modified.formatted(date: .abbreviated, time: .shortened))
                        .font(.callout)
                    HStack {
                        if editingEnabled {
                            Button("Edit Content…") { isEditing = true }
                        }
                        if edit.hasConflict {
                            Button("Keep My Edit") { keepDespiteConflict() }
                                .help("Accepts the new source content as the comparison base; the edit keeps deploying")
                            Button("Use Source Version", role: .destructive) { confirmingRevert = true }
                        } else {
                            Button("Revert to Source…", role: .destructive) { confirmingRevert = true }
                        }
                    }
                } else {
                    Button("Edit Content…") { isEditing = true }
                    Text("Changes are kept in the app and deployed instead of the file — the source file is never modified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func revertEdit() {
        store.edits.revert(itemID: item.id)
        showOriginal = false
        Task { await store.scan(sourceID: item.sourceID) }
    }

    private func keepDespiteConflict() {
        guard let original = try? store.originalFileContents(of: item) else { return }
        store.edits.keepDespiteConflict(itemID: item.id, currentOriginal: original)
    }

    private var detectionSection: some View {
        GroupBox("Detection") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Detected because", value: item.detectionReason)
                LabeledContent("File", value: item.relativePath)
                platformRow
                LabeledContent("Item ID", value: item.id)
                    .help("Stable identity used for the \(ItemIdentity.tag(forShortID: item.id)) identity tag")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.callout)
        }
    }

    /// `.mobileconfig` profiles cannot state their platform, so it is chosen
    /// here; every other type carries it in the file or package format.
    @ViewBuilder
    private var platformRow: some View {
        if item.fileURL.pathExtension.lowercased() == "mobileconfig" {
            Picker("Platform", selection: platformBinding) {
                ForEach(ItemPlatform.allCases, id: \.self) { platform in
                    Text(platform.displayName).tag(platform)
                }
            }
            .pickerStyle(.menu)
            .help("The profile deploys as a configuration profile for this platform")
        } else {
            LabeledContent("Platform", value: item.platform.displayName)
        }
    }

    private var platformBinding: Binding<ItemPlatform> {
        Binding(
            get: { item.platform },
            set: { newValue in
                store.platformOverrides.set(newValue, for: item)
                Task { await store.scan(sourceID: item.sourceID) }
            }
        )
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
        GroupBox {
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
        } label: {
            HStack {
                Text("Preview")
                if currentEdit != nil {
                    Picker("Preview content", selection: $showOriginal) {
                        Text("Edited").tag(false)
                        Text("Original").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
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
            let data = showOriginal
                ? try store.originalFileContents(of: item)
                : try store.fileContents(of: item)
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
            // Same formatting as the editor, so Preview and Edit never differ.
            if let object = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
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
