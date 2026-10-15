import SwiftUI

/// Sheet for creating or editing a tenant profile, including its variables.
struct TenantProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TenantStore.self) private var tenantStore
    @Environment(AuthManager.self) private var auth

    @State private var profile: TenantProfile
    @State private var newVariableName = ""
    private let isNew: Bool

    init(profile: TenantProfile?) {
        _profile = State(initialValue: profile ?? TenantProfile())
        isNew = profile == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Display name", text: $profile.displayName, prompt: Text("Contoso"))
                    TextField("Tenant ID", text: $profile.tenantID, prompt: Text("GUID or verified domain"))
                        .font(.body.monospaced())
                    TextField("Client ID", text: $profile.clientID, prompt: Text("00000000-0000-0000-0000-000000000000"))
                        .font(.body.monospaced())
                    TextField("Naming prefix", text: $profile.namingPrefix, prompt: Text("[CONTOSO]"))
                    Toggle("Allow creating missing Entra groups on Apply", isOn: $profile.allowGroupCreation)
                        .help("Requests Group.ReadWrite.All; without this, a missing assignment group is a plan error")
                } header: {
                    Text("Tenant")
                } footer: {
                    Text("""
                    Tenant ID and Client ID come from the app registration an admin creates \
                    in the target Entra tenant (public client, no secret, “iOS/macOS” \
                    platform with this app's bundle ID — see Settings for the exact values). \
                    Tenant ID: Entra admin center → Overview. Client ID: the registration's \
                    Application (client) ID.
                    """)
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
                if !isNew {
                    Button("Delete Profile", role: .destructive) {
                        let deleted = profile
                        tenantStore.remove(id: deleted.id)
                        Task { await auth.signOut(profile: deleted) }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(isNew ? "Add" : "Save") {
                    if isNew {
                        tenantStore.add(profile)
                    } else {
                        tenantStore.update(profile)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.displayName.trimmingCharacters(in: .whitespaces).isEmpty
                    || profile.tenantID.trimmingCharacters(in: .whitespaces).isEmpty
                    || !profile.hasValidClientID)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
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
        let intent = profile.defaultAssignments[type]
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: defaultModeBinding(for: type)) {
                Text("No default — leave unchanged").tag(AssignmentIntent.Mode?.none)
                Divider()
                ForEach(AssignmentIntent.Mode.allCases.filter { $0 != .none }, id: \.self) { mode in
                    Text(mode.displayName).tag(AssignmentIntent.Mode?.some(mode))
                }
            } label: {
                Label(type.displayName, systemImage: type.symbolName)
            }
            if let intent {
                if intent.mode == .group {
                    TextField("Group name", text: defaultBinding(for: type, \.groupName),
                              prompt: Text("Static Entra security group"))
                }
                // Intune has no assignment-filter support for scripts and
                // custom attributes.
                if type.supportsAssignmentFilters {
                    HStack {
                        TextField("Filter name", text: defaultBinding(for: type, \.filterName),
                                  prompt: Text("Assignment filter (optional)"))
                        Picker("Filter mode", selection: defaultBinding(for: type, \.filterMode)) {
                            Text("Include").tag(AssignmentIntent.FilterMode.include)
                            Text("Exclude").tag(AssignmentIntent.FilterMode.exclude)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
    }

    /// nil = no default stored for the type.
    private func defaultModeBinding(for type: ItemType) -> Binding<AssignmentIntent.Mode?> {
        Binding(
            get: { profile.defaultAssignments[type]?.mode },
            set: { newMode in
                if let newMode {
                    var intent = profile.defaultAssignments[type] ?? AssignmentIntent()
                    intent.mode = newMode
                    profile.defaultAssignments[type] = intent
                } else {
                    profile.defaultAssignments[type] = nil
                }
            }
        )
    }

    private func defaultBinding<T>(for type: ItemType, _ keyPath: WritableKeyPath<AssignmentIntent, T>) -> Binding<T> {
        Binding(
            get: { (profile.defaultAssignments[type] ?? AssignmentIntent())[keyPath: keyPath] },
            set: { newValue in
                var intent = profile.defaultAssignments[type] ?? AssignmentIntent()
                intent[keyPath: keyPath] = newValue
                profile.defaultAssignments[type] = intent
            }
        )
    }
}
