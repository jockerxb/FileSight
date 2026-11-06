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
    public static func search(chunks: [[FileEntry]], query: String, order: SearchOrder, ascending: Bool, limit: Int, cancellation: SearchCancellation = SearchCancellation()) -> QuickSearchResult? {
        if cancellation.cancelled { return nil }
        return search(pages: chunks.map { SearchPage(entries: $0) }, query: query, order: order, ascending: ascending, limit: limit, cancellation: cancellation)
    }

    public static func search(pages: [SearchPage], query: String, order: SearchOrder, ascending: Bool, limit: Int, cancellation: SearchCancellation = SearchCancellation()) -> QuickSearchResult? {
        let started = ProcessInfo.processInfo.systemUptime
        let needle = FileEntry.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty, !needle.contains("\0"), limit > 0 else { return QuickSearchResult(rows: [], total: 0, milliseconds: 0) }
        let tokens = needle.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let mask = NameFingerprint(words: tokens)
        let words = tokens.map { Array($0.utf8CString) }
        var heap: [Match] = []
        heap.reserveCapacity(min(limit, 4096))
        var total = 0, visited = 0
        func better(_ a: Match, _ b: Match) -> Bool { before(a, b, order: order, ascending: ascending) }
        for page in pages {
            for offset in page.entries.indices {
                visited += 1
                if visited & 255 == 0 && cancellation.cancelled { return nil }
                guard page.fingerprints[offset].canContain(mask) else { continue }
                let entry = page.entries[offset]
                // Both sides are normalized Unicode. UTF-8 literal matching is
                // equivalent here and avoids Foundation's per-record search
                // machinery. POSIX filenames cannot contain a NUL byte.
                let matches = entry.searchableName.withCString { name in
                    words.allSatisfy { word in word.withUnsafeBufferPointer { strstr(name, $0.baseAddress!) != nil } }
                }
                guard matches else { continue }
                total += 1
                let rank: Int
                if order == .relevance {
                    if entry.searchableName == needle { rank = 0 }
                    else if entry.searchableName.hasPrefix(needle) {
                        rank = entry.searchableName.lastIndex(of: ".").map { entry.searchableName[..<$0] == needle } == true ? 0 : 1
                    } else { rank = 2 }
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
        }
        guard !cancellation.cancelled else { return nil }
        let rows = heap.sorted(by: better).map(\.entry)
        return QuickSearchResult(rows: rows, total: total, milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }
}
