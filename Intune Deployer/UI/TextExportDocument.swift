import SwiftUI
import UniformTypeIdentifiers

/// Minimal FileDocument for exporting generated text (reports, profiles).
struct TextExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, .html, .json]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
