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
