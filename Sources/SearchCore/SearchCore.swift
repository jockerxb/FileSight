import Foundation
import Darwin

public struct FileEntry: Equatable, Codable {
    public let path: String
    public let name: String
    public let modified: Date
    public let created: Date
    public let kind: String
    public let searchableName: String

    public init(url: URL, values: URLResourceValues) {
        path = url.path
        name = url.lastPathComponent
        modified = values.contentModificationDate ?? .distantPast
        created = values.creationDate ?? .distantPast
        kind = values.isDirectory == true ? "文件夹" : (url.pathExtension.isEmpty ? "无扩展名" : url.pathExtension.lowercased())
        searchableName = Self.normalize(name)
    }

    public init(path: String, modified: Date, created: Date, kind: String) {
        self.path = path
        self.name = URL(fileURLWithPath: path).lastPathComponent
        self.modified = modified
        self.created = created
        self.kind = kind.lowercased()
        self.searchableName = Self.normalize(name)
    }

    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
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

    public init(workerURL: URL? = nil, timeout: TimeInterval = 15) {
        self.workerURL = workerURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("ScanWorker")
        self.timeout = timeout
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
        return IndexView(pages: cachedPages, revision: revision, count: count, scanning: scanning,
                         errorCount: errorCount + (watchFailed ? 1 : 0), errors: errors)
    }

    // Entry point for unsandboxed scanner verification. The App uses the
    // authorized overload, carrying only grants explicitly picked by the user.
    public func start(roots: [URL], watch: Bool = false) {
        start(authorizedRoots: Self.uniqueRoots(roots).map { ScanRoot(url: $0) }, watch: watch)
    }

    public func start(authorizedRoots: [ScanRoot], watch: Bool = true) {
        var selected: [ScanRoot] = []
        for root in authorizedRoots.sorted(by: { $0.path.count < $1.path.count }) {
            if !selected.contains(where: { $0.contains(root.path) }) { selected.append(root) }
        }
        lock.lock()
        token.cancel()
        let current = ScanToken()
        token = current
        let previousWatcher = watcher
        watcher = nil
        roots = selected
        records = [:]; cachedPages = []; pagesDirty = false; count = 0; errorCount = 0
        dirty = []; needsRebuild = false; watchFailed = false
        scanning = !selected.isEmpty; revision += 1
        lock.unlock()
        withExtendedLifetime(previousWatcher) {}
        guard !selected.isEmpty else { return }

        // Start monitoring before scanning so changes during the initial pass
        // are queued and applied after it finishes.
        if watch {
            let events = FolderEvents { [weak self, current] paths, uncertain in
                self?.invalidate(paths: paths, uncertain: uncertain, token: current)
            }
            let started = events.start(paths: selected.map(\.path))
            lock.lock()
            if !current.cancelled {
                if started { watcher = events } else { watchFailed = true; revision += 1 }
            }
            lock.unlock()
        }
        schedule(selected.map { DirectoryJob(path: $0.path, root: $0, recursive: true) }, token: current, parallelism: 4)
    }

    private func invalidate(paths: [String], uncertain: Bool, token current: ScanToken) {
        lock.lock()
        guard !current.cancelled else { lock.unlock(); return }
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
                    let next = commit(job: job, entries: entries, children: children, identities: identities, errors: errors, token: current)
                    jobs.complete(children: next)
                }
            }
        }
        group.notify(queue: .global(qos: .utility)) { [self] in
            lock.lock()
            guard !current.cancelled else { lock.unlock(); return }
            scanning = false; revision += 1
            let pending = takePending()
            lock.unlock()
            if !pending.isEmpty { schedule(pending, token: current, parallelism: 1) }
        }
    }

    private func commit(job: DirectoryJob, entries: [FileEntry], children: Set<String>, identities: [String: DirectoryIdentity],
                        errors: [String], token current: ScanToken) -> [DirectoryJob] {
        let pages = stride(from: 0, to: entries.count, by: 1024).map { start in
            SearchPage(entries: Array(entries[start..<min(start + 1024, entries.count)]))
        }
        lock.lock(); defer { lock.unlock() }
        guard !current.cancelled else { return [] }
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
        records[job.path] = Record(pages: pages, count: entries.count, children: identities, childPaths: children, errors: errors)
        count += entries.count; errorCount += errors.count; revision += 1; pagesDirty = true
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
