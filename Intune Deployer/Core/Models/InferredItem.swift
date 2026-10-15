import Foundation

/// How a shell script should run on the device. Values map 1:1 to the script
/// header directive (`# intune: runAsAccount=user frequency=1440 ...`).
nonisolated struct ScriptSettings: Codable, Sendable, Hashable {
    enum RunAsAccount: String, Codable, Sendable, CaseIterable {
        case system
        case user
    }

    var runAsAccount: RunAsAccount = .system
    /// Run frequency in minutes; nil means "run once".
    var frequencyMinutes: Int?
    var retries: Int?
    var hideNotifications: Bool = false
}

/// The value type of a custom attribute script result.
nonisolated enum CustomAttributeValueType: String, Codable, Sendable, CaseIterable {
    case string
    case integer
    case dateTime
}

/// A deployable item inferred from a file in a baseline source.
nonisolated struct InferredItem: Identifiable, Sendable, Hashable {
    /// Stable short identity hash derived from sourceID + relative path;
    /// written to the tenant as the `[IntuneDeployer:…]` identity tag.
    let id: String
    let sourceID: UUID
    /// Path relative to the source root, using `/` separators.
    let relativePath: String
    let fileURL: URL
    let type: ItemType
    let displayName: String
    /// Human-readable explanation of why this type was detected.
    let detectionReason: String
    /// `{{Token}}` placeholders found in the file content, sorted, unique.
    let tokens: [String]
    /// Only set for shell scripts.
    let scriptSettings: ScriptSettings?
    /// Only set for custom attributes.
    let customAttributeType: CustomAttributeValueType?

    init(
        id: String,
        sourceID: UUID,
        relativePath: String,
        fileURL: URL,
        type: ItemType,
        displayName: String,
        detectionReason: String,
        tokens: [String] = [],
        scriptSettings: ScriptSettings? = nil,
        customAttributeType: CustomAttributeValueType? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.relativePath = relativePath
        self.fileURL = fileURL
        self.type = type
        self.displayName = displayName
        self.detectionReason = detectionReason
        self.tokens = tokens
        self.scriptSettings = scriptSettings
        self.customAttributeType = customAttributeType
    }
}

/// A file that was found in a source but not turned into an item.
nonisolated struct SkippedFile: Identifiable, Sendable, Hashable {
    var id: String { relativePath }
    let relativePath: String
    let reason: String
}

/// The outcome of scanning one baseline source.
nonisolated struct ScanResult: Sendable {
    var items: [InferredItem] = []
    var skipped: [SkippedFile] = []
}
