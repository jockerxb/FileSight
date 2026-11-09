import Foundation
import SearchCore

/// Persists only macOS security-scoped read grants. File metadata, search
/// terms, and the in-memory index are deliberately not stored here.
enum DirectoryAuthorizationStore {
    private static let bookmarksKey = "filesight.directory-bookmarks.v1"

    static func restore() -> [ScanRoot] {
        let saved = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
        let roots = saved.compactMap { try? ScanRoot.restored($0) }
        if roots.count != saved.count { save(roots) }
        return roots
    }

    static func save(_ roots: [ScanRoot]) {
        let bookmarks = roots.compactMap(\.authorizationBookmark)
        if bookmarks.isEmpty {
            UserDefaults.standard.removeObject(forKey: bookmarksKey)
        } else {
            UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarksKey)
    }
}
