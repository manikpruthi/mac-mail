import Foundation

/// The offline cache: folders, message headers, fetched bodies, full-text index and the pending-action queue.
/// Everything lives on disk; the UI loads only the rows it shows.
@MainActor
final class Store {
    let db: SQLiteDB

    init() throws {
        let path = AppPaths.support.appendingPathComponent("mail.sqlite").path
        db = try SQLiteDB(path: path)
        // The mail cache is the whole mailbox on disk; keep other local users out of it.
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + suffix)
        }
        try migrate()
    }

    private func migrate() throws {
        // Version 1 baseline: the original schema. CREATE IF NOT EXISTS keeps existing databases intact.
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
        // Migration ladder: a v0 database (tables exist, user_version 0) migrates in place, no data loss.
        if db.userVersion < 2 { try migrate_1_to_2() }
        if db.userVersion < 3 { try migrate_2_to_3() }
        db.run("PRAGMA user_version=3")
    }

    /// v1 → v2: pending ops bound to folder id + UIDVALIDITY, body full-text index, body-cache index, contacts table.
    private func migrate_1_to_2() throws {
        if !db.columnExists(table: "pending_ops", column: "folder_id") {
            try db.exec("ALTER TABLE pending_ops ADD COLUMN folder_id INTEGER NOT NULL DEFAULT 0")
        }
        if !db.columnExists(table: "pending_ops", column: "uidvalidity") {
            try db.exec("ALTER TABLE pending_ops ADD COLUMN uidvalidity INTEGER NOT NULL DEFAULT 0")
        }
        // Backfill existing ops from their folder path so queued actions survive the upgrade.
        db.run("""
            UPDATE pending_ops SET
              folder_id = COALESCE((SELECT f.id FROM folders f WHERE f.account=pending_ops.account AND f.path=pending_ops.folder_path), 0),
              uidvalidity = COALESCE((SELECT f.uidvalidity FROM folders f WHERE f.account=pending_ops.account AND f.path=pending_ops.folder_path), 0)
            """)
        try db.exec("CREATE INDEX IF NOT EXISTS bodies_fetched ON bodies(fetched)")
        try db.exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS body_fts USING fts5(body, tokenize='unicode61 remove_diacritics 2');
            """)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS contacts(
                email TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', count INTEGER NOT NULL DEFAULT 0);
            CREATE TRIGGER IF NOT EXISTS msg_contacts_ai AFTER INSERT ON messages BEGIN
                INSERT INTO contacts(email, name, count) VALUES (new.from_addr, new.from_name, 1)
                ON CONFLICT(email) DO UPDATE SET count=count+1, name=excluded.name;
            END;
            CREATE TRIGGER IF NOT EXISTS msg_contacts_ad AFTER DELETE ON messages BEGIN
                UPDATE contacts SET count=count-1 WHERE email=old.from_addr;
                DELETE FROM contacts WHERE email=old.from_addr AND count<=0;
            END;
            """)
        // Seed contacts from what's already cached (triggers didn't exist before this migration).
        db.run("""
            INSERT INTO contacts(email, name, count) SELECT from_addr, from_name, COUNT(*) FROM messages GROUP BY from_addr
            ON CONFLICT(email) DO UPDATE SET count=count+excluded.count
            """)
    }

    // v2 → v3: the Bcc line is remembered per message so editing a draft restores its Bcc recipients
    // (Bcc never travels in the draft MIME itself).
    private func migrate_2_to_3() throws {
        if !db.columnExists(table: "messages", column: "bcc") {
            try db.exec("ALTER TABLE messages ADD COLUMN bcc TEXT NOT NULL DEFAULT ''")
        }
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
    /// The prune is skipped when the LIST result looks broken (empty, or INBOX missing): a bad response must
    /// never cascade-delete every cached folder.
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
            guard !listed.isEmpty, listed.contains(where: { $0.role == .inbox }) else { return }
            var stale: [Int64] = []
            db.query("SELECT id, path FROM folders WHERE account=?", [account]) {
                if !keep.contains($0.text(1)) { stale.append($0.int64(0)) }
            }
            for id in stale {
                db.run("DELETE FROM pending_ops WHERE folder_id=?", [id])
                db.run("DELETE FROM folders WHERE id=?", [id])
            }
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
        // Never persist UIDVALIDITY 0: a server that omits it must not wipe the known value (fail-closed).
        db.run("UPDATE folders SET uidvalidity=CASE WHEN ?!=0 THEN ? ELSE uidvalidity END, uidnext=?, modseq=? WHERE id=?",
               [uidValidity, uidValidity, uidNext, modseq, id])
    }

    func resetFolder(_ id: Int64) {
        // Stale UIDs must never be applied to a recreated folder: drop its queued actions too.
        db.run("DELETE FROM pending_ops WHERE folder_id=?", [id])
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
                   m.cc_list, m.reply_to, m.message_id, m.refs, m.list_unsub, m.structure, m.size, f.role,
                   m.in_reply_to, m.bcc
            FROM messages m JOIN folders f ON f.id=m.folder_id WHERE m.id=?
            """, [id]) { s in
            out = MessageDetail(
                id: s.int64(0), folderID: s.int64(1), accountID: s.text(2), uid: UInt32(truncatingIfNeeded: s.int64(3)),
                date: Date(timeIntervalSince1970: s.double(4)), flags: MessageFlags(rawValue: s.int(5)), subject: s.text(6),
                from: EmailAddress(name: s.text(7), email: s.text(8)), toList: s.text(9), ccList: s.text(10),
                replyTo: s.text(11), messageIDHeader: s.text(12), references: s.text(13), listUnsubscribe: s.text(14),
                structure: BodyPart.fromJSON(s.string(15)), size: s.int(16), folderRole: FolderRole(rawValue: s.text(17)) ?? .none,
                inReplyTo: s.text(18), bcc: s.text(19))
        }
        return out
    }

    // MARK: Bodies

    /// The cached row for a server UID, for opening a message from a notification tap.
    func messageID(account: String, uid: UInt32) -> Int64? {
        var out: Int64?
        db.query("""
            SELECT m.id FROM messages m JOIN folders f ON f.id=m.folder_id WHERE f.account=? AND m.uid=? LIMIT 1
            """, [account, Int(uid)]) { out = $0.int64(0) }
        return out
    }

    /// Remembers the Bcc header line for messages (drafts), whose MIME never carries it.
    func setBcc(ids: [Int64], bcc: String) {
        guard !ids.isEmpty else { return }
        db.transaction {
            for id in ids { db.run("UPDATE messages SET bcc=? WHERE id=?", [bcc, id]) }
        }
    }

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
        // Body text goes into its own full-text index so search finds words deep inside a message.
        // Capped per message; replaced (never appended) so the index tracks the cache.
        var body = text ?? ""
        if body.isEmpty, let html { body = MIME.plainText(fromHTML: html, limit: 65_536) }
        if body.utf8.count > 65_536 { body = String(body.prefix(65_536)) }
        db.run("DELETE FROM body_fts WHERE rowid=?", [id])
        if !body.isEmpty { db.run("INSERT INTO body_fts(rowid, body) VALUES (?,?)", [id, body]) }
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

    /// Removes cached bodies that came back empty for messages that clearly have content, so they're fetched again.
    func repairEmptyBodies() {
        db.run("""
            DELETE FROM bodies WHERE (html IS NULL OR html = '') AND (text IS NULL OR text = '')
            AND message_id IN (SELECT id FROM messages WHERE size > 2000)
            """)
    }

    /// Keeps the cache bounded: drops messages outside the offline window (keeping the newest 200 per folder) and old bodies.
    func prune(offlineDays: Int) {
        let cutoff = Date().addingTimeInterval(-Double(offlineDays + 7) * 86400).timeIntervalSince1970
        db.run("""
            DELETE FROM messages WHERE date < ? AND id NOT IN (
                SELECT id FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY folder_id ORDER BY date DESC) rn FROM messages) WHERE rn <= 200)
            """, [cutoff])
        db.run("DELETE FROM bodies WHERE message_id NOT IN (SELECT message_id FROM (SELECT message_id, SUM(length(COALESCE(html,'')) + length(COALESCE(text,''))) OVER (ORDER BY fetched DESC) AS total FROM bodies) WHERE total <= 536870912)")
        db.run("PRAGMA optimize")
    }

    // MARK: Search and contacts

    /// Local search over the offline cache: words via the full-text indexes (headers + body, prefix match),
    /// operators and filters via SQL.
    func search(_ q: SearchQuery, folderID: Int64? = nil, limit: Int = 400) -> [MessageRow] {
        guard q.hasLocalCriteria else { return [] }
        var sql = "SELECT \(rowCols) FROM messages m JOIN folders f ON f.id=m.folder_id"
        var conds: [String] = []
        var args: [Any?] = []
        let words = q.words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }
        if !words.isEmpty {
            let match = words.joined(separator: " ")
            conds.append("(m.id IN (SELECT rowid FROM fts WHERE fts MATCH ?) OR m.id IN (SELECT rowid FROM body_fts WHERE body_fts MATCH ?))")
            args += [match, match]
        }
        for v in q.from {
            conds.append("(m.from_name LIKE ? ESCAPE '\\' OR m.from_addr LIKE ? ESCAPE '\\')")
            args += [likePattern(v), likePattern(v)]
        }
        for v in q.to {
            conds.append("(m.to_list LIKE ? ESCAPE '\\' OR m.cc_list LIKE ? ESCAPE '\\')")
            args += [likePattern(v), likePattern(v)]
        }
        for v in q.subject {
            conds.append("m.subject LIKE ? ESCAPE '\\'")
            args.append(likePattern(v))
        }
        if q.hasAttachment { conds.append("m.has_att = 1") }
        if q.unread { conds.append("(m.flags & 1) = 0") }
        if q.flagged { conds.append("(m.flags & 2) != 0") }
        if let d = q.withinDays {
            conds.append("m.date >= ?")
            args.append(Date().addingTimeInterval(-Double(d) * 86400))
        }
        if let folderID {
            conds.append("m.folder_id = ?")
            args.append(folderID)
        }
        if !conds.isEmpty { sql += " WHERE " + conds.joined(separator: " AND ") }
        sql += " ORDER BY m.date DESC LIMIT ?"
        args.append(limit)
        var out: [MessageRow] = []
        db.query(sql, args) { out.append(self.rowFrom($0)) }
        return out
    }

    /// LIKE pattern with user wildcards escaped, so "%" and "_" in a query match literally.
    private func likePattern(_ value: String) -> String {
        var v = value.replacingOccurrences(of: "\\", with: "\\\\")
        v = v.replacingOccurrences(of: "%", with: "\\%")
        v = v.replacingOccurrences(of: "_", with: "\\_")
        return "%\(v)%"
    }

    func contacts(matching prefix: String, limit: Int = 8) -> [EmailAddress] {
        var v = prefix.lowercased().replacingOccurrences(of: "\\", with: "\\\\")
        v = v.replacingOccurrences(of: "%", with: "\\%")
        v = v.replacingOccurrences(of: "_", with: "\\_")
        let p = v + "%"
        var out: [EmailAddress] = []
        db.query("""
            SELECT name, email FROM contacts WHERE email LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\'
            ORDER BY count DESC LIMIT ?
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
        var folderID: Int64
        var uidvalidity: UInt32
    }

    func addOp(account: String, kind: String, folderPath: String, uids: [UInt32], arg: String = "",
               folderID: Int64 = 0, uidvalidity: UInt32 = 0) {
        db.run("INSERT INTO pending_ops(account, kind, folder_path, uids, arg, created, folder_id, uidvalidity) VALUES (?,?,?,?,?,?,?,?)",
               [account, kind, folderPath, uids.map(String.init).joined(separator: ","), arg, Date(), folderID, uidvalidity])
    }

    func ops(account: String) -> [PendingOp] {
        var out: [PendingOp] = []
        db.query("SELECT id, kind, folder_path, uids, arg, folder_id, uidvalidity FROM pending_ops WHERE account=? ORDER BY id", [account]) {
            out.append(PendingOp(id: $0.int64(0), kind: $0.text(1), folderPath: $0.text(2),
                                 uids: $0.text(3).split(separator: ",").compactMap { UInt32($0) }, arg: $0.text(4),
                                 folderID: $0.int64(5), uidvalidity: UInt32(truncatingIfNeeded: $0.int64(6))))
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
