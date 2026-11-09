import Foundation

/// Windowed queries for the message list, ordered in SQL so the page that is fetched is the newest (or the
/// oldest) one of the whole folder, and paging walks the mailbox in the direction the user sees (C-13).
/// They live apart from Store.swift, whose column list and row mapping are file-private.
extension Store {
    private static let listColumns = """
        m.id, m.folder_id, f.account, m.uid, m.thrid, m.gmsgid, m.date, m.flags, m.has_att, m.subject, m.from_name,
        m.from_addr, m.to_list, m.snippet, f.role
        """

    private func listRow(_ s: Statement) -> MessageRow {
        MessageRow(id: s.int64(0), folderID: s.int64(1), accountID: s.text(2), uid: UInt32(truncatingIfNeeded: s.int64(3)),
                   threadID: s.int64(4), gmailID: s.int64(5), date: Date(timeIntervalSince1970: s.double(6)),
                   flags: MessageFlags(rawValue: s.int(7)), hasAttachments: s.int(8) != 0, subject: s.text(9),
                   fromName: s.text(10), fromAddr: s.text(11), toList: s.text(12), snippet: s.text(13),
                   folderRole: FolderRole(rawValue: s.text(14)) ?? .none)
    }

    /// Newest (or oldest) rows of one folder.
    func listRows(folderID: Int64, limit: Int, ascending: Bool) -> [MessageRow] {
        list("WHERE m.folder_id=?", [folderID], limit: limit, ascending: ascending)
    }

    /// Newest (or oldest) rows across every account's folder with this role (unified views, F-13).
    func listUnifiedRows(role: FolderRole, limit: Int, ascending: Bool) -> [MessageRow] {
        list("WHERE f.role=?", [role.rawValue], limit: limit, ascending: ascending)
    }

    /// Flagged rows across every account, with the same folder filter as Store.flaggedRows.
    func listFlaggedRows(limit: Int, ascending: Bool) -> [MessageRow] {
        list("WHERE (m.flags & 2) != 0 AND f.role NOT IN ('all','starred','important','trash','spam')",
             [], limit: limit, ascending: ascending)
    }

    private func list(_ condition: String, _ args: [Any?], limit: Int, ascending: Bool) -> [MessageRow] {
        var out: [MessageRow] = []
        // The id tiebreak keeps messages with the same date in a stable order across reloads and pages.
        let direction = ascending ? "ASC" : "DESC"
        db.query("""
            SELECT \(Self.listColumns) FROM messages m JOIN folders f ON f.id=m.folder_id
            \(condition) ORDER BY m.date \(direction), m.id \(direction) LIMIT ?
            """, args + [limit as Any?]) { out.append(self.listRow($0)) }
        return out
    }
}
