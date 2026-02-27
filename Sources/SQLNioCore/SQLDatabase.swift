/// The top-level protocol every database driver must conform to.
///
/// Usage:
/// ```swift
/// let db: any SQLDatabase = try await MSSQLConnection.connect(...)
/// let rows = try await db.query("SELECT id, name FROM users WHERE active = @p1", [.bool(true)])
/// ```
public protocol SQLDatabase: Sendable {
    /// Execute a SQL query and return all result rows.
    ///
    /// - Parameters:
    ///   - sql: The SQL statement. Use driver-specific placeholders:
    ///     * MSSQL  → `@p1`, `@p2`, …
    ///     * Postgres → `$1`, `$2`, …
    ///     * MySQL  → `?`
    ///   - binds: Ordered list of bound values.
    func query(_ sql: String, _ binds: [SQLValue]) async throws -> [SQLRow]

    /// Execute a SQL statement that returns no rows (INSERT/UPDATE/DELETE/DDL).
    /// Returns the number of rows affected.
    @discardableResult
    func execute(_ sql: String, _ binds: [SQLValue]) async throws -> Int

    /// Gracefully close the connection.
    func close() async throws
}

public extension SQLDatabase {
    /// Convenience: query with no binds.
    func query(_ sql: String) async throws -> [SQLRow] {
        try await query(sql, [])
    }

    /// Convenience: execute with no binds.
    @discardableResult
    func execute(_ sql: String) async throws -> Int {
        try await execute(sql, [])
    }

    /// Query and decode results into `T` using ``SQLRowDecoder``.
    func query<T: Decodable>(_ sql: String, _ binds: [SQLValue] = [], as type: T.Type = T.self) async throws -> [T] {
        let rows = try await query(sql, binds)
        return try rows.map { try SQLRowDecoder().decode(T.self, from: $0) }
    }
}
