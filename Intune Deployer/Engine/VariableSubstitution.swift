import Foundation

/// Substitutes `{{TokenName}}` placeholders with tenant profile variables.
/// Apply is blocked while any selected item has unresolved tokens.
nonisolated enum VariableSubstitution {
    /// How substituted values are escaped so they cannot break the document.
    enum Escaping: Sendable {
        /// Scripts and other plain text.
        case none
        /// JSON string values: backslash, quote and control characters.
        case json
        /// XML/plist text: &, < and >.
        case xml

        func escape(_ value: String) -> String {
            switch self {
            case .none:
                return value
            case .json:
                var escaped = ""
                for character in value.unicodeScalars {
                    switch character {
                    case "\\": escaped += "\\\\"
                    case "\"": escaped += "\\\""
                    case "\n": escaped += "\\n"
                    case "\r": escaped += "\\r"
                    case "\t": escaped += "\\t"
                    default:
                        if character.value < 0x20 {
                            escaped += String(format: "\\u%04x", character.value)
                        } else {
                            escaped.unicodeScalars.append(character)
                        }
                    }
                }
                return escaped
            case .xml:
                return value
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
            }
        }
    }

    struct Result: Sendable {
        let text: String
        /// Token names that had no (non-empty) value, sorted, unique.
        let unresolved: [String]
    }

    static func substitute(_ text: String, variables: [String: String], escaping: Escaping = .none) -> Result {
        var unresolved = Set<String>()
        let substituted = text.replacing(TokenScanner.tokenPattern) { match in
            let name = String(match.1)
            if let value = variables[name], !value.isEmpty {
                return escaping.escape(value)
            }
            unresolved.insert(name)
            return String(match.0) // leave the placeholder in place
        }
        return Result(text: substituted, unresolved: unresolved.sorted())
    }
}
