import SwiftUI

/// Edits the assignment of one or more items for the active tenant profile:
/// the type default, "leave unchanged", or a list of include/exclude targets.
/// With several items, differing assignments show as "Mixed" and any change
/// applies to every item.
struct AssignmentEditorView: View {
    @Environment(TenantStore.self) private var tenantStore
    let items: [InferredItem]
    let profile: TenantProfile

    private enum Choice: Hashable {
        case typeDefault
        case leaveUnchanged
        case targets
        case mixed
    }

    private var storedIntents: [AssignmentIntent?] {
        items.map { profile.assignments[$0.id] }
    }

    /// Items count as sharing an assignment when their targets differ only
    /// in what is adapted per item: the platform of the built-in filter
    /// template, and filters on types without filter support.
    private var choice: Choice {
        let stored = storedIntents
        if stored.allSatisfy({ $0 == nil }) { return .typeDefault }
        let comparable = Set(zip(items, stored).map { item, intent in intent.map { Self.comparable($0, for: item) } })
        guard comparable.count == 1, let shared = stored.first ?? nil else { return .mixed }
        return shared.leavesUnchanged ? .leaveUnchanged : .targets
    }

    private static func comparable(_ intent: AssignmentIntent, for item: InferredItem) -> AssignmentIntent {
        var intent = intent
        for index in intent.targets.indices {
            if !item.type.supportsAssignmentFilters {
                intent.targets[index].filterName = ""
            } else if BuiltInFilterTemplate.platform(forName: intent.targets[index].trimmedFilterName) != nil {
                intent.targets[index].filterName = BuiltInFilterTemplate.name(for: .macOS)
            }
        }
        return intent
    }

    /// The shared targets written to one item: filters are dropped where
    /// unsupported and the built-in template follows the item's platform.
    private static func adapted(_ targets: [AssignmentTarget], for item: InferredItem) -> [AssignmentTarget] {
        targets.map { target in
            var target = target
            if !item.type.supportsAssignmentFilters {
                target.filterName = ""
            } else if BuiltInFilterTemplate.platform(forName: target.trimmedFilterName) != nil {
                target.filterName = BuiltInFilterTemplate.name(for: item.platform)
            }
            return target
        }
    }

    var body: some View {
        GroupBox(items.count == 1
            ? "Assignment — \(profile.displayName)"
            : "Assignment for \(items.count) Items — \(profile.displayName)") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Assign to", selection: choiceBinding) {
                    if choice == .mixed {
                        Text("Mixed").tag(Choice.mixed)
                        Divider()
                    }
                    Text("Type default").tag(Choice.typeDefault)
                    Text("Leave unchanged").tag(Choice.leaveUnchanged)
                    Text("Specific targets").tag(Choice.targets)
                }
                .pickerStyle(.menu)

                switch choice {
                case .typeDefault:
                    caption(typeDefaultHint)
                case .leaveUnchanged:
                    caption("The item's existing assignments in Intune are not changed.")
                case .mixed:
                    caption("The selected items have different assignments. Choosing an option applies it to all of them.")
                case .targets:
                    AssignmentTargetsEditor(
                        targets: targetsBinding,
                        supportsFilters: items.contains { $0.type.supportsAssignmentFilters },
                        showsAppIntent: items.contains { $0.type == .app },
                        applyTemplate: applyTemplateFilter
                    )
                    notes
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var notes: some View {
        let targets = sharedTargets
        if targets.contains(where: { $0.scope == .group }), !profile.allowGroupCreation {
            caption("Missing groups are a plan error unless group creation is enabled in the tenant profile.")
        }
        if items.contains(where: { !$0.type.supportsAssignmentFilters }),
           items.contains(where: { $0.type.supportsAssignmentFilters }) {
            caption("Intune does not support filters on shell scripts or custom attributes — those items are assigned without filters.")
        }
        if items.contains(where: { $0.type == .app }) {
            if items.contains(where: { $0.type != .app }) {
                caption("The install intent applies to the app items only.")
            } else if targets.contains(where: { $0.kind == .include && $0.appIntent == .available }) {
                caption("Available apps are offered in Company Portal and need a user assignment (All users or a user group).")
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Type default hint

    private var typeDefaultHint: String {
        let types = Set(items.map(\.type))
        if types.count == 1, let type = types.first {
            if let intent = profile.defaultAssignments[type] {
                return "Default for \(type.displayName): \(intent.summary). Set in the tenant profile."
            }
            return "No default for \(type.displayName) — left unchanged. Defaults are set in the tenant profile."
        }
        return "Each item follows the default for its type, set in the tenant profile."
    }

    // MARK: - Bindings

    /// The shared target list while all items have the same one, read from
    /// an item that supports filters so they show.
    private var sharedTargets: [AssignmentTarget] {
        let source = items.first { $0.type.supportsAssignmentFilters } ?? items.first
        return source.flatMap { profile.assignments[$0.id]?.targets } ?? []
    }

    private var choiceBinding: Binding<Choice> {
        Binding(
            get: { choice },
            set: { newChoice in
                switch newChoice {
                case .typeDefault:
                    mutateProfile { current in
                        for item in items { current.assignments[item.id] = nil }
                    }
                case .leaveUnchanged:
                    mutateProfile { current in
                        for item in items { current.assignments[item.id] = AssignmentIntent() }
                    }
                case .targets:
                    // Start from the items' effective assignment when they
                    // share one, so switching away from a default keeps it.
                    mutateProfile { current in
                        let effective = Set(items.map { current.effectiveAssignment(for: $0.id, type: $0.type) })
                        let seed = effective.count == 1 && !(effective.first?.leavesUnchanged ?? true)
                            ? effective.first!.targets
                            : [AssignmentTarget()]
                        for item in items {
                            current.assignments[item.id] = AssignmentIntent(targets: Self.adapted(seed, for: item))
                        }
                    }
                case .mixed:
                    break
                }
            }
        )
    }

    private var targetsBinding: Binding<[AssignmentTarget]> {
        Binding(
            get: { sharedTargets },
            set: { newTargets in
                mutateProfile { current in
                    for item in items {
                        current.assignments[item.id] = AssignmentIntent(targets: Self.adapted(newTargets, for: item))
                    }
                }
            }
        )
    }

    /// Each item gets the ADE template for its own platform (see `adapted`),
    /// so a mixed-platform selection stays valid.
    private func applyTemplateFilter(at index: Int) {
        var targets = sharedTargets
        guard targets.indices.contains(index) else { return }
        targets[index].filterName = BuiltInFilterTemplate.name(for: .macOS)
        targetsBinding.wrappedValue = targets
    }

    private func mutateProfile(_ change: (inout TenantProfile) -> Void) {
        // Re-read the profile so concurrent edits are never overwritten.
        guard var current = tenantStore.profile(id: profile.id) else { return }
        change(&current)
        tenantStore.update(current)
    }
}
