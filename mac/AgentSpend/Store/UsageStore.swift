import Foundation
import SQLite3

/// Persistent store for deduplicated usage records.
///
/// `request_id` is the primary key, so re-ingesting the same data is a no-op —
/// which is what makes the incremental pass idempotent. The one exception is
/// `output_tokens`: a streamed message can be seen first as a partial and later
/// as complete, so the upsert keeps the larger value.
final class UsageStore {
    enum StoreError: Error, CustomStringConvertible {
        case sqlite(String)
        var description: String {
            switch self { case .sqlite(let m): return "sqlite: \(m)" }
        }
    }

    private var db: OpaquePointer?
    // SQLite needs to copy bound strings; the C macro isn't exposed to Swift.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: URL) throws {
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS requests (
              request_id   TEXT PRIMARY KEY,
              session_id   TEXT,
              ts           INTEGER,
              model        TEXT NOT NULL,
              input        INTEGER NOT NULL,
              cache_write  INTEGER NOT NULL,
              cache_w5m    INTEGER NOT NULL,
              cache_w1h    INTEGER NOT NULL,
              cache_read   INTEGER NOT NULL,
              output       INTEGER NOT NULL,
              cwd          TEXT,
              git_branch   TEXT,
              is_sidechain INTEGER NOT NULL,
              is_subagent  INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_ts ON requests(ts);
            CREATE INDEX IF NOT EXISTS idx_model ON requests(model);
            CREATE INDEX IF NOT EXISTS idx_cwd ON requests(cwd);
            """)
    }

    deinit { sqlite3_close(db) }

    static func defaultLocation() throws -> URL {
        try FileIndex.supportDirectory().appending(path: "usage.sqlite")
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            defer { sqlite3_free(err) }
            throw StoreError.sqlite(err.map { String(cString: $0) } ?? "unknown")
        }
    }

    /// Insert or update records. Returns the number of rows actually written.
    ///
    /// `excluded.output > requests.output` is the whole streaming fix: an
    /// upsert that unconditionally overwrote would be fine, but one that used
    /// `INSERT OR IGNORE` would keep the first partial and lose 12.6% of output
    /// tokens.
    @discardableResult
    func upsert(_ records: some Collection<UsageRecord>) throws -> Int {
        guard !records.isEmpty else { return 0 }
        try exec("BEGIN IMMEDIATE;")
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO requests
              (request_id, session_id, ts, model, input, cache_write, cache_w5m,
               cache_w1h, cache_read, output, cwd, git_branch, is_sidechain, is_subagent)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(request_id) DO UPDATE SET
              output = MAX(requests.output, excluded.output);
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            try? exec("ROLLBACK;")
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var written = 0
        for r in records {
            sqlite3_reset(stmt)
            bindText(stmt, 1, r.id)
            bindText(stmt, 2, r.sessionId)
            if let ts = r.timestamp {
                sqlite3_bind_int64(stmt, 3, Int64(ts.timeIntervalSince1970))
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            bindText(stmt, 4, r.model)
            sqlite3_bind_int64(stmt, 5, Int64(r.input))
            sqlite3_bind_int64(stmt, 6, Int64(r.cacheWrite))
            sqlite3_bind_int64(stmt, 7, Int64(r.cacheWrite5m))
            sqlite3_bind_int64(stmt, 8, Int64(r.cacheWrite1h))
            sqlite3_bind_int64(stmt, 9, Int64(r.cacheRead))
            sqlite3_bind_int64(stmt, 10, Int64(r.output))
            bindText(stmt, 11, r.cwd)
            bindText(stmt, 12, r.gitBranch)
            sqlite3_bind_int(stmt, 13, r.isSidechain ? 1 : 0)
            sqlite3_bind_int(stmt, 14, r.isSubagent ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                try? exec("ROLLBACK;")
                throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            written += 1
        }
        try exec("COMMIT;")
        return written
    }

    private func bindText(_ stmt: OpaquePointer?, _ i: Int32, _ s: String?) {
        if let s { sqlite3_bind_text(stmt, i, s, -1, Self.transient) }
        else { sqlite3_bind_null(stmt, i) }
    }

    // MARK: - Queries

    func count() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM requests;")
    }

    func distinctIDCount() throws -> Int {
        try scalarInt("SELECT COUNT(DISTINCT request_id) FROM requests;")
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Aggregated token totals grouped by an arbitrary column.
    func totals(groupedBy column: String, since: Date? = nil) throws -> [String: TokenTotals] {
        precondition(["model", "cwd", "git_branch"].contains(column),
                     "column is interpolated into SQL — allowlist only")
        var sql = """
            SELECT COALESCE(\(column), 'unknown'), COUNT(*), SUM(input), SUM(cache_write),
                   SUM(cache_w5m), SUM(cache_w1h), SUM(cache_read), SUM(output)
            FROM requests
            """
        if since != nil { sql += " WHERE ts >= ?" }
        sql += " GROUP BY 1;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        if let since { sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970)) }

        var out: [String: TokenTotals] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            out[key] = TokenTotals(
                requests: Int(sqlite3_column_int64(stmt, 1)),
                input: Int(sqlite3_column_int64(stmt, 2)),
                cacheWrite: Int(sqlite3_column_int64(stmt, 3)),
                cacheWrite5m: Int(sqlite3_column_int64(stmt, 4)),
                cacheWrite1h: Int(sqlite3_column_int64(stmt, 5)),
                cacheRead: Int(sqlite3_column_int64(stmt, 6)),
                output: Int(sqlite3_column_int64(stmt, 7))
            )
        }
        return out
    }

    func allRecords() throws -> [UsageRecord] {
        var stmt: OpaquePointer?
        let sql = """
            SELECT request_id, session_id, ts, model, input, cache_write, cache_w5m,
                   cache_w1h, cache_read, output, cwd, git_branch, is_sidechain, is_subagent
            FROM requests;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [UsageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(stmt, i))
            }
            out.append(UsageRecord(
                id: text(0) ?? "",
                timestamp: sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2))),
                model: text(3) ?? "",
                input: Int(sqlite3_column_int64(stmt, 4)),
                output: Int(sqlite3_column_int64(stmt, 9)),
                cacheWrite: Int(sqlite3_column_int64(stmt, 5)),
                cacheWrite5m: Int(sqlite3_column_int64(stmt, 6)),
                cacheWrite1h: Int(sqlite3_column_int64(stmt, 7)),
                cacheRead: Int(sqlite3_column_int64(stmt, 8)),
                cwd: text(10),
                gitBranch: text(11),
                sessionId: text(1),
                isSidechain: sqlite3_column_int(stmt, 12) == 1,
                isSubagent: sqlite3_column_int(stmt, 13) == 1
            ))
        }
        return out
    }
}

struct TokenTotals: Sendable, Equatable {
    var requests = 0
    var input = 0
    var cacheWrite = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var output = 0

    var total: Int { input + cacheWrite + cacheRead + output }

    /// Share of prompt tokens served from cache. High is good: reads bill at
    /// 0.1x and skip prefill, while writes re-pay full prefill at a 1.25-2x
    /// premium. A low ratio means cache churn.
    var cacheEfficiency: Double {
        let denom = cacheRead + cacheWrite + input
        return denom == 0 ? 0 : Double(cacheRead) / Double(denom)
    }

    static func + (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        TokenTotals(requests: a.requests + b.requests,
                    input: a.input + b.input,
                    cacheWrite: a.cacheWrite + b.cacheWrite,
                    cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
                    cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
                    cacheRead: a.cacheRead + b.cacheRead,
                    output: a.output + b.output)
    }
}
