import Foundation

// ── SQL Dialects and Logical Dump ─────────────────────────────────────────────
//
// Shared types for generating and restoring SQL dump files across all drivers.

/// The SQL dialect used when formatting literals in a dump file.
public enum SQLDialect: String, Sendable, Codable {
    case sqlite
    case mysql
    case postgresql
    case mssql
}

// MARK: - SQL Literal Generation

public extension SQLValue {

    /// Return a SQL literal string suitable for embedding in INSERT statements.
    ///
    /// - Note: Strings are escaped by doubling internal single-quotes (standard SQL).
    ///         Binary data is hex-encoded using dialect-specific syntax.
    func sqlLiteral(for dialect: SQLDialect) -> String {
        switch self {
        case .null:
            return "NULL"

        case .bool(let v):
            switch dialect {
            case .postgresql:            return v ? "TRUE" : "FALSE"
            case .sqlite, .mysql, .mssql: return v ? "1"    : "0"
            }

        case .int(let v):    return "\(v)"
        case .int8(let v):   return "\(v)"
        case .int16(let v):  return "\(v)"
        case .int32(let v):  return "\(v)"
        case .int64(let v):  return "\(v)"

        case .float(let v):
            if v.isNaN || v.isInfinite { return "NULL" }
            return "\(v)"

        case .double(let v):
            if v.isNaN || v.isInfinite { return "NULL" }
            return "\(v)"

        case .decimal(let v):
            return (v as NSDecimalNumber).stringValue

        case .string(let v):
            // Escape by doubling single-quotes (ANSI SQL)
            let escaped = v.replacingOccurrences(of: "'", with: "''")
            return "'\(escaped)'"

        case .bytes(let v):
            let hex = v.map { String(format: "%02X", $0) }.joined()
            switch dialect {
            case .sqlite, .mysql:  return "X'\(hex)'"
            case .postgresql:      return "E'\\\\x\(hex)'"
            case .mssql:           return "0x\(hex)"
            }

        case .uuid(let v):
            return "'\(v.uuidString)'"

        case .date(let v):
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime]
            let s = fmt.string(from: v)
            switch dialect {
            case .sqlite, .mysql, .mssql: return "'\(s)'"
            case .postgresql:             return "'\(s)'::timestamptz"
            }
        }
    }
}

// MARK: - Dump Formatting Helpers

/// Quote an identifier (table/column name) for the given dialect.
public func sqlQuote(_ name: String, dialect: SQLDialect) -> String {
    switch dialect {
    case .sqlite, .postgresql: return "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    case .mysql:               return "`\(name.replacingOccurrences(of: "`",  with: "``"))`"
    case .mssql:               return "[\(name.replacingOccurrences(of: "]",  with: "]]"))]"
    }
}

/// Build the header comment for a dump file.
public func sqlDumpHeader(dialect: SQLDialect, database: String) -> String {
    let ts = ISO8601DateFormatter().string(from: Date())
    return """
    -- sql-nio dump
    -- dialect: \(dialect.rawValue)
    -- database: \(database)
    -- created: \(ts)
    -- Restore with: conn.restore(fromFile: path)
    """
}

/// Generate INSERT statements for one table from an array of rows.
public func sqlInsertStatements(
    table: String,
    rows: [SQLRow],
    dialect: SQLDialect
) -> [String] {
    guard !rows.isEmpty else { return [] }
    let tq = sqlQuote(table, dialect: dialect)
    let cols = rows[0].columns.map { sqlQuote($0.name, dialect: dialect) }.joined(separator: ", ")
    return rows.map { row in
        let vals = row.values.map { $0.sqlLiteral(for: dialect) }.joined(separator: ", ")
        return "INSERT INTO \(tq) (\(cols)) VALUES (\(vals));"
    }
}

/// Split a SQL dump string into individual executable statements.
/// Splits on semicolons (`;`), ignoring comment lines.
public func sqlSplitDump(_ sql: String) -> [String] {
    // Strip comment lines, then split on semicolons
    let stripped = sql.components(separatedBy: "\n")
        .filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("--")
        }
        .joined(separator: "\n")
    return stripped.components(separatedBy: ";")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}
