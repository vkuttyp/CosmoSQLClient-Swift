import Foundation
import CosmoSQLCore

// ── MSSQLConnection Backup & Restore ─────────────────────────────────────────
//
// Logical SQL dump: exports table data as INSERT statements.
//
// Usage:
// ```swift
// let sql = try await conn.dump()
// try await conn.dump(to: "/tmp/backup.sql")
// try await conn.restore(from: sql)
// try await conn.restore(fromFile: "/tmp/backup.sql")
// ```
//
// Note: For full SQL Server backups (including schema, indexes, stored procedures,
// etc.), use SQL Server's native BACKUP DATABASE command or SQL Server Management
// Studio. This utility covers data-only logical exports.

public extension MSSQLConnection {

    // MARK: - Dump

    /// Export all (or specific) user tables as INSERT statements.
    func dump(tables: [String]? = nil) async throws -> String {
        let tableList = try await resolveTables(tables)
        let dbName = config.database
        var lines: [String] = [sqlDumpHeader(dialect: .mssql, database: dbName), ""]
        for table in tableList {
            lines.append("-- Table: \(table)")
            // SET IDENTITY_INSERT allows inserting explicit PK values
            lines.append("SET IDENTITY_INSERT \(sqlQuote(table, dialect: .mssql)) ON;")
            let rows = try await query(
                "SELECT * FROM \(sqlQuote(table, dialect: .mssql))", [])
            lines.append(contentsOf: sqlInsertStatements(
                table: table, rows: rows, dialect: .mssql))
            lines.append("SET IDENTITY_INSERT \(sqlQuote(table, dialect: .mssql)) OFF;")
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
            "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES " +
            "WHERE TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME", [])
        return rows.compactMap { $0["TABLE_NAME"].asString() }
    }
}
