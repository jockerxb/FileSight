import Foundation
import Darwin

public enum SearchOrder: Int, CaseIterable { case relevance, modified, created, kind, name }

public final class SearchCancellation {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
    public var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

public struct QuickSearchResult {
    public let rows: [FileEntry]
    public let total: Int
    public let milliseconds: Double
    public let isComplete: Bool
}

public enum QuickSearch {
    private struct Match { let entry: FileEntry; let rank: Int }

    private static func before(_ a: Match, _ b: Match, order: SearchOrder, ascending: Bool) -> Bool {
        let x = a.entry, y = b.entry
        switch order {
        case .relevance:
            if a.rank != b.rank { return ascending ? a.rank < b.rank : a.rank > b.rank }
            if x.modified != y.modified { return x.modified > y.modified }
        case .modified:
            if x.modified != y.modified { return ascending ? x.modified < y.modified : x.modified > y.modified }
        case .created:
            if x.created != y.created { return ascending ? x.created < y.created : x.created > y.created }
        case .kind:
            if x.kind != y.kind { return ascending ? x.kind < y.kind : x.kind > y.kind }
            if x.modified != y.modified { return x.modified > y.modified }
        case .name:
            if x.searchableName != y.searchableName {
                let comparison = x.searchableName.compare(y.searchableName, options: .numeric)
                if comparison != .orderedSame { return ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
            }
        }
        if x.searchableName != y.searchableName { return x.searchableName < y.searchableName }
        return x.path < y.path
    }

    /// Counts every match but sorts only the requested page prefix. A max heap
    /// keeps the worst retained item at its root: O(N log page), not O(N log N).
    /// Increasing limit exposes every match; nothing is excluded from the index.
    public static func search(chunks: [[FileEntry]], query: String, order: SearchOrder, ascending: Bool, limit: Int,
                              cancellation: SearchCancellation = SearchCancellation(), timeLimit: TimeInterval? = nil,
                              progress: ((QuickSearchResult) -> Void)? = nil) -> QuickSearchResult? {
        if cancellation.cancelled { return nil }
        return search(pages: chunks.map { SearchPage(entries: $0) }, parsed: .parse(query), order: order, ascending: ascending,
                      limit: limit, cancellation: cancellation, timeLimit: timeLimit, progress: progress)
    }

    public static func search(pages: [SearchPage], query: String, order: SearchOrder, ascending: Bool, limit: Int,
                              cancellation: SearchCancellation = SearchCancellation(), timeLimit: TimeInterval? = nil,
                              progress: ((QuickSearchResult) -> Void)? = nil) -> QuickSearchResult? {
        search(pages: pages, parsed: .parse(query), order: order, ascending: ascending, limit: limit,
               cancellation: cancellation, timeLimit: timeLimit, progress: progress)
    }

    public static func search(pages: [SearchPage], parsed: ParsedSearchQuery, order: SearchOrder, ascending: Bool, limit: Int,
                              cancellation: SearchCancellation = SearchCancellation(), timeLimit: TimeInterval? = nil,
                              progressInterval: TimeInterval = 0.15,
                              progress: ((QuickSearchResult) -> Void)? = nil) -> QuickSearchResult? {
        let started = ProcessInfo.processInfo.systemUptime
        let needle = FileEntry.normalize(parsed.text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.contains("\0"), limit > 0, !needle.isEmpty || parsed.hasFilters else {
            return QuickSearchResult(rows: [], total: 0, milliseconds: 0, isComplete: true)
        }
        let tokens = needle.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let allowPhonetic = !needle.unicodeScalars.contains { scalar in
            switch scalar.value { case 0x3400...0x9FFF, 0x20000...0x2FA1F: return true; default: return false }
        }
        let mask = NameFingerprint(words: tokens)
        let words = tokens.map { Array($0.utf8CString) }
        var heap: [Match] = []
        heap.reserveCapacity(min(limit, 4096))
        var total = 0, visited = 0
        var complete = true
        var lastProgress = started
        let deadline = timeLimit.map { started + max(0, $0) }
        func better(_ a: Match, _ b: Match) -> Bool { before(a, b, order: order, ascending: ascending) }
        func result(isComplete: Bool) -> QuickSearchResult {
            QuickSearchResult(rows: heap.sorted(by: better).map(\.entry), total: total,
                              milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
                              isComplete: isComplete)
        }
        pageLoop: for page in pages {
            for offset in page.entries.indices {
                visited += 1
                if visited & 255 == 0 {
                    if cancellation.cancelled { return nil }
                    if let deadline, ProcessInfo.processInfo.systemUptime >= deadline {
                        complete = false
                        break pageLoop
                    }
                }
                if !tokens.isEmpty && !page.fingerprints[offset].canContain(mask) &&
                    !(allowPhonetic && page.phoneticFingerprints[offset].canContain(mask)) { continue }
                let entry = page.entries[offset]
                guard parsed.matches(entry) else { continue }
                // Both sides are normalized Unicode. UTF-8 literal matching is
                // equivalent here and avoids Foundation's per-record search
                // machinery. POSIX filenames cannot contain a NUL byte.
                let matches = entry.searchableText.withCString { name in
                    words.allSatisfy { word in word.withUnsafeBufferPointer { strstr(name, $0.baseAddress!) != nil } }
                }
                guard matches else { continue }
                total += 1
                let rank: Int
                if order == .relevance {
                    if entry.searchableName == needle { rank = 0 }
                    else if entry.searchableName.hasPrefix(needle) {
                        rank = entry.searchableName.lastIndex(of: ".").map { entry.searchableName[..<$0] == needle } == true ? 0 : 1
                    } else if entry.searchableName.contains(needle) { rank = 2 }
                    else { rank = 3 }
                } else { rank = 0 }
                let match = Match(entry: entry, rank: rank)
                if heap.count < limit {
                    heap.append(match)
                    var child = heap.count - 1
                    while child > 0 {
                        let parent = (child - 1) / 2
                        if !better(heap[parent], heap[child]) { break }
                        heap.swapAt(parent, child); child = parent
                    }
                } else if better(match, heap[0]) {
                    heap[0] = match
                    var parent = 0
                    while parent * 2 + 1 < heap.count {
                        var child = parent * 2 + 1
                        if child + 1 < heap.count && better(heap[child], heap[child + 1]) { child += 1 }
                        if !better(heap[parent], heap[child]) { break }
                        heap.swapAt(parent, child); parent = child
                    }
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let progress, now - lastProgress >= progressInterval {
                progress(result(isComplete: false))
                lastProgress = now
            }
        }
        guard !cancellation.cancelled else { return nil }
        return result(isComplete: complete)
    }
}
