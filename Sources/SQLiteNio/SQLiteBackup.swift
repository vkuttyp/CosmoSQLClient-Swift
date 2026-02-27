#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import Foundation
import NIOCore
import SQLNioCore

// ── SQLiteConnection Backup & Restore ─────────────────────────────────────────
//
// Two backup modes:
//
// 1. **Native binary backup** (SQLite-only, fastest, exact copy):
//    ```swift
//    try await conn.backup(to: "/path/to/backup.sqlite")
//    try await conn.restore(fromBackup: "/path/to/backup.sqlite")
//    let data = try await conn.serialize()
//    ```
//
// 2. **Logical SQL dump** (portable, works across all drivers):
//    ```swift
//    let sql = try await conn.dump()                       // all tables
//    let sql = try await conn.dump(tables: ["users"])      // specific tables
//    try await conn.dump(to: "/path/backup.sql")
//    try await conn.restore(from: sql)
//    try await conn.restore(fromFile: "/path/backup.sql")
//    ```

public extension SQLiteConnection {

    // MARK: - Native Binary Backup (sqlite3_backup API)

    /// Copy the entire database to a new SQLite file using the online backup API.
    /// The destination file is created (or overwritten). Safe to call on a live database.
    func backup(to path: String) async throws {
        try await pool.runIfActive(eventLoop: group.next()) {
            try self.nativeBackup(to: path)
        }.get()
    }

    /// Restore this connection's database from a previously created binary backup file.
    /// All existing data in this connection is replaced.
    func restore(fromBackup path: String) async throws {
        try await pool.runIfActive(eventLoop: group.next()) {
            try self.nativeRestore(from: path)
        }.get()
    }

    /// Serialize the entire in-memory (or file) database to a `Data` blob.
    /// Useful for storing a snapshot in memory or sending over a network.
    func serialize() async throws -> Data {
        try await pool.runIfActive(eventLoop: group.next()) {
            try self.nativeSerialize()
        }.get()
    }

    // MARK: - Logical SQL Dump

    /// Export all (or specific) tables as SQL INSERT statements.
    ///
    /// - Parameter tables: List of table names to dump. `nil` = all user tables.
    /// - Returns: A SQL string with header comments and one INSERT per row.
    func dump(tables: [String]? = nil) async throws -> String {
        let tableList = try await resolveTables(tables)
        var lines: [String] = [sqlDumpHeader(dialect: .sqlite, database: "sqlite"), ""]
        for table in tableList {
            let createSQL = try await getCreateSQL(table: table)
            lines.append("-- Table: \(table)")
            if let ddl = createSQL {
                lines.append(ddl + ";")
            }
            let rows = try await query("SELECT * FROM \(sqlQuote(table, dialect: .sqlite))", [])
            lines.append(contentsOf: sqlInsertStatements(table: table, rows: rows, dialect: .sqlite))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Write a SQL dump to a file at the given path.
    func dump(to path: String, tables: [String]? = nil) async throws {
        let sql = try await dump(tables: tables)
        try sql.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Execute a SQL dump string against this connection (restore from logical dump).
    func restore(from sql: String) async throws {
        let statements = sqlSplitDump(sql)
        for stmt in statements {
            _ = try await execute(stmt)
        }
    }

    /// Read and execute a SQL dump file (restore from logical dump).
    func restore(fromFile path: String) async throws {
        let sql = try String(contentsOfFile: path, encoding: .utf8)
        try await restore(from: sql)
    }

    // MARK: - Private helpers

    private func resolveTables(_ tables: [String]?) async throws -> [String] {
        if let tables { return tables }
        let rows = try await query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
            [])
        return rows.compactMap { $0["name"].asString() }
    }

    private func getCreateSQL(table: String) async throws -> String? {
        let rows = try await query(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name = ?",
            [.string(table)])
        return rows.first?["sql"].asString()
    }
}

// MARK: - Native backup internals (run on thread pool)

private extension SQLiteConnection {

    func nativeBackup(to destPath: String) throws {
        guard let sourceDB = self.dbHandle else { throw SQLError.connectionClosed }

        var destDB: OpaquePointer?
        let openRC = sqlite3_open_v2(destPath, &destDB,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openRC == SQLITE_OK, let destDB else {
            throw SQLError.serverError(code: Int(openRC), message: "Cannot open backup destination")
        }
        defer { sqlite3_close_v2(destDB) }

        guard let backup = sqlite3_backup_init(destDB, "main", sourceDB, "main") else {
            let msg = String(cString: sqlite3_errmsg(destDB))
            throw SQLError.serverError(code: -1, message: "Backup init failed: \(msg)")
        }
        defer { sqlite3_backup_finish(backup) }

        var rc: Int32
        repeat {
            rc = sqlite3_backup_step(backup, 100)  // copy 100 pages at a time
        } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED

        guard rc == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(destDB))
            throw SQLError.serverError(code: Int(rc), message: "Backup failed: \(msg)")
        }
    }

    func nativeRestore(from sourcePath: String) throws {
        guard let destDB = self.dbHandle else { throw SQLError.connectionClosed }

        var sourceDB: OpaquePointer?
        let openRC = sqlite3_open_v2(sourcePath, &sourceDB,
                                     SQLITE_OPEN_READONLY, nil)
        guard openRC == SQLITE_OK, let sourceDB else {
            throw SQLError.serverError(code: Int(openRC), message: "Cannot open backup source")
        }
        defer { sqlite3_close_v2(sourceDB) }

        guard let backup = sqlite3_backup_init(destDB, "main", sourceDB, "main") else {
            let msg = String(cString: sqlite3_errmsg(destDB))
            throw SQLError.serverError(code: -1, message: "Restore init failed: \(msg)")
        }
        defer { sqlite3_backup_finish(backup) }

        var rc: Int32
        repeat {
            rc = sqlite3_backup_step(backup, 100)
        } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED

        guard rc == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(destDB))
            throw SQLError.serverError(code: Int(rc), message: "Restore failed: \(msg)")
        }
    }

    func nativeSerialize() throws -> Data {
        guard let db = self.dbHandle else { throw SQLError.connectionClosed }
        var size: sqlite3_int64 = 0
        guard let ptr = sqlite3_serialize(db, "main", &size, 0) else {
            throw SQLError.serverError(code: -1, message: "sqlite3_serialize returned nil")
        }
        defer { sqlite3_free(ptr) }
        return Data(bytes: ptr, count: Int(size))
    }
}

// MARK: - Expose db handle for backup extension (package-internal)

extension SQLiteConnection {
    /// The raw `sqlite3 *` handle — accessible within the SQLiteNio module.
    var dbHandle: OpaquePointer? { db }
}
