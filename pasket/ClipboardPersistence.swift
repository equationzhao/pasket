import AppKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

nonisolated enum ClipboardMutation: Sendable {
    case upsert(ClipboardItem)
    case touch(UUID, Date)
    case delete(UUID)
    case deleteFingerprint(String)
    case deleteUnavailableFiles(includingPinned: Bool)
    case setPinned(UUID, Bool)
    case clear
    case completeImageImport(UUID)
    case settings(isPaused: Bool)
    case maintenance
}

nonisolated struct ClipboardPage: Sendable {
    var items: [ClipboardItem]
    var matchingCount: Int
    var totalCount: Int
    var imageBytes: Int
    var textBytes: Int
}

nonisolated struct ClipboardResultSnapshot: Sendable {
    var references: [ClipboardHistoryReference]
    var page: ClipboardPage
}

nonisolated enum ClipboardStorageError: LocalizedError {
    case unsupportedVersion, invalidImage, largeImage, invalidHistory, missingImage, imageBudget, invalidRetention
    case unsupportedFileExport, largeText, largeTextData, tooManyItems, missingSnapshot, unavailablePasteFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This history was created by a newer version of Pasket. It has been left unchanged."
        case .invalidImage: "This image could not be saved."
        case .largeImage: "Image not saved: the limit is 20 MB and 40 million pixels."
        case .invalidHistory: "The history file is damaged. It has been left unchanged."
        case .missingImage: "This saved image is unavailable."
        case .imageBudget: "Image not saved: the image and its thumbnail exceed your image storage limit."
        case .invalidRetention: "History limits must be positive whole numbers or Unlimited."
        case .unsupportedFileExport: "Choose a text, link, email, or image entry to save."
        case .largeText: "Text exceeds the 2,000-character history limit."
        case .largeTextData: "Text formats exceed the 2 MiB limit per copy."
        case .tooManyItems: "Copy up to 100 items at a time."
        case .missingSnapshot: "The original clipboard formats for this entry are unavailable."
        case .unavailablePasteFormat: "This paste format is unavailable for the selected entry."
        }
    }
}

nonisolated enum ClipboardEditError: LocalizedError {
    case unavailable, changed, duplicate, invalidText, textBudget

    var errorDescription: String? {
        switch self {
        case .unavailable: "This entry is unavailable."
        case .changed: "This entry changed. Reopen the editor to load its latest text."
        case .duplicate: "An entry with this text already exists."
        case .invalidText: "Enter between 1 and \(ClipboardLimits.textCharacters.formatted()) characters of text."
        case .textBudget: "This edit exceeds your history text limit."
        }
    }
}

actor ClipboardPersistence {
    let directory: URL
    private var committedImageNames: Set<String> = []
    private var pendingImages: [UUID: Set<String>] = [:]
    private var mediaDirectory: URL { directory.appendingPathComponent("Images", isDirectory: true) }
    private var historyURL: URL { directory.appendingPathComponent("history.json") }
    private var databaseURL: URL { directory.appendingPathComponent("history.sqlite") }
    private var hasOpenedDatabase = false

    init(directory: URL) { self.directory = directory }

    static func applicationDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pasket", isDirectory: true)
    }

    func load() throws -> ClipboardHistory {
        let database = try openDatabase()
        var history = try settings(in: database)
        try database.query("SELECT payload, is_pinned FROM items ORDER BY is_pinned DESC, copied_at DESC, position DESC, id") {
            history.items.append(try decodeItem($0, pinnedColumn: 1))
        }
        return history
    }

    func loadSettings() throws -> ClipboardHistory {
        try settings(in: openDatabase())
    }

    func historicalCopyCounts(timeZone: TimeZone = .current) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        // Read legacy dates before importing, since import can enforce saved retention limits.
        if !FileManager.default.fileExists(atPath: databaseURL.path),
           FileManager.default.fileExists(atPath: historyURL.path) {
            let history = try JSONDecoder().decode(ClipboardHistory.self, from: Data(contentsOf: historyURL))
            try validate(history)
            for item in history.items {
                counts[HistoryStatistics.dayKey(item.copiedAt, timeZone: timeZone), default: 0] += 1
            }
            return counts
        }
        // Scan dates only, across the entire database rather than the visible page.
        let database = try openDatabase()
        try database.query("SELECT copied_at FROM items") { row in
            let date = Date(timeIntervalSinceReferenceDate: ClipboardDatabase.real(row, 0))
            counts[HistoryStatistics.dayKey(date, timeZone: timeZone), default: 0] += 1
        }
        return counts
    }

    // Full snapshots are used by importers and fixtures; normal collection uses apply(_:).
    func save(_ history: ClipboardHistory) throws {
        try validate(history)
        let database = try openDatabase()
        try database.transaction {
            try database.execute("DELETE FROM items")
            for item in history.items.reversed() { try upsert(item, in: database) }
            try writeSettings(history, in: database)
            try enforceLimits(in: database)
        }
        for item in history.items { pendingImages[item.id] = nil }
        try didCommit(in: database)
    }

    func apply(_ mutations: [ClipboardMutation]) throws {
        let database = try openDatabase()
        try database.transaction {
            for mutation in mutations {
                switch mutation {
                case .upsert(let item): try upsert(item, in: database)
                case .touch(let id, let date):
                    if var item = try item(id, in: database) {
                        item.copiedAt = date
                        try upsert(item, in: database)
                    }
                case .delete(let id): try database.execute("DELETE FROM items WHERE id = ?", [.text(id.uuidString)])
                case .deleteFingerprint(let fingerprint):
                    try database.execute("DELETE FROM items WHERE fingerprint = ?", [.text(fingerprint)])
                case .setPinned(let id, let pinned):
                    try database.execute("UPDATE items SET is_pinned = ? WHERE id = ?",
                                         [.integer(pinned ? 1 : 0), .text(id.uuidString)])
                case .deleteUnavailableFiles(let includingPinned):
                    for id in try unavailableFileIDs(in: database, includingPinned: includingPinned) {
                        try database.execute("DELETE FROM items WHERE id = ?", [.text(id)])
                    }
                case .clear: try database.execute("DELETE FROM items")
                case .completeImageImport: break
                case let .settings(paused):
                    var history = try settings(in: database)
                    history.isPaused = paused
                    try writeSettings(history, in: database)
                case .maintenance: break
                }
            }
            try enforceLimits(in: database)
        }
        for mutation in mutations {
            switch mutation {
            case .completeImageImport(let id): pendingImages[id] = nil
            case .upsert(let item): pendingImages[item.id] = nil
            default: break
            }
        }
        try didCommit(in: database)
    }

    func item(_ id: UUID) throws -> ClipboardItem? { try item(id, in: openDatabase()) }

    func editText(_ text: String, for id: UUID, matching fingerprint: String) throws {
        guard text.prefix(ClipboardLimits.textCharacters + 1).count <= ClipboardLimits.textCharacters,
              text.contains(where: { !$0.isWhitespace }) else { throw ClipboardEditError.invalidText }
        let database = try openDatabase()
        var removedSnapshot = false
        try database.transaction {
            guard let original = try item(id, in: database), original.canEditText else { throw ClipboardEditError.unavailable }
            guard original.fingerprint == fingerprint else { throw ClipboardEditError.changed }
            guard text != original.content else { return }
            var edited = ClipboardItem.text(text, source: original.source, at: original.copiedAt)
            edited.id = id
            guard try database.integer("SELECT COUNT(*) FROM items WHERE fingerprint = ? AND id != ?",
                                       [.text(edited.fingerprint), .text(id.uuidString)]) == 0 else {
                throw ClipboardEditError.duplicate
            }
            if !original.isPinned, edited.textByteCount > original.textByteCount,
               let limit = try settings(in: database).retention?.maximumTextBytes {
                let otherBytes = try database.integer("SELECT COALESCE(SUM(text_bytes), 0) FROM items WHERE is_pinned = 0 AND id != ?",
                                                      [.text(id.uuidString)])
                guard edited.textByteCount <= limit - otherBytes else { throw ClipboardEditError.textBudget }
            }
            try upsert(edited, in: database, preservingPosition: true)
            removedSnapshot = original.snapshot != nil
        }
        if removedSnapshot { try didCommit(in: database) }
    }

    private func imageTextColumn(for mode: ClipboardImageText.Mode) -> String {
        mode == .accurate ? "image_text" : "fast_image_text"
    }

    func unrecognizedImages(limit: Int, mode: ClipboardImageText.Mode = .accurate) throws -> [ClipboardItem] {
        let database = try openDatabase()
        var items: [ClipboardItem] = []
        try database.query("""
            SELECT payload FROM items
            WHERE kind = 'image' AND image_name LIKE '%.png' AND \(imageTextColumn(for: mode)) IS NULL
            ORDER BY copied_at DESC, position DESC, id LIMIT ?
            """, [.integer(limit)]) {
            items.append(try JSONDecoder().decode(ClipboardItem.self, from: ClipboardDatabase.data($0, 0)))
        }
        return items
    }

    func imageText(for id: UUID, image: ClipboardImage, mode: ClipboardImageText.Mode = .accurate) throws -> String? {
        let database = try openDatabase()
        var text: String?
        let column = imageTextColumn(for: mode)
        try database.query("SELECT \(column) FROM items WHERE id = ? AND image_name = ? AND \(column) IS NOT NULL",
                           [.text(id.uuidString), .text(image.fileName)]) {
            text = ClipboardDatabase.text($0, 0)
        }
        return text
    }

    func saveImageText(_ text: String, for id: UUID, image: ClipboardImage,
                       mode: ClipboardImageText.Mode = .accurate) throws {
        try Task.checkCancellation()
        let database = try openDatabase()
        let column = imageTextColumn(for: mode)
        let available = text.isEmpty ? "\(column) IS NULL" : "(\(column) IS NULL OR \(column) = '')"
        try database.execute("UPDATE items SET \(column) = ? WHERE id = ? AND image_name = ? AND \(available)",
                             [.text(text), .text(id.uuidString), .text(image.fileName)])
    }

    func clearImageText() throws {
        let database = try openDatabase()
        try database.execute("PRAGMA secure_delete = ON")
        try database.execute("""
            UPDATE items SET image_text = NULL, fast_image_text = NULL
            WHERE image_text IS NOT NULL OR fast_image_text IS NOT NULL
            """)
    }

    func page(query: String = "", filter: ClipboardFilter = .all, limit: Int = 50, offset: Int = 0,
              level: ClipboardSearch.Level = .fuzzy, includesImageText: Bool = false,
              imageTextMode: ClipboardImageText.Mode = .accurate) throws -> ClipboardPage {
        let database = try openDatabase()
        let search = ClipboardSearch(query, level: level)
        let imageText = includesImageText && !search.isEmpty ? imageTextColumn(for: imageTextMode) : "NULL"
        let (clause, values, ordering) = try resultQuery(search, filter: filter, imageText: imageText, in: database)
        var items: [ClipboardItem] = []
        try database.query("SELECT summary, \(imageText), is_pinned FROM items" + clause + " ORDER BY " + ordering + " LIMIT ? OFFSET ?",
                           values + [.integer(max(0, limit)), .integer(max(0, offset))]) {
            items.append(try decodeSummary($0, search: search))
        }
        return ClipboardPage(items: items, matchingCount: try database.integer("SELECT COUNT(*) FROM items" + clause, values),
                             totalCount: try database.integer("SELECT COUNT(*) FROM items"),
                             imageBytes: try database.integer("SELECT COALESCE(SUM(image_bytes), 0) FROM items"),
                             textBytes: try database.integer("SELECT COALESCE(SUM(text_bytes), 0) FROM items"))
    }

    // Index and summaries are read in one actor turn, using exactly the same ranking as pages.
    func resultSnapshot(query: String, filter: ClipboardFilter, limit: Int,
                        retainingIDs: Set<UUID> = [], level: ClipboardSearch.Level = .fuzzy,
                        includesImageText: Bool = false,
                        imageTextMode: ClipboardImageText.Mode = .accurate) throws -> ClipboardResultSnapshot {
        let signposter = HistoryPerformance.signposter
        let interval = signposter.beginInterval("History Result Snapshot", id: signposter.makeSignpostID())
        var references: [ClipboardHistoryReference] = []
        var completed = false
        defer {
            let failure = Task.isCancelled ? "cancelled" : "failed"
            let status = completed ? "complete" : failure
            signposter.endInterval("History Result Snapshot", interval,
                                   "count=\(references.count, privacy: .public) status=\(status, privacy: .public)")
        }
        let database = try openDatabase()
        let search = ClipboardSearch(query, level: level)
        let imageText = includesImageText && !search.isEmpty ? imageTextColumn(for: imageTextMode) : "NULL"
        let (clause, values, ordering) = try resultQuery(search, filter: filter, imageText: imageText, in: database)
        try database.query("SELECT id, copied_at, is_pinned FROM items" + clause + " ORDER BY " + ordering, values) { row in
            try Task.checkCancellation()
            guard let id = UUID(uuidString: ClipboardDatabase.text(row, 0)) else {
                throw ClipboardStorageError.invalidHistory
            }
            references.append(ClipboardHistoryReference(id: id,
                copiedAt: Date(timeIntervalSinceReferenceDate: ClipboardDatabase.real(row, 1)),
                isPinned: ClipboardDatabase.int(row, 2) != 0))
        }
        let retained = references.filter { retainingIDs.contains($0.id) }.map(\.id)
        let requested = Array(Set(references.prefix(max(0, limit)).map(\.id) + retained))
        var summaries: [UUID: ClipboardItem] = [:]
        // Bound parameter counts even when a large selected range has been loaded.
        for start in stride(from: 0, to: requested.count, by: 500) {
            let ids = requested[start..<min(start + 500, requested.count)]
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try database.query("SELECT summary, \(imageText), is_pinned FROM items WHERE id IN (" + placeholders + ")",
                               ids.map { .text($0.uuidString) }) { row in
                let item = try decodeSummary(row, search: search)
                summaries[item.id] = item
            }
        }
        let page = ClipboardPage(items: references.compactMap { summaries[$0.id] }, matchingCount: references.count,
                                 totalCount: try database.integer("SELECT COUNT(*) FROM items"),
                                 imageBytes: try database.integer("SELECT COALESCE(SUM(image_bytes), 0) FROM items"),
                                 textBytes: try database.integer("SELECT COALESCE(SUM(text_bytes), 0) FROM items"))
        completed = true
        return ClipboardResultSnapshot(references: references, page: page)
    }

    private func decodeSummary(_ row: OpaquePointer, search: ClipboardSearch) throws -> ClipboardItem {
        var item = try decodeItem(row, pinnedColumn: 2)
        let text = ClipboardDatabase.text(row, 1)
        if !text.isEmpty, ClipboardSearch(search.query, level: .literal).rank(item) == 0 {
            item.imageTextMatch = search.imageTextSnippet(text)
        }
        return item
    }

    private func resultQuery(_ search: ClipboardSearch, filter: ClipboardFilter, imageText: String,
                             in database: ClipboardDatabase)
        throws -> (String, [ClipboardDatabase.Value], String) {
        var predicates: [String] = []
        var values: [ClipboardDatabase.Value] = []
        if filter == .images { predicates.append("has_image_preview = 1") }
        else if let kind = filter.kind { predicates.append("kind = ?"); values.append(.text(kind.rawValue)) }
        let rank = "pasket_search_rank(title, content, source_name, source_bundle, \(imageText))"
        if !search.isEmpty {
            try database.setSearch(search)
            predicates.append(rank + " > 0")
        }
        let clause = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        let ranking = search.isEmpty ? "is_pinned DESC, " : rank + " DESC, "
        return (clause, values, ranking + "copied_at DESC, position DESC, id")
    }

    private func validate(_ history: ClipboardHistory) throws {
        guard history.version == 1 else { throw ClipboardStorageError.unsupportedVersion }
        guard history.retention?.isValid != false else { throw ClipboardStorageError.invalidRetention }
        guard Set(history.items.map(\.id)).count == history.items.count,
              history.items.allSatisfy({ item in
                  if let image = item.image {
                      return item.kind == .image && validImageNames(image) && image.byteCount >= 0
                          && image.byteCount <= ClipboardLimits.imageBytes && image.thumbnailByteCount >= 0
                          && image.thumbnailByteCount <= ClipboardLimits.imageBytes
                  }
                  if item.kind == .image { return false }
                  if item.kind == .file { return !item.files.isEmpty }
                  return item.content.count <= ClipboardLimits.textCharacters
              }) else { throw ClipboardStorageError.invalidHistory }
    }

    private func openDatabase() throws -> ClipboardDatabase {
        if hasOpenedDatabase, !FileManager.default.fileExists(atPath: databaseURL.path) {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try ClipboardDatabase(url: databaseURL)
        let version = try database.integer("PRAGMA user_version")
        guard version <= 4 else { throw ClipboardStorageError.unsupportedVersion }
        guard version >= 0 else { throw ClipboardStorageError.invalidHistory }
        if version == 0 {
            guard try database.integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'") == 0 else {
                throw ClipboardStorageError.invalidHistory
            }
            var history = ClipboardHistory()
            if FileManager.default.fileExists(atPath: historyURL.path) {
                history = try JSONDecoder().decode(ClipboardHistory.self, from: Data(contentsOf: historyURL))
                try validate(history)
            }
            try database.transaction {
                try database.execute("""
                    CREATE TABLE items (
                        id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
                        title TEXT NOT NULL, content TEXT NOT NULL, source_name TEXT NOT NULL, source_bundle TEXT NOT NULL,
                        copied_at REAL NOT NULL, position INTEGER NOT NULL, has_image_preview INTEGER NOT NULL,
                        text_bytes INTEGER NOT NULL, image_bytes INTEGER NOT NULL,
                        image_name TEXT NOT NULL, thumbnail_name TEXT NOT NULL, summary BLOB NOT NULL, payload BLOB NOT NULL,
                        image_text TEXT, fast_image_text TEXT, is_pinned INTEGER NOT NULL DEFAULT 0
                    )
                    """)
                try database.execute("CREATE INDEX items_recency ON items(copied_at DESC, position DESC, id)")
                try database.execute("CREATE INDEX items_kind_recency ON items(kind, copied_at DESC, position DESC, id)")
                try createPinnedIndex(in: database)
                try database.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL)")
                for item in history.items.reversed() { try upsert(item, in: database) }
                try writeSettings(history, in: database)
                try enforceLimits(in: database)
                try database.execute("PRAGMA user_version = 4")
            }
        } else if version < 4 {
            try database.transaction {
                if version == 1 { try database.execute("ALTER TABLE items ADD COLUMN image_text TEXT") }
                if version < 3 { try database.execute("ALTER TABLE items ADD COLUMN fast_image_text TEXT") }
                try database.execute("ALTER TABLE items ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0")
                try createPinnedIndex(in: database)
                try database.execute("PRAGMA user_version = 4")
            }
        }
        // Only collect media after the schema and any legacy import have committed.
        if !hasOpenedDatabase {
            _ = try settings(in: database)
            try didCommit(in: database)
        }
        hasOpenedDatabase = true
        return database
    }

    private func createPinnedIndex(in database: ClipboardDatabase) throws {
        try database.execute("CREATE INDEX items_pinned_recency ON items(is_pinned DESC, copied_at DESC, position DESC, id)")
    }

    private func settings(in database: ClipboardDatabase) throws -> ClipboardHistory {
        var history: ClipboardHistory?
        try database.query("SELECT payload FROM settings WHERE id = 1") {
            history = try JSONDecoder().decode(ClipboardHistory.self, from: ClipboardDatabase.data($0, 0))
        }
        guard let history else { throw ClipboardStorageError.invalidHistory }
        try validate(history)
        return history
    }

    private func writeSettings(_ history: ClipboardHistory, in database: ClipboardDatabase) throws {
        let settings = ClipboardHistory(isPaused: history.isPaused, retention: history.retention)
        try validate(settings)
        try database.execute("INSERT OR REPLACE INTO settings(id, payload) VALUES(1, ?)", [.blob(try JSONEncoder().encode(settings))])
    }

    private func item(_ id: UUID, in database: ClipboardDatabase) throws -> ClipboardItem? {
        var item: ClipboardItem?
        try database.query("SELECT payload, is_pinned FROM items WHERE id = ?", [.text(id.uuidString)]) {
            item = try decodeItem($0, pinnedColumn: 1)
        }
        return item
    }

    private func decodeItem(_ row: OpaquePointer, pinnedColumn: Int32) throws -> ClipboardItem {
        var item = try JSONDecoder().decode(ClipboardItem.self, from: ClipboardDatabase.data(row, 0))
        item.isPinned = ClipboardDatabase.int(row, pinnedColumn) != 0
        return item
    }

    private func upsert(_ incoming: ClipboardItem, in database: ClipboardDatabase, preservingPosition: Bool = false) throws {
        var item = incoming
        try database.query("SELECT id FROM items WHERE fingerprint = ?", [.text(item.fingerprint)]) {
            guard let id = UUID(uuidString: ClipboardDatabase.text($0, 0)) else { throw ClipboardStorageError.invalidHistory }
            item.id = id
        }
        try validate(ClipboardHistory(items: [item]))
        if item.id != incoming.id {
            // Refreshed bookmarks can make two previously distinct paths converge.
            try database.execute("""
                UPDATE items SET is_pinned = 1 WHERE id = ?
                AND EXISTS (SELECT 1 FROM items WHERE id = ? AND is_pinned = 1)
                """, [.text(item.id.uuidString), .text(incoming.id.uuidString)])
            try database.execute("DELETE FROM items WHERE id = ?", [.text(incoming.id.uuidString)])
        }
        let position = preservingPosition
            ? try database.integer("SELECT position FROM items WHERE id = ?", [.text(item.id.uuidString)])
            : try database.integer("SELECT COALESCE(MAX(position), 0) + 1 FROM items")
        var summary = item
        summary.content = String(item.content.prefix(500))
        let encoder = JSONEncoder()
        try database.execute("""
            INSERT INTO items (id, fingerprint, kind, title, content, source_name, source_bundle, copied_at,
                position, has_image_preview, text_bytes, image_bytes, image_name, thumbnail_name, summary, payload, is_pinned)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                fingerprint=excluded.fingerprint, kind=excluded.kind, title=excluded.title, content=excluded.content,
                source_name=excluded.source_name, source_bundle=excluded.source_bundle, copied_at=excluded.copied_at,
                position=excluded.position, has_image_preview=excluded.has_image_preview,
                text_bytes=excluded.text_bytes, image_bytes=excluded.image_bytes,
                image_text=CASE WHEN items.image_name = excluded.image_name THEN items.image_text END,
                fast_image_text=CASE WHEN items.image_name = excluded.image_name THEN items.fast_image_text END,
                image_name=excluded.image_name, thumbnail_name=excluded.thumbnail_name,
                summary=excluded.summary, payload=excluded.payload
            """, [.text(item.id.uuidString), .text(item.fingerprint), .text(item.kind.rawValue), .text(item.title), .text(item.content),
                  .text(item.source.name), .text(item.source.bundleIdentifier ?? ""), .real(item.copiedAt.timeIntervalSinceReferenceDate),
                  .integer(position), .integer(item.hasImagePreview ? 1 : 0), .integer(item.textByteCount), .integer(item.imageByteCount),
                  .text(item.image?.fileName ?? ""), .text(item.image?.thumbnailName ?? ""),
                  .blob(try encoder.encode(summary)), .blob(try encoder.encode(item)), .integer(item.isPinned ? 1 : 0)])
    }

    private func enforceLimits(in database: ClipboardDatabase) throws {
        guard let retention = try settings(in: database).retention else { return }
        try delete(retentionPlan(retention, in: database, now: Date()), in: database)
    }

    private func unavailableFileIDs(in database: ClipboardDatabase, includingPinned: Bool) throws -> Set<String> {
        var ids: Set<String> = []
        let condition = includingPinned ? "" : " AND is_pinned = 0"
        try database.query("SELECT payload FROM items WHERE kind = ?" + condition, [.text(ClipboardKind.file.rawValue)]) {
            let item = try JSONDecoder().decode(ClipboardItem.self, from: ClipboardDatabase.data($0, 0))
            if !ClipboardFileAccess.areAvailable(item.files) { ids.insert(item.id.uuidString) }
        }
        return ids
    }

    func previewRetention(_ retention: ClipboardRetention, now: Date = Date()) throws -> ClipboardRetentionPlan {
        guard retention.isValid else { throw ClipboardStorageError.invalidRetention }
        return try retentionPlan(retention, in: openDatabase(), now: now)
    }

    // The preview is checked again inside the same transaction that saves settings and deletes rows.
    // Even a different set of victims with the same count and size requires another confirmation.
    func applyRetention(_ retention: ClipboardRetention, confirmed: ClipboardRetentionPlan? = nil,
                        now: Date = Date()) throws -> ClipboardRetentionResult {
        guard retention.isValid else { throw ClipboardStorageError.invalidRetention }
        let database = try openDatabase()
        var result = ClipboardRetentionResult.applied
        try database.transaction {
            let plan = try retentionPlan(retention, in: database, now: now)
            if plan.count > 0, plan != confirmed {
                result = .confirmationRequired(plan)
                return
            }
            var history = try settings(in: database)
            history.retention = retention
            try writeSettings(history, in: database)
            try delete(plan, in: database)
        }
        if case .applied = result { try didCommit(in: database) }
        return result
    }

    private func retentionPlan(_ retention: ClipboardRetention, in database: ClipboardDatabase,
                               now: Date) throws -> ClipboardRetentionPlan {
        var entries: [ClipboardRetentionEntry] = []
        try database.query("""
            SELECT id, copied_at, text_bytes, image_bytes,
                length(payload) + length(summary) + length(CAST(content AS BLOB))
                + length(CAST(title AS BLOB)) + length(CAST(source_name AS BLOB))
                + length(CAST(source_bundle AS BLOB)) + length(CAST(fingerprint AS BLOB)),
                image_name, thumbnail_name, is_pinned, fingerprint
            FROM items ORDER BY copied_at DESC, position DESC, id
            """) { row in
            entries.append(ClipboardRetentionEntry(
                id: ClipboardDatabase.text(row, 0), copiedAt: Date(timeIntervalSinceReferenceDate: ClipboardDatabase.real(row, 1)),
                textBytes: ClipboardDatabase.int(row, 2), imageBytes: ClipboardDatabase.int(row, 3),
                recordBytes: ClipboardDatabase.int(row, 4), imageName: ClipboardDatabase.text(row, 5),
                thumbnailName: ClipboardDatabase.text(row, 6), isPinned: ClipboardDatabase.int(row, 7) != 0,
                snapshotName: ClipboardPasteboardSnapshot.storageName(for: ClipboardDatabase.text(row, 8))))
        }
        let cutoff = retention.maximumAgeDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        var remainingText = retention.maximumTextBytes ?? Int.max
        var remainingImages = retention.maximumImageBytes ?? Int.max
        var remainingItems = retention.maximumItems ?? Int.max
        var textExceeded = false
        var imagesExceeded = false
        var deleted: [ClipboardRetentionEntry] = []
        var survivingImages: Set<String> = []
        for entry in entries {
            var remove = false
            if !entry.isPinned {
                remove = cutoff.map { entry.copiedAt < $0 } ?? false
                if !remove, entry.textBytes > 0 {
                    textExceeded = textExceeded || entry.textBytes > remainingText
                    remove = textExceeded
                    if !remove { remainingText -= entry.textBytes }
                }
                if !remove, entry.imageBytes > 0 {
                    imagesExceeded = imagesExceeded || entry.imageBytes > remainingImages
                    remove = imagesExceeded
                    if !remove { remainingImages -= entry.imageBytes }
                }
                if !remove {
                    remove = remainingItems == 0
                    if !remove { remainingItems -= 1 }
                }
            }
            if remove { deleted.append(entry) }
            else { survivingImages.formUnion(entry.mediaNames) }
        }
        // Database records contain bookmarks and metadata, never the referenced original file bytes.
        // Shared or in-flight image files will not be released by this cleanup.
        let pending = pendingImages.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        var countedImages = survivingImages.union(pending)
        var bytes = 0
        for entry in deleted {
            bytes += entry.recordBytes
            for name in entry.mediaNames where isManagedImageName(name) {
                if countedImages.insert(name).inserted,
                   let size = try? mediaDirectory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    bytes += size
                }
            }
        }
        return ClipboardRetentionPlan(settings: retention, entries: deleted, estimatedBytes: bytes)
    }

    private func delete(_ plan: ClipboardRetentionPlan, in database: ClipboardDatabase) throws {
        for entry in plan.entries {
            try database.execute("DELETE FROM items WHERE id = ?", [.text(entry.id)])
        }
    }

    private func didCommit(in database: ClipboardDatabase) throws {
        var names: Set<String> = []
        try database.query("""
            SELECT image_name, thumbnail_name, fingerprint FROM items
            WHERE image_name != '' OR fingerprint LIKE 'snapshot:%'
            """) {
            let imageName = ClipboardDatabase.text($0, 0)
            if !imageName.isEmpty {
                names.insert(imageName)
                names.insert(ClipboardDatabase.text($0, 1))
            }
            if let snapshot = ClipboardPasteboardSnapshot.storageName(for: ClipboardDatabase.text($0, 2)) {
                names.insert(snapshot)
            }
        }
        committedImageNames = names
        try cleanImages()
        // Reclaim substantial free space without compacting the database on every copy.
        let pageSize = try database.integer("PRAGMA page_size")
        let freePages = try database.integer("PRAGMA freelist_count")
        let totalPages = try database.integer("PRAGMA page_count")
        if freePages > 0, freePages >= totalPages / 4, freePages * pageSize >= 4 * ClipboardRetention.mebibyte {
            try database.execute("VACUUM")
        }
    }

    func importSnapshot(_ original: ClipboardPasteboardSnapshot, source: ClipboardSource, at date: Date) throws -> ClipboardItem? {
        var snapshot = original
        let text = snapshot.items.map(ClipboardPasteboardSnapshot.readPlainText)
        let primaryImage = snapshot.items.indices.lazy.compactMap { index in
            let representations = snapshot.items[index]
            let preferred = [UTType.gif.identifier, UTType.png.identifier]
            let imageIndex = preferred.lazy.compactMap { type in
                representations.firstIndex { $0.type == type }
            }.first ?? representations.firstIndex(where: \.isImage)
            return imageIndex.map { (index, $0) }
        }.first
        var item: ClipboardItem
        if let (itemIndex, representationIndex) = primaryImage {
            let representation = snapshot.items[itemIndex][representationIndex]
            guard let data = representation.data else { throw ClipboardStorageError.invalidImage }
            item = try importImage(data, source: source, at: date)
            let storedType: UTType = item.image?.isGIF == true ? .gif : .png
            if representation.type == storedType.identifier, item.fingerprint == "image:" + ClipboardItem.digest(data) {
                if snapshot.items.count == 1, snapshot.items[0].count == 1 { return item }
                snapshot.items[itemIndex][representationIndex].data = nil
            }
        } else {
            let urls = snapshot.items.map(ClipboardPasteboardSnapshot.readURL)
            let content = zip(urls, text).compactMap { $0 ?? $1 }.joined(separator: "\n")
            guard content.prefix(ClipboardLimits.textCharacters + 1).count <= ClipboardLimits.textCharacters else {
                throw ClipboardStorageError.largeText
            }
            let hasText = content.contains { !$0.isWhitespace }
            if snapshot.items.count == 1, snapshot.items[0].map(\.pasteboardType) == [.string] {
                return hasText ? .text(content, source: source, at: date) : nil
            }
            let types = Set(snapshot.items.flatMap { $0.map(\.pasteboardType) })
            guard hasText || types.contains(.html) || types.contains(.rtf) else { return nil }
            item = .text(content, source: source, at: date)
            if snapshot.items.count == 1, let url = urls[0] {
                item.kind = .link
                let label = ClipboardPasteboardSnapshot.readString(ClipboardPasteboardSnapshot.urlName, in: snapshot.items[0])
                    ?? text[0] ?? url
                item.title = String((label.isEmpty ? url : label).prefix(120))
            } else if !hasText {
                item.title = types.contains(.html) ? "HTML" : "RTF"
            }
        }
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(snapshot)
            let fingerprint = snapshot.fingerprint(primaryImageName: item.image?.fileName)
            guard let name = ClipboardPasteboardSnapshot.storageName(for: fingerprint) else {
                throw ClipboardStorageError.invalidHistory
            }
            let representations = snapshot.items.flatMap { $0 }
            let imageBytes = representations.filter(\.isImage).reduce(0) { $0 + ($1.data?.count ?? 0) }
            let textBytes = representations.filter { !$0.isImage }.reduce(0) { $0 + ($1.data?.count ?? 0) }
            let overhead = max(0, data.count - imageBytes - textBytes)
            item.fingerprint = fingerprint
            item.snapshot = ClipboardSnapshotInfo(formats: snapshot.availableFormats(plainText: text),
                textBytes: textBytes + (item.image == nil ? overhead : 0),
                imageBytes: imageBytes + (item.image == nil ? 0 : overhead),
                imageCount: snapshot.items.filter { $0.contains(where: \.isImage) }.count)
            try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            try data.write(to: mediaDirectory.appendingPathComponent(name), options: .atomic)
            pendingImages[item.id, default: []].insert(name)
            return item
        } catch {
            try discardImportedImage(item)
            throw error
        }
    }

    func loadRepresentations(for item: ClipboardItem, format: ClipboardPasteFormat?) throws
        -> [[ClipboardPasteboardSnapshot.Representation]] {
        guard let info = item.snapshot,
              let name = ClipboardPasteboardSnapshot.storageName(for: item.fingerprint) else {
            throw ClipboardStorageError.missingSnapshot
        }
        if let format, !info.formats.contains(format) { throw ClipboardStorageError.unavailablePasteFormat }
        let url = mediaDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ClipboardStorageError.missingSnapshot }
        let snapshot = try PropertyListDecoder().decode(ClipboardPasteboardSnapshot.self, from: Data(contentsOf: url))
        var convertedImageBytes = 0
        return try snapshot.items.map { representations in
            switch format {
            case .plainText:
                guard let text = ClipboardPasteboardSnapshot.readPlainText(in: representations) else {
                    throw ClipboardStorageError.unavailablePasteFormat
                }
                return [.init(.string, data: Data(text.utf8))]
            case .html: return representations.filter { $0.pasteboardType == .html }
            case .rtf: return representations.filter { $0.pasteboardType == .rtf }
            case .url:
                guard let url = ClipboardPasteboardSnapshot.readURL(in: representations) else {
                    throw ClipboardStorageError.unavailablePasteFormat
                }
                let link = representations.filter { [.URL, ClipboardPasteboardSnapshot.urlName].contains($0.pasteboardType) }
                return link + [.init(.string, data: Data(url.utf8))]
            case .png:
                guard let data = representations.first(where: { $0.pasteboardType == .tiff })?.data else {
                    throw ClipboardStorageError.unavailablePasteFormat
                }
                let (_, image) = try decodeImage(data)
                let png = try encodePNG(image)
                convertedImageBytes += png.count
                guard convertedImageBytes <= ClipboardLimits.imageBytes else { throw ClipboardStorageError.largeImage }
                return [.init(.png, data: png)]
            case nil:
                return try representations.map { representation in
                    guard representation.data == nil else { return representation }
                    guard let image = item.image else { throw ClipboardStorageError.missingImage }
                    return .init(representation.pasteboardType, data: try imageData(image))
                }
            }
        }
    }

    func importImage(_ data: Data, source: ClipboardSource, at date: Date) throws -> ClipboardItem {
        let (imageSource, image) = try decodeImage(data)
        let type = CGImageSourceGetType(imageSource) as String?
        let isGIF = type == UTType.gif.identifier
        let original = isGIF || type == UTType.png.identifier ? data : try encodePNG(image)
        guard original.count <= ClipboardLimits.imageBytes else { throw ClipboardStorageError.largeImage }

        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 480,
                                      kCGImageSourceCreateThumbnailWithTransform: true]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
        else { throw ClipboardStorageError.invalidImage }
        let thumbnailData = try encodePNG(thumbnail)

        let hash = ClipboardItem.digest(original)
        let payload = ClipboardImage(fileName: hash + (isGIF ? ".gif" : ".png"), thumbnailName: hash + ".thumb.png",
                                     byteCount: original.count, thumbnailByteCount: thumbnailData.count, width: image.width, height: image.height)
        if FileManager.default.fileExists(atPath: databaseURL.path),
           let budget = try settings(in: openDatabase()).retention?.maximumImageBytes,
           payload.byteCount + payload.thumbnailByteCount > budget {
            throw ClipboardStorageError.imageBudget
        }
        let item = ClipboardItem(kind: .image, title: "Image · \(image.width) × \(image.height)", content: "\(image.width) × \(image.height)",
                                 source: source, copiedAt: date, fingerprint: "image:" + hash, image: payload)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try original.write(to: mediaDirectory.appendingPathComponent(payload.fileName), options: .atomic)
        try thumbnailData.write(to: mediaDirectory.appendingPathComponent(payload.thumbnailName), options: .atomic)
        pendingImages[item.id] = [payload.fileName, payload.thumbnailName]
        return item
    }

    private func decodeImage(_ data: Data) throws -> (CGImageSource, CGImage) {
        guard data.count <= ClipboardLimits.imageBytes else { throw ClipboardStorageError.largeImage }
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let (width, height) = imageDimensions(imageSource) else { throw ClipboardStorageError.invalidImage }
        guard width <= ClipboardLimits.imagePixels / height else { throw ClipboardStorageError.largeImage }
        let fullSizeOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                              kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                                              kCGImageSourceCreateThumbnailWithTransform: true,
                                              kCGImageSourceShouldCache: false]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, fullSizeOptions as CFDictionary)
        else { throw ClipboardStorageError.invalidImage }
        return (imageSource, image)
    }

    private func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw ClipboardStorageError.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ClipboardStorageError.invalidImage }
        return data as Data
    }

    func imageData(_ image: ClipboardImage, thumbnail: Bool = false) throws -> Data {
        guard validImageNames(image) else { throw ClipboardStorageError.invalidHistory }
        let url = mediaDirectory.appendingPathComponent(thumbnail ? image.thumbnailName : image.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ClipboardStorageError.missingImage }
        return try Data(contentsOf: url)
    }

    func previewImage(_ image: ClipboardImage, thumbnail: Bool = false) throws -> CGImage {
        guard validImageNames(image) else { throw ClipboardStorageError.invalidHistory }
        let url = mediaDirectory.appendingPathComponent(thumbnail ? image.thumbnailName : image.fileName)
        return try previewImage(at: url, maxPixelSize: thumbnail ? 480 : 1_600)
    }

    func previewImageFile(_ file: ClipboardFile, thumbnail: Bool = false) throws
        -> (image: CGImage, file: ClipboardFile, animatedData: Data?) {
        try ClipboardFileAccess.withResolvedFiles([file]) { urls, updated in
            let url = urls[0]
            let image = try previewImage(at: url, maxPixelSize: thumbnail ? 480 : 1_600)
            let animatedData = thumbnail ? nil : (try? animatedGIFData(at: url))
            return (image, updated[0], animatedData)
        }
    }

    private func animatedGIFData(at url: URL) throws -> Data? {
        guard url.pathExtension.lowercased() == "gif" else { return nil }
        let resources = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resources.isRegularFile == true, let size = resources.fileSize, size <= ClipboardLimits.imageBytes else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: ClipboardLimits.imageBytes + 1),
              data.count <= ClipboardLimits.imageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier,
              CGImageSourceGetCount(source) > 1,
              let (width, height) = imageDimensions(source), width <= ClipboardLimits.imagePixels / height
        else { return nil }
        return data
    }

    private func imageDimensions(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private func previewImage(at url: URL, maxPixelSize: Int) throws -> CGImage {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ClipboardStorageError.missingImage }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ClipboardStorageError.invalidImage }
        return preview
    }

    func hasImage(_ image: ClipboardImage) -> Bool {
        validImageNames(image) && FileManager.default.isReadableFile(atPath: mediaDirectory.appendingPathComponent(image.fileName).path)
    }

    func discardImportedImage(_ item: ClipboardItem) throws {
        pendingImages[item.id] = nil
        try cleanImages()
    }

    private func cleanImages() throws {
        guard FileManager.default.fileExists(atPath: mediaDirectory.path) else { return }
        let names = committedImageNames.union(pendingImages.values.reduce(into: Set<String>()) { $0.formUnion($1) })
        for file in try FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil) {
            // Only remove files owned by this storage format.
            if isManagedImageName(file.lastPathComponent), !names.contains(file.lastPathComponent) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    private func validImageNames(_ image: ClipboardImage) -> Bool {
        image.fileName.range(of: #"\A[a-f0-9]{64}\.(?:gif|png)\z"#, options: .regularExpression) != nil
            && image.thumbnailName == image.fileName.dropLast(4) + ".thumb.png"
    }

    private func isManagedImageName(_ name: String) -> Bool {
        name.range(of: #"\A[a-f0-9]{64}\.(?:gif|png|thumb\.png|pasteboard)\z"#, options: .regularExpression) != nil
    }
}
