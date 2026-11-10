import Foundation

public enum FileCategory: String, CaseIterable, Hashable {
    case pdf, word, spreadsheet, presentation, image, video, audio, folder

    public var title: String {
        switch self {
        case .pdf: "PDF"
        case .word: "Word"
        case .spreadsheet: "表格"
        case .presentation: "演示文稿"
        case .image: "图片"
        case .video: "视频"
        case .audio: "音频"
        case .folder: "文件夹"
        }
    }

    public func contains(kind: String) -> Bool {
        indexedKinds.contains(kind.lowercased())
    }

    public var indexedKinds: Set<String> {
        switch self {
        case .pdf: ["pdf"]
        case .word: ["doc", "docx", "rtf", "pages"]
        case .spreadsheet: ["xls", "xlsx", "csv", "numbers"]
        case .presentation: ["ppt", "pptx", "key"]
        case .image: ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp", "svg"]
        case .video: ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
        case .audio: ["mp3", "m4a", "wav", "aac", "flac", "ogg"]
        case .folder: ["文件夹"]
        }
    }
}

public enum FileDateBasis: String {
    case modified, created
    public var title: String { self == .modified ? "修改时间" : "创建时间" }
}

public struct FileDateFilter {
    public let basis: FileDateBasis
    public let start: Date
    public let end: Date
    public let phrase: String
    public var title: String { "\(basis.title)：\(phrase)" }

    public func contains(_ entry: FileEntry) -> Bool {
        let value = basis == .modified ? entry.modified : entry.created
        return value != .distantPast && value >= start && value < end
    }
}

public struct ParsedSearchQuery {
    public let text: String
    public let categories: Set<FileCategory>
    public let date: FileDateFilter?
    public let withoutCategories: String
    public let withoutDate: String

    public var hasFilters: Bool { !categories.isEmpty || date != nil }
    public var categoryTitle: String {
        FileCategory.allCases.filter(categories.contains).map(\.title).joined(separator: "、")
    }

    public static func parse(_ raw: String, now: Date = Date(), calendar original: Calendar = .current) -> Self {
        let prepared = insertDateBoundary(in: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let tokens = prepared.split(whereSeparator: \.isWhitespace).map(String.init)
        var categories = Set<FileCategory>()
        var categoryIndices = Set<Int>()
        var dateIndex: Int?
        var dateFilter: FileDateFilter?
        var filename: [String] = []
        let calendar = original

        for (index, token) in tokens.enumerated() {
            if let category = category(for: token) {
                categories.insert(category); categoryIndices.insert(index); continue
            }
            if dateFilter == nil, let found = date(for: token, now: now, calendar: calendar) {
                dateFilter = found; dateIndex = index; continue
            }
            filename.append(token)
        }

        func joining(excluding: Set<Int>) -> String {
            tokens.indices.filter { !excluding.contains($0) }.map { tokens[$0] }.joined(separator: " ")
        }
        var dateSet = Set<Int>()
        if let dateIndex { dateSet.insert(dateIndex) }
        return Self(text: filename.joined(separator: " "), categories: categories, date: dateFilter,
                    withoutCategories: joining(excluding: categoryIndices), withoutDate: joining(excluding: dateSet))
    }

    public func matches(_ entry: FileEntry) -> Bool {
        (categories.isEmpty || categories.contains { $0.contains(kind: entry.kind) }) && (date?.contains(entry) ?? true)
    }

    private static func category(for raw: String) -> FileCategory? {
        let token = FileEntry.normalize(raw).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch token {
        case "pdf": return .pdf
        case "word", "doc", "docx": return .word
        case "excel", "xls", "xlsx", "csv", "表格": return .spreadsheet
        case "ppt", "pptx", "keynote", "演示文稿": return .presentation
        case "图片", "image", "images": return .image
        case "视频", "video", "videos": return .video
        case "音频", "audio": return .audio
        case "文件夹", "folder", "folders": return .folder
        default: return nil
        }
    }

    private static func date(for raw: String, now: Date, calendar: Calendar) -> FileDateFilter? {
        var token = raw
        var basis = FileDateBasis.modified
        for prefix in ["创建时间:", "创建时间：", "创建于"] where token.hasPrefix(prefix) {
            basis = .created; token.removeFirst(prefix.count)
        }
        for prefix in ["修改时间:", "修改时间：", "修改于"] where token.hasPrefix(prefix) {
            basis = .modified; token.removeFirst(prefix.count)
        }
        let startOfToday = calendar.startOfDay(for: now)
        func result(_ interval: DateInterval, _ phrase: String = "") -> FileDateFilter {
            FileDateFilter(basis: basis, start: interval.start, end: interval.end, phrase: phrase.isEmpty ? token : phrase)
        }
        switch token {
        case "今天":
            return result(DateInterval(start: startOfToday, end: calendar.date(byAdding: .day, value: 1, to: startOfToday)!))
        case "昨天":
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
            return result(DateInterval(start: start, end: startOfToday))
        case "本周":
            return calendar.dateInterval(of: .weekOfYear, for: now).map { result($0) }
        case "本月":
            return calendar.dateInterval(of: .month, for: now).map { result($0) }
        case "今年":
            return calendar.dateInterval(of: .year, for: now).map { result($0) }
        default: break
        }

        if let match = captures(#"^最近(\d+)(天|周|个月|月|年)$"#, in: token), let amount = Int(match[0]), amount > 0, amount <= 999 {
            let unit: Calendar.Component
            let count: Int
            switch match[1] {
            case "天": unit = .day; count = amount
            case "周": unit = .day; count = amount * 7
            case "个月", "月": unit = .month; count = amount
            default: unit = .year; count = amount
            }
            guard let start = calendar.date(byAdding: unit, value: -count, to: now) else { return nil }
            return result(DateInterval(start: start, end: now.addingTimeInterval(0.001)))
        }
        if let match = captures(#"^(\d{4})年(\d{1,2})月$"#, in: token), let year = Int(match[0]), let month = Int(match[1]) {
            return monthInterval(year: year, month: month, basis: basis, phrase: token, calendar: calendar)
        }
        if let match = captures(#"^(\d{4})-(\d{1,2})$"#, in: token), let year = Int(match[0]), let month = Int(match[1]) {
            return monthInterval(year: year, month: month, basis: basis, phrase: token, calendar: calendar)
        }
        return nil
    }

    private static func monthInterval(year: Int, month: Int, basis: FileDateBasis, phrase: String, calendar: Calendar) -> FileDateFilter? {
        guard (1...12).contains(month), let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return FileDateFilter(basis: basis, start: start, end: end, phrase: phrase)
    }

    private static func insertDateBoundary(in raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let phrase = #"(?:今天|昨天|本周|本月|今年|最近\d+(?:天|周|个月|月|年)|\d{4}年\d{1,2}月|\d{4}-\d{1,2})"#
        let prefixes = ["", "创建于", "修改于", "创建时间:", "创建时间：", "修改时间:", "修改时间："]
        for prefix in prefixes {
            let expression = try! NSRegularExpression(pattern: "^(\(NSRegularExpression.escapedPattern(for: prefix))\(phrase))(?=\\S)")
            let range = NSRange(raw.startIndex..., in: raw)
            if let match = expression.firstMatch(in: raw, range: range), let swiftRange = Range(match.range(at: 1), in: raw), swiftRange.upperBound < raw.endIndex {
                return String(raw[..<swiftRange.upperBound]) + " " + String(raw[swiftRange.upperBound...])
            }
        }
        return raw
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range), match.range == range else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
