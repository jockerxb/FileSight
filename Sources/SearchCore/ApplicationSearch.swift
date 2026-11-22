import Foundation

public struct ApplicationSearchEntry: Equatable {
    public let name: String
    public let path: String
    public let searchableText: String
    public let searchableAliases: [String]

    public init(name: String, path: String, searchableText: String, searchableAliases: [String]) {
        self.name = name
        self.path = path
        self.searchableText = searchableText
        self.searchableAliases = searchableAliases
    }
}

/// Pure, UI-independent app ranking so the launcher contract can be verified
/// without starting AppKit or relying on a developer machine's installed apps.
public enum ApplicationSearch {
    public static func search(_ entries: [ApplicationSearchEntry], queries: [String], limit: Int = 5) -> [ApplicationSearchEntry] {
        let needles = queries.map { FileEntry.normalize($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
        guard !needles.isEmpty else { return [] }

        return entries.compactMap { entry -> (ApplicationSearchEntry, Int, Int)? in
            var best: (rank: Int, queryIndex: Int)?
            for (queryIndex, needle) in needles.enumerated() {
                let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
                guard words.allSatisfy({ entry.searchableText.contains($0) }) else { continue }
                let rank: Int
                if entry.searchableAliases.contains(needle) { rank = 0 }
                else if entry.searchableAliases.contains(where: { $0.hasPrefix(needle) }) { rank = 1 }
                else if entry.searchableAliases.contains(where: { $0.contains(needle) }) { rank = 2 }
                else { rank = 3 }
                if best == nil || rank < best!.rank || (rank == best!.rank && queryIndex < best!.queryIndex) {
                    best = (rank, queryIndex)
                }
            }
            return best.map { (entry, $0.rank, $0.queryIndex) }
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            return $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending
        }.prefix(limit).map(\.0)
    }
}
