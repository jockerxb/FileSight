import Foundation
import CSQLite
import Darwin

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct DatabaseSearchResult {
    public let rows: [FileEntry]
    public let hasMore: Bool
    public let milliseconds: Double
}

public enum IndexDatabaseError: LocalizedError {
    case sqlite(String)
    public var errorDescription: String? {
        switch self { case .sqlite(let message): "本地索引错误：\(message)" }
    }
}

/// Local-only metadata database. File contents are never read or stored.
public final class IndexDatabase {
    private enum Bind { case text(String), double(Double), int(Int64) }
    private static let schemaVersion = 3
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var cachedStatements: [String: OpaquePointer] = [:]
    private var storedCount = 0
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法创建数据库"
            if let database { sqlite3_close(database) }
            throw IndexDatabaseError.sqlite(message)
        }
        handle = database
        do {
            let collation = sqlite3_create_collation_v2(database, "FILESIGHT_NAME", SQLITE_UTF8, nil, { _, leftCount, leftBytes, rightCount, rightBytes in
                guard let leftBytes, let rightBytes else { return leftBytes == nil ? (rightBytes == nil ? 0 : -1) : 1 }
                let left = UnsafeRawBufferPointer(start: leftBytes, count: Int(leftCount)).bindMemory(to: UInt8.self)
                let right = UnsafeRawBufferPointer(start: rightBytes, count: Int(rightCount)).bindMemory(to: UInt8.self)
                switch String(decoding: left, as: UTF8.self).compare(String(decoding: right, as: UTF8.self), options: .numeric) {
                case .orderedAscending: return -1
                case .orderedDescending: return 1
                case .orderedSame: return 0
                }
            }, nil)
            guard collation == SQLITE_OK else { throw IndexDatabaseError.sqlite("无法注册文件名排序规则") }
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA temp_store=MEMORY")
            try execute("PRAGMA busy_timeout=2000")
            try ensureSchema()
            storedCount = try scalarInt("SELECT COUNT(*) FROM files")
            Self.protectFiles(at: url)
        } catch {
            sqlite3_close(database); handle = nil
            throw error
        }
    }

    deinit {
        for statement in cachedStatements.values { sqlite3_finalize(statement) }
        if let handle { sqlite3_close(handle) }
    }

    public static func openRecovering(url: URL) throws -> IndexDatabase {
        do { return try IndexDatabase(url: url) }
        catch {
            for path in [url.path, url.path + "-wal", url.path + "-shm"] { try? FileManager.default.removeItem(atPath: path) }
            return try IndexDatabase(url: url)
        }
    }
    public var fileCount: Int { lock.lock(); defer { lock.unlock() }; return storedCount }
    public var storageBytes: Int64 {
        [url.path, url.path + "-wal", url.path + "-shm"].reduce(0) { total, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    /// Returns true only for a completed cache belonging to exactly these roots.
    public func prepare(roots: [ScanRoot], forceRebuild: Bool = false) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let expected = roots.sorted { $0.path < $1.path }.map {
            ($0.path, Int64($0.identity?.device ?? 0), String($0.identity?.inode ?? 0))
        }
        var actual: [(String, Int64, String)] = []
        try rows("SELECT path,device,inode FROM roots ORDER BY path") { statement in
            actual.append((columnText(statement, 0), sqlite3_column_int64(statement, 1), columnText(statement, 2)))
        }
        let same = actual.count == expected.count && zip(actual, expected).allSatisfy {
            $0.0.0 == $0.1.0 && $0.0.1 == $0.1.1 && $0.0.2 == $0.1.2
        }
        let complete = try meta("complete") == "1"
        if forceRebuild || !same || !complete {
            try transaction {
                try clearDataLocked()
                for root in expected {
                    try run("INSERT INTO roots(path,device,inode) VALUES(?,?,?)",
                            [.text(root.0), .int(root.1), .text(root.2)])
                }
            }
            storedCount = 0
            Self.protectFiles(at: url)
            return false
        }
        return true
    }

    public var checkpoint: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return UInt64((try? meta("checkpoint")) ?? "0") ?? 0
    }

    public func finishUpdate(checkpoint: UInt64, complete: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try transaction {
            try setMeta("checkpoint", String(checkpoint))
            if complete { try setMeta("complete", "1") }
        }
        Self.protectFiles(at: url)
    }

    /// A failed database write means the persisted snapshot and the event
    /// checkpoint no longer describe the same filesystem state. Keep the old
    /// checkpoint and force a clean rebuild on the next launch.
    public func invalidateCache() throws {
        lock.lock(); defer { lock.unlock() }
        try transaction { try setMeta("complete", "0") }
    }

    public func clearAll() throws {
        lock.lock(); defer { lock.unlock() }
        try transaction { try clearDataLocked() }
        storedCount = 0
    }

    /// Replaces one directory listing and atomically removes vanished subtrees.
    func replaceDirectory(path: String, entries: [FileEntry], children: [String: DirectoryIdentity]) throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var previous: [String: String] = [:]
        try rows("SELECT path,device,inode FROM directories WHERE parent=?", [.text(path)]) { statement in
            previous[columnText(statement, 0)] = "\(sqlite3_column_int64(statement, 1)):\(columnText(statement, 2))"
        }
        let vanished = previous.compactMap { child, inode in
            children[child].map { "\($0.device):\($0.inode)" } == inode ? nil : child
        }
        let changed = Set(children.compactMap { child, identity in
            previous[child] == "\(identity.device):\(identity.inode)" ? nil : child
        })
        var removed = 0
        try transaction {
            for child in vanished { removed += try deleteSubtree(child) }
            try run("DELETE FROM files WHERE scan_dir=?", [.text(path)])
            removed += Int(sqlite3_changes(handle))
            try run("DELETE FROM directories WHERE parent=?", [.text(path)])
            for (child, identity) in children {
                try run("INSERT INTO directories(path,parent,device,inode) VALUES(?,?,?,?)",
                        [.text(child), .text(path), .int(Int64(identity.device)), .text(String(identity.inode))])
            }
            for entry in entries { try insert(entry, scanDirectory: path) }
        }
        storedCount += entries.count - removed
        Self.protectFiles(at: url)
        return changed
    }

    public func search(parsed: ParsedSearchQuery, order: SearchOrder, ascending: Bool, limit: Int,
                       cancellation: SearchCancellation = SearchCancellation()) throws -> DatabaseSearchResult? {
        let started = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        guard !cancellation.cancelled else { return nil }
        let plan = queryPlan(parsed: parsed)
        var binds = plan.binds
        let orderSQL = ordering(parsed: parsed, order: order, ascending: ascending, binds: &binds)
        binds.append(.int(Int64(limit + 1)))
        let sql = plan.prefix + "SELECT f.path,f.modified,f.created,f.kind,f.name_norm,f.phonetic,f.search_text " +
            plan.from + plan.whereSQL + orderSQL + " LIMIT ?"
        var found: [FileEntry] = []
        try withCancellation(cancellation) {
            try rows(sql, binds) { statement in
                found.append(FileEntry(path: columnText(statement, 0),
                                       modified: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                                       created: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                                       kind: columnText(statement, 3), searchableName: columnText(statement, 4),
                                       searchablePhonetic: columnText(statement, 5), searchableText: columnText(statement, 6)))
            }
        }
        guard !cancellation.cancelled else { return nil }
        let more = found.count > limit
        if more { found.removeLast(found.count - limit) }
        return DatabaseSearchResult(rows: found, hasMore: more,
                                    milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }

    public func count(parsed: ParsedSearchQuery, cancellation: SearchCancellation = SearchCancellation()) throws -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !cancellation.cancelled else { return nil }
        let plan = queryPlan(parsed: parsed)
        var value = 0
        try withCancellation(cancellation) {
            value = try scalarInt(plan.prefix + "SELECT COUNT(*) " + plan.from + plan.whereSQL, plan.binds)
        }
        return cancellation.cancelled ? nil : value
    }

    private struct QueryPlan { let prefix: String; let from: String; let whereSQL: String; let binds: [Bind] }

    private func queryPlan(parsed: ParsedSearchQuery) -> QueryPlan {
        let normalized = FileEntry.normalize(parsed.text.trimmingCharacters(in: .whitespacesAndNewlines))
        let tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var selects: [String] = [], binds: [Bind] = []
        for token in tokens {
            if token.count <= 2 {
                selects.append("SELECT file_id AS id FROM short_tokens WHERE token=?")
                binds.append(.text(token))
            } else {
                selects.append("SELECT rowid AS id FROM file_fts WHERE file_fts MATCH ?")
                binds.append(.text("\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""))
            }
        }
        let prefix = selects.isEmpty ? "" : "WITH candidates(id) AS (" + selects.joined(separator: " INTERSECT ") + ") "
        let from = selects.isEmpty ? "FROM files f " : "FROM files f JOIN candidates c ON c.id=f.id "
        var clauses: [String] = []
        if !parsed.categories.isEmpty {
            let kinds = Set(parsed.categories.flatMap(\.indexedKinds))
            clauses.append("f.kind IN (" + Array(repeating: "?", count: kinds.count).joined(separator: ",") + ")")
            binds.append(contentsOf: kinds.sorted().map(Bind.text))
        }
        if let date = parsed.date {
            let column = date.basis == .modified ? "f.modified" : "f.created"
            clauses.append("\(column)>=? AND \(column)<?")
            binds.append(.double(date.start.timeIntervalSince1970)); binds.append(.double(date.end.timeIntervalSince1970))
        }
        return QueryPlan(prefix: prefix, from: from,
                         whereSQL: clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ") + " ", binds: binds)
    }

    private func ordering(parsed: ParsedSearchQuery, order: SearchOrder, ascending: Bool, binds: inout [Bind]) -> String {
        let direction = ascending ? "ASC" : "DESC"
        switch order {
        case .relevance:
            let needle = FileEntry.normalize(parsed.text.trimmingCharacters(in: .whitespacesAndNewlines))
            if needle.isEmpty { return "ORDER BY f.modified DESC,f.name_norm COLLATE FILESIGHT_NAME ASC,f.path ASC" }
            binds.append(.text(needle)); binds.append(.text(needle)); binds.append(.text(escapedLike(needle) + "%")); binds.append(.text("%" + escapedLike(needle) + "%"))
            return "ORDER BY CASE WHEN f.name_norm=? OR f.stem_norm=? THEN 0 WHEN f.name_norm LIKE ? ESCAPE '\\' THEN 1 " +
                "WHEN f.name_norm LIKE ? ESCAPE '\\' THEN 2 ELSE 3 END,f.modified DESC,f.name_norm COLLATE FILESIGHT_NAME ASC,f.path ASC"
        case .modified: return "ORDER BY f.modified \(direction),f.name_norm COLLATE FILESIGHT_NAME ASC,f.path ASC"
        case .created: return "ORDER BY f.created \(direction),f.name_norm COLLATE FILESIGHT_NAME ASC,f.path ASC"
        case .kind: return "ORDER BY f.kind \(direction),f.modified DESC,f.name_norm COLLATE FILESIGHT_NAME ASC,f.path ASC"
        case .name: return "ORDER BY f.name_norm COLLATE FILESIGHT_NAME \(direction),f.path ASC"
        }
    }

    private func insert(_ entry: FileEntry, scanDirectory: String) throws {
        let stem = FileEntry.normalize((entry.name as NSString).deletingPathExtension)
        try run("INSERT INTO files(path,scan_dir,name,name_norm,stem_norm,phonetic,search_text,kind,modified,created) VALUES(?,?,?,?,?,?,?,?,?,?)",
                [.text(entry.path), .text(scanDirectory), .text(entry.name), .text(entry.searchableName),
                 .text(stem), .text(entry.searchablePhonetic), .text(entry.searchableText), .text(entry.kind),
                 .double(entry.modified.timeIntervalSince1970), .double(entry.created.timeIntervalSince1970)])
        let identifier = sqlite3_last_insert_rowid(handle)
        for token in Self.shortTokens(entry.searchableText) {
            try run("INSERT OR IGNORE INTO short_tokens(token,file_id) VALUES(?,?)", [.text(token), .int(identifier)])
        }
    }

    private static func shortTokens(_ text: String) -> Set<String> {
        var result = Set<String>()
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let characters = Array(word)
            for index in characters.indices {
                result.insert(String(characters[index]))
                if index + 1 < characters.count { result.insert(String(characters[index...index + 1])) }
            }
        }
        return result
    }

    private func deleteSubtree(_ path: String) throws -> Int {
        let prefix = escapedLike(path) + "/%"
        try run("DELETE FROM files WHERE path=? OR path LIKE ? ESCAPE '\\'", [.text(path), .text(prefix)])
        let removed = Int(sqlite3_changes(handle))
        try run("DELETE FROM directories WHERE path=? OR path LIKE ? ESCAPE '\\'", [.text(path), .text(prefix)])
        return removed
    }

    private func ensureSchema() throws {
        let version = try scalarInt("PRAGMA user_version")
        if version != Self.schemaVersion {
            try execute("DROP TABLE IF EXISTS short_tokens; DROP TABLE IF EXISTS file_fts; DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS directories; DROP TABLE IF EXISTS roots; DROP TABLE IF EXISTS meta")
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS roots(path TEXT PRIMARY KEY,device INTEGER NOT NULL,inode TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS directories(path TEXT PRIMARY KEY,parent TEXT NOT NULL,device INTEGER NOT NULL,inode TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS directories_parent ON directories(parent);
            CREATE TABLE IF NOT EXISTS files(
              id INTEGER PRIMARY KEY,path TEXT NOT NULL UNIQUE,scan_dir TEXT NOT NULL,name TEXT NOT NULL,
              name_norm TEXT NOT NULL,stem_norm TEXT NOT NULL,phonetic TEXT NOT NULL,search_text TEXT NOT NULL,kind TEXT NOT NULL,
              modified REAL NOT NULL,created REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS files_scan_dir ON files(scan_dir);
            CREATE INDEX IF NOT EXISTS files_kind_modified ON files(kind,modified DESC);
            CREATE INDEX IF NOT EXISTS files_modified ON files(modified DESC);
            CREATE INDEX IF NOT EXISTS files_created ON files(created DESC);
            CREATE INDEX IF NOT EXISTS files_name ON files(name_norm);
            CREATE INDEX IF NOT EXISTS files_stem ON files(stem_norm);
            CREATE VIRTUAL TABLE IF NOT EXISTS file_fts USING fts5(search_text,content='files',content_rowid='id',tokenize='trigram');
            CREATE TABLE IF NOT EXISTS short_tokens(token TEXT NOT NULL,file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,PRIMARY KEY(token,file_id)) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS short_tokens_file ON short_tokens(file_id);
            CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
              INSERT INTO file_fts(rowid,search_text) VALUES(new.id,new.search_text);
            END;
            CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
              INSERT INTO file_fts(file_fts,rowid,search_text) VALUES('delete',old.id,old.search_text);
            END;
            CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE ON files BEGIN
              INSERT INTO file_fts(file_fts,rowid,search_text) VALUES('delete',old.id,old.search_text);
              INSERT INTO file_fts(rowid,search_text) VALUES(new.id,new.search_text);
            END;
            PRAGMA user_version=3;
            """)
        if try meta("complete") == nil { try setMeta("complete", "0") }
        if try meta("checkpoint") == nil { try setMeta("checkpoint", "0") }
    }

    private func clearDataLocked() throws {
        try execute("DELETE FROM short_tokens; DELETE FROM files; DELETE FROM directories; DELETE FROM roots")
        try setMeta("complete", "0"); try setMeta("checkpoint", "0")
    }

    private func meta(_ key: String) throws -> String? {
        var result: String?
        try rows("SELECT value FROM meta WHERE key=?", [.text(key)]) { result = columnText($0, 0) }
        return result
    }
    private func setMeta(_ key: String, _ value: String) throws {
        try run("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func withCancellation<T>(_ cancellation: SearchCancellation, _ body: () throws -> T) throws -> T {
        sqlite3_progress_handler(handle, 1000, { context in
            guard let context else { return 0 }
            return Unmanaged<SearchCancellation>.fromOpaque(context).takeUnretainedValue().cancelled ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque())
        defer { sqlite3_progress_handler(handle, 0, nil, nil) }
        return try body()
    }

    private func scalarInt(_ sql: String, _ binds: [Bind] = []) throws -> Int {
        var result = 0
        try rows(sql, binds) { result = Int(sqlite3_column_int64($0, 0)) }
        return result
    }

    private func rows(_ sql: String, _ binds: [Bind] = [], row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement)
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW { try row(statement) }
            else if code == SQLITE_DONE { return }
            else if code == SQLITE_INTERRUPT { return }
            else { throw failure() }
        }
    }

    private func run(_ sql: String, _ binds: [Bind] = []) throws {
        let statement: OpaquePointer
        if let cached = cachedStatements[sql] {
            statement = cached
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure() }
            cachedStatements[sql] = prepared; statement = prepared
        }
        try bind(binds, to: statement)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw failure() }
    }

    private func bind(_ values: [Bind], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), code: Int32
            switch value {
            case .text(let text): code = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case .double(let value): code = sqlite3_bind_double(statement, index, value)
            case .int(let value): code = sqlite3_bind_int64(statement, index, value)
            }
            if code != SQLITE_OK { throw failure() }
        }
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &message)
        guard code == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(message); throw IndexDatabaseError.sqlite(text)
        }
    }

    private func failure() -> IndexDatabaseError { .sqlite(String(cString: sqlite3_errmsg(handle))) }
    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }
    private func escapedLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
    private static func protectFiles(at url: URL) {
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            _ = chmod(path, S_IRUSR | S_IWUSR)
        }
    }
}
