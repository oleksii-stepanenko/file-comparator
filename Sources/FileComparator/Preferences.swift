import AppKit
import DiffCore

struct RecentComparison: Codable, Identifiable, Hashable {
    var id = UUID()
    var paths: [String]
    var date: Date
    var kind: String

    var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }
    var title: String { paths.map { ($0 as NSString).lastPathComponent }.joined(separator: "  ↔  ") }
}

/// UserDefaults-backed app preferences.
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    var fontSize: CGFloat {
        get { let v = defaults.double(forKey: "fontSize"); return v > 0 ? CGFloat(v) : 12.5 }
        set { defaults.set(Double(min(28, max(8, newValue))), forKey: "fontSize") }
    }

    var fontName: String {
        get { defaults.string(forKey: "fontName") ?? "SF Mono" }
        set { defaults.set(newValue, forKey: "fontName") }
    }

    var lineSpacing: CGFloat {
        get { let v = defaults.double(forKey: "lineSpacing"); return v > 0 ? CGFloat(v) : 1.32 }
        set { defaults.set(Double(newValue), forKey: "lineSpacing") }
    }

    var compareOptions: CompareOptions {
        get {
            guard let d = defaults.data(forKey: "compareOptions"),
                  let o = try? JSONDecoder().decode(CompareOptions.self, from: d) else { return CompareOptions() }
            return o
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "compareOptions") }
    }

    var viewMode: ViewMode {
        get {
            guard let d = defaults.data(forKey: "viewMode"),
                  let m = try? JSONDecoder().decode(ViewMode.self, from: d) else { return .all }
            return m
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "viewMode") }
    }

    var inlineGranularity: InlineGranularity {
        get { InlineGranularity(rawValue: defaults.string(forKey: "inlineGranularity") ?? "") ?? .word }
        set { defaults.set(newValue.rawValue, forKey: "inlineGranularity") }
    }

    var showWhitespace: Bool {
        get { defaults.bool(forKey: "showWhitespace") }
        set { defaults.set(newValue, forKey: "showWhitespace") }
    }

    var showLineNumbers: Bool {
        get { defaults.object(forKey: "showLineNumbers") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showLineNumbers") }
    }

    /// Context size used by the "Changes + context" view mode.
    var contextLines: Int {
        get { let v = defaults.integer(forKey: "contextLines"); return v > 0 ? v : 3 }
        set { defaults.set(max(1, newValue), forKey: "contextLines") }
    }

    var folderOptions: FolderCompareOptions {
        get {
            guard let d = defaults.data(forKey: "folderOptions"),
                  let o = try? JSONDecoder().decode(FolderCompareOptions.self, from: d) else { return FolderCompareOptions() }
            return o
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "folderOptions") }
    }

    var recents: [RecentComparison] {
        get {
            guard let d = defaults.data(forKey: "recents"),
                  let r = try? JSONDecoder().decode([RecentComparison].self, from: d) else { return [] }
            return r
        }
        set { defaults.set(try? JSONEncoder().encode(Array(newValue.prefix(14))), forKey: "recents") }
    }

    func addRecent(urls: [URL], kind: String) {
        var list = recents
        let paths = urls.map(\.path)
        list.removeAll { $0.paths == paths }
        list.insert(RecentComparison(paths: paths, date: Date(), kind: kind), at: 0)
        recents = list
        NotificationCenter.default.post(name: .recentsChanged, object: nil)
    }

    func removeRecent(_ item: RecentComparison) {
        recents = recents.filter { $0.id != item.id }
        NotificationCenter.default.post(name: .recentsChanged, object: nil)
    }

    func clearRecents() {
        recents = []
        NotificationCenter.default.post(name: .recentsChanged, object: nil)
    }
}

extension Notification.Name {
    static let recentsChanged = Notification.Name("FCRecentsChanged")
    static let openRequest = Notification.Name("FCOpenRequest")
    static let fontChanged = Notification.Name("FCFontChanged")
}
