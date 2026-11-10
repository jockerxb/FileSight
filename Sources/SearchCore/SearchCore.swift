import Foundation
import Darwin
import CoreServices

public struct FileEntry: Equatable, Codable {
    public let path: String
    public let name: String
    public let modified: Date
    public let created: Date
    public let kind: String
    public let searchableName: String
    public let searchablePhonetic: String
    public let searchableText: String

    public init(url: URL, values: URLResourceValues) {
        path = url.path
        name = url.lastPathComponent
        modified = values.contentModificationDate ?? .distantPast
        created = values.creationDate ?? .distantPast
        kind = values.isDirectory == true ? "文件夹" : (url.pathExtension.isEmpty ? "无扩展名" : url.pathExtension.lowercased())
        searchableName = Self.normalize(name)
        searchablePhonetic = Self.phoneticText(name)
        searchableText = [searchableName, searchablePhonetic].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public init(path: String, modified: Date, created: Date, kind: String) {
        self.path = path
        self.name = URL(fileURLWithPath: path).lastPathComponent
        self.modified = modified
        self.created = created
        self.kind = kind.lowercased()
        self.searchableName = Self.normalize(name)
        self.searchablePhonetic = Self.phoneticText(name)
        self.searchableText = [searchableName, searchablePhonetic].filter { !$0.isEmpty }.joined(separator: " ")
    }

    init(path: String, modified: Date, created: Date, kind: String, searchableName: String,
         searchablePhonetic: String, searchableText: String) {
        self.path = path
        self.name = URL(fileURLWithPath: path).lastPathComponent
        self.modified = modified
        self.created = created
        self.kind = kind
        self.searchableName = searchableName
        self.searchablePhonetic = searchablePhonetic
        self.searchableText = searchableText
    }

    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Original text plus compact Pinyin and Pinyin initials. Only CJK
    /// characters are transliterated; ordinary Latin filenames keep their
    /// existing deterministic matching behavior.
    public static func searchText(_ text: String) -> String {
        let original = normalize(text)
        let phonetic = phoneticText(text)
        return [original, phonetic].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func phoneticText(_ text: String) -> String {
        var syllables: [String] = []
        for character in text {
            guard let scalar = character.unicodeScalars.first(where: isCJK) else { continue }
            let syllable = PinyinCache.value(for: scalar)
            if !syllable.isEmpty { syllables.append(syllable) }
        }
        guard !syllables.isEmpty else { return "" }
        let compact = syllables.joined()
        let initials = syllables.compactMap(\.first).map(String.init).joined()
        return [compact, initials].joined(separator: " ")
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x9FFF, 0x20000...0x2FA1F: true
        default: false
        }
    }

    private enum PinyinCache {
        static let lock = NSLock()
        nonisolated(unsafe) static var values: [UnicodeScalar: String] = [:]

        static func value(for scalar: UnicodeScalar) -> String {
            lock.lock()
            if let cached = values[scalar] { lock.unlock(); return cached }
            lock.unlock()
            let latin = String(scalar).applyingTransform(.toLatin, reverse: false) ?? ""
            let normalized = FileEntry.normalize(latin)
            let ascii = normalized.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
            let result = String(String.UnicodeScalarView(ascii))
            lock.lock(); values[scalar] = result; lock.unlock()
            return result
        }
    }

    private enum CodingKeys: String, CodingKey { case path, name, modified, created, kind, searchableName, searchablePhonetic, searchableText }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? URL(fileURLWithPath: path).lastPathComponent
        modified = try values.decode(Date.self, forKey: .modified)
        created = try values.decode(Date.self, forKey: .created)
        kind = try values.decode(String.self, forKey: .kind)
        searchableName = try values.decodeIfPresent(String.self, forKey: .searchableName) ?? Self.normalize(name)
        searchablePhonetic = try values.decodeIfPresent(String.self, forKey: .searchablePhonetic) ?? Self.phoneticText(name)
        searchableText = try values.decodeIfPresent(String.self, forKey: .searchableText) ??
            [searchableName, searchablePhonetic].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(path, forKey: .path)
        try values.encode(name, forKey: .name)
        try values.encode(modified, forKey: .modified)
        try values.encode(created, forKey: .created)
        try values.encode(kind, forKey: .kind)
        try values.encode(searchableName, forKey: .searchableName)
        try values.encode(searchablePhonetic, forKey: .searchablePhonetic)
        try values.encode(searchableText, forKey: .searchableText)
    }
}

public enum SortField: Int { case modified, created, kind, name }

public enum FileSearch {
    public static func results(in entries: [FileEntry], query: String, sort: SortField, ascending: Bool) -> [FileEntry] {
        let needle = FileEntry.normalize(query)
        return entries.filter { needle.isEmpty || $0.searchableName.contains(needle) }.sorted { a, b in
            let order: ComparisonResult
            switch sort {
            case .modified: order = a.modified.compare(b.modified)
            case .created: order = a.created.compare(b.created)
            case .kind:
                let groupOrder = a.kind.localizedStandardCompare(b.kind)
                if groupOrder == .orderedSame && a.modified != b.modified { return a.modified > b.modified }
                order = groupOrder
            case .name: order = a.name.localizedStandardCompare(b.name)
            }
            if order == .orderedSame { return a.path < b.path }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

public struct ScanSnapshot {
    public let entries: [FileEntry]
    public let revision: Int
    public let scanning: Bool
    public let errorCount: Int
    public let errors: [String]
}

public struct IndexView {
    public let pages: [SearchPage]
    public var chunks: [[FileEntry]] { pages.map(\.entries) }
    public let revision: Int
    public let count: Int
    public let scanning: Bool
    public let rebuilding: Bool
    public let errorCount: Int
    public let errors: [String]
}

final class ScanToken {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

public final class FileIndex {
    private struct Record {
        let pages: [SearchPage]
        let count: Int
        let children: [String: DirectoryIdentity]
        let childPaths: Set<String>
        let errors: [String]
    }
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var cachedPages: [SearchPage] = []
    private var pagesDirty = false
    private var count = 0
    private var errorCount = 0
    private var revision = 0
    private var scanning = false
    private var watchFailed = false
    private var roots: [ScanRoot] = []
    private var dirty: Set<String> = []
    private var needsRebuild = false
    private var watcher: FolderEvents?
    private var token = ScanToken()
    private let workerURL: URL
    private let timeout: TimeInterval
    private let database: IndexDatabase?
    private var pendingEventID: UInt64 = 0
    private var databaseBuildInProgress = false
    private var databaseWriteFailed = false

    public init(workerURL: URL? = nil, timeout: TimeInterval = 15, database: IndexDatabase? = nil) {
        self.workerURL = workerURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("ScanWorker")
        self.timeout = timeout
        self.database = database
    }

    public func snapshot() -> ScanSnapshot {
        let current = view()
        return ScanSnapshot(entries: current.pages.flatMap(\.entries), revision: current.revision, scanning: current.scanning,
                            errorCount: current.errorCount, errors: current.errors)
    }

    public func view() -> IndexView {
        lock.lock(); defer { lock.unlock() }
        if pagesDirty {
            cachedPages = records.values.flatMap(\.pages)
            pagesDirty = false
        }
        var errors = watchFailed ? ["无法监听目录变化；可手动刷新索引。"] : []
        if errorCount > 0 {
            for record in records.values where !record.errors.isEmpty {
                errors.append(contentsOf: record.errors.prefix(200 - errors.count))
                if errors.count == 200 { break }
            }
        }
        let visibleCount = database?.fileCount ?? count
        return IndexView(pages: cachedPages, revision: revision, count: visibleCount, scanning: scanning,
                         rebuilding: databaseBuildInProgress,
                         errorCount: errorCount + (watchFailed ? 1 : 0), errors: errors)
    }

    // Entry point for unsandboxed scanner verification. The App uses the
    // authorized overload, carrying only grants explicitly picked by the user.
    public func start(roots: [URL], watch: Bool = false, forceRebuild: Bool = false) {
        start(authorizedRoots: Self.uniqueRoots(roots).map { ScanRoot(url: $0) }, watch: watch,
              forceRebuild: forceRebuild)
    }

    /// Stops live work without changing the durable database. Authorization
    /// changes decide separately whether cached metadata must be removed.
    public func stop() {
        lock.lock()
        token.cancel()
        token = ScanToken()
        let previousWatcher = watcher
        watcher = nil
        roots = []; records = [:]; cachedPages = []; pagesDirty = false
        count = 0; errorCount = 0; dirty = []; needsRebuild = false
        scanning = false; watchFailed = false; databaseBuildInProgress = false; databaseWriteFailed = false; revision += 1
        lock.unlock()
        withExtendedLifetime(previousWatcher) {}
    }

    public func start(authorizedRoots: [ScanRoot], watch: Bool = true, forceRebuild: Bool = false) {
        var selected: [ScanRoot] = []
        for root in authorizedRoots.sorted(by: { $0.path.count < $1.path.count }) {
            if !selected.contains(where: { $0.contains(root.path) }) { selected.append(root) }
        }
        let cacheReady: Bool
        do { cacheReady = try database?.prepare(roots: selected, forceRebuild: forceRebuild) ?? false }
        catch { cacheReady = false }
        let checkpoint = cacheReady ? (database?.checkpoint ?? 0) : 0
        let currentEventID = FolderEvents.currentEventID
        lock.lock()
        token.cancel()
        let current = ScanToken()
        token = current
        let previousWatcher = watcher
        watcher = nil
        roots = selected
        records = [:]; cachedPages = []; pagesDirty = false; count = 0; errorCount = 0
        dirty = []; needsRebuild = false; watchFailed = false
        pendingEventID = cacheReady ? checkpoint : currentEventID
        databaseBuildInProgress = !selected.isEmpty && !cacheReady
        databaseWriteFailed = false
        scanning = databaseBuildInProgress; revision += 1
        lock.unlock()
        withExtendedLifetime(previousWatcher) {}
        guard !selected.isEmpty else { return }

        // Start monitoring before scanning so changes during the initial pass
        // are queued and applied after it finishes.
        if watch {
            let events = FolderEvents { [weak self, current] paths, uncertain, eventID in
                self?.invalidate(paths: paths, uncertain: uncertain, eventID: eventID, token: current)
            }
            let since = cacheReady && checkpoint > 0 ? checkpoint : UInt64(kFSEventStreamEventIdSinceNow)
            let started = events.start(paths: selected.map(\.path), since: since)
            lock.lock()
            if !current.cancelled {
                if started { watcher = events } else { watchFailed = true; revision += 1 }
            }
            lock.unlock()
        }
        if !cacheReady {
            schedule(selected.map { DirectoryJob(path: $0.path, root: $0, recursive: true) }, token: current, parallelism: 4)
        }
    }

    private func invalidate(paths: [String], uncertain: Bool, eventID: UInt64, token current: ScanToken) {
        lock.lock()
        guard !current.cancelled else { lock.unlock(); return }
        pendingEventID = max(pendingEventID, eventID)
        if uncertain { needsRebuild = true }
        for path in paths {
            if let root = roots.first(where: { $0.contains(path) }) {
                // File events refer to either a file or a directory. Refresh
                // its parent listing; new directory identities trigger a walk.
                dirty.insert(path == root.path ? path : (path as NSString).deletingLastPathComponent)
            }
        }
        if dirty.count > 4096 { dirty = []; needsRebuild = true }
        let jobs = scanning ? [] : takePending()
        lock.unlock()
        if !jobs.isEmpty { schedule(jobs, token: current, parallelism: 1) }
    }

    // Called with lock held.
    private func takePending() -> [DirectoryJob] {
        let jobs: [DirectoryJob]
        if needsRebuild {
            jobs = roots.map { DirectoryJob(path: $0.path, root: $0, recursive: true) }
        } else {
            jobs = dirty.sorted { $0.count < $1.count }.compactMap { path in
                roots.first(where: { $0.contains(path) }).map { DirectoryJob(path: path, root: $0, recursive: false) }
            }
        }
        dirty = []; needsRebuild = false
        if !jobs.isEmpty { scanning = true; revision += 1 }
        return jobs
    }

    private func schedule(_ initial: [DirectoryJob], token current: ScanToken, parallelism: Int) {
        let jobs = DirectoryJobs(initial)
        let group = DispatchGroup()
        for _ in 0..<parallelism {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                let session = ScanWorkerSession(executable: workerURL, timeout: timeout, token: current)
                defer { session.stop(); group.leave() }
                while let job = jobs.next(token: current) {
                    var entries: [FileEntry] = []
                    var children: Set<String> = []
                    var identities: [String: DirectoryIdentity] = [:]
                    var errors: [String] = []
                    var failed = false
                    do {
                        try session.scan(ScanRequest(path: job.path, root: job.root)) { response in
                            entries.append(contentsOf: response.entries)
                            children.formUnion(response.directories)
                            identities.merge(response.identities ?? [:]) { _, new in new }
                            errors.append(contentsOf: response.errors)
                            failed = response.failed == true
                        }
                    } catch {
                        errors.append("\(job.path)：\(error.localizedDescription)")
                        failed = true
                    }
                    if failed { entries = []; children = []; identities = [:] }
                    var databaseChildren: Set<String>?
                    var databaseFailed = false
                    if !failed, let database {
                        do { databaseChildren = try database.replaceDirectory(path: job.path, entries: entries, children: identities) }
                        catch { errors.append("\(job.path)：\(error.localizedDescription)"); failed = true; databaseFailed = true }
                    }
                    let next = commit(job: job, entries: entries, children: children, identities: identities,
                                      errors: errors, failed: failed, databaseFailed: databaseFailed,
                                      databaseChildren: databaseChildren, token: current)
                    jobs.complete(children: next)
                }
            }
        }
        group.notify(queue: .global(qos: .utility)) { [self] in
            lock.lock()
            guard !current.cancelled else { lock.unlock(); return }
            scanning = false; revision += 1
            let pending = takePending()
            let checkpoint = pendingEventID
            let wasBuilding = databaseBuildInProgress
            let databaseValid = !databaseWriteFailed
            if pending.isEmpty { databaseBuildInProgress = false }
            lock.unlock()
            if !pending.isEmpty { schedule(pending, token: current, parallelism: 1) }
            else if databaseValid { try? database?.finishUpdate(checkpoint: checkpoint, complete: wasBuilding) }
            else { try? database?.invalidateCache() }
        }
    }

    private func commit(job: DirectoryJob, entries: [FileEntry], children: Set<String>, identities: [String: DirectoryIdentity],
                        errors: [String], failed: Bool, databaseFailed: Bool,
                        databaseChildren: Set<String>?, token current: ScanToken) -> [DirectoryJob] {
        let pages = database == nil ? stride(from: 0, to: entries.count, by: 1024).map { start in
            SearchPage(entries: Array(entries[start..<min(start + 1024, entries.count)]))
        } : []
        lock.lock(); defer { lock.unlock() }
        guard !current.cancelled else { return [] }
        if databaseFailed { databaseWriteFailed = true }
        let old = records[job.path]
        func remove(_ path: String) {
            if let previous = records.removeValue(forKey: path) {
                count -= previous.count; errorCount -= previous.errors.count
            }
        }
        let outdated = old?.childPaths.filter { !children.contains($0) || old?.children[$0] != identities[$0] } ?? []
        if !outdated.isEmpty {
            let prefixes = outdated.map { $0 + "/" }
            for path in Array(records.keys) where outdated.contains(path) || prefixes.contains(where: { path.hasPrefix($0) }) { remove(path) }
        }
        remove(job.path)
        records[job.path] = Record(pages: failed ? [] : pages, count: failed ? 0 : entries.count,
                                   children: failed ? [:] : identities, childPaths: failed ? [] : children, errors: errors)
        count += failed ? 0 : entries.count; errorCount += errors.count; revision += 1; pagesDirty = true
        if failed { return [] }
        if let databaseChildren {
            return databaseChildren.sorted().map { DirectoryJob(path: $0, root: job.root, recursive: true) }
        }
        return children.sorted().filter { job.recursive || old?.childPaths.contains($0) != true || old?.children[$0] != identities[$0] }
            .map { DirectoryJob(path: $0, root: job.root, recursive: true) }
    }

    public static func uniqueRoots(_ roots: [URL]) -> [URL] {
        var result: [URL] = []
        for url in roots.map(canonicalRoot).sorted(by: { $0.path.count < $1.path.count }) {
            if !result.contains(where: { $0.path == url.path || $0.path == "/" || url.path.hasPrefix($0.path + "/") }) { result.append(url) }
        }
        return result
    }

    // Foundation may abbreviate /private/var to /var while enumeration returns
    // physical paths. realpath keeps scope de-duplication and result paths aligned.
    public static func canonicalRoot(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}
