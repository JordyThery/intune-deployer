import SwiftUI

/// Sheet for a tenant profile's baseline: naming prefix, group creation,
/// default assignments and variables. Its name, tenant ID and client ID are
/// edited in Settings › Connections.
struct BaselineSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TenantStore.self) private var tenantStore

    @State private var profile: TenantProfile
    @State private var newVariableName = ""

    init(profile: TenantProfile) {
        _profile = State(initialValue: profile)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Naming prefix", text: $profile.namingPrefix, prompt: Text("[CONTOSO]"))
                    Toggle("Allow creating missing Entra groups on Apply", isOn: $profile.allowGroupCreation)
                        .help("Requests Group.ReadWrite.All; without this, a missing assignment group is a plan error")
                } header: {
                    Text("Baseline for \(profile.displayName)")
                } footer: {
                    Text("The tenant's name, tenant ID and client ID are in Settings › Connections.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(Self.defaultableTypes, id: \.self) { type in
                        defaultAssignmentRow(for: type)
                    }
                } header: {
                    Text("Default Assignments")
                } footer: {
                    Text("Applied at plan time to selected items that have no assignment of their own. An item's assignment editor can override a default or switch back to it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(profile.variables.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text("{{\(key)}}")
                                .font(.callout.monospaced())
                                .frame(minWidth: 160, alignment: .leading)
                            TextField("Value", text: variableBinding(for: key))
                            Button {
                                profile.variables[key] = nil
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("New variable name", text: $newVariableName, prompt: Text("EnrollmentProfileName"))
                            .font(.callout.monospaced())
                        Button("Add") {
                            let name = newVariableName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty, profile.variables[name] == nil else { return }
                            profile.variables[name] = ""
                            newVariableName = ""
                        }
                        .disabled(newVariableName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Variables")
                } footer: {
                    Text("Values are substituted for {{Token}} placeholders at plan time. Add every token your selected items use — an empty value counts as unresolved and blocks Apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    tenantStore.update(baselineToSave)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
    }

    /// The sheet's baseline on top of the profile as saved now: items ticked
    /// or a sign-in while the sheet was open are kept.
    private var baselineToSave: TenantProfile {
        guard var current = tenantStore.profile(id: profile.id) else { return profile }
        current.namingPrefix = profile.namingPrefix
        current.allowGroupCreation = profile.allowGroupCreation
        current.defaultAssignments = profile.defaultAssignments
        current.variables = profile.variables
        return current
    }

    private func variableBinding(for key: String) -> Binding<String> {
        Binding(
            get: { profile.variables[key] ?? "" },
            set: { profile.variables[key] = $0 }
        )
    }

    // MARK: - Default assignments

    /// Assignment filters cannot themselves be assigned.
    private static let defaultableTypes = ItemType.allCases.filter { $0 != .assignmentFilter }

    @ViewBuilder
    private func defaultAssignmentRow(for type: ItemType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: hasDefaultBinding(for: type)) {
                Label(type.displayName, systemImage: type.symbolName)
            }
            .help("When off, items of this type without their own assignment are left unchanged")
            if profile.defaultAssignments[type] != nil {
                AssignmentTargetsEditor(
                    targets: defaultTargetsBinding(for: type),
                    supportsFilters: type.supportsAssignmentFilters,
                    showsAppIntent: type == .app
                )
                .padding(.leading, 20)
            }
        }
    }

    private func hasDefaultBinding(for type: ItemType) -> Binding<Bool> {
        Binding(
            get: { profile.defaultAssignments[type] != nil },
            set: { enabled in
                profile.defaultAssignments[type] = enabled ? .single(.allDevices) : nil
            }
        )
    }

    private func defaultTargetsBinding(for type: ItemType) -> Binding<[AssignmentTarget]> {
        Binding(
            get: { profile.defaultAssignments[type]?.targets ?? [] },
            set: { profile.defaultAssignments[type] = AssignmentIntent(targets: $0) }
        )
    }
}
