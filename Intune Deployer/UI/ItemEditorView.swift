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
                    "Can’t Edit",
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
                Text("The source file isn’t changed. This edit is deployed instead of it until it’s reverted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let validationError {
                    Label {
                        Text(validationError)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .accessibilityLabel("Error")
                    }
                    .font(.callout)
                    .frame(maxWidth: 320, alignment: .trailing)
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // Return types a new line in the editor, so Save is ⌘S.
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
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
                loadError = ItemEditValidation.tooLarge
                return
            }
            let editable: String
            switch Self.editableText(from: effective, pathExtension: item.fileURL.pathExtension.lowercased()) {
            case .success(let text): editable = text
            case .failure(let error):
                loadError = error.message
                return
            }
            // The base for conflict detection is the file as it is right now.
            originalData = try store.originalFileContents(of: item)
            text = editable
            initialText = editable
            isLoaded = true
        } catch {
            loadError = "Couldn’t load the file: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard let originalData else { return }
        switch ItemEditValidation.validate(text: text, for: item) {
        case .invalid(let message):
            validationError = message
            // Save did nothing: VoiceOver says why
            AccessibilityNotification.Announcement(message).post()
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

    /// The text presented in the editor: the content as it is. JSON on one
    /// line is indented (keys keep their order, values their spelling);
    /// nothing else changes. Content that can't be shown as UTF-8 text
    /// unchanged (a binary profile, another text encoding) isn't edited here.
    nonisolated static func editableText(from data: Data, pathExtension: String) -> Result<String, EditableTextError> {
        guard let text = String(data: data, encoding: .utf8) else {
            if pathExtension == "mobileconfig",
               (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil {
                return .failure(.binaryProfile)
            }
            return .failure(.notUTF8)
        }
        if pathExtension == "json", !text.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n"),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return .success(indentedJSON(text))
        }
        return .success(text)
    }

    nonisolated enum EditableTextError: Error, Equatable {
        case binaryProfile
        case notUTF8

        var message: String {
            switch self {
            case .binaryProfile: "This profile is a binary property list, which can’t be edited as text. Edit the source file instead."
            case .notUTF8: "This file isn’t UTF-8 text, so editing it here would change its other characters. Edit the source file instead."
            }
        }
    }

    /// Valid JSON with line breaks and two-space indents added between its
    /// tokens; the tokens themselves are copied as they are.
    nonisolated static func indentedJSON(_ text: String) -> String {
        var output = ""
        var depth = 0
        var inString = false
        var escaped = false
        func newline() { output += "\n" + String(repeating: "  ", count: depth) }
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if inString {
                output.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"":
                inString = true
                output.append(character)
            case "{", "[":
                output.append(character)
                // An empty object or array stays on its line.
                let next = characters[(index + 1)...].first { !$0.isWhitespace }
                depth += 1
                if next != "}" && next != "]" { newline() }
            case "}", "]":
                depth -= 1
                if let last = output.last(where: { !$0.isWhitespace }), last != "{" && last != "[" {
                    newline()
                } else {
                    while output.last?.isWhitespace == true { output.removeLast() }
                }
                output.append(character)
            case ",":
                output.append(character)
                newline()
            case ":":
                output += ": "
            case " ", "\t", "\n", "\r":
                break
            default:
                output.append(character)
            }
        }
        return output
    }
}
