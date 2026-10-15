import Foundation

/// Finds `{{TokenName}}` variable placeholders in file content.
///
/// Tokens may appear in JSON values, mobileconfig strings and scripts.
/// Substitution happens at plan time; scanning only reports which variables
/// an item needs.
nonisolated enum TokenScanner {
    /// The one `{{Token}}` pattern: scanning and substitution must agree on
    /// what a token is. Token names: a letter, then letters/digits/underscores.
    /// Regex is not Sendable, so it is built per call rather than cached.
    static var tokenPattern: Regex<(Substring, Substring)> {
        /\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}/
    }

    /// Returns the unique token names found in `text`, sorted alphabetically.
    static func tokens(in text: String) -> [String] {
        var names = Set<String>()
        for match in text.matches(of: tokenPattern) {
            names.insert(String(match.1))
        }
        return names.sorted()
    }
}
