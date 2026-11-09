import Foundation
import Darwin
import SearchCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "Verification", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

let fm = FileManager.default
let root = FileIndex.canonicalRoot(fm.temporaryDirectory).appendingPathComponent("qianliyan-verification-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
var expected: Set<String> = []
for sub in ["a", "b", ".hidden", "Bundle.app/Contents"] {
    try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
}
for n in 0..<1205 {
    let sub = n % 2 == 0 ? "a" : "b"
    let ext = n % 3 == 0 ? "PDF" : "txt"
    let url = root.appendingPathComponent("\(sub)/合同-\(n).\(ext)")
    try Data("fixture".utf8).write(to: url)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_700_000_000 + n))], ofItemAtPath: url.path)
    expected.insert(url.path)
}
for path in [".hidden/合同-hidden.txt", "Bundle.app/Contents/合同-package.txt", "a/RÉSUMÉ.txt", "b/resume.txt", "a/同名.txt", "b/同名.txt"] {
    let url = root.appendingPathComponent(path)
    try Data().write(to: url)
    if path.contains("合同") { expected.insert(url.path) }
}
try fm.createSymbolicLink(at: root.appendingPathComponent("a/loop"), withDestinationURL: root)
try require(FileIndex.uniqueRoots([root, root.appendingPathComponent("a/loop")]).count == 1, "目录别名未正确去重")
let index = FileIndex()
index.start(roots: [root, root.appendingPathComponent("a"), root])
let deadline = Date().addingTimeInterval(30)
while index.snapshot().scanning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
let snapshot = index.snapshot()
try require(!snapshot.scanning, "扫描超时（可能发生符号链接循环）")
try require(snapshot.errorCount == 0, "意外扫描错误：\(snapshot.errors)")
let matches = FileSearch.results(in: snapshot.entries, query: "合同", sort: .modified, ascending: false)
let actual = Set(matches.map(\.path))
try require(actual == expected, "漏文件或多出结果：匹配 \(actual.count)/预期 \(expected.count)，缺失 \(Array(expected.subtracting(actual).prefix(3)))，额外 \(Array(actual.subtracting(expected).prefix(3)))")
try require(matches.count == expected.count, "重复目录产生重复结果")
try require(matches.count > 1000, "结果被截断")
for field in [SortField.modified, .created, .kind, .name] {
    for ascending in [true, false] {
        let sorted = FileSearch.results(in: snapshot.entries, query: "合同", sort: field, ascending: ascending)
        try require(sorted.count == expected.count, "排序导致结果丢失")
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let order: ComparisonResult
            switch field {
            case .modified: order = a.modified.compare(b.modified)
            case .created: order = a.created.compare(b.created)
            case .kind: order = a.kind.localizedStandardCompare(b.kind)
            case .name: order = a.name.localizedStandardCompare(b.name)
            }
            try require(ascending ? order != .orderedDescending : order != .orderedAscending, "排序方向错误")
        }
    }
}
try require(FileSearch.results(in: snapshot.entries, query: "RESUME", sort: .name, ascending: true).count == 2, "大小写或 Unicode 匹配失败")
try require(FileSearch.results(in: snapshot.entries, query: "同名", sort: .name, ascending: true).count == 2, "不同目录同名文件丢失")
try require(FileSearch.results(in: snapshot.entries, query: "不存在的名字", sort: .name, ascending: true).isEmpty, "空结果错误")
let newFile = root.appendingPathComponent("a/合同-new.txt")
try Data().write(to: newFile)
try fm.removeItem(at: root.appendingPathComponent("a/合同-0.PDF"))
index.start(roots: [root])
while index.snapshot().scanning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
let refreshed = FileSearch.results(in: index.snapshot().entries, query: "合同", sort: .name, ascending: true)
try require(refreshed.contains(where: { $0.path == newFile.path }), "重新扫描没有收录新增文件")
try require(!refreshed.contains(where: { $0.name == "合同-0.PDF" }), "重新扫描仍残留删除文件")
// Cancelling an old scan must not leak its entries into the new scope.
index.start(roots: [root])
index.start(roots: [root.appendingPathComponent(".hidden")])
while index.snapshot().scanning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
try require(index.snapshot().entries.allSatisfy { $0.path.hasPrefix(root.appendingPathComponent(".hidden").path) }, "切换范围后旧扫描污染结果")
index.start(roots: [root.appendingPathComponent("missing")])
while index.snapshot().scanning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
try require(index.snapshot().errorCount > 0, "无法访问的范围被静默忽略")

// Saturate all four workers with stalled filesystem calls. The supervisor must
// terminate them, restart a worker, and still reach the healthy pending folder.
let fakeWorker = root.appendingPathComponent("slow-worker.py")
let script = """
#!/usr/bin/env python3
import sys, json, time, os
for line in sys.stdin:
    req = json.loads(line)
    path = req['path']
    name = os.path.basename(path)
    if name.startswith('blocked'):
        time.sleep(10)
    reply = {'entries': [], 'directories': [], 'errors': [], 'done': True}
    if req['includeRoot']:
        reply['directories'] = [path + '/blocked' + str(n) for n in range(4)] + [path + '/healthy']
    elif name == 'healthy':
        reply['entries'] = [{'path': path + '/恢复验收.txt', 'name': '恢复验收.txt', 'modified': 0, 'created': 0, 'kind': 'txt', 'searchableName': '恢复验收.txt'}]
    print(json.dumps(reply), flush=True)
"""
try Data(script.utf8).write(to: fakeWorker)
try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeWorker.path)
let isolated = FileIndex(workerURL: fakeWorker, timeout: 0.8)
let started = Date()
isolated.start(roots: [root])
while isolated.snapshot().scanning && Date().timeIntervalSince(started) < 8 { Thread.sleep(forTimeInterval: 0.02) }
try require(!isolated.snapshot().scanning, "所有 worker 阻塞后未结束")
try require(isolated.snapshot().errorCount == 4, "未明确上报四个超时目录：\(isolated.snapshot().errors)")
try require(isolated.snapshot().entries.contains(where: { $0.name == "恢复验收.txt" }), "超时目录阻止了其余目录扫描")
try require(Date().timeIntervalSince(started) < 8, "超时隔离没有生效")
print("PASS：1207 个匹配文件、同名/隐藏/package、8 种排序、Unicode、刷新、取消、访问错误、四路阻塞隔离与 worker 重启均通过")

// Reproduce the audit: an intermediate component is swapped for a link
// after the directory was enqueued. The queued path still looks in-scope.
let guarded = root.appendingPathComponent("guarded")
let queued = guarded.appendingPathComponent("parent/child")
let external = root.appendingPathComponent("outside/child")
try fm.createDirectory(at: queued, withIntermediateDirectories: true)
try fm.createDirectory(at: external, withIntermediateDirectories: true)
try Data().write(to: external.appendingPathComponent("outside-scope.txt"))
var rootInfo = stat()
try require(lstat(guarded.path, &rootInfo) == 0, "读取测试根目录身份失败")
let request = try JSONDecoder().decode(ScanRequest.self, from: JSONSerialization.data(withJSONObject: [
    "path": queued.path, "includeRoot": false, "rootPath": guarded.path,
    "rootIdentity": ["device": Int64(rootInfo.st_dev), "inode": rootInfo.st_ino]
]))
try fm.moveItem(at: guarded.appendingPathComponent("parent"), to: root.appendingPathComponent("old-parent"))
try fm.createSymbolicLink(at: guarded.appendingPathComponent("parent"), withDestinationURL: external.deletingLastPathComponent())
var blocked = false
try DirectoryScanner.scan(request) { response in
    try require(response.entries.isEmpty, "越界路径被列进索引")
    blocked = blocked || !response.errors.isEmpty
}
try require(blocked, "符号链接替换未被明确拒绝")

// A directory can disappear after FSEvents enqueues it. This must clear the
// stale record without presenting a false access/permission warning.
let vanished = guarded.appendingPathComponent("vanished")
try fm.createDirectory(at: vanished, withIntermediateDirectories: true)
let vanishedRequest = try JSONDecoder().decode(ScanRequest.self, from: JSONSerialization.data(withJSONObject: [
    "path": vanished.path, "includeRoot": false, "rootPath": guarded.path,
    "rootIdentity": ["device": Int64(rootInfo.st_dev), "inode": rootInfo.st_ino]
]))
try fm.removeItem(at: vanished)
var vanishedResponse: ScanResponse?
try DirectoryScanner.scan(vanishedRequest) { vanishedResponse = $0 }
try require(vanishedResponse?.errors.isEmpty == true && vanishedResponse?.done == true,
            "已删除目录被错误报告为访问失败")

// No manual refresh: the real macOS event stream drives reconciliation.
let live = root.appendingPathComponent("live")
let left = live.appendingPathComponent("left")
let right = live.appendingPathComponent("right")
try fm.createDirectory(at: left, withIntermediateDirectories: true)
try fm.createDirectory(at: right, withIntermediateDirectories: true)
let original = left.appendingPathComponent("initial.txt")
let untouched = right.appendingPathComponent("unchanged.txt")
try Data().write(to: original)
try Data().write(to: untouched)
let watching = FileIndex()
watching.start(roots: [live], watch: true)
func waitFor(_ message: String, _ predicate: (ScanSnapshot) -> Bool) throws {
    let end = Date().addingTimeInterval(10)
    repeat {
        if predicate(watching.snapshot()) { return }
        Thread.sleep(forTimeInterval: 0.04)
    } while Date() < end
    let snapshot = watching.snapshot()
    throw NSError(domain: "LiveIndexVerification", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "\(message)，当前：\(snapshot.entries.map(\.name))，错误：\(snapshot.errors)"])
}
try waitFor("初始扫描或监听失败") { !$0.scanning && $0.errorCount == 0 && $0.entries.contains { $0.path == original.path } }
let renamed = left.appendingPathComponent("renamed.txt")
try fm.moveItem(at: original, to: renamed)
try waitFor("同目录改名未同步") { snapshot in
    snapshot.entries.contains { $0.path == renamed.path } && !snapshot.entries.contains { $0.path == original.path }
}
let nested = right.appendingPathComponent("fresh/deep")
try fm.createDirectory(at: nested, withIntermediateDirectories: true)
let moved = nested.appendingPathComponent("moved.txt")
try fm.moveItem(at: renamed, to: moved)
try waitFor("新子目录或跨目录移动未同步") { snapshot in
    snapshot.entries.contains { $0.path == moved.path } && !snapshot.entries.contains { $0.path == renamed.path }
}
let changedDate = Date(timeIntervalSince1970: 1_735_689_600)
try fm.setAttributes([.modificationDate: changedDate], ofItemAtPath: moved.path)
try waitFor("修改时间未同步") { $0.entries.contains { $0.path == moved.path && $0.modified == changedDate } }
try fm.removeItem(at: right.appendingPathComponent("fresh"))
try waitFor("删除目录后索引仍有残留") { snapshot in
    !snapshot.entries.contains { $0.path == moved.path || $0.path == nested.path } &&
        snapshot.entries.contains { $0.path == untouched.path }
}
watching.start(roots: [])
try require(watching.snapshot().entries.isEmpty, "撤换范围后结果未清空")
print("PASS：拒绝父目录符号链接替换；真实文件事件自动处理改名、移动、新目录、修改与删除。")
