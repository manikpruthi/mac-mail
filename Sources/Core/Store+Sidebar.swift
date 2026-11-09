import Foundation

/// Sidebar counts that need their own aggregate query (C-35). Live apart from Store.swift, whose row
/// helpers are file-private, so the sidebar can ask for one cheap count instead of loading rows.
extension Store {
    /// Unread flagged messages across every account: the badge for the unified Flagged row. Uses the same
    /// folder filter as flaggedRows / listFlaggedRows so it stands for exactly that view's messages.
    func flaggedUnreadCount() -> Int {
        Int(db.scalarInt("""
            SELECT COUNT(*) FROM messages m JOIN folders f ON f.id=m.folder_id
            WHERE (m.flags & 2) != 0 AND (m.flags & 1)=0 AND f.role NOT IN ('all','starred','important','trash','spam')
            """) ?? 0)
    }
}
