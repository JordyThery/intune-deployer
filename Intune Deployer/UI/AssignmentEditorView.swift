import SwiftUI

/// Edits the assignment intent of one or more items for the active tenant
/// profile. With several items, differing values show as "Mixed" and any
/// change applies to every item.
struct AssignmentEditorView: View {
    @Environment(TenantStore.self) private var tenantStore
    let items: [InferredItem]
    let profile: TenantProfile

    /// What the mode picker can show. An item without a stored intent follows
    /// its type default from the tenant profile.
    private enum ModeChoice: Hashable {
        case typeDefault
        case mode(AssignmentIntent.Mode)
        case mixed
    }

    private var storedIntents: [AssignmentIntent?] {
        items.map { profile.assignments[$0.id] }
    }

    private var modeChoice: ModeChoice {
        let stored = storedIntents
        if stored.allSatisfy({ $0 == nil }) { return .typeDefault }
        let modes = Set(stored.map { $0?.mode })
        return modes.count == 1 ? .mode(stored[0]?.mode ?? .none) : .mixed
    }

    /// The mode the fields below the picker belong to (nil = no fields).
    private var editedMode: AssignmentIntent.Mode? {
        if case .mode(let mode) = modeChoice { return mode }
        return nil
    }

    var body: some View {
        GroupBox(items.count == 1
            ? "Assignment — \(profile.displayName)"
            : "Assignment for \(items.count) Items — \(profile.displayName)") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Assign to", selection: modeBinding) {
                    if modeChoice == .mixed {
                        Text("Mixed").tag(ModeChoice.mixed)
                        Divider()
                    }
                    Text("Type default").tag(ModeChoice.typeDefault)
                    Divider()
                    ForEach(AssignmentIntent.Mode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(ModeChoice.mode(mode))
                    }
                }
                .pickerStyle(.menu)

                if modeChoice == .typeDefault {
                    Text(typeDefaultHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if modeChoice == .mixed {
                    Text("The selected items have different assignments. Choosing a value applies it to all of them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if editedMode == .group {
                    TextField("Group name", text: binding(\.groupName),
                              prompt: Text(mixedPrompt(\.groupName, fallback: "Static Entra security group")))
                    if !profile.allowGroupCreation {
                        Text("Missing groups are a plan error unless group creation is enabled in the tenant profile.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Shell scripts and custom attributes cannot carry assignment
                // filters in Intune — hide the fields for them.
                if let editedMode, editedMode != .none,
                   items.contains(where: { $0.type.supportsAssignmentFilters }) {
                    HStack {
                        TextField("Filter name", text: binding(\.filterName),
                                  prompt: Text(mixedPrompt(\.filterName, fallback: "Assignment filter (optional)")))
                        Picker("Filter mode", selection: binding(\.filterMode)) {
                            Text("Include").tag(AssignmentIntent.FilterMode.include)
                            Text("Exclude").tag(AssignmentIntent.FilterMode.exclude)
                        }
                        .labelsHidden()
                        .fixedSize()
                        Menu {
                            Button("Use built-in template: \(BuiltInFilterTemplate.name)") {
                                update { $0.filterName = BuiltInFilterTemplate.name }
                            }
                        } label: {
                            Image(systemName: "sparkles")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("The built-in ADE filter is created at apply time from: \(BuiltInFilterTemplate.rule)")
                        .accessibilityLabel("Filter templates")
                    }
                    if items.contains(where: { !$0.type.supportsAssignmentFilters }) {
                        Text("Intune does not support filters on shell scripts or custom attributes — those items are assigned without the filter.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Type default hint

    private var typeDefaultHint: String {
        let types = Set(items.map(\.type))
        if types == [.assignmentFilter] {
            return "Assignment filters cannot be assigned."
        }
        if types.count == 1, let type = types.first {
            if let intent = profile.defaultAssignments[type] {
                return "Default for \(type.displayName): \(intent.summary). Set in the tenant profile."
            }
            return "No default for \(type.displayName) — left unchanged. Defaults are set in the tenant profile."
        }
        return "Each item follows the default for its type, set in the tenant profile."
    }

    // MARK: - Bindings

    private var modeBinding: Binding<ModeChoice> {
        Binding(
            get: { modeChoice },
            set: { choice in
                switch choice {
                case .typeDefault:
                    mutateProfile { current in
                        for item in items { current.assignments[item.id] = nil }
                    }
                case .mode(let mode):
                    // Seed new entries from the item's effective intent so
                    // switching away from a default keeps its field values.
                    mutateProfile { current in
                        for item in items {
                            var intent = current.assignments[item.id]
                                ?? current.effectiveAssignment(for: item.id, type: item.type)
                            intent.mode = mode
                            current.assignments[item.id] = intent
                        }
                    }
                case .mixed:
                    break
                }
            }
        )
    }

    /// Common value across all items; empty when they differ (the text field
    /// then shows a "Mixed" prompt).
    private func commonValue<T: Hashable>(_ keyPath: KeyPath<AssignmentIntent, T>) -> T? {
        let values = Set(items.map {
            (profile.assignments[$0.id] ?? AssignmentIntent())[keyPath: keyPath]
        })
        return values.count == 1 ? values.first : nil
    }

    private func mixedPrompt(_ keyPath: KeyPath<AssignmentIntent, String>, fallback: String) -> String {
        items.count > 1 && commonValue(keyPath) == nil ? "Mixed — type to replace" : fallback
    }

    private func binding<T: Hashable>(_ keyPath: WritableKeyPath<AssignmentIntent, T>) -> Binding<T> {
        Binding(
            get: { commonValue(keyPath) ?? AssignmentIntent()[keyPath: keyPath] },
            set: { newValue in update { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Applies a change to every item's stored intent.
    private func update(_ change: (inout AssignmentIntent) -> Void) {
        mutateProfile { current in
            for item in items {
                var intent = current.assignments[item.id] ?? AssignmentIntent()
                change(&intent)
                current.assignments[item.id] = intent
            }
        }
    }

    private func mutateProfile(_ change: (inout TenantProfile) -> Void) {
        // Re-read the profile so concurrent edits are never overwritten.
        guard var current = tenantStore.profiles.first(where: { $0.id == profile.id }) else { return }
        change(&current)
        tenantStore.update(current)
    }
}
