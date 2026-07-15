import Foundation
import AppKit
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

protocol ClipboardHistoryPersisting {
    func loadEntries(limit: Int?, offset: Int) -> [ClipboardEntry]
    func searchEntries(keyword: String, limit: Int) -> [ClipboardEntry]
    func saveEntries(_ entries: [ClipboardEntry])
    func append(entry: ClipboardEntry)
    func updateEntry(_ entry: ClipboardEntry)
    func removeEntry(id: UUID)
    func clearNonFavorites()
    func enforceQuota(historyLimit: Int, imageQuotaMB: Int)
    func persistImage(_ image: NSImage) throws -> String
    func deleteImage(named: String)
    func imageURL(for relativePath: String) -> URL
}

final class ClipboardHistoryStore: ClipboardHistoryPersisting {
    enum StoreError: Error {
        case unableToEncodeImage
    }

    private let directoryURL: URL
    private let dbURL: URL
    private let imageDirectory: URL
    private let queue = DispatchQueue(label: "clipboard-history-store")
    private var db: OpaquePointer?
    private let defaultLimit = 5000

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            directoryURL = baseDirectory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            directoryURL = support.appending(path: "ClipboardHistory", directoryHint: .isDirectory)
        }
        dbURL = directoryURL.appending(path: "clipboard.sqlite")
        imageDirectory = directoryURL.appending(path: "static", directoryHint: .isDirectory)
        createDirectoriesIfNeeded()
        openDatabase()
        createTableIfNeeded()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func loadEntries(limit: Int? = nil, offset: Int = 0) -> [ClipboardEntry] {
        queue.sync {
            guard let db else { return [] }
            let sql = "SELECT id, ts, type, text, image_path, tab, note, source_app, is_favorite FROM clipboard_entry ORDER BY ts DESC LIMIT ? OFFSET ?;"
            var statement: OpaquePointer?
            var results: [ClipboardEntry] = []
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(limit ?? defaultLimit))
                sqlite3_bind_int(statement, 2, Int32(offset))
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let entry = buildEntry(from: statement) {
                        results.append(entry)
                    }
                }
            }
            sqlite3_finalize(statement)
            return results
        }
    }

    func searchEntries(keyword: String, limit: Int = 50) -> [ClipboardEntry] {
        queue.sync {
            guard let db else { return [] }
            let like = "%" + keyword.lowercased() + "%"
            let sql = "SELECT id, ts, type, text, image_path, tab, note, source_app, is_favorite FROM clipboard_entry WHERE lower(text) LIKE ? OR lower(note) LIKE ? ORDER BY ts DESC LIMIT ?;"
            var statement: OpaquePointer?
            var entries: [ClipboardEntry] = []
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, like, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, like, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(statement, 3, Int32(limit))
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let entry = buildEntry(from: statement) {
                        entries.append(entry)
                    }
                }
            }
            sqlite3_finalize(statement)
            return entries
        }
    }

    func saveEntries(_ entries: [ClipboardEntry]) {
        queue.async {
            guard let db = self.db else { return }
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM clipboard_entry", nil, nil, nil)
            entries.prefix(self.defaultLimit).forEach { self.insert(entry: $0, db: db) }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    func append(entry: ClipboardEntry) {
        queue.async {
            guard let db = self.db else { return }
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            self.insert(entry: entry, db: db)
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    func updateEntry(_ entry: ClipboardEntry) {
        queue.async {
            guard let db = self.db else { return }
            let sql = "UPDATE clipboard_entry SET ts = ?, type = ?, text = ?, image_path = ?, tab = ?, note = ?, source_app = ?, is_favorite = ? WHERE id = ?;"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_double(statement, 1, entry.timestamp.timeIntervalSince1970)
                sqlite3_bind_text(statement, 2, entry.type.rawValue, -1, SQLITE_TRANSIENT)
                self.bindOptionalText(statement, index: 3, value: entry.text)
                self.bindOptionalText(statement, index: 4, value: entry.imagePath)
                sqlite3_bind_text(statement, 5, entry.tab.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 6, entry.note, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 7, entry.sourceApp, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(statement, 8, entry.isFavorite ? 1 : 0)
                sqlite3_bind_text(statement, 9, entry.id.uuidString, -1, SQLITE_TRANSIENT)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }

    func removeEntry(id: UUID) {
        queue.async {
            guard let db = self.db else { return }
            let sql = "DELETE FROM clipboard_entry WHERE id = ?;"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, id.uuidString, -1, SQLITE_TRANSIENT)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }

    func clearNonFavorites() {
        queue.async {
            guard let db = self.db else { return }
            let entriesToDelete = self.fetchEntriesForDeletion(
                db: db,
                sql: "SELECT id, image_path FROM clipboard_entry WHERE is_favorite = 0 LIMIT ?;",
                limit: Int(Int32.max)
            )
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            if sqlite3_exec(db, "DELETE FROM clipboard_entry WHERE is_favorite = 0;", nil, nil, nil) != SQLITE_OK {
                ClipLog.error("清理非收藏失败")
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            entriesToDelete.compactMap(\.imagePath).forEach { self.deleteImage(named: $0) }
        }
    }

    func enforceQuota(historyLimit: Int, imageQuotaMB: Int) {
        queue.sync {
            guard let db = self.db else { return }
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            self.trimIfNeeded(db: db, limit: historyLimit)
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            self.trimImages(maxMB: imageQuotaMB, db: db)
        }
    }

    func persistImage(_ image: NSImage) throws -> String {
        guard let data = image.pngData() else { throw StoreError.unableToEncodeImage }
        let filename = UUID().uuidString + ".png"
        let url = imageDirectory.appending(path: filename)
        try data.write(to: url)
        return filename
    }

    func deleteImage(named: String) {
        let url = imageDirectory.appending(path: named)
        try? FileManager.default.removeItem(at: url)
    }

    func imageURL(for relativePath: String) -> URL {
        imageDirectory.appending(path: relativePath)
    }

    // MARK: - Private Helpers

    private func createDirectoriesIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        } catch {
            ClipLog.error("创建目录失败: \(error.localizedDescription)")
        }
    }

    private func openDatabase() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            ClipLog.error("打开数据库失败")
            db = nil
        }
    }

    private func createTableIfNeeded() {
        guard let db else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS clipboard_entry (
            id TEXT PRIMARY KEY,
            ts REAL,
            type TEXT,
            text TEXT,
            image_path TEXT,
            tab TEXT,
            note TEXT,
            source_app TEXT,
            is_favorite INTEGER
        );
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            ClipLog.error("创建主表失败")
        }
    }

    private func buildEntry(from statement: OpaquePointer?) -> ClipboardEntry? {
        guard let statement,
              let idPointer = sqlite3_column_text(statement, 0),
              let uuid = UUID(uuidString: String(cString: idPointer)) else { return nil }
        let ts = sqlite3_column_double(statement, 1)
        let typeString = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ClipboardEntryType.text.rawValue
        let entryType = ClipboardEntryType(rawValue: typeString) ?? .text
        let text = sqlite3_column_text(statement, 3).map { String(cString: $0) }
        let imagePath = sqlite3_column_text(statement, 4).map { String(cString: $0) }
        let tabString = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? ClipboardTab.clipboardHistory.rawValue
        let tab = ClipboardTab(rawValue: tabString) ?? .clipboardHistory
        let note = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
        let sourceApp = sqlite3_column_text(statement, 7).map { String(cString: $0) } ?? "未知"
        let isFavorite = sqlite3_column_int(statement, 8) == 1
        return ClipboardEntry(id: uuid,
                              timestamp: Date(timeIntervalSince1970: ts),
                              type: entryType,
                              text: text,
                              imagePath: imagePath,
                              isFavorite: isFavorite,
                              tab: tab,
                              note: note,
                              sourceApp: sourceApp)
    }

    private func bindOptionalText(_ statement: OpaquePointer?, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func insert(entry: ClipboardEntry, db: OpaquePointer) {
        let sql = "INSERT OR REPLACE INTO clipboard_entry (id, ts, type, text, image_path, tab, note, source_app, is_favorite) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, entry.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 2, entry.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(statement, 3, entry.type.rawValue, -1, SQLITE_TRANSIENT)
            bindOptionalText(statement, index: 4, value: entry.text)
            bindOptionalText(statement, index: 5, value: entry.imagePath)
            sqlite3_bind_text(statement, 6, entry.tab.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 7, entry.note, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 8, entry.sourceApp, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 9, entry.isFavorite ? 1 : 0)
            if sqlite3_step(statement) != SQLITE_DONE {
                ClipLog.error("插入失败")
            }
        }
        sqlite3_finalize(statement)
    }

    private func trimIfNeeded(db: OpaquePointer, limit: Int? = nil) {
        let limitValue = limit ?? defaultLimit
        let count = currentCount(db: db)
        guard count > limitValue else { return }
        let overflow = count - limitValue
        let removable = fetchEntriesForDeletion(
            db: db,
            sql: "SELECT id, image_path FROM clipboard_entry WHERE is_favorite = 0 ORDER BY ts ASC LIMIT ?;",
            limit: overflow
        )
        deleteEntries(removable, db: db)
    }

    private func currentCount(db: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM clipboard_entry;", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            count = Int(sqlite3_column_int(statement, 0))
        }
        sqlite3_finalize(statement)
        return count
    }

    private func trimImages(maxMB: Int, db: OpaquePointer) {
        let maxBytes = Int64(maxMB) * 1024 * 1024
        let manager = FileManager.default
        let imageEntries = fetchImageEntries(db: db)
        let referencedPaths = Set(imageEntries.map(\.imagePath))
        cleanupOrphanedImages(referencedPaths: referencedPaths, manager: manager)

        var totalBytes: Int64 = 0
        var fileSizes: [String: Int64] = [:]
        for path in referencedPaths {
            let url = imageDirectory.appending(path: path)
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            fileSizes[path] = size
            totalBytes += size
        }

        guard totalBytes > maxBytes else { return }

        var removable: [(id: String, imagePath: String?)] = []
        for entry in imageEntries where !entry.isFavorite {
            removable.append((id: entry.id, imagePath: entry.imagePath))
            totalBytes -= fileSizes[entry.imagePath] ?? 0
            if totalBytes <= maxBytes {
                break
            }
        }

        deleteEntries(removable, db: db)

        if totalBytes > maxBytes {
            ClipLog.error("图片配额仍超限，当前仅剩收藏图片或缺少可清理项")
        }
    }

    private func fetchEntriesForDeletion(db: OpaquePointer,
                                         sql: String,
                                         limit: Int) -> [(id: String, imagePath: String?)] {
        var statement: OpaquePointer?
        var results: [(id: String, imagePath: String?)] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(max(limit, 0)))
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idPointer = sqlite3_column_text(statement, 0) else { continue }
                let id = String(cString: idPointer)
                let imagePath = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                results.append((id: id, imagePath: imagePath))
            }
        }
        sqlite3_finalize(statement)
        return results
    }

    private func fetchImageEntries(db: OpaquePointer) -> [(id: String, imagePath: String, isFavorite: Bool)] {
        let sql = "SELECT id, image_path, is_favorite FROM clipboard_entry WHERE type = ? AND image_path IS NOT NULL ORDER BY ts ASC;"
        var statement: OpaquePointer?
        var results: [(id: String, imagePath: String, isFavorite: Bool)] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, ClipboardEntryType.image.rawValue, -1, SQLITE_TRANSIENT)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idPointer = sqlite3_column_text(statement, 0),
                      let imagePathPointer = sqlite3_column_text(statement, 1) else { continue }
                results.append((
                    id: String(cString: idPointer),
                    imagePath: String(cString: imagePathPointer),
                    isFavorite: sqlite3_column_int(statement, 2) == 1
                ))
            }
        }
        sqlite3_finalize(statement)
        return results
    }

    private func deleteEntries(_ entries: [(id: String, imagePath: String?)], db: OpaquePointer) {
        guard !entries.isEmpty else { return }
        let sql = "DELETE FROM clipboard_entry WHERE id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for entry in entries {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, entry.id, -1, SQLITE_TRANSIENT)
                if sqlite3_step(statement) != SQLITE_DONE {
                    ClipLog.error("删除条目失败 id=\(entry.id)")
                }
                if let imagePath = entry.imagePath {
                    deleteImage(named: imagePath)
                }
            }
        }
        sqlite3_finalize(statement)
    }

    private func cleanupOrphanedImages(referencedPaths: Set<String>, manager: FileManager) {
        guard let urls = try? manager.contentsOfDirectory(at: imageDirectory,
                                                          includingPropertiesForKeys: nil,
                                                          options: .skipsHiddenFiles) else { return }
        for url in urls where !referencedPaths.contains(url.lastPathComponent) {
            try? manager.removeItem(at: url)
        }
    }
}
