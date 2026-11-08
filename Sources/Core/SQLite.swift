import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DBError: Error, LocalizedError {
    case open(String)
    case sql(String)
    var errorDescription: String? {
        switch self {
        case .open(let m): return "Could not open the mail cache: \(m)"
        case .sql(let m): return "Mail cache error: \(m)"
        }
    }
}

/// A thin SQLite wrapper with a prepared-statement cache. One instance, used from the main actor.
final class SQLiteDB {
    private var handle: OpaquePointer?
    private var cache: [String: Statement] = [:]

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            throw DBError.open(String(cString: sqlite3_errmsg(handle)))
        }
        // A 2 MB page cache keeps the database's resident memory small; WAL keeps writes cheap.
        try exec("""
            PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;
            PRAGMA cache_size=-2000; PRAGMA temp_store=MEMORY; PRAGMA mmap_size=0;
            """)
    }

    deinit {
        cache.removeAll()
        sqlite3_close_v2(handle)
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.sql(message)
        }
    }

    func statement(_ sql: String) throws -> Statement {
        if let s = cache[sql] {
            s.reset()
            return s
        }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DBError.sql(String(cString: sqlite3_errmsg(handle)) + " — " + sql.prefix(120))
        }
        let s = Statement(stmt!)
        cache[sql] = s
        return s
    }

    /// Runs a write statement.
    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) -> Bool {
        guard let s = try? statement(sql) else { return false }
        s.bind(args)
        let rc = s.stepRaw()
        s.reset()
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    /// Iterates result rows.
    func query(_ sql: String, _ args: [Any?] = [], _ row: (Statement) -> Void) {
        guard let s = try? statement(sql) else { return }
        s.bind(args)
        while s.stepRaw() == SQLITE_ROW { row(s) }
        s.reset()
    }

    func scalarInt(_ sql: String, _ args: [Any?] = []) -> Int64? {
        var out: Int64?
        query(sql, args) { out = $0.int64(0) }
        return out
    }

    func transaction(_ body: () -> Void) {
        _ = try? exec("BEGIN IMMEDIATE")
        body()
        _ = try? exec("COMMIT")
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }
}

final class Statement {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { sqlite3_finalize(raw) }

    func reset() {
        sqlite3_reset(raw)
        sqlite3_clear_bindings(raw)
    }

    func bind(_ args: [Any?]) {
        for (i, value) in args.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case nil: sqlite3_bind_null(raw, idx)
            case let v as Int: sqlite3_bind_int64(raw, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(raw, idx, v)
            case let v as UInt32: sqlite3_bind_int64(raw, idx, Int64(v))
            case let v as UInt64: sqlite3_bind_int64(raw, idx, Int64(bitPattern: v))
            case let v as Bool: sqlite3_bind_int64(raw, idx, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(raw, idx, v)
            case let v as Date: sqlite3_bind_double(raw, idx, v.timeIntervalSince1970)
            case let v as String: sqlite3_bind_text(raw, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(raw, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            default: sqlite3_bind_null(raw, idx)
            }
        }
    }

    func stepRaw() -> Int32 { sqlite3_step(raw) }

    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(raw, i) }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(raw, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(raw, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(raw, i) == SQLITE_NULL }
    func string(_ i: Int32) -> String? {
        guard let p = sqlite3_column_text(raw, i) else { return nil }
        return String(cString: p)
    }
    func text(_ i: Int32) -> String { string(i) ?? "" }
}
