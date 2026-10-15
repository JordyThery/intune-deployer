import SwiftUI

/// Sheet that edits an item's content in-app. The source file is never
/// written; the saved edit deploys instead of the file until it is reverted.
struct ItemEditorView: View {
    @Environment(SourceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let item: InferredItem

    @State private var text = ""
    @State private var initialText = ""
    @State private var originalData: Data?
    @State private var loadError: String?
    @State private var validationError: String?
    @State private var isLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: item.type.symbolName)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Edit \(item.displayName)")
                        .font(.headline)
                    Text("\(item.type.displayName) · \(item.relativePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            if let loadError {
                ContentUnavailableView(
                    "Cannot Edit",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if isLoaded {
                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack {
                Text("The source file is not modified — this edit is deployed instead of it until it is reverted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: 320, alignment: .trailing)
                }
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isLoaded || loadError != nil || text == initialText)
            }
            .padding()
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 440, idealHeight: 560)
        .task { load() }
    }

    private func load() {
        do {
            let effective = try store.fileContents(of: item)
            guard effective.count <= ItemEditValidation.maxSize else {
                loadError = "This file is larger than 2 MB — edit it in the source instead."
                return
            }
            guard let editable = Self.editableText(from: effective, pathExtension: item.fileURL.pathExtension.lowercased()) else {
                loadError = "This file could not be read as text."
                return
            }
            // The base for conflict detection is the file as it is right now.
            originalData = try store.originalFileContents(of: item)
            text = editable
            initialText = editable
            isLoaded = true
        } catch {
            loadError = "Could not load the file: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard let originalData else { return }
        switch ItemEditValidation.validate(text: text, for: item) {
        case .invalid(let message):
            validationError = message
        case .valid(let data):
            validationError = nil
            store.edits.save(ItemEdit(
                itemID: item.id,
                sourceID: item.sourceID,
                relativePath: item.relativePath,
                content: data,
                baseContentHash: ItemEditStore.hash(originalData),
                modified: .now
            ))
            // Rescan so the item's name, tokens and badges reflect the edit.
            Task { await store.scan(sourceID: item.sourceID) }
            dismiss()
        }
    }

    /// The text presented in the editor. JSON is pretty-printed with the
    /// read-only Graph metadata removed (the deploy path strips those keys
    /// anyway) and nulls dropped (Graph treats a missing optional field and
    /// an explicit null identically — exports are full of echoed nulls), and
    /// binary mobileconfig plists are converted to XML — the stored edit is
    /// the readable form, which deploys identically (plans compare parsed
    /// values, not bytes).
    nonisolated static func editableText(from data: Data, pathExtension: String) -> String? {
        if pathExtension == "json",
           let object = try? JSONSerialization.jsonObject(with: data) {
            var cleaned = (object as? [String: Any]).map { PayloadBuilder.stripServerKeys($0) } ?? object
            cleaned = removingNulls(cleaned) ?? cleaned
            if let pretty = try? JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let text = String(data: pretty, encoding: .utf8) {
                return text
            }
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if pathExtension == "mobileconfig",
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            return String(data: xml, encoding: .utf8)
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Recursively drops JSON nulls. Empty dictionaries that only held nulls
    /// (e.g. a templateReference of nothing but null fields) disappear too.
    nonisolated private static func removingNulls(_ value: Any) -> Any? {
        if value is NSNull { return nil }
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in dict {
                if let cleaned = removingNulls(child) { result[key] = cleaned }
            }
            return result.isEmpty && !dict.isEmpty ? nil : result
        }
        if let array = value as? [Any] {
            return array.compactMap { removingNulls($0) }
        }
        return value
    }
}
