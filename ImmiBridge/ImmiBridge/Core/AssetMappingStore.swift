import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-based store for tracking PHAsset to Immich asset ID mappings
/// Used for metadata sync to update existing assets without re-uploading
public final class AssetMappingStore: @unchecked Sendable {
    private let db: OpaquePointer?
    private let lock = NSLock()

    public init(sqliteURL: URL) throws {
        try FileManager.default.createDirectory(at: sqliteURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(sqliteURL.path, &db, flags, nil) != SQLITE_OK {
            defer { if db != nil { sqlite3_close(db) } }
            throw NSError(domain: "AssetMappingStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to open asset mapping DB: \(String(cString: sqlite3_errmsg(db)))"
            ])
        }
        self.db = db
        try runExec("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS asset_mappings (
          localIdentifier TEXT PRIMARY KEY,
          immichAssetId TEXT NOT NULL,
          deviceAssetId TEXT NOT NULL,
          lastSyncedSignature TEXT NOT NULL,
          lastSyncedAt REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_immichAssetId ON asset_mappings(immichAssetId);
        CREATE INDEX IF NOT EXISTS idx_deviceAssetId ON asset_mappings(deviceAssetId);
        """)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func runExec(_ sql: String) throws {
        guard let db else { return }
        var err: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(err)
            throw NSError(domain: "AssetMappingStore", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    /// Get mapping by PHAsset localIdentifier
    public func get(localIdentifier: String) -> AssetMapping? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }

        let sql = "SELECT localIdentifier, immichAssetId, deviceAssetId, lastSyncedSignature, lastSyncedAt FROM asset_mappings WHERE localIdentifier = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, localIdentifier, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return mappingFromRow(stmt)
    }

    /// Get mapping by Immich asset ID
    public func getByImmichId(immichAssetId: String) -> AssetMapping? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }

        let sql = "SELECT localIdentifier, immichAssetId, deviceAssetId, lastSyncedSignature, lastSyncedAt FROM asset_mappings WHERE immichAssetId = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, immichAssetId, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return mappingFromRow(stmt)
    }

    /// Get mapping by deviceAssetId (for recovery of pre-existing uploads)
    public func getByDeviceAssetId(deviceAssetId: String) -> AssetMapping? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }

        let sql = "SELECT localIdentifier, immichAssetId, deviceAssetId, lastSyncedSignature, lastSyncedAt FROM asset_mappings WHERE deviceAssetId = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, deviceAssetId, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return mappingFromRow(stmt)
    }

    private func mappingFromRow(_ stmt: OpaquePointer?) -> AssetMapping {
        let localId = String(cString: sqlite3_column_text(stmt, 0))
        let immichId = String(cString: sqlite3_column_text(stmt, 1))
        let deviceId = String(cString: sqlite3_column_text(stmt, 2))
        let signature = String(cString: sqlite3_column_text(stmt, 3))
        let lastSyncedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        return AssetMapping(
            localIdentifier: localId,
            immichAssetId: immichId,
            deviceAssetId: deviceId,
            lastSyncedSignature: signature,
            lastSyncedAt: lastSyncedAt
        )
    }

    /// Insert or update a mapping
    public func upsert(_ mapping: AssetMapping) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let sql = """
        INSERT INTO asset_mappings(localIdentifier, immichAssetId, deviceAssetId, lastSyncedSignature, lastSyncedAt)
        VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(localIdentifier) DO UPDATE SET
          immichAssetId=excluded.immichAssetId,
          deviceAssetId=excluded.deviceAssetId,
          lastSyncedSignature=excluded.lastSyncedSignature,
          lastSyncedAt=excluded.lastSyncedAt;
        """
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw NSError(domain: "AssetMappingStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "SQLite prepare failed"])
        }
        sqlite3_bind_text(stmt, 1, mapping.localIdentifier, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, mapping.immichAssetId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, mapping.deviceAssetId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, mapping.lastSyncedSignature, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, mapping.lastSyncedAt.timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw NSError(domain: "AssetMappingStore", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "SQLite upsert failed: \(String(cString: sqlite3_errmsg(db)))"
            ])
        }
    }

    /// Delete a mapping by localIdentifier
    public func delete(localIdentifier: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let sql = "DELETE FROM asset_mappings WHERE localIdentifier = ?;"
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return }
        sqlite3_bind_text(stmt, 1, localIdentifier, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    /// Get all mappings (for debugging/stats)
    public func allMappings() -> [AssetMapping] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        let sql = "SELECT localIdentifier, immichAssetId, deviceAssetId, lastSyncedSignature, lastSyncedAt FROM asset_mappings;"
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        var mappings: [AssetMapping] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            mappings.append(mappingFromRow(stmt))
        }
        return mappings
    }

    /// Get count of mappings
    public func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return 0 }

        let sql = "SELECT COUNT(*) FROM asset_mappings;"
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Get mappings where signature differs from provided signatures
    /// Used to find assets that need metadata sync
    public func mappingsNeedingSync(currentSignatures: [String: String]) -> [AssetMapping] {
        let allMaps = allMappings()
        return allMaps.filter { mapping in
            guard let currentSig = currentSignatures[mapping.localIdentifier] else {
                return false  // Asset no longer exists in Photos
            }
            return currentSig != mapping.lastSyncedSignature
        }
    }
}
