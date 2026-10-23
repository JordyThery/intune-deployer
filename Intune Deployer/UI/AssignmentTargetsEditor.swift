import SwiftUI

/// Edits a list of assignment targets: one row per include or exclude
/// target. Used by the item assignment editor and the tenant profile's
/// per-type defaults.
struct AssignmentTargetsEditor: View {
    @Binding var targets: [AssignmentTarget]
    /// Whether any edited item supports assignment filters.
    let supportsFilters: Bool
    /// Whether any edited item is an app (shows the install intent).
    let showsAppIntent: Bool
    /// Applies the built-in ADE template filter to one target (the caller
    /// knows each item's platform).
    var applyTemplate: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(targets.indices, id: \.self) { index in
                row(index)
                if index < targets.count - 1 {
                    Divider()
                }
            }
            Button {
                targets.append(AssignmentTarget())
            } label: {
                Label("Add Target", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func row(_ index: Int) -> some View {
        let target = targets[index]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Include or exclude", selection: kindBinding(index)) {
                    ForEach(AssignmentTarget.Kind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Exclusions can only target groups")

                Picker("Target", selection: binding(index, \.scope)) {
                    ForEach(AssignmentTarget.Scope.allCases, id: \.self) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(target.kind == .exclude)
                .help(target.kind == .exclude ? "Exclusions can only target groups" : "")

                if target.scope == .group {
                    TextField("Group name", text: binding(index, \.groupName), prompt: Text("Static Entra security group"))
                }
                Spacer(minLength: 0)
                Button {
                    targets.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(targets.count == 1)
                .help(targets.count == 1 ? "At least one target is required" : "Remove this target")
                .accessibilityLabel("Remove target")
            }

            // Exclusions carry no filter and no install intent.
            if target.kind == .include {
                if supportsFilters {
                    HStack {
                        TextField("Filter name", text: binding(index, \.filterName), prompt: Text("Assignment filter (optional)"))
                        Picker("Filter mode", selection: binding(index, \.filterMode)) {
                            Text("Include filter").tag(AssignmentIntent.FilterMode.include)
                            Text("Exclude filter").tag(AssignmentIntent.FilterMode.exclude)
                        }
                        .labelsHidden()
                        .fixedSize()
                        if let applyTemplate {
                            Menu {
                                Button("Use Built-in ADE Filter Template") { applyTemplate(index) }
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
                if showsAppIntent {
                    Picker("Install intent", selection: binding(index, \.appIntent)) {
                        ForEach(AssignmentIntent.AppIntent.allCases, id: \.self) { intent in
                            Text(intent.displayName).tag(intent)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    /// Switching to Exclude forces a group target and clears the filter and
    /// install intent (Intune excludes groups only, without options).
    private func kindBinding(_ index: Int) -> Binding<AssignmentTarget.Kind> {
        Binding(
            get: { targets.indices.contains(index) ? targets[index].kind : .include },
            set: { kind in
                guard targets.indices.contains(index) else { return }
                targets[index].kind = kind
                if kind == .exclude {
                    targets[index].scope = .group
                    targets[index].filterName = ""
                    targets[index].filterMode = .include
                    targets[index].appIntent = .required
                }
            }
        )
    }

    private func binding<T>(_ index: Int, _ keyPath: WritableKeyPath<AssignmentTarget, T>) -> Binding<T> {
        Binding(
            get: { targets.indices.contains(index) ? targets[index][keyPath: keyPath] : AssignmentTarget()[keyPath: keyPath] },
            set: { newValue in
                guard targets.indices.contains(index) else { return }
                targets[index][keyPath: keyPath] = newValue
            }
        )
    }
}
