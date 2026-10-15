import Foundation

/// Finds `{{TokenName}}` variable placeholders in file content.
///
/// Tokens may appear in JSON values, mobileconfig strings and scripts.
/// Substitution happens at plan time; scanning only reports which variables
/// an item needs.
nonisolated enum TokenScanner {
    /// Returns the unique token names found in `text`, sorted alphabetically.
    static func tokens(in text: String) -> [String] {
        // Token names: letters, digits and underscores, e.g. `{{EnrollmentProfileName}}`.
        // Regex is not Sendable, so build it locally rather than caching it statically.
        let tokenPattern = /\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}/
        var names = Set<String>()
        for match in text.matches(of: tokenPattern) {
            names.insert(String(match.1))
        }
        return names.sorted()
    }
}
