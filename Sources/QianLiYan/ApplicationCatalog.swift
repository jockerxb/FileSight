import AppKit
import SearchCore

struct ApplicationEntry {
    let name: String
    let path: String
    let searchableName: String
    let searchableText: String
    let searchableAliases: [String]
}

enum ApplicationCatalog {
    static func load() -> [ApplicationEntry] {
        let fm = FileManager.default
        let homeApplications = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        // App discovery is independent from the user's file-search scope and
        // uses only standard local application locations that macOS exposes to
        // sandboxed launchers without a document-directory grant.
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                     URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
                     URL(fileURLWithPath: "/Library/CoreServices/Applications", isDirectory: true),
                     homeApplications]
        let keys: Set<URLResourceKey> = [.isApplicationKey, .isDirectoryKey, .localizedNameKey]
        var entries: [ApplicationEntry] = []
        var seen = Set<String>()
        for root in roots where fm.fileExists(atPath: root.path) {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard seen.insert(canonical).inserted else { continue }
                let values = try? url.resourceValues(forKeys: keys)
                let packageName = url.deletingPathExtension().lastPathComponent
                let resourceName = values?.localizedName.flatMap(Self.withoutAppSuffix)
                let bundle = Bundle(url: url)
                let localizedInfo = Self.localizedInfo(at: url, bundle: bundle)
                    ?? bundle?.localizedInfoDictionary
                let name = (localizedInfo?["CFBundleDisplayName"] as? String)
                    ?? (localizedInfo?["CFBundleName"] as? String)
                    ?? resourceName
                    ?? packageName
                let aliases = [name,
                               localizedInfo?["CFBundleDisplayName"] as? String,
                               localizedInfo?["CFBundleName"] as? String,
                               bundle?.infoDictionary?["CFBundleDisplayName"] as? String,
                               bundle?.infoDictionary?["CFBundleName"] as? String,
                               resourceName, packageName].compactMap { $0 }
                var searchableAliases: [String] = []
                var seenAliases = Set<String>()
                for alias in aliases {
                    let normalized = FileEntry.normalize(alias)
                    if !normalized.isEmpty, seenAliases.insert(normalized).inserted { searchableAliases.append(normalized) }
                    for phonetic in FileEntry.phoneticText(alias).split(whereSeparator: \.isWhitespace).map(String.init)
                        where seenAliases.insert(phonetic).inserted {
                        searchableAliases.append(phonetic)
                    }
                }
                entries.append(ApplicationEntry(name: name, path: url.path,
                                                searchableName: FileEntry.normalize(name),
                                                searchableText: searchableAliases.joined(separator: " "),
                                                searchableAliases: searchableAliases))
            }
        }
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func withoutAppSuffix(_ name: String) -> String {
        name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// System apps on recent macOS releases store localized bundle names in an
    /// InfoPlist.loctable. URLResourceValues and Bundle can both return the
    /// English package name when the host app has a different localization set,
    /// so resolve the table against the user's preferred languages directly.
    private static func localizedInfo(at appURL: URL, bundle: Bundle?) -> [String: Any]? {
        let tableURL = appURL.appendingPathComponent("Contents/Resources/InfoPlist.loctable")
        if let data = try? Data(contentsOf: tableURL),
           let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for key in preferredLocalizationKeys() {
                if let info = table[key] as? [String: Any] { return info }
            }
        }

        // Many third-party apps (including WeChat) use the older
        // <language>.lproj/InfoPlist.strings layout instead of a loctable.
        let available = bundle?.localizations ?? []
        let preferred = Bundle.preferredLocalizations(from: available, forPreferences: Locale.preferredLanguages)
        let candidates = preferred + preferredLocalizationKeys().flatMap { key in
            [key, key.replacingOccurrences(of: "_", with: "-")]
        }
        let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        var seen = Set<String>()
        for localization in candidates where seen.insert(localization).inserted {
            let strings = resources.appendingPathComponent("\(localization).lproj/InfoPlist.strings")
            guard let data = try? Data(contentsOf: strings),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            return info
        }
        return nil
    }

    private static func preferredLocalizationKeys() -> [String] {
        var keys: [String] = []
        for language in Locale.preferredLanguages {
            let normalized = language.replacingOccurrences(of: "-", with: "_")
            keys.append(normalized)
            let lower = normalized.lowercased()
            if lower.hasPrefix("zh") {
                if lower.contains("hant") || lower.contains("_tw") {
                    keys.append("zh_Hant")
                    keys.append("zh_TW")
                } else if lower.contains("_hk") || lower.contains("_mo") {
                    keys.append("zh_Hant")
                    keys.append("zh_HK")
                } else {
                    keys.append("zh_Hans")
                    keys.append("zh_CN")
                }
            }
            if let base = normalized.split(separator: "_").first {
                keys.append(String(base))
            }
        }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    static func search(_ entries: [ApplicationEntry], query: String, limit: Int = 5) -> [ApplicationEntry] {
        let needle = FileEntry.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.compactMap { entry -> (ApplicationEntry, Int)? in
            guard words.allSatisfy({ entry.searchableText.contains($0) }) else { return nil }
            let rank: Int
            if entry.searchableAliases.contains(needle) { rank = 0 }
            else if entry.searchableAliases.contains(where: { $0.hasPrefix(needle) }) { rank = 1 }
            else if entry.searchableAliases.contains(where: { $0.contains(needle) }) { rank = 2 }
            else { rank = 3 }
            return (entry, rank)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending
        }.prefix(limit).map(\.0)
    }
}
