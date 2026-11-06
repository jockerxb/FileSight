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
    private let lock = NSLock()
    private var chunks: [SearchPage] = []
    private var tail: [FileEntry] = []
    private var tailFingerprints: [NameFingerprint] = []
    private var count = 0
    private var revision = 0
    private var scanning = false
    private var errors: [String] = []
    private var errorCount = 0
    private var token = ScanToken()
    private let workerURL: URL
    private let timeout: TimeInterval

    public init(workerURL: URL? = nil, timeout: TimeInterval = 15) {
        self.workerURL = workerURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("ScanWorker")
        self.timeout = timeout
    }

    public func snapshot() -> ScanSnapshot {
        lock.lock(); defer { lock.unlock() }
        return ScanSnapshot(entries: chunks.flatMap(\.entries) + tail, revision: revision, scanning: scanning, errorCount: errorCount, errors: errors)
    }

    // Immutable pages prevent every scanner update from copying a million-row
    // array while the UI holds a snapshot. Only the small tail can be copied.
    public func view() -> IndexView {
        lock.lock(); defer { lock.unlock() }
        var pages = chunks
        if !tail.isEmpty { pages.append(SearchPage(entries: tail, fingerprints: tailFingerprints)) }
        return IndexView(pages: pages, revision: revision, count: count, scanning: scanning, errorCount: errorCount, errors: errors)
    }

    public func start(roots: [URL]) {
        lock.lock()
        token.cancel()
        let current = ScanToken()
        token = current
        chunks = []; tail = []; tailFingerprints = []; count = 0; errors = []; errorCount = 0; scanning = true; revision += 1
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let roots = Self.uniqueRoots(roots)
            let jobs = DirectoryJobs(roots: roots)
            let excludes = roots.contains(where: { $0.path == "/" }) ? ["/dev", "/System/Volumes"] : []
            let group = DispatchGroup()
            func receive(_ response: ScanResponse) {
                lock.lock(); defer { lock.unlock() }
                guard !current.cancelled else { return }
                count += response.entries.count
                for entry in response.entries {
                    tail.append(entry)
                    tailFingerprints.append(NameFingerprint(normalized: entry.searchableName))
                    if tail.count == 1024 { chunks.append(SearchPage(entries: tail, fingerprints: tailFingerprints)); tail = []; tailFingerprints = [] }
                }
                errorCount += response.errors.count
                errors.append(contentsOf: response.errors.prefix(max(0, 200 - errors.count)))
                revision += 1
            }
            for _ in 0..<4 {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let session = ScanWorkerSession(executable: self.workerURL, timeout: self.timeout, token: current)
                    defer { session.stop(); group.leave() }
                    while let job = jobs.next(token: current) {
                        var children: [String] = []
                        do {
                            try session.scan(ScanRequest(path: job.path, includeRoot: job.includeRoot, excludes: excludes)) { response in
                                children.append(contentsOf: response.directories)
                                receive(response)
                            }
                        } catch {
                            receive(ScanResponse(errors: ["\(job.path)：\(error.localizedDescription)"]))
                        }
                        jobs.complete(children: children)
                    }
                }
            }
            group.wait()
            lock.lock(); defer { lock.unlock() }
            if !current.cancelled { scanning = false; revision += 1 }
        }
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
