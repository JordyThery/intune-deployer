import Foundation

/// The result of one export, shown to the user afterwards.
nonisolated struct ExportSummary: Identifiable, Sendable {
    struct Skipped: Sendable, Hashable {
        let name: String
        let reason: String
    }

    let id = UUID()
    let folder: URL
    /// Relative paths of the files written, e.g. "Scripts/Dock.sh".
    let written: [String]
    let skipped: [Skipped]
}

/// A tenant object picked for export, identified by collection and Graph id.
nonisolated struct ExportSelection: Hashable, Sendable {
    let collection: TenantCollection
    let objectID: String
    /// Display name, for reporting objects that fail to fetch.
    let name: String
}

extension TenantSession {
    /// Fetches the selected objects in full, converts them to baseline files
    /// and writes them into `folder` (a user-picked, security-scoped URL).
    /// Objects that cannot be exported are reported, never fatal.
    func export(_ selection: [ExportSelection], profile: TenantProfile, to folder: URL) async -> ExportSummary {
        isExporting = true
        defer { isExporting = false }

        let client = client(for: profile)
        let (bodies, fetchFailures) = await Self.fetchFullBodies(selection, client: client)
        let outcomes = bodies.map { TenantExporter.export(collection: $0.collection, body: $0.body, namingPrefix: profile.namingPrefix) }

        var skipped = fetchFailures
        let written: [String]
        do {
            let result = try Self.write(outcomes, to: folder)
            written = result.written
            skipped += result.skipped
        } catch {
            written = []
            skipped.append(.init(name: "Export folder", reason: error.localizedDescription))
        }
        return ExportSummary(folder: folder, written: written, skipped: skipped)
    }

    // MARK: - Fetching

    /// Full Graph bodies for the selection. List responses omit script
    /// content and Settings Catalog settings, so each object is fetched
    /// individually; compliance policies come from the expanded list (the
    /// same request the plan uses for scheduled actions).
    nonisolated static func fetchFullBodies(
        _ selection: [ExportSelection],
        client: GraphClient
    ) async -> (bodies: [(collection: TenantCollection, body: Data)], failures: [ExportSummary.Skipped]) {
        var bodies: [(collection: TenantCollection, body: Data)] = []
        var failures: [ExportSummary.Skipped] = []

        let compliance = Set(selection.filter { $0.collection == .compliancePolicies }.map(\.objectID))
        if !compliance.isEmpty {
            do {
                let path = "\(TenantCollection.compliancePolicies.listPath)?$expand=scheduledActionsForRule($expand=scheduledActionConfigurations)"
                for body in try await client.listRaw(path, version: TenantCollection.compliancePolicies.version)
                where objectID(of: body).map(compliance.contains) == true {
                    bodies.append((.compliancePolicies, body))
                }
            } catch {
                failures.append(.init(name: "Compliance policies", reason: error.localizedDescription))
            }
        }

        let individual = selection.filter { $0.collection != .compliancePolicies && $0.collection != .apps }
        await withTaskGroup(of: Result<(TenantCollection, Data), FetchFailure>.self) { group in
            for entry in individual {
                group.addTask {
                    do {
                        return .success((entry.collection, try await fetchOne(entry, client: client)))
                    } catch {
                        return .failure(FetchFailure(name: entry.name, message: error.localizedDescription))
                    }
                }
            }
            for await result in group {
                switch result {
                case .success(let pair): bodies.append((pair.0, pair.1))
                case .failure(let failure): failures.append(.init(name: failure.name, reason: failure.message))
                }
            }
        }
        return (bodies, failures)
    }

    nonisolated private struct FetchFailure: Error {
        let name: String
        let message: String
    }

    nonisolated private static func fetchOne(_ entry: ExportSelection, client: GraphClient) async throws -> Data {
        let path = "\(entry.collection.listPath)/\(entry.objectID)"
        let body = try await client.getRaw(path, version: entry.collection.version)
        guard entry.collection == .settingsCatalog else { return body }
        // GET .../configurationPolicies/{id}/settings is the documented
        // settings read route; the policy body itself has no settings.
        let settings = try await client.listRaw("\(path)/settings", version: .beta)
        guard var dict = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { return body }
        dict["settings"] = settings.compactMap { try? JSONSerialization.jsonObject(with: $0) }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    nonisolated private static func objectID(of body: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["id"] as? String
    }

    // MARK: - Writing

    /// Writes converted files below `folder`, one subfolder per type. Never
    /// overwrites: names already present on disk get a numbered suffix.
    nonisolated static func write(
        _ outcomes: [TenantExporter.Outcome],
        to folder: URL
    ) throws -> (written: [String], skipped: [ExportSummary.Skipped]) {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        var taken = Set<String>()
        for subfolder in Set(TenantExporter.exportableCollections.map(TenantExporter.folder(for:))) {
            let entries = (try? fileManager.contentsOfDirectory(atPath: folder.appending(path: subfolder).path)) ?? []
            taken.formUnion(entries.map { "\(subfolder)/\($0)".lowercased() })
        }

        var written: [String] = []
        var skipped: [ExportSummary.Skipped] = []
        // Stable order: by folder, then name.
        let files = outcomes.compactMap { outcome -> TenantExporter.ExportFile? in
            if case .file(let file) = outcome { return file }
            return nil
        }.sorted { ($0.folder, $0.baseName) < ($1.folder, $1.baseName) }

        for outcome in outcomes {
            if case .skipped(let name, let reason) = outcome {
                skipped.append(.init(name: name, reason: reason))
            }
        }
        for file in files {
            let relativePath = TenantExporter.uniqueRelativePath(for: file, taken: &taken)
            let destination = folder.appending(path: relativePath)
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.contents.write(to: destination, options: .withoutOverwriting)
                written.append(relativePath)
            } catch {
                skipped.append(.init(name: file.baseName, reason: error.localizedDescription))
            }
        }
        return (written, skipped)
    }
}
