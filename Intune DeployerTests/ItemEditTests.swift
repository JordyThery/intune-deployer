import Foundation
import Testing
@testable import Intune_Deployer

// MARK: - Helpers

private let sourceID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

private func makeItem(_ relativePath: String, type: ItemType) -> InferredItem {
    let url = URL(filePath: "/tmp/fixture/\(relativePath)")
    return InferredItem(
        id: ItemIdentity.shortID(sourceID: sourceID, relativePath: relativePath),
        sourceID: sourceID,
        relativePath: relativePath,
        fileURL: url,
        type: type,
        displayName: url.deletingPathExtension().lastPathComponent,
        detectionReason: "test"
    )
}

private func makeEdit(_ relativePath: String, content: String, basedOn original: String) -> ItemEdit {
    ItemEdit(
        itemID: ItemIdentity.shortID(sourceID: sourceID, relativePath: relativePath),
        sourceID: sourceID,
        relativePath: relativePath,
        content: Data(content.utf8),
        baseContentHash: ItemEditStore.hash(Data(original.utf8)),
        modified: .now
    )
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "item-edit-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Item edits")
@MainActor
struct ItemEditTests {

    // MARK: Store

    @Test func editsRoundTripThroughDisk() throws {
        let storage = try tempDir().appending(path: "edits.json")
        defer { try? FileManager.default.removeItem(at: storage.deletingLastPathComponent()) }

        let edit = makeEdit("scripts/hello.sh", content: "#!/bin/zsh\necho edited\n", basedOn: "#!/bin/zsh\necho hi\n")
        let store = ItemEditStore(storageURL: storage)
        store.save(edit)
        #expect(store.contentOverride(for: edit.itemID) == edit.content)
        #expect(store.overrides(forSource: sourceID) == [edit.relativePath: edit.content])

        // A fresh store instance loads the persisted edit.
        let reloaded = ItemEditStore(storageURL: storage)
        #expect(reloaded.edit(for: edit.itemID) == edit)

        reloaded.revert(itemID: edit.itemID)
        #expect(reloaded.edit(for: edit.itemID) == nil)
        #expect(ItemEditStore(storageURL: storage).edit(for: edit.itemID) == nil)
    }

    @Test func reconcileCoversAllFourCases() throws {
        let storage = try tempDir().appending(path: "edits.json")
        defer { try? FileManager.default.removeItem(at: storage.deletingLastPathComponent()) }
        let store = ItemEditStore(storageURL: storage)

        let original = "#!/bin/zsh\necho hi\n"
        let caughtUp = makeEdit("a.sh", content: "new", basedOn: original)
        let unchanged = makeEdit("b.sh", content: "new", basedOn: original)
        let conflicted = makeEdit("c.sh", content: "new", basedOn: original)
        let orphaned = makeEdit("d.sh", content: "new", basedOn: original)
        for edit in [caughtUp, unchanged, conflicted, orphaned] { store.save(edit) }

        store.reconcile(sourceID: sourceID, originalContents: [
            "a.sh": Data("new".utf8),            // source caught up with the edit
            "b.sh": Data(original.utf8),         // source unchanged
            "c.sh": Data("surprise".utf8),       // source changed differently
            // "d.sh" missing → file deleted
        ], consideredPaths: ["a.sh", "b.sh", "c.sh", "d.sh"])

        #expect(store.edit(for: caughtUp.itemID) == nil)
        #expect(store.edit(for: unchanged.itemID)?.hasConflict == false)
        #expect(store.edit(for: conflicted.itemID)?.hasConflict == true)
        #expect(store.edit(for: orphaned.itemID) == nil)

        // Keeping a conflicted edit re-bases it on the new source content.
        store.keepDespiteConflict(itemID: conflicted.itemID, currentOriginal: Data("surprise".utf8))
        #expect(store.edit(for: conflicted.itemID)?.hasConflict == false)
        store.reconcile(sourceID: sourceID, originalContents: ["c.sh": Data("surprise".utf8)], consideredPaths: ["c.sh"])
        #expect(store.edit(for: conflicted.itemID)?.hasConflict == false)

        // Edits outside a scan's snapshot are never touched — a stale scan
        // must not mistake a just-saved edit for a deleted file.
        store.reconcile(sourceID: sourceID, originalContents: [:], consideredPaths: [])
        #expect(store.edit(for: conflicted.itemID) != nil)
        #expect(store.edit(for: unchanged.itemID) != nil)
    }

    // MARK: Validation

    @Test func validationChecksParsingTypeAndSize() {
        let script = makeItem("scripts/hello.sh", type: .shellScript)
        #expect(ItemEditValidation.validate(text: "#!/bin/zsh\necho edited\n", for: script) ==
            .valid(Data("#!/bin/zsh\necho edited\n".utf8)))

        // A script directive may flip the type — rejected, identity would
        // point at a different Graph collection.
        let becomesAttribute = "#!/bin/zsh\n# intune: type=customAttribute\necho x\n"
        guard case .invalid(let typeMessage) = ItemEditValidation.validate(text: becomesAttribute, for: script) else {
            Issue.record("Expected a type-change rejection")
            return
        }
        #expect(typeMessage.contains("Custom Attribute"))

        // Broken JSON no longer classifies as the item's type.
        let catalog = makeItem("sc/updates.json", type: .settingsCatalog)
        guard case .invalid = ItemEditValidation.validate(text: "{ not json", for: catalog) else {
            Issue.record("Expected invalid JSON to be rejected")
            return
        }

        // Valid JSON of a DIFFERENT type is a type change.
        guard case .invalid = ItemEditValidation.validate(text: Fixtures.assignmentFilterJSON, for: catalog) else {
            Issue.record("Expected a type change to be rejected")
            return
        }

        // Oversized content is refused outright.
        let huge = String(repeating: "x", count: ItemEditValidation.maxSize + 1)
        guard case .invalid(let sizeMessage) = ItemEditValidation.validate(text: huge, for: script) else {
            Issue.record("Expected oversized content to be rejected")
            return
        }
        #expect(sizeMessage.contains("2 MB"))
    }

    @Test func minifiedJSONBecomesEditablePrettyPrintWithoutServerKeys() throws {
        let minified = #"{"name":"Policy","settings":[{"id":"0"}],"platforms":"macOS","@odata.context":"x","id":"abc","createdDateTime":"2026-01-01","settingCount":1}"#
        let text = try #require(ItemEditorView.editableText(from: Data(minified.utf8), pathExtension: "json"))
        #expect(text.contains("\n"))
        #expect(text.contains("\"name\" : \"Policy\""))
        // Read-only Graph metadata the deploy path strips is hidden; nested
        // ids (setting instance ids) are content and stay.
        #expect(!text.contains("@odata.context"))
        #expect(!text.contains("createdDateTime"))
        #expect(!text.contains("settingCount"))
        #expect(!text.contains("abc"))
        #expect(text.contains("\"id\" : \"0\""))
        // Still parses to the same deployable object.
        let roundTripped = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(roundTripped?["platforms"] as? String == "macOS")
    }

    @Test func binaryMobileconfigBecomesEditableXML() throws {
        let plist: [String: Any] = ["PayloadDisplayName": "Dock", "PayloadType": "Configuration"]
        let binary = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let text = try #require(ItemEditorView.editableText(from: binary, pathExtension: "mobileconfig"))
        #expect(text.contains("<?xml"))
        #expect(text.contains("PayloadDisplayName"))
    }

    // MARK: Scan overlay

    @Test func scanOverlayReplacesContentNameAndTokens() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Fixtures.settingsCatalogJSON.write(to: root.appending(path: "catalog.json"), atomically: true, encoding: .utf8)

        let edited = Fixtures.settingsCatalogJSON.replacingOccurrences(
            of: "macOS - Restrictions - Content Caching",
            with: "Edited Name {{OrgName}}"
        )
        let plain = try InferenceEngine.scan(root: root, sourceID: sourceID)
        let overlaid = try InferenceEngine.scan(
            root: root,
            sourceID: sourceID,
            overrides: ["catalog.json": Data(edited.utf8)]
        )

        #expect(plain.items.first?.displayName == "macOS - Restrictions - Content Caching")
        #expect(plain.items.first?.tokens.isEmpty == true)
        let item = try #require(overlaid.items.first)
        #expect(item.displayName == "Edited Name {{OrgName}}")
        #expect(item.tokens == ["OrgName"])
        // Identity is path-based and must not move with the content.
        #expect(item.id == plain.items.first?.id)
    }

    // MARK: Source store integration

    @Test func sourceStoreServesEditsAndReconcilesOnScan() async throws {
        let container = try tempDir()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appending(path: "baseline", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scriptURL = root.appending(path: "hello.sh")
        try "#!/bin/zsh\necho hi\n".write(to: scriptURL, atomically: true, encoding: .utf8)

        let store = SourceStore(
            storageURL: container.appending(path: "sources.json"),
            editStore: ItemEditStore(storageURL: container.appending(path: "edits.json"))
        )
        store.addLocalFolder(at: root)
        let source = try #require(store.sources.first)
        await store.scan(sourceID: source.id)
        let item = try #require(store.items(for: [source.id]).first)

        // Save an edit: effective content changes, the file does not.
        let editedContent = "#!/bin/zsh\necho edited {{OrgName}}\n"
        store.edits.save(ItemEdit(
            itemID: item.id,
            sourceID: source.id,
            relativePath: item.relativePath,
            content: Data(editedContent.utf8),
            baseContentHash: ItemEditStore.hash(try store.originalFileContents(of: item)),
            modified: .now
        ))
        #expect(try store.fileContents(of: item) == Data(editedContent.utf8))
        #expect(try store.originalFileContents(of: item) == Data("#!/bin/zsh\necho hi\n".utf8))

        // Rescan: the item reflects the edit (tokens), no conflict.
        await store.scan(sourceID: source.id)
        let overlaid = try #require(store.items(for: [source.id]).first)
        #expect(overlaid.tokens == ["OrgName"])
        #expect(store.edits.edit(for: item.id)?.hasConflict == false)

        // The file changes differently → conflict flagged, edit still wins.
        try "#!/bin/zsh\necho upstream change\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        await store.scan(sourceID: source.id)
        #expect(store.edits.edit(for: item.id)?.hasConflict == true)
        #expect(try store.fileContents(of: item) == Data(editedContent.utf8))

        // The file catches up with the edit → the edit clears itself.
        try editedContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        await store.scan(sourceID: source.id)
        #expect(store.edits.edit(for: item.id) == nil)
        #expect(try store.fileContents(of: item) == Data(editedContent.utf8))
    }

    // MARK: Plan integration

    @Test func planWarnsAboutEditedContent() {
        let item = makeItem("scripts/greeting.sh", type: .shellScript)
        let profile = TenantProfile(
            displayName: "T", clientID: "e445f0a6-0000-0000-0000-000000000000",
            tenantID: "t", selectedItemIDs: [item.id]
        )
        let plan = PlanEngine.makePlan(input: PlanInput(
            selectedItems: [.init(item: item, fileData: Data("#!/bin/zsh\necho hi\n".utf8), isEdited: true)],
            profile: profile,
            existingObjects: [:],
            groups: [:],
            knownSettingDefinitionIDs: nil
        ))
        #expect(plan.actions.first?.warnings.contains { $0.contains("edited in the app") } == true)
    }
}
