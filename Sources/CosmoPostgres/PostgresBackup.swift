import Foundation
import CosmoSQLCore

// ── PostgresConnection Backup & Restore ───────────────────────────────────────
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

public extension PostgresConnection {

    // MARK: - Dump

    /// Export all (or specific) tables in the `public` schema as INSERT statements.
    func dump(tables: [String]? = nil) async throws -> String {
        let tableList = try await resolveTables(tables)
        let dbName = config.database
        var lines: [String] = [sqlDumpHeader(dialect: .postgresql, database: dbName), ""]
        for table in tableList {
            lines.append("-- Table: \(table)")
            let rows = try await query(
                "SELECT * FROM \(sqlQuote(table, dialect: .postgresql))", [])
            lines.append(contentsOf: sqlInsertStatements(
                table: table, rows: rows, dialect: .postgresql))
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
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename",
            [])
        return rows.compactMap { $0["tablename"].asString() }
    }
}
