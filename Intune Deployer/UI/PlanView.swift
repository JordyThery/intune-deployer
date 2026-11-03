import JTKit
import SwiftUI
import UniformTypeIdentifiers

/// The dry-run sheet: grouped actions with expandable diffs, warnings and
/// errors, orphan opt-in deletion, and the explicit Apply step.
struct PlanView: View {
    @Environment(TenantSession.self) private var session
    @Environment(SourceStore.self) private var sourceStore
    @Environment(TenantStore.self) private var tenantStore
    @Environment(\.dismiss) private var dismiss

    let profile: TenantProfile
    let items: [InferredItem]

    @State private var orphansToDelete: Set<String> = []
    /// Apply… pressed: the dialog, or from two deletions the typed count.
    @State private var confirmingApply: ApplyRequest?
    @State private var typingDeletionCount: ApplyRequest?
    @State private var reportDocument: TextExportDocument?
    @State private var reportType: UTType = .plainText
    @State private var reportFilename = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            RequestWaitsBar(waits: session.waits)
            Divider()
            footer
        }
        .frame(minWidth: 680, idealWidth: 680, minHeight: 560, idealHeight: 560)
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
                await session.plan(profile: profile, items: items, sourceStore: sourceStore,
                                   isOnlyProfileForTenant: tenantStore.isOnlyProfile(forTenantOf: profile))
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
                    .accessibilityLabel(session.isApplying ? "Applying" : "Planning")
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
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            if !plan.groupsToCreate.isEmpty || !plan.filtersToCreate.isEmpty {
                Section("Prerequisites to Create") {
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
                    Text("Orphans are deleted only when ticked. Other profiles’ objects and untagged objects are never touched.")
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
                // the color is on the symbol; the text stays readable
                Label {
                    Text(ApplyResult.summary(results))
                        .foregroundStyle(failures == 0 ? Color.secondary : .primary)
                } icon: {
                    if failures > 0 {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                .font(.callout)
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
                .keyboardShortcut(.cancelAction)
            if session.applyResults == nil {
                Button("Apply…") {
                    let request = ApplyRequest(deleteOrphanIDs: orphansToDelete)
                    // from two deletions the number is typed, which a dialog can't hold
                    if request.typedCount != nil {
                        typingDeletionCount = request
                    } else {
                        confirmingApply = request
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
            "Apply \(confirmingApply.map(applySummary) ?? applySummary) to “\(profile.displayName)”?",
            isPresented: Binding(get: { confirmingApply != nil }, set: { if !$0 { confirmingApply = nil } }),
            titleVisibility: .visible,
            presenting: confirmingApply
        ) { request in
            Button("Apply", role: .destructive) { startApply(request) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Changes are written to the tenant through Microsoft Graph and are not undone automatically.")
        }
        .sheet(item: $typingDeletionCount) { request in
            ApplyDeletionsSheet(
                title: "Apply \(applySummary(request)) to “\(profile.displayName)”?",
                deletions: request.deletions,
                tenant: profile.displayName,
                apply: { startApply(request) }
            )
        }
    }

    /// Apply deletes exactly the orphans the confirmation counted.
    private func startApply(_ request: ApplyRequest) {
        guard let plan = session.currentPlan else { return }
        let orphanIDs = request.deleteOrphanIDs
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

    private func applySummary(_ request: ApplyRequest) -> String {
        ApplyConfirmation.summary(session.currentPlan, deletions: request.deletions)
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
        reportFilename = "AsBuilt-\(TenantProfile.fileNameSafe(profile.displayName))-\(stamp).\(markdown ? "md" : "html")"
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
                // the collection's name follows as text
                Image(systemName: action.collection.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(action.displayName)
                Spacer()
                if let assignments = action.assignments {
                    Text(assignmentLabel(assignments))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .help(assignments.map(AsBuiltReport.targetDescription).joined(separator: "\n"))
                        .accessibilityHint(assignments.map(AsBuiltReport.targetDescription).joined(separator: ", "))
                }
                Text(action.collection.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(action.warnings, id: \.self) { warning in
                Label {
                    Text(warning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .accessibilityLabel("Warning")
                }
                .font(.callout)
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
                        .font(.callout)
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
        // − and + carry the meaning; the color is on the symbols only, so
        // the values keep full contrast
        VStack(alignment: .leading, spacing: 1) {
            Text(change.path).font(.callout.monospaced().bold())
            changeLine("minus.circle.fill", .red, "− \(change.oldValue)", spoken: "Old value: \(change.oldValue)")
            changeLine("plus.circle.fill", .green, "+ \(change.newValue)", spoken: "New value: \(change.newValue)")
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
        let symbol: (name: String, color: Color) = switch change.kind {
        case .changed: ("arrow.right.circle.fill", .blue)
        case .added: ("plus.circle.fill", .green)
        case .removed: ("minus.circle.fill", .red)
        }
        return VStack(alignment: .leading, spacing: 1) {
            Text(names.joined(separator: " › "))
                .font(.callout.bold())
            changeLine(symbol.name, symbol.color, detail, spoken: detail)
        }
        .padding(.vertical, 1)
        .help(change.definitionID)
        .textSelection(.enabled)
    }

    /// One line of a change: a colored symbol, then the text in the primary color.
    private func changeLine(_ symbol: String, _ color: Color, _ text: String, spoken: String) -> some View {
        Label {
            Text(text).font(.callout.monospaced())
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
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
                        .accessibilityLabel("Succeeded")
                case .failure:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        .accessibilityLabel("Failed")
                case .skipped:
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        .accessibilityLabel("Skipped")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                    if case .failure(let message) = result.outcome {
                        Text(message).font(.callout)
                    }
                    if case .skipped(let reason) = result.outcome {
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
        .overlay(alignment: .bottom) {
            if isRunning {
                ProgressView()
                    .padding()
                    .accessibilityLabel("Applying")
            }
        }
    }
}
