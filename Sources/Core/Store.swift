import Foundation

/// The offline cache: folders, message headers, fetched bodies, full-text index and the pending-action queue.
/// Everything lives on disk; the UI loads only the rows it shows.
@MainActor
final class Store {
    let db: SQLiteDB
    /// The database file, so background maintenance can open its own connection.
    nonisolated let path: String

    init(path: String = AppPaths.support.appendingPathComponent("mail.sqlite").path) throws {
        self.path = path
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
        if db.userVersion < 4 { try migrate_3_to_4() }
        if db.userVersion < 5 { try migrate_4_to_5() }
        try upgradeHeaderIndex()
        db.run("PRAGMA user_version=5")
    }

    /// The header index gains Cc (W-02), so `from:`/`to:`/`cc:`/`subject:` filters are answered by the index
    /// instead of a leading-wildcard LIKE that reads every cached message. Guarded by the table's own shape
    /// rather than user_version, so it runs exactly once per database and is idempotent if interrupted.
    private func upgradeHeaderIndex() throws {
        guard !db.columnExists(table: "fts", column: "cc_list") else { return }
        try db.transactionChecked {
            // One transaction: dropping the index without rebuilding it would break search until relaunch.
            try db.exec("""
                DROP TRIGGER IF EXISTS msg_ai;
                DROP TRIGGER IF EXISTS msg_ad;
                DROP TRIGGER IF EXISTS msg_au;
                DROP TABLE IF EXISTS fts;
                CREATE VIRTUAL TABLE fts USING fts5(
                    subject, from_name, from_addr, to_list, cc_list, snippet, content='messages',
                    content_rowid='id', tokenize='unicode61 remove_diacritics 2');
                CREATE TRIGGER msg_ai AFTER INSERT ON messages BEGIN
                    INSERT INTO fts(rowid, subject, from_name, from_addr, to_list, cc_list, snippet)
                    VALUES (new.id, new.subject, new.from_name, new.from_addr, new.to_list, new.cc_list, new.snippet);
                END;
                CREATE TRIGGER msg_ad AFTER DELETE ON messages BEGIN
                    INSERT INTO fts(fts, rowid, subject, from_name, from_addr, to_list, cc_list, snippet)
                    VALUES ('delete', old.id, old.subject, old.from_name, old.from_addr, old.to_list, old.cc_list, old.snippet);
                END;
                CREATE TRIGGER msg_au AFTER UPDATE OF subject, snippet, from_name, from_addr, to_list, cc_list ON messages BEGIN
                    INSERT INTO fts(fts, rowid, subject, from_name, from_addr, to_list, cc_list, snippet)
                    VALUES ('delete', old.id, old.subject, old.from_name, old.from_addr, old.to_list, old.cc_list, old.snippet);
                    INSERT INTO fts(rowid, subject, from_name, from_addr, to_list, cc_list, snippet)
                    VALUES (new.id, new.subject, new.from_name, new.from_addr, new.to_list, new.cc_list, new.snippet);
                END;
                INSERT INTO fts(fts) VALUES('rebuild');
                """)
        }
    }

    /// v4 → v5: index maintenance that cascade deletes used to skip, header FTS that follows sender/recipient
    /// changes, body_fts backfill, reference-based thread keys for non-Gmail mail, and a Message-ID index.
    private func migrate_4_to_5() throws {
        try db.exec("""
            DROP TRIGGER IF EXISTS msg_au;
            CREATE TRIGGER msg_au AFTER UPDATE OF subject, snippet, from_name, from_addr, to_list ON messages BEGIN
                INSERT INTO fts(fts, rowid, subject, from_name, from_addr, to_list, snippet)
                VALUES ('delete', old.id, old.subject, old.from_name, old.from_addr, old.to_list, old.snippet);
                INSERT INTO fts(rowid, subject, from_name, from_addr, to_list, snippet)
                VALUES (new.id, new.subject, new.from_name, new.from_addr, new.to_list, new.snippet);
            END;
            CREATE TRIGGER IF NOT EXISTS msg_body_fts_ad AFTER DELETE ON messages BEGIN
                DELETE FROM body_fts WHERE rowid=old.id;
            END;
            CREATE INDEX IF NOT EXISTS msg_msgid ON messages(message_id);
            """)
        // Earlier cascade deletes left orphans behind (B-14): rebuild both indexes and the contact counts.
        db.run("INSERT INTO fts(fts) VALUES('rebuild')")
        db.run("DELETE FROM body_fts WHERE rowid NOT IN (SELECT id FROM messages)")
        db.transaction {
            db.run("DELETE FROM contacts")
            db.run("""
                INSERT INTO contacts(email, name, count) SELECT from_addr, MAX(from_name), COUNT(*) FROM messages
                WHERE from_addr != '' GROUP BY from_addr
                """)
        }
        backfillBodyIndex()
        rethreadNonGmail()
    }

    /// Indexes cached bodies that predate body_fts (B-38). Only rows missing from the index are touched.
    private func backfillBodyIndex() {
        var pending: [(Int64, String?, String?)] = []
        db.query("SELECT message_id, html, text FROM bodies WHERE message_id NOT IN (SELECT rowid FROM body_fts)") {
            pending.append(($0.int64(0), $0.string(1), $0.string(2)))
        }
        guard !pending.isEmpty else { return }
        db.transaction {
            for (id, html, text) in pending {
                let body = Self.indexText(html: html, text: text)
                if !body.isEmpty { db.run("INSERT INTO body_fts(rowid, body) VALUES (?,?)", [id, body]) }
            }
        }
        db.run("PRAGMA optimize")
    }

    /// Recomputes conversation keys for non-Gmail messages (gmsgid 0) with the References-based key (B-12).
    private func rethreadNonGmail() {
        var updates: [(Int64, Int64)] = []
        db.query("SELECT id, message_id, in_reply_to, refs, subject, from_addr, to_list, cc_list FROM messages WHERE gmsgid=0") { s in
            let people = [s.text(5)] + MIME.parseAddresses(s.text(6)).map { $0.email } + MIME.parseAddresses(s.text(7)).map { $0.email }
            let key = MIME.threadKey(messageID: s.text(1), inReplyTo: s.text(2), references: s.text(3),
                                     subject: s.text(4), participants: people)
            updates.append((s.int64(0), key))
        }
        guard !updates.isEmpty else { return }
        db.transaction {
            for (id, key) in updates { db.run("UPDATE messages SET thrid=? WHERE id=?", [key, id]) }
        }
    }

    /// Text that goes into body_fts for one message: the plain part, else text extracted from the HTML, capped.
    nonisolated static func indexText(html: String?, text: String?) -> String {
        var body = text ?? ""
        if body.isEmpty, let html { body = MIME.plainText(fromHTML: html, limit: 65_536) }
        if body.utf8.count > 65_536 { body = String(body.prefix(65_536)) }
        return body
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
        // Seed contacts from what's already cached (triggers didn't exist before this migration). Recomputed,
        // never added: a migration that has to re-run must not inflate the counts.
        db.run("DELETE FROM contacts")
        db.run("INSERT INTO contacts(email, name, count) SELECT from_addr, MAX(from_name), COUNT(*) FROM messages GROUP BY from_addr")
        backfillBodyIndex()
    }

    // v2 → v3: the Bcc line is remembered per message so editing a draft restores its Bcc recipients
    // (Bcc never travels in the draft MIME itself).
    /// v3 → v4: the server's unread count per folder (IMAP STATUS), so counts cover mail outside the offline window.
    /// `unread_base` is the local unread count when the server count was taken; local changes since then
    /// (read/unread, moves, new mail) are applied on top until the next STATUS.
    private func migrate_3_to_4() throws {
        if !db.columnExists(table: "folders", column: "server_unread") {
            try db.exec("ALTER TABLE folders ADD COLUMN server_unread INTEGER NOT NULL DEFAULT -1")
        }
        if !db.columnExists(table: "folders", column: "unread_base") {
            try db.exec("ALTER TABLE folders ADD COLUMN unread_base INTEGER NOT NULL DEFAULT 0")
        }
    }

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
                // Explicit delete so the FTS/contacts triggers run for every message (B-14).
                db.run("DELETE FROM messages WHERE folder_id=?", [id])
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

    /// Throwing form: sync must not treat the folder as caught up when the state write failed (C-10).
    func updateFolderStateChecked(_ id: Int64, uidValidity: UInt32, uidNext: UInt32, modseq: UInt64) throws {
        try db.runChecked("UPDATE folders SET uidvalidity=CASE WHEN ?!=0 THEN ? ELSE uidvalidity END, uidnext=?, modseq=? WHERE id=?",
                          [uidValidity, uidValidity, uidNext, modseq, id])
    }

    func resetFolder(_ id: Int64) {
        var account = "", path = ""
        db.query("SELECT account, path FROM folders WHERE id=?", [id]) { account = $0.text(0); path = $0.text(1) }
        // Stale UIDs must never be applied to a recreated folder: drop its queued actions too.
        db.transaction {
            db.run("DELETE FROM pending_ops WHERE folder_id=?", [id])
            // Ops queued by builds before v2 have no folder id; they still name the folder by path.
            db.run("DELETE FROM pending_ops WHERE folder_id=0 AND account=? AND folder_path=?", [account, path])
            db.run("DELETE FROM messages WHERE folder_id=?", [id])
            db.run("UPDATE folders SET uidvalidity=0, uidnext=0, modseq=0 WHERE id=?", [id])
        }
    }

    func deleteAccount(_ account: String) {
        db.transaction {
            // Messages first, explicitly, so the FTS and contacts triggers fire for each one (B-14).
            db.run("DELETE FROM messages WHERE folder_id IN (SELECT id FROM folders WHERE account=?)", [account])
            db.run("DELETE FROM folders WHERE account=?", [account])
            db.run("DELETE FROM pending_ops WHERE account=?", [account])
        }
    }

    /// Adds a folder created on the server (F-12 / F-14) so it can be used before the next LIST.
    @discardableResult
    func addFolder(account: String, path: String, name: String, role: FolderRole, delimiter: String) -> Folder? {
        db.run("""
            INSERT INTO folders(account, path, name, role, delim, selectable) VALUES (?,?,?,?,?,1)
            ON CONFLICT(account, path) DO UPDATE SET name=excluded.name
            """, [account, path, name, role.rawValue, delimiter])
        return folder(account: account, path: path)
    }

    /// Renames a folder and repoints everything that stored its path (C-28): queued actions for the folder,
    /// queued moves whose destination it is, and child folders under the old prefix — a child was renamed
    /// with its parent on the server, so its cache and queued actions must follow, not be pruned as stale.
    func renameFolder(_ id: Int64, path: String, name: String) {
        db.transaction {
            var oldPath = "", account = "", delim = "/"
            db.query("SELECT path, account, delim FROM folders WHERE id=?", [id]) {
                oldPath = $0.text(0); account = $0.text(1); delim = $0.text(2)
            }
            db.run("UPDATE folders SET path=?, name=? WHERE id=?", [path, name, id])
            db.run("UPDATE pending_ops SET folder_path=? WHERE folder_id=?", [path, id])
            guard !oldPath.isEmpty, oldPath != path else { return }
            // Ops queued by builds before v2 carry no folder id; they still name the folder by path.
            db.run("UPDATE pending_ops SET folder_path=? WHERE folder_id=0 AND account=? AND folder_path=?",
                   [path, account, oldPath])
            db.run("UPDATE pending_ops SET arg=? WHERE kind='move' AND account=? AND arg=?", [path, account, oldPath])
            guard !delim.isEmpty else { return }
            var children: [(id: Int64, path: String)] = []
            db.query("SELECT id, path FROM folders WHERE account=? AND path LIKE ? ESCAPE '\\' AND id!=?",
                     [account, likePrefix(oldPath + delim), id]) { children.append(($0.int64(0), $0.text(1))) }
            for child in children {
                let newChild = path + String(child.path.dropFirst(oldPath.count))
                db.run("UPDATE folders SET path=? WHERE id=?", [newChild, child.id])
                db.run("UPDATE pending_ops SET folder_path=? WHERE folder_id=?", [newChild, child.id])
                db.run("UPDATE pending_ops SET arg=? WHERE kind='move' AND account=? AND arg=?",
                       [newChild, account, child.path])
            }
        }
    }

    func deleteFolder(_ id: Int64) {
        db.transaction {
            db.run("DELETE FROM pending_ops WHERE folder_id=?", [id])
            db.run("DELETE FROM messages WHERE folder_id=?", [id])
            db.run("DELETE FROM folders WHERE id=?", [id])
        }
    }

    // MARK: Messages

    func insert(folderID: Int64, _ headers: [ParsedHeader]) {
        do { try insertChecked(folderID: folderID, headers) }
        catch { /* logged by SQLiteDB; sync uses the throwing form so it never advances past a gap */ }
    }

    /// Throwing form: a failed header write must stop sync from moving UIDNEXT past the missing rows (C-10).
    /// The whole batch is one transaction, so a failure leaves none of it behind for the next sync to skip.
    func insertChecked(folderID: Int64, _ headers: [ParsedHeader]) throws {
        guard !headers.isEmpty else { return }
        try db.transactionChecked {
            for h in headers {
                try db.runChecked("""
                    INSERT INTO messages(folder_id, uid, gmsgid, thrid, date, size, flags, has_att, subject, from_name,
                        from_addr, to_list, cc_list, reply_to, message_id, in_reply_to, refs, list_unsub, structure)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(folder_id, uid) DO UPDATE SET flags=excluded.flags, gmsgid=excluded.gmsgid,
                        thrid=excluded.thrid, date=excluded.date, size=excluded.size, has_att=excluded.has_att,
                        subject=excluded.subject, from_name=excluded.from_name, from_addr=excluded.from_addr,
                        to_list=excluded.to_list, cc_list=excluded.cc_list, reply_to=excluded.reply_to,
                        message_id=excluded.message_id, in_reply_to=excluded.in_reply_to, refs=excluded.refs,
                        list_unsub=excluded.list_unsub, structure=COALESCE(excluded.structure, structure)
                    """, [folderID, h.uid, h.gmailID, h.threadID, h.date, h.size, h.flags.rawValue, h.hasAttachments,
                          h.subject, h.from.name, h.from.email.lowercased(), h.toList, h.ccList, h.replyTo, h.messageID,
                          h.inReplyTo, h.references, h.listUnsubscribe, h.structureJSON])
            }
        }
    }

    /// Applies server flags; returns the UIDs whose flags actually changed (so a no-op sync redraws nothing).
    @discardableResult
    func updateFlags(folderID: Int64, _ changes: [(UInt32, MessageFlags)]) -> [UInt32] {
        (try? updateFlagsChecked(folderID: folderID, changes)) ?? []
    }

    /// Throwing form: a failed flag write must keep MODSEQ where it was so the changes are fetched again (C-10).
    func updateFlagsChecked(folderID: Int64, _ changes: [(UInt32, MessageFlags)]) throws -> [UInt32] {
        guard !changes.isEmpty else { return [] }
        var changed: [UInt32] = []
        try db.transactionChecked {
            for (uid, f) in changes {
                // Only count a change the write really made: after a failed statement sqlite3_changes()
                // still reports the previous one.
                try db.runChecked("UPDATE messages SET flags=? WHERE folder_id=? AND uid=? AND flags!=?",
                                  [f.rawValue, folderID, uid, f.rawValue])
                if db.changes > 0 { changed.append(uid) }
            }
        }
        return changed
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

    /// Newest rows of a folder. `limit` is the list's fetch window (O-05): big caches load a page at a time.
    func rows(folderID: Int64, limit: Int = Int(Int32.max)) -> [MessageRow] {
        var out: [MessageRow] = []
        db.query("SELECT \(rowCols) FROM messages m JOIN folders f ON f.id=m.folder_id WHERE m.folder_id=? ORDER BY m.date DESC LIMIT ?",
                 [folderID, limit]) { out.append(self.rowFrom($0)) }
        return out
    }

    func unifiedInboxRows(limit: Int = Int(Int32.max)) -> [MessageRow] {
        unifiedRows(role: .inbox, limit: limit)
    }

    /// Every account's folder with this role, merged newest first (unified Sent, Drafts, Trash… — F-13).
    func unifiedRows(role: FolderRole, limit: Int = Int(Int32.max)) -> [MessageRow] {
        var out: [MessageRow] = []
        db.query("SELECT \(rowCols) FROM messages m JOIN folders f ON f.id=m.folder_id WHERE f.role=? ORDER BY m.date DESC LIMIT ?",
                 [role.rawValue, limit]) { out.append(self.rowFrom($0)) }
        return out
    }

    func unifiedCount(role: FolderRole) -> Int {
        Int(db.scalarInt("SELECT COUNT(*) FROM messages m JOIN folders f ON f.id=m.folder_id WHERE f.role=?", [role.rawValue]) ?? 0)
    }

    /// Rows the user explicitly flagged, across every account (unified Flagged — F-13).
    func flaggedRows(limit: Int = Int(Int32.max)) -> [MessageRow] {
        var out: [MessageRow] = []
        db.query("""
            SELECT \(rowCols) FROM messages m JOIN folders f ON f.id=m.folder_id
            WHERE (m.flags & 2) != 0 AND f.role NOT IN ('all','starred','important','trash','spam') ORDER BY m.date DESC LIMIT ?
            """, [limit]) { out.append(self.rowFrom($0)) }
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

    /// The cached row for a server UID in one folder, for opening a message from a notification tap.
    /// UIDs are only unique per folder, so the folder is part of the key (B-05).
    func messageID(folderID: Int64, uid: UInt32) -> Int64? {
        db.scalarInt("SELECT id FROM messages WHERE folder_id=? AND uid=?", [folderID, uid])
    }

    /// The row carrying a given Message-ID header in a folder (with or without angle brackets), so a saved
    /// draft is found by the id it was built with rather than by its subject (B-09).
    func messageID(folderID: Int64, messageIDHeader: String) -> Int64? {
        let bare = messageIDHeader.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
        guard !bare.isEmpty else { return nil }
        return db.scalarInt("SELECT id FROM messages WHERE folder_id=? AND (message_id=? OR message_id=?) ORDER BY uid DESC LIMIT 1",
                            [folderID, "<\(bare)>", bare])
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
        // One transaction through the prepared variant: a body row without its snippet/index would be
        // half-cached and never repaired.
        saveBody(id, html: html, text: text, snippet: MIME.snippet(html: html, text: text),
                 indexText: Self.indexText(html: html, text: text))
    }

    /// Saves a body whose snippet and index text were already computed off the main actor (O-03).
    func saveBody(_ id: Int64, html: String?, text: String?, snippet: String, indexText: String) {
        db.transaction {
            db.run("INSERT OR REPLACE INTO bodies(message_id, html, text, fetched) VALUES (?,?,?,?)", [id, html, text, Date()])
            db.run("UPDATE messages SET snippet=? WHERE id=?", [snippet, id])
            db.run("DELETE FROM body_fts WHERE rowid=?", [id])
            if !indexText.isEmpty { db.run("INSERT INTO body_fts(rowid, body) VALUES (?,?)", [id, indexText]) }
        }
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

    /// The prune cutoff: exactly the offline window from Settings, no hidden grace period (B-36).
    nonisolated static func pruneCutoff(offlineDays: Int, now: Date = Date()) -> Date {
        now.addingTimeInterval(-Double(max(1, offlineDays)) * 86400)
    }

    /// Body cache cap: the newest 512 MB of message text is kept.
    nonisolated static let bodyCacheBytes = 536_870_912

    /// Keeps the cache bounded: drops messages outside the offline window (keeping the newest 200 per folder)
    /// and the oldest bodies past the cap. Runs on its own connection in batches of separate transactions, so
    /// it never holds the main thread or a long write lock (O-09). Returns how many messages were removed.
    @discardableResult
    nonisolated static func prune(path: String, offlineDays: Int, now: Date = Date()) -> Int {
        guard let db = try? SQLiteDB(path: path) else { return 0 }
        let cutoff = pruneCutoff(offlineDays: offlineDays, now: now).timeIntervalSince1970
        var doomed: [Int64] = []
        db.query("""
            SELECT id FROM (SELECT id, date, ROW_NUMBER() OVER (PARTITION BY folder_id ORDER BY date DESC) rn FROM messages)
            WHERE rn > 200 AND date < ?
            """, [cutoff]) { doomed.append($0.int64(0)) }
        for chunk in doomed.chunked(500) {
            db.transaction {
                for id in chunk { db.run("DELETE FROM messages WHERE id=?", [id]) }
            }
        }
        var oldBodies: [Int64] = []
        db.query("""
            SELECT message_id FROM (SELECT message_id, SUM(length(COALESCE(html,'')) + length(COALESCE(text,'')))
                OVER (ORDER BY fetched DESC) AS total FROM bodies) WHERE total > ?
            """, [bodyCacheBytes]) { oldBodies.append($0.int64(0)) }
        for chunk in oldBodies.chunked(500) {
            db.transaction {
                for id in chunk {
                    db.run("DELETE FROM bodies WHERE message_id=?", [id])
                    // A pruned body must leave the full-text index too, or search keeps matching text
                    // that is no longer cached.
                    db.run("DELETE FROM body_fts WHERE rowid=?", [id])
                }
            }
        }
        db.run("PRAGMA optimize")
        return doomed.count
    }

    /// Same as the background prune, on the app's own connection (tests and the demo).
    func prune(offlineDays: Int) {
        _ = Self.prune(path: path, offlineDays: offlineDays)
    }

    // MARK: Snapshots (undo for move / archive / delete — F-08)

    /// Full copies of message rows (and their cached bodies) taken before an optimistic local delete,
    /// so Undo can put them back exactly as they were.
    struct Snapshot {
        fileprivate var messages: [(columns: [String], values: [Any?])] = []
        fileprivate var bodies: [(columns: [String], values: [Any?])] = []
        var isEmpty: Bool { messages.isEmpty }
    }

    func snapshot(ids: [Int64]) -> Snapshot {
        var snap = Snapshot()
        guard !ids.isEmpty else { return snap }
        let list = ids.map(String.init).joined(separator: ",")
        func grab(_ sql: String, into out: inout [(columns: [String], values: [Any?])]) {
            var rows: [(columns: [String], values: [Any?])] = []
            db.query(sql) { s in
                let n = s.columnCount
                rows.append(((0..<n).map { s.columnName($0) }, (0..<n).map { s.value($0) }))
            }
            out = rows
        }
        grab("SELECT * FROM messages WHERE id IN (\(list))", into: &snap.messages)
        grab("SELECT * FROM bodies WHERE message_id IN (\(list))", into: &snap.bodies)
        return snap
    }

    /// Re-inserts snapshotted rows (same ids, so the FTS/contacts triggers and body index come back too).
    func restore(_ snap: Snapshot) {
        db.transaction {
            for r in snap.messages {
                let cols = r.columns.joined(separator: ",")
                let marks = Array(repeating: "?", count: r.columns.count).joined(separator: ",")
                db.run("INSERT OR IGNORE INTO messages(\(cols)) VALUES (\(marks))", r.values)
            }
            for r in snap.bodies {
                let cols = r.columns.joined(separator: ",")
                let marks = Array(repeating: "?", count: r.columns.count).joined(separator: ",")
                db.run("INSERT OR IGNORE INTO bodies(\(cols)) VALUES (\(marks))", r.values)
                if let idIdx = r.columns.firstIndex(of: "message_id"), let id = r.values[idIdx] as? Int64 {
                    let html = r.columns.firstIndex(of: "html").flatMap { r.values[$0] as? String }
                    let text = r.columns.firstIndex(of: "text").flatMap { r.values[$0] as? String }
                    let body = Self.indexText(html: html, text: text)
                    db.run("DELETE FROM body_fts WHERE rowid=?", [id])
                    if !body.isEmpty { db.run("INSERT INTO body_fts(rowid, body) VALUES (?,?)", [id, body]) }
                }
            }
        }
    }

    // MARK: Diagnostics (F-26)

    /// Bytes used by the database and its WAL.
    var databaseBytes: Int64 {
        ["", "-wal", "-shm"].reduce(Int64(0)) { sum, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }

    var cachedMessageCount: Int { Int(db.scalarInt("SELECT COUNT(*) FROM messages") ?? 0) }
    var cachedBodyCount: Int { Int(db.scalarInt("SELECT COUNT(*) FROM bodies") ?? 0) }

    /// Drops every cached body (they are re-fetched on demand); headers and queued actions stay.
    func clearBodyCache() {
        db.transaction {
            db.run("DELETE FROM bodies")
            db.run("DELETE FROM body_fts")
            db.run("UPDATE messages SET snippet=''")
        }
        // Compacting a multi-gigabyte cache is real I/O; the rows are already gone, so compact on its own
        // connection instead of freezing the window (O-09 pattern).
        let path = self.path
        DispatchQueue.global(qos: .utility).async {
            guard let db = try? SQLiteDB(path: path) else { return }
            try? db.exec("VACUUM")
        }
    }

    // MARK: Search and contacts

    /// Local search over the offline cache: words via the full-text indexes (headers + body, prefix match),
    /// operators and filters via SQL. Header filters (from/to/cc/subject) run through the header index too,
    /// so they never scan every cached message (W-02).
    func search(_ q: SearchQuery, folderID: Int64? = nil, limit: Int = 2000) -> [MessageRow] {
        guard q.hasLocalCriteria else { return [] }
        var sql = "SELECT \(rowCols) FROM messages m JOIN folders f ON f.id=m.folder_id"
        var conds: [String] = []
        var args: [Any?] = []
        // A word with no letters or digits tokenizes to nothing, and FTS5 rejects a phrase with no tokens —
        // which would make the whole MATCH fail and hide every other term's results.
        let words = q.words
            .filter { $0.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"*" }
        if !words.isEmpty {
            let match = words.joined(separator: " ")
            conds.append("(m.id IN (SELECT rowid FROM fts WHERE fts MATCH ?) OR m.id IN (SELECT rowid FROM body_fts WHERE body_fts MATCH ?))")
            args += [match, match]
        } else if !q.words.isEmpty {
            conds.append("0") // Only unsearchable words: nothing can match them.
        }
        for v in q.from { addHeaderFilter(v, "{from_name from_addr}", &conds, &args) }
        for v in q.to { addHeaderFilter(v, "{to_list cc_list}", &conds, &args) }
        for v in q.cc { addHeaderFilter(v, "{cc_list}", &conds, &args) }
        for v in q.subject { addHeaderFilter(v, "{subject}", &conds, &args) }
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

    /// One header filter as an index lookup. A value's words are quoted and prefix-matched, so "ann" finds
    /// "Ann" and "ann@x.com"; a value with nothing to look for matches nothing (it can never match a word).
    private func addHeaderFilter(_ value: String, _ columns: String, _ conds: inout [String], _ args: inout [Any?]) {
        let tokens = value.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !tokens.isEmpty else { conds.append("0"); return }
        conds.append("m.id IN (SELECT rowid FROM fts WHERE fts MATCH ?)")
        args.append(columns + " : (" + tokens.map { "\"\($0)\"*" }.joined(separator: " AND ") + ")")
    }

    /// LIKE pattern for "starts with", wildcards escaped (used to find the children of a renamed folder).
    private func likePrefix(_ prefix: String) -> String {
        var v = prefix.replacingOccurrences(of: "\\", with: "\\\\")
        v = v.replacingOccurrences(of: "%", with: "\\%")
        v = v.replacingOccurrences(of: "_", with: "\\_")
        return v + "%"
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

    private func localUnread(folderID: Int64) -> Int {
        Int(db.scalarInt("SELECT COUNT(*) FROM messages WHERE folder_id=? AND (flags & 1)=0", [folderID]) ?? 0)
    }

    /// Unread count for a folder: the server's count (covers mail older than the offline window) adjusted by
    /// local changes since it was taken; the cached count when the server hasn't reported one yet.
    func unreadCount(folderID: Int64) -> Int {
        let local = localUnread(folderID: folderID)
        var server = -1, base = 0
        db.query("SELECT server_unread, unread_base FROM folders WHERE id=?", [folderID]) {
            server = $0.int(0); base = $0.int(1)
        }
        return server < 0 ? local : max(local, server + local - base)
    }

    /// Records the server's unread count (IMAP STATUS UNSEEN) together with the local count at that moment.
    func setServerUnread(folderID: Int64, _ count: Int) {
        db.run("UPDATE folders SET server_unread=?, unread_base=? WHERE id=?",
               [Int64(count), Int64(localUnread(folderID: folderID)), folderID])
    }

    func unifiedUnreadCount() -> Int {
        unifiedUnreadCount(role: .inbox)
    }

    func unifiedUnreadCount(role: FolderRole) -> Int {
        var ids: [Int64] = []
        db.query("SELECT id FROM folders WHERE role=?", [role.rawValue]) { ids.append($0.int64(0)) }
        let all = unreadCounts()
        return ids.reduce(0) { $0 + (all[$1] ?? 0) }
    }

    /// Unread counts for every folder in one aggregate query (O-06), same rule as unreadCount(folderID:).
    func unreadCounts() -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        db.query("""
            SELECT f.id, f.server_unread, f.unread_base, COALESCE(u.n, 0) FROM folders f
            LEFT JOIN (SELECT folder_id, COUNT(*) n FROM messages WHERE (flags & 1)=0 GROUP BY folder_id) u ON u.folder_id=f.id
            """) { s in
            let server = s.int(1), base = s.int(2), local = s.int(3)
            out[s.int64(0)] = server < 0 ? local : max(local, server + local - base)
        }
        return out
    }

    /// Queued actions per account in one query (O-06).
    func opCounts() -> [String: Int] {
        var out: [String: Int] = [:]
        db.query("SELECT account, COUNT(*) FROM pending_ops GROUP BY account") { out[$0.text(0)] = $0.int(1) }
        return out
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

    /// Queues a server action. Returns false when it could not be written, so the caller can say so instead of
    /// letting the action silently disappear (C-10).
    @discardableResult
    func addOp(account: String, kind: String, folderPath: String, uids: [UInt32], arg: String = "",
               folderID: Int64 = 0, uidvalidity: UInt32 = 0) -> Bool {
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
