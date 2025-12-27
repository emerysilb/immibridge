import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ManifestEntry: Sendable {
    public var key: String
    public var relPath: String
    public var signature: String
    public var size: Int64
    public var mtime: Double
    public var lastSeenRunId: String
    public var deletedAt: Double?

    public init(
        key: String,
        relPath: String,
        signature: String,
        size: Int64,
        mtime: Double,
        lastSeenRunId: String,
        deletedAt: Double? = nil
    ) {
        self.key = key
        self.relPath = relPath
        self.signature = signature
        self.size = size
        self.mtime = mtime
        self.lastSeenRunId = lastSeenRunId
        self.deletedAt = deletedAt
    }
}

public final class ManifestStore: @unchecked Sendable {
    private let db: OpaquePointer?
    private let lock = NSLock()

    public init(sqliteURL: URL) throws {
        try FileManager.default.createDirectory(at: sqliteURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(sqliteURL.path, &db, flags, nil) != SQLITE_OK {
            defer { if db != nil { sqlite3_close(db) } }
            throw NSError(domain: "ManifestStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to open manifest DB: \(String(cString: sqlite3_errmsg(db)))"
            ])
        }
        self.db = db
        try exec("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS entries (
          key TEXT PRIMARY KEY,
          relPath TEXT NOT NULL,
          signature TEXT NOT NULL,
          size INTEGER NOT NULL,
          mtime REAL NOT NULL,
          lastSeenRunId TEXT NOT NULL,
          deletedAt REAL
        );
        CREATE INDEX IF NOT EXISTS idx_entries_lastSeenRunId ON entries(lastSeenRunId);
        """)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func exec(_ sql: String) throws {
        guard let db else { return }
        var err: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(err)
            throw NSError(domain: "ManifestStore", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    public func get(key: String) -> ManifestEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }

        let sql = "SELECT key, relPath, signature, size, mtime, lastSeenRunId, deletedAt FROM entries WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let keyStr = String(cString: sqlite3_column_text(stmt, 0))
        let relPath = String(cString: sqlite3_column_text(stmt, 1))
        let signature = String(cString: sqlite3_column_text(stmt, 2))
        let size = sqlite3_column_int64(stmt, 3)
        let mtime = sqlite3_column_double(stmt, 4)
        let lastSeenRunId = String(cString: sqlite3_column_text(stmt, 5))
        let deletedAt: Double?
        if sqlite3_column_type(stmt, 6) == SQLITE_NULL {
            deletedAt = nil
        } else {
            deletedAt = sqlite3_column_double(stmt, 6)
        }
        return ManifestEntry(
            key: keyStr,
            relPath: relPath,
            signature: signature,
            size: size,
            mtime: mtime,
            lastSeenRunId: lastSeenRunId,
            deletedAt: deletedAt
        )
    }

    public func upsert(_ entry: ManifestEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let sql = """
        INSERT INTO entries(key, relPath, signature, size, mtime, lastSeenRunId, deletedAt)
        VALUES(?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
          relPath=excluded.relPath,
          signature=excluded.signature,
          size=excluded.size,
          mtime=excluded.mtime,
          lastSeenRunId=excluded.lastSeenRunId,
          deletedAt=excluded.deletedAt;
        """
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw NSError(domain: "ManifestStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "SQLite prepare failed"])
        }
        sqlite3_bind_text(stmt, 1, entry.key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, entry.relPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, entry.signature, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, entry.size)
        sqlite3_bind_double(stmt, 5, entry.mtime)
        sqlite3_bind_text(stmt, 6, entry.lastSeenRunId, -1, SQLITE_TRANSIENT)
        if let deletedAt = entry.deletedAt {
            sqlite3_bind_double(stmt, 7, deletedAt)
        } else {
            sqlite3_bind_null(stmt, 7)
        }

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw NSError(domain: "ManifestStore", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "SQLite upsert failed: \(String(cString: sqlite3_errmsg(db)))"
            ])
        }
    }

    public func markDeleted(key: String, deletedAt: Double = Date().timeIntervalSince1970) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        let sql = "UPDATE entries SET deletedAt = ? WHERE key = ?;"
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return }
        sqlite3_bind_double(stmt, 1, deletedAt)
        sqlite3_bind_text(stmt, 2, key, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    public func keysNotSeen(runId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let sql = "SELECT key FROM entries WHERE lastSeenRunId != ? AND deletedAt IS NULL;"
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, runId, -1, SQLITE_TRANSIENT)
        var keys: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            keys.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return keys
    }
}
