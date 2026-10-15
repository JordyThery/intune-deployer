import SwiftUI

/// Edits the assignment intent of one item for the active tenant profile.
struct AssignmentEditorView: View {
    @Environment(TenantStore.self) private var tenantStore
    let item: InferredItem
    let profile: TenantProfile

    private var intent: AssignmentIntent {
        profile.assignments[item.id] ?? AssignmentIntent()
    }

    var body: some View {
        GroupBox("Assignment — \(profile.displayName)") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Assign to", selection: binding(\.mode)) {
                    ForEach(AssignmentIntent.Mode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                if intent.mode == .group {
                    TextField("Group name", text: binding(\.groupName), prompt: Text("Static Entra security group"))
                    if !profile.allowGroupCreation {
                        Text("Missing groups are a plan error unless group creation is enabled in the tenant profile.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if intent.mode != .none {
                    HStack {
                        TextField("Filter name", text: binding(\.filterName), prompt: Text("Assignment filter (optional)"))
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func update(_ change: (inout AssignmentIntent) -> Void) {
        // Re-read the profile so concurrent edits are never overwritten.
        guard var current = tenantStore.profiles.first(where: { $0.id == profile.id }) else { return }
        var intent = current.assignments[item.id] ?? AssignmentIntent()
        change(&intent)
        current.assignments[item.id] = intent
        tenantStore.update(current)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AssignmentIntent, T>) -> Binding<T> {
        Binding(
            get: { intent[keyPath: keyPath] },
            set: { newValue in update { $0[keyPath: keyPath] = newValue } }
        )
    }
}
