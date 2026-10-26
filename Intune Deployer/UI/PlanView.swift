import JTKit
import SwiftUI
import UniformTypeIdentifiers

/// The dry-run sheet: grouped actions with expandable diffs, warnings and
/// errors, orphan opt-in deletion, and the explicit Apply step.
struct PlanView: View {
    @Environment(TenantSession.self) private var session
    @Environment(SourceStore.self) private var sourceStore
    @Environment(\.dismiss) private var dismiss

    let profile: TenantProfile
    let items: [InferredItem]

    @State private var orphansToDelete: Set<String> = []
    @State private var confirmingApply = false
    @State private var typingDeletionCount = false
    @State private var reportDocument: TextExportDocument?
    @State private var reportType: UTType = .plainText
    @State private var reportFilename = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 680, height: 560)
        .fileExporter(
            isPresented: Binding(
                get: { reportDocument != nil },
                set: { if !$0 { reportDocument = nil } }
            ),
            document: reportDocument,
            contentType: reportType,
            defaultFilename: reportFilename
        ) { _ in
            reportDocument = nil
        }
        .task {
            if session.currentPlan == nil && !session.isPlanning {
                await session.plan(profile: profile, items: items, sourceStore: sourceStore)
            }
        }
    }

    private var header: some View {
        HStack {
            Label("Plan — \(profile.displayName)", systemImage: "list.bullet.clipboard")
                .font(.title3.bold())
            Spacer()
            if session.isPlanning || session.isApplying {
                ProgressView().controlSize(.small)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if let results = session.applyResults {
            ApplyResultsList(results: results, isRunning: session.isApplying)
        } else if session.isPlanning {
            Spacer()
            ProgressView("Reading tenant state and computing changes…")
                .frame(maxWidth: .infinity)
            Spacer()
        } else if let error = session.planError {
            ContentUnavailableView("Plan Failed", systemImage: "xmark.octagon", description: Text(error))
        } else if let plan = session.currentPlan {
            planList(plan)
        } else {
            ContentUnavailableView("No Plan", systemImage: "list.bullet.clipboard", description: Text("Planning has not started."))
        }
    }

    private func planList(_ plan: Plan) -> some View {
        List {
            if !plan.issues.isEmpty {
                Section("Problems") {
                    ForEach(plan.issues) { issue in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                if let name = issue.itemName {
                                    Text(name).font(.callout.bold())
                                }
                                Text(issue.message).font(.callout)
                            }
                        } icon: {
                            Image(systemName: issue.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.severity == .error ? .red : .yellow)
                        }
                    }
                }
            }

            if !plan.groupsToCreate.isEmpty || !plan.filtersToCreate.isEmpty {
                Section("Prerequisites to create") {
                    ForEach(plan.groupsToCreate) { group in
                        Label("Group “\(group.name)”", systemImage: "person.3")
                    }
                    ForEach(plan.filtersToCreate) { filter in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Filter “\(filter.name)”")
                                Text(filter.rule).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: TenantCollection.assignmentFilters.symbolName)
                        }
                    }
                }
            }

            actionSection("Create", plan: plan) { if case .create = $0.kind { true } else { false } }
            actionSection("Update", plan: plan) { if case .update = $0.kind { true } else { false } }
            actionSection("Unchanged", plan: plan) { $0.kind == .unchanged }

            if !plan.orphans.isEmpty {
                Section {
                    ForEach(plan.orphans) { orphan in
                        Toggle(isOn: Binding(
                            get: { orphansToDelete.contains(orphan.objectID) },
                            set: { on in
                                if on { orphansToDelete.insert(orphan.objectID) } else { orphansToDelete.remove(orphan.objectID) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(orphan.displayName)
                                Text("\(orphan.collection.displayName) · \(ItemIdentity.tag(forShortID: orphan.shortID))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Orphaned (tagged but no longer selected)")
                } footer: {
                    Text("Orphans are deleted only when ticked. Objects without this app's tag are never touched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func actionSection(_ title: String, plan: Plan, filter: (PlanItemAction) -> Bool) -> some View {
        let actions = plan.actions.filter(filter)
        return Group {
            if !actions.isEmpty {
                Section("\(title) (\(actions.count))") {
                    ForEach(actions) { action in
                        PlanActionRow(action: action, definitions: plan.settingDefinitions)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let plan = session.currentPlan, session.applyResults == nil {
                Text("\(plan.createCount) create · \(plan.updateCount) update · \(plan.unchangedCount) unchanged · \(plan.orphans.count) orphaned")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let results = session.applyResults, !session.isApplying {
                let failures = results.count(where: \.isFailure)
                Text(failures == 0
                    ? "Applied \(results.count) step\(results.count == 1 ? "" : "s") successfully"
                    : "\(failures) of \(results.count) steps failed")
                    .font(.callout)
                    .foregroundStyle(failures == 0 ? Color.secondary : .red)
            }
            Spacer()
            if session.applyResults != nil, !session.isApplying {
                Menu {
                    Button("Markdown…") { prepareReport(markdown: true) }
                    Button("HTML…") { prepareReport(markdown: false) }
                } label: {
                    Label("Export As-Built Report", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
                .help("Save a report of everything that was deployed")
            }
            Button("Close") { dismiss() }
            if session.applyResults == nil {
                Button("Apply…") {
                    // from two deletions the number is typed, which a dialog can't hold
                    if ApplyConfirmation.typedCount(deletions: orphansToDelete.count) != nil {
                        typingDeletionCount = true
                    } else {
                        confirmingApply = true
                    }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ApplyConfirmation.canApply(session.currentPlan, deletions: orphansToDelete.count,
                                                          isPlanning: session.isPlanning, isApplying: session.isApplying))
                    .help(session.currentPlan?.hasErrors == true ? "Fix the listed errors first"
                        : planHasWork ? "" : "Everything is already up to date")
            }
        }
        .padding()
        .confirmationDialog(
            "Apply \(applySummary) to “\(profile.displayName)”?",
            isPresented: $confirmingApply,
            titleVisibility: .visible
        ) {
            Button("Apply", role: .destructive) { startApply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changes are written to the tenant through Microsoft Graph and are not undone automatically.")
        }
        .sheet(isPresented: $typingDeletionCount) {
            ApplyDeletionsSheet(
                title: "Apply \(applySummary) to “\(profile.displayName)”?",
                deletions: orphansToDelete.count,
                tenant: profile.displayName,
                apply: startApply
            )
        }
    }

    private func startApply() {
        guard let plan = session.currentPlan else { return }
        let orphanIDs = orphansToDelete
        Task {
            await session.apply(
                profile: profile,
                plan: plan,
                deleteOrphanIDs: orphanIDs,
                items: items,
                sourceStore: sourceStore
            )
        }
    }

    private var planHasWork: Bool {
        ApplyConfirmation.hasWork(session.currentPlan, deletions: orphansToDelete.count)
    }

    private var applySummary: String {
        ApplyConfirmation.summary(session.currentPlan, deletions: orphansToDelete.count)
    }

    // MARK: - As-built report export

    private func prepareReport(markdown: Bool) {
        guard let plan = session.currentPlan, let results = session.applyResults else { return }
        let input = AsBuiltReport.Input(
            profileName: profile.displayName,
            tenantID: profile.tenantID,
            namingPrefix: profile.namingPrefix,
            plan: plan,
            results: results,
            date: .now
        )
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        reportType = markdown ? .plainText : .html
        reportFilename = "AsBuilt-\(profile.displayName)-\(stamp).\(markdown ? "md" : "html")"
        reportDocument = TextExportDocument(text: markdown ? AsBuiltReport.markdown(input) : AsBuiltReport.html(input))
    }
}

private struct PlanActionRow: View {
    let action: PlanItemAction
    /// Names for setting definitions (missing entries fall back to the ID).
    let definitions: [String: SettingDefinitionInfo]
    @State private var expanded = false
    @State private var showsRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: action.collection.symbolName)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                Text(action.displayName)
                Spacer()
                if let assignments = action.assignments {
                    Text(assignmentLabel(assignments))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .help(assignments.map(AsBuiltReport.targetDescription).joined(separator: "\n"))
                }
                Text(action.collection.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(action.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .update(let changes) = action.kind, !changes.isEmpty || !action.settingChanges.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    // Settings Catalog updates read by setting name; the raw
                    // field-level view stays one click away.
                    if !action.settingChanges.isEmpty {
                        Picker("Change view", selection: $showsRaw) {
                            Text("Readable").tag(false)
                            Text("Raw").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if !action.settingChanges.isEmpty && !showsRaw {
                        ForEach(action.settingChanges) { change in
                            settingChangeRow(change)
                        }
                        // Non-setting fields (name, description, …) changed too.
                        let otherFields = changes.filter { !$0.path.hasPrefix("settings") }
                        ForEach(otherFields) { change in
                            rawChangeRow(change)
                        }
                    } else {
                        ForEach(changes) { change in
                            rawChangeRow(change)
                        }
                    }
                } label: {
                    Text(changeSummary(changes))
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func changeSummary(_ changes: [FieldChange]) -> String {
        if !action.settingChanges.isEmpty {
            let count = action.settingChanges.count
            let others = changes.count { !$0.path.hasPrefix("settings") }
            let summary = "\(count) setting change\(count == 1 ? "" : "s")"
            return others == 0 ? summary : summary + ", \(others) other field change\(others == 1 ? "" : "s")"
        }
        return "\(changes.count) field change\(changes.count == 1 ? "" : "s")"
    }

    private func rawChangeRow(_ change: FieldChange) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(change.path).font(.caption.monospaced().bold())
            Text("− \(change.oldValue)").font(.caption.monospaced()).foregroundStyle(.red)
            Text("+ \(change.newValue)").font(.caption.monospaced()).foregroundStyle(.green)
        }
        .padding(.vertical, 1)
        .textSelection(.enabled)
    }

    /// The setting path (parent › setting) above "Old → New"; choice values
    /// show their option names.
    private func settingChangeRow(_ change: SettingChange) -> some View {
        let names = (change.parentDefinitionIDs + [change.definitionID]).map(settingName)
        let options = definitions[change.definitionID]?.options ?? [:]
        func value(_ raw: String?) -> String {
            guard let raw else { return "—" }
            return options[raw] ?? raw
        }
        let detail: String = switch change.kind {
        case .changed: "\(value(change.oldValue)) → \(value(change.newValue))"
        case .added: "Added: \(value(change.newValue))"
        case .removed: "Removed (was \(value(change.oldValue)))"
        }
        return VStack(alignment: .leading, spacing: 1) {
            Text(names.joined(separator: " › "))
                .font(.caption.bold())
            Text(detail)
                .font(.caption)
                .foregroundStyle(change.kind == .removed ? .red : change.kind == .added ? .green : .primary)
        }
        .padding(.vertical, 1)
        .help(change.definitionID)
        .textSelection(.enabled)
    }

    private func settingName(_ definitionID: String) -> String {
        definitions[definitionID]?.displayName ?? definitionID
    }

    private func assignmentLabel(_ assignments: [ResolvedAssignment]) -> String {
        guard assignments.count == 1, let assignment = assignments.first else {
            return assignments.isEmpty ? "No targets" : "\(assignments.count) targets"
        }
        let base: String
        switch assignment.target {
        case .allDevices: base = "All devices"
        case .allUsers: base = "All users"
        case .group(_, let name): base = name
        }
        if assignment.isExclusion {
            return "Excluding \(base)"
        }
        var label = assignment.filter == nil ? base : "\(base) + filter"
        if assignment.appIntent == .available {
            label += ", available"
        }
        return label
    }
}

/// Per-step apply results (also used by Remove Baseline).
struct ApplyResultsList: View {
    let results: [ApplyResult]
    let isRunning: Bool

    var body: some View {
        List(results) { result in
            HStack(alignment: .top) {
                switch result.outcome {
                case .success:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failure:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .skipped:
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                    if case .failure(let message) = result.outcome {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    if case .skipped(let reason) = result.outcome {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if isRunning {
                ProgressView()
                    .padding()
            }
        }
    }
}
