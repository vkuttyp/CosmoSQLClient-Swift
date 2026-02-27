import Foundation
import SQLNioCore

// ── MySQLConnection Backup & Restore ─────────────────────────────────────────
//
// Logical SQL dump: exports table data as INSERT statements.
//
// Usage:
// ```swift
// let sql = try await conn.dump()                        // all tables
// let sql = try await conn.dump(tables: ["users"])       // specific tables
// try await conn.dump(to: "/tmp/backup.sql")             // write to file
// try await conn.restore(from: sql)                      // restore from string
// try await conn.restore(fromFile: "/tmp/backup.sql")    // restore from file
// ```

public extension MySQLConnection {

    // MARK: - Dump

    /// Export all (or specific) tables as SQL INSERT statements.
    func dump(tables: [String]? = nil) async throws -> String {
        let tableList = try await resolveTables(tables)
        let dbName = config.database
        var lines: [String] = [sqlDumpHeader(dialect: .mysql, database: dbName), ""]
        for table in tableList {
            lines.append("-- Table: \(table)")
            let rows = try await query(
                "SELECT * FROM \(sqlQuote(table, dialect: .mysql))", [])
            lines.append(contentsOf: sqlInsertStatements(
                table: table, rows: rows, dialect: .mysql))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Write a SQL dump to a file.
    func dump(to path: String, tables: [String]? = nil) async throws {
        let sql = try await dump(tables: tables)
        try sql.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Execute a SQL dump string to restore data.
    func restore(from sql: String) async throws {
        for stmt in sqlSplitDump(sql) {
            _ = try await execute(stmt)
        }
    }

    /// Read and execute a SQL dump file to restore data.
    func restore(fromFile path: String) async throws {
        let sql = try String(contentsOfFile: path, encoding: .utf8)
        try await restore(from: sql)
    }

    // MARK: - Private

    private func resolveTables(_ tables: [String]?) async throws -> [String] {
        if let tables { return tables }
        let rows = try await query(
            "SELECT TABLE_NAME FROM information_schema.TABLES " +
            "WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME", [])
        return rows.compactMap { $0["TABLE_NAME"].asString() }
    }
}
