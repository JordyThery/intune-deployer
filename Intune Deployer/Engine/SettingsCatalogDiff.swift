import Foundation

/// One changed, added or removed setting in a Settings Catalog policy.
nonisolated struct SettingChange: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable {
        case changed
        case added
        case removed
    }

    /// Unique position of the setting (definition IDs of its parents plus
    /// collection indices); stable across both sides of the comparison.
    let id: String
    let definitionID: String
    /// Definition IDs of the enclosing group settings, outermost first.
    let parentDefinitionIDs: [String]
    let kind: Kind
    /// Raw values (choice option IDs or simple values); nil when absent.
    let oldValue: String?
    let newValue: String?
}

/// Display names for setting definitions and their choice options, fetched
/// from the tenant's settings catalog for the settings a plan changes.
nonisolated struct SettingDefinitionInfo: Sendable, Hashable {
    let displayName: String
    /// Choice option ID → display name.
    let options: [String: String]
}

/// Compares Settings Catalog policies setting by setting, keyed by
/// settingDefinitionId instead of array position, so reordered settings
/// never read as changes and every change names the setting it affects.
nonisolated enum SettingsCatalogDiff {
    private struct Entry {
        let definitionID: String
        let parents: [String]
        let value: String
    }

    /// Setting-level changes between a desired and a remote policy body; nil
    /// when either body has no readable `settings` array or contains
    /// settings the comparison cannot key reliably.
    static func changes(desired: Data, remote: Data) -> [SettingChange]? {
        guard let desiredEntries = entries(in: desired),
              let remoteEntries = entries(in: remote) else { return nil }

        var changes: [SettingChange] = []
        for key in Set(desiredEntries.keys).union(remoteEntries.keys).sorted() {
            let new = desiredEntries[key]
            let old = remoteEntries[key]
            let entry = new ?? old!
            let kind: SettingChange.Kind
            switch (old, new) {
            case (nil, _?): kind = .added
            case (_?, nil): kind = .removed
            case (let old?, let new?) where old.value != new.value: kind = .changed
            default: continue
            }
            changes.append(SettingChange(
                id: key,
                definitionID: entry.definitionID,
                parentDefinitionIDs: entry.parents,
                kind: kind,
                oldValue: old?.value,
                newValue: new?.value
            ))
        }
        return changes
    }

    /// Field names whose positional raw changes the setting comparison
    /// accounts for. A raw change to any other field inside `settings`
    /// (e.g. a template reference) is not visible per setting.
    static let comparedFieldNames: Set<String> = [
        "settings", "settingInstance", "settingDefinitionId", "value", "children",
        "choiceSettingValue", "simpleSettingValue", "groupSettingValue",
        "simpleSettingCollectionValue", "choiceSettingCollectionValue", "groupSettingCollectionValue",
    ]

    /// True when every raw change inside `settings` concerns a field the
    /// setting comparison covers, so the setting-level result is complete.
    static func explains(_ rawChanges: [FieldChange]) -> Bool {
        rawChanges.allSatisfy { change in
            guard change.path.hasPrefix("settings") else { return true }
            let leaf = change.path.split(separator: ".").last.map(String.init) ?? change.path
            let name = leaf.split(separator: "[").first.map(String.init) ?? leaf
            return comparedFieldNames.contains(name)
        }
    }

    /// Every definition ID a change refers to, parents included (for name
    /// resolution).
    static func referencedDefinitionIDs(_ changes: [SettingChange]) -> Set<String> {
        Set(changes.flatMap { $0.parentDefinitionIDs + [$0.definitionID] })
    }

    // MARK: - Flattening

    private static func entries(in body: Data) -> [String: Entry]? {
        guard let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let settings = dict["settings"] as? [Any] else { return nil }
        var result: [String: Entry] = [:]
        var complete = true
        var occurrences: [String: Int] = [:]
        for setting in settings {
            guard let instance = (setting as? [String: Any])?["settingInstance"] as? [String: Any],
                  let id = instance["settingDefinitionId"] as? String else { return nil }
            // Top-level settings are identified by their definition ID; a
            // repeated ID gets an occurrence suffix.
            let count = occurrences[id, default: 0]
            occurrences[id] = count + 1
            let key = count == 0 ? id : "\(id)#\(count + 1)"
            flatten(instance, key: key, parents: [], into: &result, complete: &complete)
        }
        return complete ? result : nil
    }

    /// Records the instance's own value (if it has one) and recurses into
    /// its children. Collections index their elements so both sides line up.
    /// Anything that cannot be keyed (missing IDs, colliding keys) clears
    /// `complete`, and the caller falls back to the raw comparison.
    private static func flatten(
        _ instance: [String: Any],
        key: String,
        parents: [String],
        into result: inout [String: Entry],
        complete: inout Bool
    ) {
        guard let id = instance["settingDefinitionId"] as? String else {
            complete = false
            return
        }
        let childParents = parents + [id]

        func record(_ value: String) {
            if result[key] != nil { complete = false }
            result[key] = Entry(definitionID: id, parents: parents, value: value)
        }
        func recurse(children: Any?, prefix: String) {
            guard let children = children as? [Any] else { return }
            var occurrences: [String: Int] = [:]
            for child in children {
                guard let child = child as? [String: Any],
                      let childID = child["settingDefinitionId"] as? String else {
                    complete = false
                    continue
                }
                let count = occurrences[childID, default: 0]
                occurrences[childID] = count + 1
                let childKey = "\(prefix)/\(childID)" + (count == 0 ? "" : "#\(count + 1)")
                flatten(child, key: childKey, parents: childParents, into: &result, complete: &complete)
            }
        }

        if let choice = instance["choiceSettingValue"] as? [String: Any] {
            record(scalar(choice["value"]))
            recurse(children: choice["children"], prefix: key)
        } else if let simple = instance["simpleSettingValue"] as? [String: Any] {
            record(scalar(simple["value"]))
        } else if let collection = instance["simpleSettingCollectionValue"] as? [Any] {
            let values = collection.compactMap { ($0 as? [String: Any]).map { scalar($0["value"]) } }
            record(values.joined(separator: ", "))
        } else if let collection = instance["choiceSettingCollectionValue"] as? [Any] {
            var values: [String] = []
            for (index, element) in collection.enumerated() {
                guard let element = element as? [String: Any] else { continue }
                values.append(scalar(element["value"]))
                recurse(children: element["children"], prefix: "\(key)[\(index)]")
            }
            record(values.joined(separator: ", "))
        } else if let group = instance["groupSettingValue"] as? [String: Any] {
            recurse(children: group["children"], prefix: key)
        } else if let collection = instance["groupSettingCollectionValue"] as? [Any] {
            // The instance count is a value of its own: an added or removed
            // empty instance has no children to show it.
            record(collection.count == 1 ? "1 instance" : "\(collection.count) instances")
            for (index, element) in collection.enumerated() {
                guard let element = element as? [String: Any] else { continue }
                recurse(children: element["children"], prefix: "\(key)[\(index)]")
            }
        } else {
            // Unknown instance type: compare the whole instance (without
            // server noise) so no change can go unnoticed.
            let normalized = GraphDiff.normalize(instance)
            let data = (try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])) ?? Data()
            record(String(decoding: data, as: UTF8.self))
        }
    }

    private static func scalar(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "(not set)" }
        // Objects and arrays as sorted-key JSON, so key order never differs.
        let structured: Any? = (value as? [String: Any]).map { GraphDiff.normalize($0) } ?? (value as? [Any])
        if let structured, let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return GraphDiff.canonical(value)
    }
}
