import Foundation
import Darwin

struct DirectoryIdentity: Codable, Equatable {
    let device: Int32
    let inode: UInt64
    init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
}

public struct ScanRoot {
    public let path: String
    let identity: DirectoryIdentity?
    let bookmark: Data?

    public var authorizationBookmark: Data? { bookmark }

    // The app calls this only with URLs returned by its directory picker.
    // A security-scoped bookmark transfers the read-only picker grant to the
    // worker and can be restored by the same signed app on a later launch.
    public static func authorized(_ url: URL) throws -> Self {
        guard url.isFileURL, url.path != "/", try LocalFiles.isLocal(url) else { throw POSIXError(.EACCES) }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let root = Self(url: url, bookmark: bookmark)
        guard root.identity != nil else { throw POSIXError(.EACCES) }
        return root
    }

    public static func restored(_ bookmark: Data) throws -> Self {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark,
                          options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.isFileURL, url.path != "/", !stale,
              url.startAccessingSecurityScopedResource() else { throw POSIXError(.EACCES) }
        defer { url.stopAccessingSecurityScopedResource() }
        guard try LocalFiles.isLocal(url) else { throw POSIXError(.EACCES) }
        let root = Self(url: url, bookmark: bookmark)
        guard root.identity != nil else { throw POSIXError(.EACCES) }
        return root
    }

    /// Keep the app-scoped grant active while scanner child processes run.
    /// The helper inherits this narrowed sandbox extension; the persistent
    /// bookmark itself never leaves the main app.
    public func startAccessing() throws -> URL {
        guard let bookmark else { throw POSIXError(.EACCES) }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark,
                          options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.isFileURL, !stale, FileIndex.canonicalRoot(url).path == path,
              url.startAccessingSecurityScopedResource() else { throw POSIXError(.EACCES) }
        return url
    }

    public init(url: URL) {
        self.init(url: url, bookmark: nil)
    }

    private init(url: URL, bookmark: Data?) {
        path = FileIndex.canonicalRoot(url).path
        var metadata = stat()
        identity = lstat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFDIR ? DirectoryIdentity(metadata) : nil
        self.bookmark = bookmark
    }

    func contains(_ candidate: String) -> Bool {
        candidate == path || candidate.hasPrefix(path == "/" ? "/" : path + "/")
    }
}

public struct ScanRequest: Codable {
    public var path: String
    public var includeRoot: Bool
    var rootPath: String
    var rootIdentity: DirectoryIdentity?

    init(path: String, root: ScanRoot) {
        self.path = path; includeRoot = path == root.path
        rootPath = root.path; rootIdentity = root.identity
    }
}

public struct ScanResponse: Codable {
    public var entries: [FileEntry] = []
    public var directories: [String] = []
    public var errors: [String] = []
    public var done: Bool = false
    var identities: [String: DirectoryIdentity]? = nil
    var failed: Bool? = nil
}

public enum DirectoryScanner {
    private static func lastError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    private static func timestamp(_ value: timespec) -> Date {
        value.tv_sec == 0 && value.tv_nsec == 0 ? .distantPast :
            Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000)
    }

    private static func entry(_ path: String, _ value: stat) -> FileEntry {
        let ext = (path as NSString).pathExtension
        let kind = value.st_mode & S_IFMT == S_IFDIR ? "文件夹" : ext.isEmpty ? "无扩展名" : ext
        return FileEntry(path: path, modified: timestamp(value.st_mtimespec), created: timestamp(value.st_birthtimespec), kind: kind)
    }

    /// Follow only root-relative directory components, never a queued path or
    /// a symlink. Directory descriptors keep each check tied to the object read.
    public static func scan(_ request: ScanRequest, emit: (ScanResponse) throws -> Void) throws {
        do {
            guard let identity = request.rootIdentity else { throw POSIXError(.ENOENT) }
            let prefix = request.rootPath == "/" ? "/" : request.rootPath + "/"
            guard request.path == request.rootPath || request.path.hasPrefix(prefix) else { throw POSIXError(.EACCES) }
            let relative = request.path == request.rootPath ? "" : String(request.path.dropFirst(prefix.count))
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard relative.isEmpty || components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
                throw POSIXError(.EINVAL)
            }
            let root = request.rootPath

            var rootMetadata = stat()
            guard fstatat(AT_FDCWD, root, &rootMetadata, AT_SYMLINK_NOFOLLOW_ANY) == 0 else { throw lastError() }
            guard DirectoryIdentity(rootMetadata) == identity else { throw POSIXError(.ESTALE) }
            if rootMetadata.st_flags & UInt32(SF_DATALESS) != 0 {
                try emit(ScanResponse(entries: request.includeRoot ? [entry(request.path, rootMetadata)] : [],
                                      errors: ["\(root)：云端目录尚未下载，内部未扫描。"], done: true))
                return
            }
            var descriptor = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard descriptor >= 0 else { throw lastError() }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw lastError() }
            guard DirectoryIdentity(metadata) == identity else { throw POSIXError(.ESTALE) }
            var volume = statfs()
            guard fstatfs(descriptor, &volume) == 0 else { throw lastError() }
            guard volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw POSIXError(.EXDEV) }
            for component in components where !relative.isEmpty {
                var child = stat()
                guard fstatat(descriptor, String(component), &child, AT_SYMLINK_NOFOLLOW) == 0 else { throw lastError() }
                guard child.st_dev == identity.device, child.st_mode & S_IFMT == S_IFDIR,
                      child.st_flags & UInt32(SF_DATALESS) == 0 else { throw POSIXError(.EACCES) }
                let next = openat(descriptor, String(component), directoryFlags)
                guard next >= 0 else { throw lastError() }
                close(descriptor); descriptor = next
                guard fstat(descriptor, &metadata) == 0 else { throw lastError() }
                guard DirectoryIdentity(metadata) == DirectoryIdentity(child) else { throw POSIXError(.ESTALE) }
            }
            // A moved directory descriptor must not become a source of results
            // under its old name. This check also detects replacement by a link.
            func verifyLocation() throws {
                var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard fcntl(descriptor, F_GETPATH, &bytes) == 0 else { throw lastError() }
                guard String(cString: bytes) == request.path else { throw POSIXError(.ESTALE) }
            }
            try verifyLocation()
            var batch = ScanResponse()
            if request.includeRoot { batch.entries.append(entry(request.path, metadata)) }
            if metadata.st_flags & UInt32(SF_DATALESS) != 0 {
                batch.errors.append("\(request.path)：云端目录尚未下载，内部未扫描。")
                batch.done = true
                try emit(batch)
                return
            }
            let duplicate = dup(descriptor)
            guard duplicate >= 0 else { throw lastError() }
            guard let directory = fdopendir(duplicate) else { let error = lastError(); close(duplicate); throw error }
            defer { closedir(directory) }
            var last = ProcessInfo.processInfo.systemUptime
            while true {
                errno = 0
                guard let item = readdir(directory) else {
                    if errno != 0 { throw lastError() }
                    break
                }
                let length = Int(item.pointee.d_namlen)
                let name = withUnsafeBytes(of: &item.pointee.d_name) { String(bytes: $0.prefix(length), encoding: .utf8) }
                guard let name, name != ".", name != ".." else { continue }
                let path = (request.path == "/" ? "/" : request.path + "/") + name
                var child = stat()
                if fstatat(descriptor, name, &child, AT_SYMLINK_NOFOLLOW) == 0 {
                    batch.entries.append(entry(path, child))
                    if child.st_mode & S_IFMT == S_IFDIR {
                        if child.st_dev != identity.device {
                            batch.errors.append("\(path)：不跨越挂载点，请单独选择该磁盘。")
                        } else if child.st_flags & UInt32(SF_DATALESS) != 0 {
                            batch.errors.append("\(path)：云端目录尚未下载，内部未扫描。")
                        } else {
                            batch.directories.append(path)
                            if batch.identities == nil { batch.identities = [:] }
                            batch.identities?[path] = DirectoryIdentity(child)
                        }
                    }
                } else if errno != ENOENT {
                    batch.errors.append("\(path)：\(lastError().localizedDescription)")
                }
                if batch.entries.count + batch.errors.count >= 512 || ProcessInfo.processInfo.systemUptime - last >= 0.4 {
                    try verifyLocation()
                    try emit(batch); batch = ScanResponse(); last = ProcessInfo.processInfo.systemUptime
                }
            }
            try verifyLocation()
            batch.done = true
            try emit(batch)
        } catch let error as POSIXError where request.path != request.rootPath &&
            (error.code == .ENOENT || error.code == .ESTALE || error.code == .ENOTDIR) {
            // FSEvents can enqueue a directory just before it is deleted,
            // renamed, or replaced. That is a normal reconciliation outcome,
            // not a permission failure. Committing an empty successful result
            // removes any stale record for the vanished path.
            try emit(ScanResponse(done: true))
        } catch {
            try emit(ScanResponse(errors: ["\(request.path)：\(error.localizedDescription)"], done: true, failed: true))
        }
    }
}

struct DirectoryJob { let path: String; let root: ScanRoot; let recursive: Bool }

final class DirectoryJobs {
    private let condition = NSCondition()
    private var pending: [DirectoryJob]
    private var seen: Set<String>
    private var cursor = 0
    private var active = 0
    init(_ jobs: [DirectoryJob]) { pending = jobs; seen = Set(jobs.map(\.path)) }
    func next(token: ScanToken) -> DirectoryJob? {
        condition.lock(); defer { condition.unlock() }
        while cursor == pending.count && active > 0 && !token.cancelled { _ = condition.wait(until: Date().addingTimeInterval(0.2)) }
        guard !token.cancelled, cursor < pending.count else { return nil }
        let job = pending[cursor]; cursor += 1; active += 1
        // Release completed directory paths as the breadth-first queue advances.
        if cursor > 4096 { pending.removeFirst(cursor); cursor = 0 }
        return job
    }
    func complete(children: [DirectoryJob]) {
        condition.lock(); defer { condition.unlock() }
        pending.append(contentsOf: children.filter { seen.insert($0.path).inserted })
        active -= 1; condition.broadcast()
    }
}

final class ScanWorkerSession {
    private let executable: URL
    private let timeout: TimeInterval
    private let token: ScanToken
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    init(executable: URL, timeout: TimeInterval, token: ScanToken) { self.executable = executable; self.timeout = timeout; self.token = token }

    func stop() {
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? input?.close(); try? output?.close()
        input = nil; output = nil; process = nil; buffer.removeAll()
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        stop()
        let child = Process(); child.executableURL = executable
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child; input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading
    }

    func scan(_ request: ScanRequest, receive: (ScanResponse) -> Void) throws {
        try startIfNeeded()
        guard let process, let input, let output else { return }
        let activity = WorkerActivity()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [token, timeout] in
            if token.cancelled || activity.expired(after: timeout) {
                activity.markInterrupted()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        timer.resume()
        defer { timer.cancel() }
        do {
            var data = try JSONEncoder().encode(request); data.append(10)
            try input.write(contentsOf: data)
            while !token.cancelled {
                if let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]
                    let response = try JSONDecoder().decode(ScanResponse.self, from: line)
                    buffer.removeSubrange(...newline)
                    activity.touch(); receive(response)
                    if response.done { return }
                } else {
                    var bytes = [UInt8](repeating: 0, count: 65536)
                    let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    activity.touch(); buffer.append(contentsOf: bytes.prefix(count))
                    guard buffer.count <= 8 * 1024 * 1024 else { throw POSIXError(.EMSGSIZE) }
                }
            }
            if !token.cancelled {
                throw NSError(domain: "ScanWorker", code: 1, userInfo: [NSLocalizedDescriptionKey: activity.interrupted ? "目录访问超过 \(Int(timeout)) 秒没有响应，已停止该目录并继续其余目录。请检查权限或磁盘连接后重新扫描。" : "扫描进程提前退出，请重新扫描。"])
            }
        } catch {
            stop(); throw error
        }
        stop()
    }
}

private final class WorkerActivity {
    private let lock = NSLock()
    private var last = ProcessInfo.processInfo.systemUptime
    private var wasInterrupted = false
    func touch() { lock.lock(); last = ProcessInfo.processInfo.systemUptime; lock.unlock() }
    func expired(after timeout: TimeInterval) -> Bool { lock.lock(); defer { lock.unlock() }; return ProcessInfo.processInfo.systemUptime - last > timeout }
    func markInterrupted() { lock.lock(); wasInterrupted = true; lock.unlock() }
    var interrupted: Bool { lock.lock(); defer { lock.unlock() }; return wasInterrupted }
}
