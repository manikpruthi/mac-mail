import Foundation

/// The offline cache: folders, message headers, fetched bodies, full-text index and the pending-action queue.
/// Everything lives on disk; the UI loads only the rows it shows.
@MainActor
final class Store {
    let db: SQLiteDB

    init() throws {
        let path = AppPaths.support.appendingPathComponent("mail.sqlite").path
        db = try SQLiteDB(path: path)
        try migrate()
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS folders(
            id INTEGER PRIMARY KEY, account TEXT NOT NULL, path TEXT NOT NULL, name TEXT NOT NULL,
            role TEXT NOT NULL, delim TEXT NOT NULL DEFAULT '/', uidvalidity INTEGER NOT NULL DEFAULT 0,
            uidnext INTEGER NOT NULL DEFAULT 0, modseq INTEGER NOT NULL DEFAULT 0,
            selectable INTEGER NOT NULL DEFAULT 1, UNIQUE(account, path));
        CREATE TABLE IF NOT EXISTS messages(
            id INTEGER PRIMARY KEY, folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
            uid INTEGER NOT NULL, gmsgid INTEGER NOT NULL DEFAULT 0, thrid INTEGER NOT NULL DEFAULT 0,
            date REAL NOT NULL, size INTEGER NOT NULL DEFAULT 0, flags INTEGER NOT NULL DEFAULT 0,
            has_att INTEGER NOT NULL DEFAULT 0, subject TEXT NOT NULL DEFAULT '', from_name TEXT NOT NULL DEFAULT '',
            from_addr TEXT NOT NULL DEFAULT '', to_list TEXT NOT NULL DEFAULT '', cc_list TEXT NOT NULL DEFAULT '',
            reply_to TEXT NOT NULL DEFAULT '', message_id TEXT NOT NULL DEFAULT '', in_reply_to TEXT NOT NULL DEFAULT '',
            refs TEXT NOT NULL DEFAULT '', list_unsub TEXT NOT NULL DEFAULT '', snippet TEXT NOT NULL DEFAULT '',
            structure TEXT, UNIQUE(folder_id, uid));
        CREATE INDEX IF NOT EXISTS msg_folder_date ON messages(folder_id, date DESC);
        CREATE INDEX IF NOT EXISTS msg_from ON messages(from_addr);
        CREATE TABLE IF NOT EXISTS bodies(
            message_id INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
            html TEXT, text TEXT, fetched REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS pending_ops(
            id INTEGER PRIMARY KEY, account TEXT NOT NULL, kind TEXT NOT NULL, folder_path TEXT NOT NULL,
            uids TEXT NOT NULL, arg TEXT NOT NULL DEFAULT '', created REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS prefs(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
            subject, from_name, from_addr, to_list, snippet, content='messages', content_rowid='id',
            tokenize='unicode61 remove_diacritics 2');
        CREATE TRIGGER IF NOT EXISTS msg_ai AFTER INSERT ON messages BEGIN
            INSERT INTO fts(rowid, subject, from_name, from_addr, to_list, snippet)
            VALUES (new.id, new.subject, new.from_name, new.from_addr, new.to_list, new.snippet);
        END;
        CREATE TRIGGER IF NOT EXISTS msg_ad AFTER DELETE ON messages BEGIN
            INSERT INTO fts(fts, rowid, subject, from_name, from_addr, to_list, snippet)
            VALUES ('delete', old.id, old.subject, old.from_name, old.from_addr, old.to_list, old.snippet);
        END;
        CREATE TRIGGER IF NOT EXISTS msg_au AFTER UPDATE OF subject, snippet ON messages BEGIN
            INSERT INTO fts(fts, rowid, subject, from_name, from_addr, to_list, snippet)
            VALUES ('delete', old.id, old.subject, old.from_name, old.from_addr, old.to_list, old.snippet);
            INSERT INTO fts(rowid, subject, from_name, from_addr, to_list, snippet)
            VALUES (new.id, new.subject, new.from_name, new.from_addr, new.to_list, new.snippet);
        END;
        """)
    }

    // MARK: Folders

    private func folderFrom(_ s: Statement) -> Folder {
        Folder(id: s.int64(0), accountID: s.text(1), path: s.text(2), name: s.text(3),
               role: FolderRole(rawValue: s.text(4)) ?? .none, delimiter: s.text(5),
               uidValidity: UInt32(truncatingIfNeeded: s.int64(6)), uidNext: UInt32(truncatingIfNeeded: s.int64(7)),
               modseq: UInt64(bitPattern: s.int64(8)), selectable: s.int(9) != 0)
    }

    private let folderCols = "id, account, path, name, role, delim, uidvalidity, uidnext, modseq, selectable"

    func folders(account: String) -> [Folder] {
        var out: [Folder] = []
        db.query("SELECT \(folderCols) FROM folders WHERE account=?", [account]) { out.append(self.folderFrom($0)) }
        return out.sorted {
            if $0.role.sortOrder != $1.role.sortOrder { return $0.role.sortOrder < $1.role.sortOrder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func folder(_ id: Int64) -> Folder? {
        var out: Folder?
        db.query("SELECT \(folderCols) FROM folders WHERE id=?", [id]) { out = self.folderFrom($0) }
        return out
    }

    func folder(account: String, role: FolderRole) -> Folder? {
        var out: Folder?
        db.query("SELECT \(folderCols) FROM folders WHERE account=? AND role=? LIMIT 1", [account, role.rawValue]) {
            out = self.folderFrom($0)
        }
        return out
    }

    func folder(account: String, path: String) -> Folder? {
        var out: Folder?
        db.query("SELECT \(folderCols) FROM folders WHERE account=? AND path=?", [account, path]) { out = self.folderFrom($0) }
        return out
    }

    /// Replaces the account's folder list with what the server reported, keeping sync state for known folders.
    func upsertFolders(account: String, _ listed: [ListedFolder], isGmail: Bool) {
        db.transaction {
            var keep = Set<String>()
            for f in listed {
                keep.insert(f.path)
                let name = Self.displayName(f, isGmail: isGmail)
                db.run("""
                    INSERT INTO folders(account, path, name, role, delim, selectable) VALUES (?,?,?,?,?,?)
                    ON CONFLICT(account, path) DO UPDATE SET name=excluded.name, role=excluded.role,
                    delim=excluded.delim, selectable=excluded.selectable
                    """, [account, f.path, name, f.role.rawValue, f.delimiter, f.selectable])
            }
            var stale: [Int64] = []
            db.query("SELECT id, path FROM folders WHERE account=?", [account]) {
                if !keep.contains($0.text(1)) { stale.append($0.int64(0)) }
            }
            for id in stale { db.run("DELETE FROM folders WHERE id=?", [id]) }
        }
    }

    static func displayName(_ f: ListedFolder, isGmail: Bool) -> String {
        switch f.role {
        case .inbox: return "Inbox"
        case .sent: return "Sent"
        case .drafts: return "Drafts"
        case .spam: return "Spam"
        case .trash: return "Trash"
        case .all: return "All Mail"
        case .starred: return "Starred"
        case .important: return "Important"
        case .archive: return "Archive"
        case .none:
            var p = f.path
            if isGmail, p.hasPrefix("[Gmail]" + f.delimiter) { p = String(p.dropFirst(8)) }
            return p
        }
    }

    func updateFolderState(_ id: Int64, uidValidity: UInt32, uidNext: UInt32, modseq: UInt64) {
        db.run("UPDATE folders SET uidvalidity=?, uidnext=?, modseq=? WHERE id=?", [uidValidity, uidNext, modseq, id])
    }

    func resetFolder(_ id: Int64) {
        db.run("DELETE FROM messages WHERE folder_id=?", [id])
        db.run("UPDATE folders SET uidvalidity=0, uidnext=0, modseq=0 WHERE id=?", [id])
    }

    func deleteAccount(_ account: String) {
        db.run("DELETE FROM folders WHERE account=?", [account])
        db.run("DELETE FROM pending_ops WHERE account=?", [account])
    }

    // MARK: Messages

    func insert(folderID: Int64, _ headers: [ParsedHeader]) {
        guard !headers.isEmpty else { return }
        db.transaction {
            for h in headers {
                db.run("""
                    INSERT INTO messages(folder_id, uid, gmsgid, thrid, date, size, flags, has_att, subject, from_name,
                        from_addr, to_list, cc_list, reply_to, message_id, in_reply_to, refs, list_unsub, structure)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(folder_id, uid) DO UPDATE SET flags=excluded.flags
                    """, [folderID, h.uid, h.gmailID, h.threadID, h.date, h.size, h.flags.rawValue, h.hasAttachments,
                          h.subject, h.from.name, h.from.email.lowercased(), h.toList, h.ccList, h.replyTo, h.messageID,
                          h.inReplyTo, h.references, h.listUnsubscribe, h.structureJSON])
            }
        }
    }

    func updateFlags(folderID: Int64, _ changes: [(UInt32, MessageFlags)]) {
        guard !changes.isEmpty else { return }
        db.transaction {
            for (uid, f) in changes {
                db.run("UPDATE messages SET flags=? WHERE folder_id=? AND uid=?", [f.rawValue, folderID, uid])
            }
        }
    }

    func setFlag(messageIDs: [Int64], flag: MessageFlags, on: Bool) {
        db.transaction {
            for id in messageIDs {
                if on {
                    db.run("UPDATE messages SET flags = flags | ? WHERE id=?", [flag.rawValue, id])
                } else {
                    db.run("UPDATE messages SET flags = flags & ~? WHERE id=?", [flag.rawValue, id])
                }
            }
        }
    }

    func deleteMessages(folderID: Int64, uids: [UInt32]) {
        guard !uids.isEmpty else { return }
        db.transaction {
            for u in uids { db.run("DELETE FROM messages WHERE folder_id=? AND uid=?", [folderID, u]) }
        }
    }

    func deleteMessages(ids: [Int64]) {
        db.transaction {
            for id in ids { db.run("DELETE FROM messages WHERE id=?", [id]) }
        }
    }

    func localUIDs(folderID: Int64) -> [UInt32] {
        var out: [UInt32] = []
        db.query("SELECT uid FROM messages WHERE folder_id=?", [folderID]) { out.append(UInt32(truncatingIfNeeded: $0.int64(0))) }
        return out
    }

    func minUID(folderID: Int64) -> UInt32? {
        db.scalarInt("SELECT MIN(uid) FROM messages WHERE folder_id=?", [folderID]).flatMap { $0 > 0 ? UInt32(truncatingIfNeeded: $0) : nil }
    }

    func maxUID(folderID: Int64) -> UInt32? {
        db.scalarInt("SELECT MAX(uid) FROM messages WHERE folder_id=?", [folderID]).flatMap { $0 > 0 ? UInt32(truncatingIfNeeded: $0) : nil }
    }

    func messageCount(folderID: Int64) -> Int {
        Int(db.scalarInt("SELECT COUNT(*) FROM messages WHERE folder_id=?", [folderID]) ?? 0)
    }

    private let rowCols = """
        m.id, m.folder_id, f.account, m.uid, m.thrid, m.gmsgid, m.date, m.flags, m.has_att, m.subject, m.from_name,
        m.from_addr, m.to_list, m.snippet, f.role
        """

    private func rowFrom(_ s: Statement) -> MessageRow {
        MessageRow(id: s.int64(0), folderID: s.int64(1), accountID: s.text(2), uid: UInt32(truncatingIfNeeded: s.int64(3)),
                   threadID: s.int64(4), gmailID: s.int64(5), date: Date(timeIntervalSince1970: s.double(6)),
                   flags: MessageFlags(rawValue: s.int(7)), hasAttachments: s.int(8) != 0, subject: s.text(9),
                   fromName: s.text(10), fromAddr: s.text(11), toList: s.text(12), snippet: s.text(13),
                   folderRole: FolderRole(rawValue: s.text(14)) ?? .none)
    }

    func rows(folderID: Int64) -> [MessageRow] {
        var out: [MessageRow] = []
        db.query("SELECT \(rowCols) FROM messages m JOIN folders f ON f.id=m.folder_id WHERE m.folder_id=? ORDER BY m.date DESC",
                 [folderID]) { out.append(self.rowFrom($0)) }
        return out
    }

    func unifiedInboxRows() -> [MessageRow] {
        var out: [MessageRow] = []
        db.query("SELECT \(rowCols) FROM messages m JOIN folders f ON f.id=m.folder_id WHERE f.role='inbox' ORDER BY m.date DESC") {
            out.append(self.rowFrom($0))
        }
        return out
    }

    func rows(ids: [Int64]) -> [MessageRow] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(String.init).joined(separator: ",")
        var out: [MessageRow] = []
        db.query("SELECT \(rowCols) FROM messages m JOIN folders f ON f.id=m.folder_id WHERE m.id IN (\(list)) ORDER BY m.date DESC") {
            out.append(self.rowFrom($0))
        }
        return out
    }

    func ids(folderID: Int64, uids: [UInt32]) -> [Int64] {
        guard !uids.isEmpty else { return [] }
        let list = uids.map(String.init).joined(separator: ",")
        var out: [Int64] = []
        db.query("SELECT id FROM messages WHERE folder_id=? AND uid IN (\(list))", [folderID]) { out.append($0.int64(0)) }
        return out
    }

    func detail(_ id: Int64) -> MessageDetail? {
        var out: MessageDetail?
        db.query("""
            SELECT m.id, m.folder_id, f.account, m.uid, m.date, m.flags, m.subject, m.from_name, m.from_addr, m.to_list,
                   m.cc_list, m.reply_to, m.message_id, m.refs, m.list_unsub, m.structure, m.size, f.role
            FROM messages m JOIN folders f ON f.id=m.folder_id WHERE m.id=?
            """, [id]) { s in
            out = MessageDetail(
                id: s.int64(0), folderID: s.int64(1), accountID: s.text(2), uid: UInt32(truncatingIfNeeded: s.int64(3)),
                date: Date(timeIntervalSince1970: s.double(4)), flags: MessageFlags(rawValue: s.int(5)), subject: s.text(6),
                from: EmailAddress(name: s.text(7), email: s.text(8)), toList: s.text(9), ccList: s.text(10),
                replyTo: s.text(11), messageIDHeader: s.text(12), references: s.text(13), listUnsubscribe: s.text(14),
                structure: BodyPart.fromJSON(s.string(15)), size: s.int(16), folderRole: FolderRole(rawValue: s.text(17)) ?? .none)
        }
        return out
    }

    // MARK: Bodies

    func body(_ id: Int64) -> StoredBody? {
        var out: StoredBody?
        db.query("SELECT html, text FROM bodies WHERE message_id=?", [id]) { out = StoredBody(html: $0.string(0), text: $0.string(1)) }
        return out
    }

    func hasBody(_ id: Int64) -> Bool {
        db.scalarInt("SELECT 1 FROM bodies WHERE message_id=?", [id]) != nil
    }

    func saveBody(_ id: Int64, html: String?, text: String?) {
        db.run("INSERT OR REPLACE INTO bodies(message_id, html, text, fetched) VALUES (?,?,?,?)", [id, html, text, Date()])
        let snip = MIME.snippet(html: html, text: text)
        db.run("UPDATE messages SET snippet=? WHERE id=?", [snip, id])
    }

    /// Newest messages in a folder whose body has not been cached yet (for background prefetch).
    func messagesNeedingBody(folderID: Int64, limit: Int) -> [Int64] {
        var out: [Int64] = []
        db.query("""
            SELECT m.id FROM messages m LEFT JOIN bodies b ON b.message_id=m.id
            WHERE m.folder_id=? AND b.message_id IS NULL AND m.size < 3000000 ORDER BY m.date DESC LIMIT ?
            """, [folderID, limit]) { out.append($0.int64(0)) }
        return out
    }

    /// Keeps the cache bounded: drops messages outside the offline window (keeping the newest 200 per folder) and old bodies.
    func prune(offlineDays: Int) {
        let cutoff = Date().addingTimeInterval(-Double(offlineDays + 7) * 86400).timeIntervalSince1970
        db.run("""
            DELETE FROM messages WHERE date < ? AND id NOT IN (
                SELECT id FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY folder_id ORDER BY date DESC) rn FROM messages) WHERE rn <= 200)
            """, [cutoff])
        db.run("DELETE FROM bodies WHERE message_id NOT IN (SELECT message_id FROM bodies ORDER BY fetched DESC LIMIT 3000)")
        db.run("PRAGMA optimize")
    }

    // MARK: Search and contacts

    /// Local full-text search; each word is matched as a prefix.
    func search(_ query: String, limit: Int = 300) -> [MessageRow] {
        let words = query.split(whereSeparator: { $0.isWhitespace })
            .filter { !$0.contains(":") }
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }
        guard !words.isEmpty else { return [] }
        var out: [MessageRow] = []
        db.query("""
            SELECT \(rowCols) FROM fts JOIN messages m ON m.id=fts.rowid JOIN folders f ON f.id=m.folder_id
            WHERE fts MATCH ? ORDER BY m.date DESC LIMIT ?
            """, [words.joined(separator: " "), limit]) { out.append(self.rowFrom($0)) }
        return out
    }

    func contacts(matching prefix: String, limit: Int = 8) -> [EmailAddress] {
        let p = prefix.lowercased() + "%"
        var out: [EmailAddress] = []
        db.query("""
            SELECT from_name, from_addr, COUNT(*) c FROM messages WHERE from_addr LIKE ? OR from_name LIKE ?
            GROUP BY from_addr ORDER BY c DESC LIMIT ?
            """, [p, p, limit]) { out.append(EmailAddress(name: $0.text(0), email: $0.text(1))) }
        return out
    }

    func flags(ids: [Int64]) -> [Int64: MessageFlags] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: MessageFlags] = [:]
        db.query("SELECT id, flags FROM messages WHERE id IN (\(ids.map(String.init).joined(separator: ",")))") {
            out[$0.int64(0)] = MessageFlags(rawValue: $0.int(1))
        }
        return out
    }

    func unreadCount(folderID: Int64) -> Int {
        Int(db.scalarInt("SELECT COUNT(*) FROM messages WHERE folder_id=? AND (flags & 1)=0", [folderID]) ?? 0)
    }

    func unifiedUnreadCount() -> Int {
        Int(db.scalarInt("SELECT COUNT(*) FROM messages m JOIN folders f ON f.id=m.folder_id WHERE f.role='inbox' AND (m.flags & 1)=0") ?? 0)
    }

    // MARK: Pending operations

    struct PendingOp {
        var id: Int64
        var kind: String
        var folderPath: String
        var uids: [UInt32]
        var arg: String
    }

    func addOp(account: String, kind: String, folderPath: String, uids: [UInt32], arg: String = "") {
        db.run("INSERT INTO pending_ops(account, kind, folder_path, uids, arg, created) VALUES (?,?,?,?,?,?)",
               [account, kind, folderPath, uids.map(String.init).joined(separator: ","), arg, Date()])
    }

    func ops(account: String) -> [PendingOp] {
        var out: [PendingOp] = []
        db.query("SELECT id, kind, folder_path, uids, arg FROM pending_ops WHERE account=? ORDER BY id", [account]) {
            out.append(PendingOp(id: $0.int64(0), kind: $0.text(1), folderPath: $0.text(2),
                                 uids: $0.text(3).split(separator: ",").compactMap { UInt32($0) }, arg: $0.text(4)))
        }
        return out
    }

    func removeOp(_ id: Int64) { db.run("DELETE FROM pending_ops WHERE id=?", [id]) }

    // MARK: Small preferences

    func pref(_ key: String) -> String? {
        var out: String?
        db.query("SELECT value FROM prefs WHERE key=?", [key]) { out = $0.string(0) }
        return out
    }

    func setPref(_ key: String, _ value: String?) {
        if let value { db.run("INSERT OR REPLACE INTO prefs(key, value) VALUES (?,?)", [key, value]) }
        else { db.run("DELETE FROM prefs WHERE key=?", [key]) }
    }
}
