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
                        PlanActionRow(action: action)
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
                Button("Apply…") { confirmingApply = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.currentPlan == nil
                        || session.currentPlan?.hasErrors == true
                        || !planHasWork
                        || session.isPlanning
                        || session.isApplying)
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
            Button("Apply", role: .destructive) {
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
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changes are written to the tenant through Microsoft Graph and are not undone automatically.")
        }
    }

    /// Whether applying would do anything: creates, updates, prerequisites,
    /// assignment refreshes or ticked orphan deletions.
    private var planHasWork: Bool {
        guard let plan = session.currentPlan else { return false }
        return plan.createCount > 0
            || plan.updateCount > 0
            || !orphansToDelete.isEmpty
            || plan.actions.contains { $0.assignment != nil }
    }

    private var applySummary: String {
        guard let plan = session.currentPlan else { return "changes" }
        var parts = [
            "\(plan.createCount) create\(plan.createCount == 1 ? "" : "s")",
            "\(plan.updateCount) update\(plan.updateCount == 1 ? "" : "s")",
        ]
        let assignmentCount = plan.actions.count { $0.assignment != nil }
        if assignmentCount > 0 {
            parts.append("\(assignmentCount) assignment\(assignmentCount == 1 ? "" : "s")")
        }
        if !orphansToDelete.isEmpty {
            parts.append("\(orphansToDelete.count) deletion\(orphansToDelete.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
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
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: action.collection.symbolName)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                Text(action.displayName)
                Spacer()
                if let assignment = action.assignment {
                    Text(assignmentLabel(assignment))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
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
            if case .update(let changes) = action.kind, !changes.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(changes) { change in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(change.path).font(.caption.monospaced().bold())
                            Text("− \(change.oldValue)").font(.caption.monospaced()).foregroundStyle(.red)
                            Text("+ \(change.newValue)").font(.caption.monospaced()).foregroundStyle(.green)
                        }
                        .padding(.vertical, 1)
                    }
                } label: {
                    Text("\(changes.count) field change\(changes.count == 1 ? "" : "s")")
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func assignmentLabel(_ assignment: ResolvedAssignment) -> String {
        let base: String
        switch assignment.target {
        case .allDevices: base = "All devices"
        case .allUsers: base = "All users"
        case .group(_, let name): base = name
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
