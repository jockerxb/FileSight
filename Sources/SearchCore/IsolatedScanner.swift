import Foundation
import Darwin

public struct ScanRequest: Codable {
    public var path: String
    public var includeRoot: Bool
    public var excludes: [String]
}

public struct ScanResponse: Codable {
    public var entries: [FileEntry] = []
    public var directories: [String] = []
    public var errors: [String] = []
    public var done: Bool = false
}

public enum DirectoryScanner {
    private static func hasNoLocalData(_ url: URL, values: URLResourceValues) -> Bool {
        if values.ubiquitousItemDownloadingStatus == .notDownloaded { return true }
        // File Provider can return no ubiquitous download status at all. The
        // filesystem's dataless flag still identifies its unmaterialized item.
        var metadata = stat()
        return lstat(url.path, &metadata) == 0 && metadata.st_flags & UInt32(SF_DATALESS) != 0
    }
    /// A worker handles one directory at a time. It never recurses by itself:
    /// if a system call stalls, its supervisor can kill it and retain other work.
    public static func scan(_ request: ScanRequest, emit: (ScanResponse) throws -> Void) throws {
        let root = URL(fileURLWithPath: request.path, isDirectory: true)
        guard try LocalFiles.isLocal(root) else {
            try emit(ScanResponse(errors: ["\(root.path)：离线模式不扫描网络磁盘。"], done: true)); return
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .creationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var batch = ScanResponse()
        if request.includeRoot {
            do {
                let values = try root.resourceValues(forKeys: keys)
                batch.entries.append(FileEntry(url: root, values: values))
                if values.isDirectory == true && hasNoLocalData(root, values: values) {
                    batch.errors.append("\(root.path)：云端目录尚未下载；已收录目录名称，内部文件未扫描。请先在 Finder 中下载后重新扫描。")
                    batch.done = true; try emit(batch); return
                }
            }
            catch { batch.errors.append("\(root.path)：\(error.localizedDescription)") }
        }
        try emit(batch)
        batch = ScanResponse()
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsSubdirectoryDescendants], errorHandler: { url, error in
            batch.errors.append("\(url.path)：\(error.localizedDescription)")
            return true
        }) else {
            try emit(ScanResponse(errors: ["\(root.path)：无法枚举目录"], done: true)); return
        }
        var lastEmission = Date()
        // nextObject avoids NSFastEnumeration buffering a whole batch behind a
        // protected directory before delivering even the first available result.
        while let url = iterator.nextObject() as? URL {
            if request.excludes.contains(url.path) { continue }
            do {
                let values = try url.resourceValues(forKeys: keys)
                batch.entries.append(FileEntry(url: url, values: values))
                if values.isDirectory == true && values.isSymbolicLink != true {
                    if try !LocalFiles.isLocal(url) {
                        batch.errors.append("\(url.path)：离线模式不扫描网络磁盘。")
                    } else if hasNoLocalData(url, values: values) {
                        batch.errors.append("\(url.path)：云端目录尚未下载；已收录目录名称，内部文件未扫描。请先在 Finder 中下载后重新扫描。")
                    } else {
                        batch.directories.append(url.path)
                    }
                }
            } catch { batch.errors.append("\(url.path)：\(error.localizedDescription)") }
            if batch.entries.count >= 512 || Date().timeIntervalSince(lastEmission) >= 0.4 {
                try emit(batch); batch = ScanResponse(); lastEmission = Date()
            }
        }
        batch.done = true
        try emit(batch)
    }
}

struct DirectoryJob { let path: String; let includeRoot: Bool }

final class DirectoryJobs {
    private let condition = NSCondition()
    private var pending: [DirectoryJob]
    private var cursor = 0
    private var active = 0
    init(roots: [URL]) { pending = roots.map { DirectoryJob(path: $0.path, includeRoot: true) } }
    func next(token: ScanToken) -> DirectoryJob? {
        condition.lock(); defer { condition.unlock() }
        while cursor == pending.count && active > 0 && !token.cancelled { _ = condition.wait(until: Date().addingTimeInterval(0.2)) }
        guard !token.cancelled, cursor < pending.count else { return nil }
        let job = pending[cursor]; cursor += 1; active += 1
        // Release completed directory paths as the breadth-first queue advances.
        if cursor > 4096 { pending.removeFirst(cursor); cursor = 0 }
        return job
    }
    func complete(children: [String]) {
        condition.lock(); defer { condition.unlock() }
        pending.append(contentsOf: children.map { DirectoryJob(path: $0, includeRoot: false) })
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
    private var last = Date()
    private var wasInterrupted = false
    func touch() { lock.lock(); last = Date(); lock.unlock() }
    func expired(after timeout: TimeInterval) -> Bool { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) > timeout }
    func markInterrupted() { lock.lock(); wasInterrupted = true; lock.unlock() }
    var interrupted: Bool { lock.lock(); defer { lock.unlock() }; return wasInterrupted }
}
