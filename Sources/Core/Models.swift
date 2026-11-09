import Foundation

enum Provider: String, Codable {
    case gmail, imap, demo

    var label: String {
        switch self {
        case .gmail: return "Gmail"
        case .imap: return "IMAP"
        case .demo: return "Demo"
        }
    }
}

struct Account: Codable, Equatable, Identifiable {
    var id: String
    var email: String
    var displayName: String
    var provider: Provider
    var username: String
    var imapHost: String
    var imapPort: UInt16
    var smtpHost: String
    var smtpPort: UInt16
    var signature: String

    static func gmail(email: String, name: String) -> Account {
        Account(id: UUID().uuidString, email: email, displayName: name, provider: .gmail, username: email,
                imapHost: "imap.gmail.com", imapPort: 993, smtpHost: "smtp.gmail.com", smtpPort: 465, signature: "")
    }

    var fromHeader: EmailAddress { EmailAddress(name: displayName, email: email) }
}

enum FolderRole: String {
    case inbox, starred, important, sent, drafts, all, spam, trash, archive, none

    var sortOrder: Int {
        switch self {
        case .inbox: return 0
        case .starred: return 1
        case .important: return 2
        case .sent: return 3
        case .drafts: return 4
        case .all: return 5
        case .archive: return 6
        case .spam: return 7
        case .trash: return 8
        case .none: return 100
        }
    }

    var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .starred: return "star"
        case .important: return "exclamationmark.circle"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .all: return "archivebox"
        case .archive: return "archivebox"
        case .spam: return "xmark.bin"
        case .trash: return "trash"
        case .none: return "folder"
        }
    }
}

struct Folder: Equatable {
    var id: Int64
    var accountID: String
    var path: String
    var name: String
    var role: FolderRole
    var delimiter: String
    var uidValidity: UInt32
    var uidNext: UInt32
    var modseq: UInt64
    var selectable: Bool
}

struct MessageFlags: OptionSet {
    let rawValue: Int
    static let seen = MessageFlags(rawValue: 1)
    static let flagged = MessageFlags(rawValue: 2)
    static let answered = MessageFlags(rawValue: 4)
    static let draft = MessageFlags(rawValue: 8)
    static let deleted = MessageFlags(rawValue: 16)

    static func from(imapFlags: [String]) -> MessageFlags {
        var f: MessageFlags = []
        for flag in imapFlags {
            switch flag.lowercased() {
            case "\\seen": f.insert(.seen)
            case "\\flagged": f.insert(.flagged)
            case "\\answered": f.insert(.answered)
            case "\\draft": f.insert(.draft)
            case "\\deleted": f.insert(.deleted)
            default: break
            }
        }
        return f
    }
}

struct EmailAddress: Hashable, Codable {
    var name: String
    var email: String

    var display: String { name.isEmpty ? email : name }
    /// Header form. Names containing separators/controls are quoted and escaped so this round-trips
    /// through MIME.parseAddresses as exactly one address.
    var full: String {
        guard !name.isEmpty else { return email }
        let risky = name.contains { c in
            ",;\"<>@".contains(c) || c.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        }
        guard risky else { return "\(name) <\(email)>" }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\" <\(email)>"
    }
}

/// One row in the message list. A class, because NSOutlineView items must be objects.
final class MessageRow {
    let id: Int64
    let folderID: Int64
    let accountID: String
    let uid: UInt32
    let threadID: Int64
    let gmailID: Int64
    let date: Date
    var flags: MessageFlags
    let hasAttachments: Bool
    let subject: String
    let fromName: String
    let fromAddr: String
    let toList: String
    var snippet: String
    let folderRole: FolderRole

    init(id: Int64, folderID: Int64, accountID: String, uid: UInt32, threadID: Int64, gmailID: Int64, date: Date,
         flags: MessageFlags, hasAttachments: Bool, subject: String, fromName: String, fromAddr: String,
         toList: String, snippet: String, folderRole: FolderRole) {
        self.id = id; self.folderID = folderID; self.accountID = accountID; self.uid = uid
        self.threadID = threadID; self.gmailID = gmailID; self.date = date; self.flags = flags
        self.hasAttachments = hasAttachments; self.subject = subject; self.fromName = fromName
        self.fromAddr = fromAddr; self.toList = toList; self.snippet = snippet; self.folderRole = folderRole
    }

    var senderDisplay: String {
        if folderRole == .sent || folderRole == .drafts {
            let to = MIME.parseAddresses(toList).first
            return "To: " + (to?.display ?? toList)
        }
        return fromName.isEmpty ? fromAddr : fromName
    }
}

/// Everything known about one message, for the preview and reply.
struct MessageDetail {
    var id: Int64
    var folderID: Int64
    var accountID: String
    var uid: UInt32
    var date: Date
    var flags: MessageFlags
    var subject: String
    var from: EmailAddress
    var toList: String
    var ccList: String
    var replyTo: String
    var messageIDHeader: String
    var references: String
    var listUnsubscribe: String
    var structure: BodyPart?
    var size: Int
    var folderRole: FolderRole
    /// Header-only fields not carried by every query: In-Reply-To for reply drafts, Bcc for drafts.
    var inReplyTo: String = ""
    var bcc: String = ""
}

/// Parsed header + structure data for a message, built off the main thread from an IMAP FETCH.
struct ParsedHeader {
    var uid: UInt32
    var gmailID: Int64
    var threadID: Int64
    var date: Date
    var size: Int
    var flags: MessageFlags
    var subject: String
    var from: EmailAddress
    var toList: String
    var ccList: String
    var replyTo: String
    var messageID: String
    var inReplyTo: String
    var references: String
    var listUnsubscribe: String
    var structureJSON: String?
    var hasAttachments: Bool
}

struct StoredBody {
    var html: String?
    var text: String?
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

extension Notification.Name {
    static let mailDataChanged = Notification.Name("MacMail.dataChanged")
    static let mailFoldersChanged = Notification.Name("MacMail.foldersChanged")
    static let mailStatusChanged = Notification.Name("MacMail.statusChanged")
    /// Server unread counts changed (sidebar and Dock badge only; the message list doesn't reload).
    static let mailCountsChanged = Notification.Name("MacMail.countsChanged")
    static let mailAccountsChanged = Notification.Name("MacMail.accountsChanged")
    static let themeChanged = Notification.Name("MacMail.themeChanged")
}

/// What changed in the cached mail (the typed payload of `.mailDataChanged`, ARC-09).
enum MailDataChange {
    /// Anything may have changed (settings, account removal).
    case all
    /// Rows in this folder were added, removed or changed.
    case folder(Int64)
    /// Only these messages' flags changed; lists can patch rows in place.
    case flags(ids: [Int64])
}

extension NotificationCenter {
    func postMailDataChanged(_ change: MailDataChange) {
        post(name: .mailDataChanged, object: nil, userInfo: ["change": change])
    }
}

extension Notification {
    /// The change carried by a `.mailDataChanged` notification (`.all` if none was attached).
    var mailDataChange: MailDataChange { userInfo?["change"] as? MailDataChange ?? .all }
}
