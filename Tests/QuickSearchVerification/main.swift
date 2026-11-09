import Foundation
import SearchCore

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "QuickSearchVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func entry(_ name: String, _ modified: Double, _ kind: String = "pdf") -> FileEntry {
    FileEntry(path: "/fixture/\(name)", modified: Date(timeIntervalSince1970: modified), created: Date(timeIntervalSince1970: 10000 - modified), kind: kind)
}
let small = [entry("a/合同.pdf", 100), entry("b/合同.pdf", 90), entry("合同草稿.pdf", 400), entry("去年合同.pdf", 600), entry("合同.txt", 300, "txt"), entry("合同.xlsx", 200, "xlsx"), entry("无关.pdf", 999)]
let ranked = QuickSearch.search(chunks: [small], query: "合同", order: .relevance, ascending: true, limit: 100)!
try require(ranked.total == 6, "匹配项数量错误")
try require(ranked.isComplete, "小型搜索被误标为未完成")
try require(ranked.rows.map(\.name).suffix(2) == ["合同草稿.pdf", "去年合同.pdf"], "包含或前缀匹配盖过了完整名称")
let types = QuickSearch.search(chunks: [small], query: "合同", order: .kind, ascending: true, limit: 100)!
try require(types.rows.map(\.kind) == ["pdf", "pdf", "pdf", "pdf", "txt", "xlsx"], "类型未连续分组")
try require(types.rows.prefix(4).map(\.modified) == [600, 400, 100, 90].map { Date(timeIntervalSince1970: $0) }, "同类型未按最近修改排序")
let reverseTypes = QuickSearch.search(chunks: [small], query: "合同", order: .kind, ascending: false, limit: 100)!
try require(reverseTypes.rows.suffix(4).map(\.modified) == types.rows.prefix(4).map(\.modified), "类型降序错误地倒置了组内时间")
for order in SearchOrder.allCases {
    for ascending in [true, false] {
        let full = QuickSearch.search(chunks: [small], query: "合同", order: order, ascending: ascending, limit: 100)!
        for count in 1...full.total {
            let page = QuickSearch.search(chunks: [small], query: "合同", order: order, ascending: ascending, limit: count)!
            try require(page.rows == Array(full.rows.prefix(count)) && page.total == full.total, "\(order) heap 分页与完整排序不一致")
        }
        if order == .modified || order == .created {
            let dates = full.rows.map { order == .modified ? $0.modified : $0.created }
            try require(dates == dates.sorted(by: ascending ? (<) : (>)), "时间方向错误")
        }
    }
}
try require(QuickSearch.search(chunks: [small], query: "合同 草稿", order: .relevance, ascending: true, limit: 100)!.total == 1, "多关键词错误")
try require(QuickSearch.search(chunks: [small], query: "　", order: .relevance, ascending: true, limit: 100)!.rows.isEmpty, "空搜索不应排序所有文件")
try require(QuickSearch.search(chunks: [[entry("Report-2.pdf", 1), entry("report-10.pdf", 2)]], query: "REPORT", order: .name, ascending: true, limit: 100)!.rows.map(\.name) == ["Report-2.pdf", "report-10.pdf"], "文件名没有按自然数字顺序排列")
try require(QuickSearch.search(chunks: [[entry("RÉSUMÉ.txt", 1, "txt")]], query: "résumé", order: .relevance, ascending: true, limit: 100)!.total == 1, "UTF-8 优化破坏了 Unicode 规范化")

let chinese = [entry("微信支付接入.pdf", 100), entry("合同草稿.docx", 200, "docx")]
try require(QuickSearch.search(chunks: [chinese], query: "weixin", order: .relevance, ascending: true, limit: 100)!.rows.map(\.name) == ["微信支付接入.pdf"], "完整拼音未命中文件")
try require(QuickSearch.search(chunks: [chinese], query: "wxzf", order: .relevance, ascending: true, limit: 100)!.rows.map(\.name) == ["微信支付接入.pdf"], "拼音首字母未命中文件")
try require(QuickSearch.search(chunks: [chinese], query: "hetong", order: .relevance, ascending: true, limit: 100)!.rows.map(\.name) == ["合同草稿.docx"], "另一组拼音未命中文件")

var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
let recent = FileEntry(path: "/fixture/发票-本月.pdf", modified: utc.date(from: DateComponents(year: 2026, month: 10, day: 20))!,
                       created: utc.date(from: DateComponents(year: 2026, month: 9, day: 1))!, kind: "pdf")
let old = FileEntry(path: "/fixture/发票-去年.pdf", modified: utc.date(from: DateComponents(year: 2025, month: 8, day: 1))!,
                    created: utc.date(from: DateComponents(year: 2025, month: 8, day: 1))!, kind: "pdf")
let sheet = FileEntry(path: "/fixture/发票-本月.xlsx", modified: utc.date(from: DateComponents(year: 2026, month: 10, day: 21))!,
                      created: utc.date(from: DateComponents(year: 2026, month: 11, day: 2))!, kind: "xlsx")
let parsed = ParsedSearchQuery.parse("最近1个月发票 pdf", now: now, calendar: utc)
try require(parsed.text == "发票" && parsed.categories == [.pdf] && parsed.date?.basis == .modified, "无空格日期、名称和类型没有正确拆分")
let filtered = QuickSearch.search(pages: [SearchPage(entries: [recent, old, sheet])], parsed: parsed,
                                  order: .relevance, ascending: true, limit: 100)!
try require(filtered.rows == [recent] && filtered.total == 1, "日期与 PDF 联合筛选错误")
let literal = ParsedSearchQuery.parse("发票pdf", now: now, calendar: utc)
try require(literal.text == "发票pdf" && !literal.hasFilters, "没有空格的类型词被误判为筛选条件")
let typeOnly = ParsedSearchQuery.parse("pdf", now: now, calendar: utc)
try require(QuickSearch.search(pages: [SearchPage(entries: [recent, old, sheet])], parsed: typeOnly,
                              order: .modified, ascending: false, limit: 100)!.total == 2, "仅输入类型时没有列出全部 PDF")
let createdThisMonth = ParsedSearchQuery.parse("创建于本月 发票", now: now, calendar: utc)
try require(createdThisMonth.date?.basis == .created &&
            QuickSearch.search(pages: [SearchPage(entries: [recent, old, sheet])], parsed: createdThisMonth,
                               order: .relevance, ascending: true, limit: 100)!.rows == [sheet], "创建时间筛选错误")
let cancel = SearchCancellation(); cancel.cancel()
try require(QuickSearch.search(chunks: [Array(repeating: small, count: 100).flatMap { $0 }], query: "合同", order: .modified, ascending: false, limit: 100, cancellation: cancel) == nil, "取消请求仍返回结果")

var many: [FileEntry] = []
many.reserveCapacity(200_000)
for n in 0..<200_000 { many.append(entry("folder\(n % 1000)/合同-\(n).\(n % 2 == 0 ? "pdf" : "txt")", Double(n), n % 2 == 0 ? "pdf" : "txt")) }
let chunks = stride(from: 0, to: many.count, by: 1024).map { Array(many[$0..<min($0 + 1024, many.count)]) }
let pages = chunks.map { SearchPage(entries: $0) }
let baselineStart = ProcessInfo.processInfo.systemUptime
let baseline = FileSearch.results(in: many, query: "合同", sort: .kind, ascending: true)
let baselineMs = (ProcessInfo.processInfo.systemUptime - baselineStart) * 1000
let fast = QuickSearch.search(pages: pages, query: "合同", order: .kind, ascending: true, limit: 100)!
try require(fast.total == many.count && fast.rows == Array(baseline.prefix(100)), "大数据排序不正确")
let expanded = QuickSearch.search(pages: pages, query: "合同-199", order: .modified, ascending: false, limit: 10_000)!
let expected = many.filter { $0.name.contains("合同-199") }.sorted { $0.modified > $1.modified }
try require(expanded.rows == expected && expanded.total > 100, "展开结果后仍有截断")

let millionPages = Array(repeating: pages, count: 10).flatMap { $0 }
let million = QuickSearch.search(pages: millionPages, query: "合同", order: .kind, ascending: true, limit: 100)!
try require(million.total == 2_000_000, "200 万记录的总数错误")
try require(million.milliseconds < 3000, "200 万记录搜索超过 3 秒：\(million.milliseconds)")
var progressCount = 0
let progressive = QuickSearch.search(pages: pages, parsed: .parse("合同"), order: .relevance, ascending: true,
                                     limit: 100, progressInterval: 0) { _ in progressCount += 1 }!
try require(progressive.isComplete && progressCount > 0, "渐进结果未回调")
let timed = QuickSearch.search(pages: millionPages, query: "合同", order: .relevance, ascending: true,
                               limit: 100, timeLimit: 0)!
try require(!timed.isComplete && timed.milliseconds < 500, "超时搜索没有及时结束")
print(String(format: "PASS：10 种顺序、相关度、同类型时间、分页完整性、取消均正确。20 万记录旧版 %.1f ms，新版 %.1f ms；200 万记录 %.1f ms。", baselineMs, fast.milliseconds, million.milliseconds))
for mode in SearchOrder.allCases {
    let measured = QuickSearch.search(pages: millionPages, query: "合同", order: mode, ascending: mode == .name || mode == .kind || mode == .relevance, limit: 100)!
    print(String(format: "200 万条，%@：%.1f ms", String(describing: mode), measured.milliseconds))
}
let targeted = QuickSearch.search(pages: millionPages, query: "合同-199999", order: .relevance, ascending: true, limit: 100)!
try require(targeted.total == 10, "指纹预筛漏掉了正确匹配")
print(String(format: "200 万条，具体文件名查询：%.1f ms", targeted.milliseconds))
// Compare candidate fingerprints against literal matching over many different
// substrings. A Bloom prefilter must never eliminate a real match.
for query in ["合", "同-", "1999", "PDF", "合同 12", "-0", "不存在", "9.txt", ".", "\0"] {
    let found = QuickSearch.search(pages: pages, query: query, order: .modified, ascending: false, limit: 100)!
    let tokens = FileEntry.normalize(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let expectedCount = many.filter { item in tokens.allSatisfy { item.searchableName.contains($0) } }.count
    try require(found.total == expectedCount, "预筛破坏完整性：\(query)")
}
