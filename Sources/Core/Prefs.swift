import Foundation

/// User settings, backed by UserDefaults.
enum Prefs {
    /// Demo mode keeps its own settings so screenshot runs never touch the real app's accounts or preferences.
    static let d: UserDefaults = AppPaths.isDemo
        ? (UserDefaults(suiteName: "com.manikpruthi.macmail.demo") ?? .standard) : .standard

    static func register() {
        d.register(defaults: [
            "offlineDays": 30,
            "groupByConversation": false,
            "imageMaxMB": 2.0,
            "imageMessageMaxMB": 10.0,
            "askBeforeImages": false,
            "markReadOnOpen": true,
            "undoSendSeconds": 10,
            "notifyNewMail": true,
            "theme": "system",
            "sortOrder": "dateDesc",
            "compactRows": false,
        ])
    }

    /// How many days of mail are kept offline per folder (at least the newest 200 messages are always kept).
    static var offlineDays: Int {
        get { max(1, d.integer(forKey: "offlineDays")) }
        set { d.set(newValue, forKey: "offlineDays") }
    }

    static var groupByConversationDefault: Bool {
        get { d.bool(forKey: "groupByConversation") }
        set { d.set(newValue, forKey: "groupByConversation") }
    }

    static func groupByConversation(folderKey: String) -> Bool {
        if d.object(forKey: "group." + folderKey) == nil { return groupByConversationDefault }
        return d.bool(forKey: "group." + folderKey)
    }

    static func setGroupByConversation(_ on: Bool, folderKey: String) {
        d.set(on, forKey: "group." + folderKey)
    }

    static var imageMaxBytes: Int { Int(d.double(forKey: "imageMaxMB") * 1_048_576) }
    static var imageMessageMaxBytes: Int { Int(d.double(forKey: "imageMessageMaxMB") * 1_048_576) }
    static var imageMaxMB: Double {
        get { d.double(forKey: "imageMaxMB") }
        set { d.set(newValue, forKey: "imageMaxMB") }
    }
    static var imageMessageMaxMB: Double {
        get { d.double(forKey: "imageMessageMaxMB") }
        set { d.set(newValue, forKey: "imageMessageMaxMB") }
    }
    static var askBeforeImages: Bool {
        get { d.bool(forKey: "askBeforeImages") }
        set { d.set(newValue, forKey: "askBeforeImages") }
    }
    static var markReadOnOpen: Bool {
        get { d.bool(forKey: "markReadOnOpen") }
        set { d.set(newValue, forKey: "markReadOnOpen") }
    }
    static var undoSendSeconds: Int {
        get { d.integer(forKey: "undoSendSeconds") }
        set { d.set(newValue, forKey: "undoSendSeconds") }
    }
    static var notifyNewMail: Bool {
        get { d.bool(forKey: "notifyNewMail") }
        set { d.set(newValue, forKey: "notifyNewMail") }
    }

    /// Message list order (F-24).
    enum SortOrder: String, CaseIterable {
        case dateDesc, dateAsc, sender, subject
        var label: String {
            switch self {
            case .dateDesc: return "Newest First"
            case .dateAsc: return "Oldest First"
            case .sender: return "Sender"
            case .subject: return "Subject"
            }
        }
    }

    static var sortOrder: SortOrder {
        get { SortOrder(rawValue: d.string(forKey: "sortOrder") ?? "") ?? .dateDesc }
        set { d.set(newValue.rawValue, forKey: "sortOrder") }
    }

    /// Two-line rows instead of three (F-24).
    static var compactRows: Bool {
        get { d.bool(forKey: "compactRows") }
        set { d.set(newValue, forKey: "compactRows") }
    }

    /// Per-account new-mail notifications (F-23); accounts are on unless switched off.
    static func notifications(for accountID: String) -> Bool {
        d.object(forKey: "notify." + accountID) == nil || d.bool(forKey: "notify." + accountID)
    }

    static func setNotifications(_ on: Bool, for accountID: String) {
        d.set(on, forKey: "notify." + accountID)
    }

    enum Theme: String, CaseIterable {
        case system, light, dark
        var label: String {
            switch self {
            case .system: return "Match macOS"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    /// App theme. "system" follows macOS (the default).
    static var theme: Theme {
        get { Theme(rawValue: d.string(forKey: "theme") ?? "system") ?? .system }
        set { d.set(newValue.rawValue, forKey: "theme") }
    }

    /// Images are shrunk to at most this many pixels on the long side before WebKit sees them.
    static let imageMaxPixels = 2400
    /// HTML beyond this size is clipped, like Gmail's "View entire message".
    static let htmlClipBytes = 512 * 1024
    static let imageCacheBytes = 200 * 1_048_576

    static var accounts: [Account] {
        get {
            guard let data = d.data(forKey: "accounts"),
                  let list = try? JSONDecoder().decode([Account].self, from: data) else { return [] }
            return list
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "accounts") }
    }

    static var defaultAccountID: String? {
        get { d.string(forKey: "defaultAccount") }
        set { d.set(newValue, forKey: "defaultAccount") }
    }
}

enum AppPaths {
    static let isDemo = ProcessInfo.processInfo.environment["MAC_MAIL_DEMO"] == "1"

    /// Resolved and created once (O-22): these used to run createDirectory on every access, including per image.
    /// MAC_MAIL_SUPPORT_DIR / MAC_MAIL_CACHE_DIR redirect them for the offline tests.
    static let support: URL = {
        let env = ProcessInfo.processInfo.environment
        let dir: URL
        if let custom = env["MAC_MAIL_SUPPORT_DIR"], !custom.isEmpty {
            dir = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent(isDemo ? "MacMailDemo" : "MacMail", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let caches: URL = {
        let env = ProcessInfo.processInfo.environment
        let dir: URL
        if let custom = env["MAC_MAIL_CACHE_DIR"], !custom.isEmpty {
            dir = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent("com.manikpruthi.macmail", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let imageCache: URL = {
        let dir = caches.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Unsent composers are autosaved here so a crash or forced quit can't lose them (F-06).
    static let autosave: URL = {
        let dir = support.appendingPathComponent("Autosave", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Messages waiting to be sent while offline (F-07): one folder per message with its MIME and metadata.
    static let outbox: URL = {
        let dir = support.appendingPathComponent("Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func tempDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMail", isDirectory: true)
            .appendingPathComponent(name + "-" + UUID().uuidString.prefix(8), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Total size of the files under a directory (diagnostics).
    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }
}
