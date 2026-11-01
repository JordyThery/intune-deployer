import Foundation
import JTKit
import OSLog

/// One of the app's JSON lists next to `tenants.json` (`sources.json`,
/// `item-edits.json`, `platform-overrides.json`, `source-identities.json`),
/// in JTKit's file storage: pretty-printed with sorted keys, written
/// atomically. A file that can't be read is copied aside once and never
/// saved over: until it is fixed, changes stay in memory only and `problem`
/// says why.
@MainActor
final class SavedList<Record: Codable> {
    private static var logger: Logger { Logger(subsystem: "be.jordythery.intune-deployer", category: "SavedList") }

    private let storage: JSONFileConnectionStorage<Record>
    /// What the list holds, e.g. "sources", for the problem's sentence.
    private let name: String

    /// Why changes aren't saved: the file couldn't be read. Nil when fine.
    private(set) var problem: String?

    var fileURL: URL { storage.fileURL }

    init(fileURL: URL, name: String) {
        storage = JSONFileConnectionStorage(fileURL: fileURL)
        self.name = name
    }

    /// The saved records; none when there is no file yet or it can't be read.
    func load() -> [Record] {
        do {
            let records = try storage.load()
            problem = nil
            return records
        } catch {
            let copy = storage.keepUnreadableCopy()
            let copyNote = copy.map { " A copy is at \($0)." } ?? ""
            problem = "The saved \(name) couldn’t be read, so changes aren’t saved until this is fixed (\(error.localizedDescription)).\(copyNote)"
            Self.logger.error("Couldn’t read \(self.storage.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription)")
            return []
        }
    }

    /// Saves the records, unless the file couldn't be read.
    func save(_ records: [Record]) {
        guard problem == nil else { return }
        do {
            try storage.save(records)
        } catch {
            Self.logger.error("Couldn’t save \(self.storage.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription)")
        }
    }
}
