import Foundation

/// Compares a desired payload against the tenant object and produces readable
/// field-level changes.
///
/// The comparison is one-way over the DESIRED keys: Graph returns every
/// property with server defaults, so only fields we intend to manage are
/// compared. Arrays are compared element-wise including count. Server keys
/// (ids, timestamps, status fields) are stripped from both sides first.
nonisolated enum GraphDiff {
    /// Field changes between desired and remote JSON objects. `ignoringKeys`
    /// are removed at any depth before comparing — for fields the service
    /// rewrites or returns inconsistently (e.g. compliance `ruleName`).
    static func changes(desired: Data, remote: Data, ignoringKeys: Set<String> = []) throws -> [FieldChange] {
        guard let desiredObject = try JSONSerialization.jsonObject(with: desired) as? [String: Any],
              let remoteObject = try JSONSerialization.jsonObject(with: remote) as? [String: Any] else {
            throw PayloadError.invalidJSON("diff input")
        }
        var changes: [FieldChange] = []
        compare(
            desired: normalize(desiredObject, ignoringKeys: ignoringKeys),
            remote: normalize(remoteObject, ignoringKeys: ignoringKeys),
            path: "",
            into: &changes
        )
        return changes
    }

    /// Strips server-managed keys at the top level and ids/@odata noise at
    /// any depth so both sides are comparable.
    static func normalize(_ object: [String: Any], ignoringKeys: Set<String> = []) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in object {
            if PayloadBuilder.strippedKeys.contains(key) || ignoringKeys.contains(key) { continue }
            if key.hasPrefix("#") || key.contains("@odata.count") || key == "@odata.type" { continue }
            result[key] = scrub(value, ignoringKeys: ignoringKeys)
        }
        if let tags = result["roleScopeTagIds"] as? [String], tags.isEmpty || tags == ["0"] {
            result["roleScopeTagIds"] = nil
        }
        return result
    }

    private static func scrub(_ value: Any, ignoringKeys: Set<String>) -> Any {
        if var dict = value as? [String: Any] {
            dict["id"] = nil
            // Nested @odata.type is dropped too: Graph returns "#microsoft…"
            // while request bodies may use the unprefixed form.
            dict["@odata.type"] = nil
            for key in dict.keys where key.contains("@odata.count") || key.hasPrefix("#") || ignoringKeys.contains(key) {
                dict[key] = nil
            }
            for (key, nested) in dict {
                dict[key] = scrub(nested, ignoringKeys: ignoringKeys)
            }
            return dict
        }
        if let array = value as? [Any] {
            return array.map { scrub($0, ignoringKeys: ignoringKeys) }
        }
        return value
    }

    // MARK: - Recursive comparison

    private static func compare(desired: Any, remote: Any?, path: String, into changes: inout [FieldChange]) {
        guard let remote else {
            changes.append(FieldChange(path: path, oldValue: "—", newValue: display(desired)))
            return
        }
        if let desiredDict = desired as? [String: Any] {
            let remoteDict = remote as? [String: Any] ?? [:]
            for key in desiredDict.keys.sorted() {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                compare(desired: desiredDict[key]!, remote: remoteDict[key], path: childPath, into: &changes)
            }
            return
        }
        if let desiredArray = desired as? [Any] {
            let remoteArray = remote as? [Any] ?? []
            if desiredArray.count != remoteArray.count {
                changes.append(FieldChange(
                    path: path,
                    oldValue: "\(remoteArray.count) item(s)",
                    newValue: "\(desiredArray.count) item(s)"
                ))
                return
            }
            for (index, element) in desiredArray.enumerated() {
                compare(desired: element, remote: remoteArray[index], path: "\(path)[\(index)]", into: &changes)
            }
            return
        }
        if !valuesEqual(desired, remote) {
            changes.append(FieldChange(path: path, oldValue: display(remote), newValue: display(desired)))
        }
    }

    private static func valuesEqual(_ a: Any, _ b: Any) -> Bool {
        if canonical(a) == canonical(b) { return true }
        // Graph may echo dates with fractional seconds or an offset; equal
        // instants must not read as changes (e.g. expirationDateTime).
        if let dateA = isoDate(a), let dateB = isoDate(b) {
            return dateA == dateB
        }
        return false
    }

    private static func isoDate(_ value: Any) -> Date? {
        guard let text = value as? String, text.count >= 16, text.contains("T") else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Canonical scalar representation; distinguishes booleans from numbers.
    static func canonical(_ value: Any) -> String {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if value is NSNull { return "null" }
        if let string = value as? String { return string }
        return String(describing: value)
    }

    /// Human-readable value for diff rows; long blobs are summarised.
    static func display(_ value: Any) -> String {
        let text = canonical(value)
        if text.count > 120 {
            return "(\(text.count) characters)"
        }
        return text
    }
}
