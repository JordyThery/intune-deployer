import Foundation

/// Parses the optional `# intune:` header directive in shell scripts, e.g.
///
///     # intune: type=customAttribute attributeType=string
///     # intune: runAsAccount=user frequency=1440 retries=3 hideNotifications=true
///
/// Multiple directive lines are merged; later lines win on key conflicts.
/// Unknown keys and invalid values are collected for diagnostics.
nonisolated struct ScriptDirective: Sendable, Equatable {
    enum DeclaredType: String, Sendable {
        case shellScript
        case customAttribute
    }

    var declaredType: DeclaredType?
    var attributeType: CustomAttributeValueType?
    var runAsAccount: ScriptSettings.RunAsAccount?
    var frequencyMinutes: Int?
    var retries: Int?
    var hideNotifications: Bool?
    var unknownKeys: [String] = []

    /// Scans the first `maxLines` lines of a script for directive comments.
    static func parse(scriptText: String, maxLines: Int = 15) -> ScriptDirective {
        var directive = ScriptDirective()
        // Split on any newline so CRLF files keep their directives.
        let lines = scriptText
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .prefix(maxLines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let match = trimmed.firstMatch(of: /^#\s*intune:\s*(.+)$/) else { continue }
            directive.apply(pairs: String(match.1))
        }
        return directive
    }

    private mutating func apply(pairs: String) {
        for pair in pairs.split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1])
            switch key {
            case "type":
                // Accept both camelCase and lowercase spellings.
                switch value.lowercased() {
                case "customattribute": declaredType = .customAttribute
                case "shellscript", "script": declaredType = .shellScript
                default: unknownKeys.append("\(key)=\(value)")
                }
            case "attributeType":
                switch value.lowercased() {
                case "string": attributeType = .string
                case "integer", "int": attributeType = .integer
                case "datetime", "date": attributeType = .dateTime
                default: unknownKeys.append("\(key)=\(value)")
                }
            case "runAsAccount":
                switch value.lowercased() {
                case "system", "root": runAsAccount = .system
                case "user": runAsAccount = .user
                default: unknownKeys.append("\(key)=\(value)")
                }
            case "frequency":
                if let minutes = Int(value) { frequencyMinutes = minutes } else { unknownKeys.append("\(key)=\(value)") }
            case "retries":
                if let count = Int(value) { retries = count } else { unknownKeys.append("\(key)=\(value)") }
            case "hideNotifications":
                hideNotifications = (value as NSString).boolValue
            default:
                unknownKeys.append(key)
            }
        }
    }

    /// The script settings expressed by this directive, over defaults.
    var scriptSettings: ScriptSettings {
        var settings = ScriptSettings()
        if let runAsAccount { settings.runAsAccount = runAsAccount }
        settings.frequencyMinutes = frequencyMinutes
        settings.retries = retries
        if let hideNotifications { settings.hideNotifications = hideNotifications }
        return settings
    }
}
