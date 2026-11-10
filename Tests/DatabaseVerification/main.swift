import Foundation
import SearchCore

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "DatabaseVerification", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: message]) }
}

func wait(_ message: String, timeout: TimeInterval = 15, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        Thread.sleep(forTimeInterval: 0.04)
    }
    throw NSError(domain: "DatabaseVerification", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
}

let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("filesight-db-\(UUID().uuidString)", isDirectory: true)
let root = base.appendingPathComponent("root", isDirectory: true)
let store = base.appendingPathComponent("store", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
try fm.createDirectory(at: store, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: base) }

let now = Date()
let invoice = root.appendingPathComponent("最近发票.pdf")
let wechat = root.appendingPathComponent("微信输入法.app")
let old = root.appendingPathComponent("旧发票.pdf")
let exact = root.appendingPathComponent("合同.txt")
let numbered2 = root.appendingPathComponent("合同2.txt")
let numbered10 = root.appendingPathComponent("合同10.txt")
for url in [invoice, wechat, old, exact, numbered2, numbered10] { try Data("test".utf8).write(to: url) }
try fm.setAttributes([.modificationDate: now], ofItemAtPath: invoice.path)
try fm.setAttributes([.modificationDate: now], ofItemAtPath: wechat.path)
try fm.setAttributes([.modificationDate: Calendar.current.date(byAdding: .month, value: -3, to: now)!], ofItemAtPath: old.path)

let databaseURL = store.appendingPathComponent("metadata.sqlite3")
var database: IndexDatabase? = try IndexDatabase(url: databaseURL)
var index: FileIndex? = FileIndex(timeout: 5, database: database)
index!.start(roots: [root], watch: false)
try wait("初始 SQLite 索引未完成") { index!.view().scanning == false }
try require(database!.fileCount == 7, "目录元数据计数不正确：\(database!.fileCount)")

func names(_ query: String) throws -> [String] {
    try database!.search(parsed: .parse(query, now: now), order: .relevance, ascending: true, limit: 20)!.rows.map(\.name)
}
try require(try names("微信").contains("微信输入法.app"), "中文短词索引失败")
try require(try names("weixin").contains("微信输入法.app"), "完整拼音索引失败")
try require(try names("wx").contains("微信输入法.app"), "拼音首字母短词索引失败")
try require(try names("最近1个月 发票 pdf").contains("最近发票.pdf"), "类型与日期 SQL 筛选失败")
try require(!(try names("最近1个月 发票 pdf")).contains("旧发票.pdf"), "日期筛选包含了过期文件")
try require(try database!.count(parsed: .parse("发票")) == 2, "异步总数查询不正确")
let relevance = try database!.search(parsed: .parse("合同"), order: .relevance, ascending: true, limit: 20)!.rows.map(\.name)
try require(relevance.first == "合同.txt", "无扩展名完整命中没有排在首位")
let numeric = try database!.search(parsed: .parse("合同"), order: .name, ascending: true, limit: 20)!.rows.map(\.name)
try require(numeric.firstIndex(of: "合同2.txt")! < numeric.firstIndex(of: "合同10.txt")!, "数字文件名排序退化为字典序")

index!.stop(); index = nil; database = nil
try fm.removeItem(at: wechat)
database = try IndexDatabase(url: databaseURL)
index = FileIndex(timeout: 5, database: database)
index!.start(roots: [root], watch: false)
try require(index!.view().scanning == false, "健康缓存启动时仍触发了全量扫描")
try require(database!.fileCount == 7, "健康启动错误修改了缓存计数")
try require(try names("微信").contains("微信输入法.app"), "重启未直接加载持久化索引")

index!.start(roots: [root], watch: true, forceRebuild: true)
try wait("强制重建未完成") { index!.view().scanning == false }
try require(!(try names("微信")).contains("微信输入法.app"), "强制重建未删除过期记录")
try require(database!.fileCount == 6, "强制重建后的增量计数不正确")

// Simulate an app being closed: persist the checkpoint, release the watcher,
// change the filesystem, then reopen and replay the missed FSEvents range.
index!.stop(); index = nil; database = nil
let offline = root.appendingPathComponent("离线新增合同.txt")
try Data("offline".utf8).write(to: offline)
Thread.sleep(forTimeInterval: 0.6)
database = try IndexDatabase(url: databaseURL)
index = FileIndex(timeout: 5, database: database)
index!.start(roots: [root], watch: true)
do {
    try wait("App 关闭期间的 FSEvents 没有补齐", timeout: 20) {
        ((try? names("离线新增")) ?? []).contains("离线新增合同.txt")
    }
    try require(database!.fileCount == 7, "离线事件补齐后的增量计数不正确")
} catch {
    let view = index!.view()
    let found = (try? names("离线新增")) ?? []
    throw NSError(domain: "DatabaseVerification", code: 3,
                  userInfo: [NSLocalizedDescriptionKey: "离线补齐失败：checkpoint=\(database!.checkpoint)，count=\(database!.fileCount)，scanning=\(view.scanning)，errors=\(view.errors)，matches=\(found)"])
}

let permissions = try fm.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? NSNumber
try require(permissions?.intValue == 0o600, "SQLite 文件权限不是 0600")
let corruptURL = store.appendingPathComponent("corrupt.sqlite3")
try Data("not a sqlite database".utf8).write(to: corruptURL)
let recovered = try IndexDatabase.openRecovering(url: corruptURL)
try require(recovered.fileCount == 0, "损坏数据库没有自动恢复")

// A filesystem access warning is not a database consistency failure. Marking
// the snapshot complete prevents the same inaccessible path from triggering a
// full traversal on every launch.
let missingRoot = base.appendingPathComponent("missing-root", isDirectory: true)
let warningURL = store.appendingPathComponent("warning.sqlite3")
let warningDatabase = try IndexDatabase(url: warningURL)
let warningRoot = ScanRoot(url: missingRoot)
let warningIndex = FileIndex(timeout: 2, database: warningDatabase)
warningIndex.start(authorizedRoots: [warningRoot], watch: false)
try wait("不可读目录扫描未结束") { !warningIndex.view().scanning }
try require(try warningDatabase.prepare(roots: [warningRoot]), "访问提示导致下次启动重复全量扫描")

// A failed SQLite update must not acknowledge newer filesystem events. The
// previous checkpoint is intentionally retained so replay can repair the gap.
try warningDatabase.finishUpdate(checkpoint: 1234, complete: true)
try warningDatabase.invalidateCache()
try require(warningDatabase.checkpoint == 1234, "失效缓存错误推进了 FSEvents checkpoint")
try require(!(try warningDatabase.prepare(roots: [warningRoot])), "失效缓存没有触发下次启动重建")

print("PASS：SQLite 持久化、健康启动、短词/拼音/首字母、数字排序、完整命中、类型/日期、异步总数、强制重建、损坏恢复、访问提示、checkpoint 一致性与离线事件补齐均通过。")
