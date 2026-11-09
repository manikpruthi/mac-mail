import Foundation

/// On-disk mail cache figures for the Storage tab, read off the main thread (C-33).
struct MailCacheStats: Sendable {
    var databaseBytes: Int64 = 0
    var messages = 0
    var bodies = 0
    var queuedOps = 0
}

/// Maintenance that must not run on the app's main-actor connection: it opens its own short-lived
/// SQLite connection on whatever queue calls it (C-06, C-33).
extension Store {
    /// Cache sizes and counts. Never call this from the main actor: it opens a connection and runs SQL.
    nonisolated static func stats(path: String) -> MailCacheStats {
        var out = MailCacheStats()
        out.databaseBytes = fileBytes(path: path)
        guard let db = try? SQLiteDB(path: path) else { return out }
        out.messages = Int(db.scalarInt("SELECT COUNT(*) FROM messages") ?? 0)
        out.bodies = Int(db.scalarInt("SELECT COUNT(*) FROM bodies") ?? 0)
        out.queuedOps = Int(db.scalarInt("SELECT COUNT(*) FROM pending_ops") ?? 0)
        return out
    }

    /// Bytes used by the database file and its WAL/SHM companions.
    nonisolated static func fileBytes(path: String) -> Int64 {
        ["", "-wal", "-shm"].reduce(Int64(0)) { sum, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }

    /// Drops every cached body, its search index and the snippets, then compacts the file. Runs on the
    /// caller's queue with its own connection so two DELETEs and a VACUUM never block the UI (C-06).
    /// Returns true once the cache really is empty.
    @discardableResult
    nonisolated static func clearBodies(path: String) -> Bool {
        guard let db = try? SQLiteDB(path: path) else { return false }
        db.transaction {
            db.run("DELETE FROM bodies")
            db.run("DELETE FROM body_fts")
            db.run("UPDATE messages SET snippet=''")
        }
        // VACUUM must run outside a transaction; it rewrites the file so the space goes back to macOS.
        db.run("VACUUM")
        db.run("PRAGMA optimize")
        return db.scalarInt("SELECT COUNT(*) FROM bodies") == 0
    }
}
