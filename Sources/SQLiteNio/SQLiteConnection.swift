import SQLite3
import Foundation
import NIOCore
import NIOPosix
import Logging
import SQLNioCore

// SQLITE_TRANSIENT tells SQLite to copy the data (safe for Swift strings/buffers)
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self)

// ── SQLiteConnection ──────────────────────────────────────────────────────────
//
// A single async/await connection to an SQLite database.
// Wraps the sqlite3 C API, running all blocking calls on NIOThreadPool.
//
// Usage:
// ```swift
// // In-memory
// let conn = try SQLiteConnection.open(configuration: .init(storage: .memory))
// defer { try? await conn.close() }
//
// // File-based
// let conn = try SQLiteConnection.open(
//     configuration: .init(storage: .file(path: "/tmp/mydb.sqlite")))
//
// let rows = try await conn.query("SELECT id, name FROM users WHERE active = ?", [.bool(true)])
// ```

public final class SQLiteConnection: SQLDatabase, @unchecked Sendable {

    // MARK: - Storage

    public enum Storage: Sendable {
        /// Volatile in-memory database (gone when connection closes).
        case memory
        /// Persistent file database at the given path.
        case file(path: String)

        var path: String {
            switch self {
            case .memory:             return ":memory:"
            case .file(let path):    return path
            }
        }
    }

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var storage: Storage
        public var logger:  Logger

        public init(storage: Storage = .memory,
                    logger:  Logger  = Logger(label: "SQLiteNio")) {
            self.storage = storage
            self.logger  = logger
        }
    }

    // MARK: - State

    var db:       OpaquePointer?  // internal — accessed by SQLiteBackup extension
    private let config:   Configuration
    private let logger:   Logger
    let pool:     NIOThreadPool    // internal — accessed by SQLiteBackup extension
    let group:    any EventLoopGroup  // internal — accessed by SQLiteBackup extension
    private var _isOpen:  Bool = true

    public var isOpen: Bool { _isOpen }

    // MARK: - Open

    /// Open (or create) an SQLite database.
    /// This call is synchronous because `sqlite3_open_v2` is fast (no network).
    public static func open(
        configuration:  Configuration   = .init(),
        threadPool:     NIOThreadPool   = .singleton,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) throws -> SQLiteConnection {
        var db: OpaquePointer?
        // SQLITE_OPEN_FULLMUTEX: serialize all access so multi-thread use is safe
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(configuration.storage.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close_v2(db) }
            throw SQLError.connectionError(msg)
        }
        // Enable WAL journal for better concurrent read performance on file DBs
        if case .file = configuration.storage {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        }
        return SQLiteConnection(db: db, config: configuration,
                                pool: threadPool, group: eventLoopGroup)
    }

    private init(db: OpaquePointer, config: Configuration,
                 pool: NIOThreadPool, group: any EventLoopGroup) {
        self.db     = db
        self.config = config
        self.logger = config.logger
        self.pool   = pool
        self.group  = group
    }

    // MARK: - SQLDatabase

    public func query(_ sql: String, _ binds: [SQLValue]) async throws -> [SQLRow] {
        let prepared = renderQuery(sql, binds: binds)
        logger.debug("SQLite query: \(prepared)")
        return try await pool.runIfActive(eventLoop: group.next()) {
            try self.execQuery(prepared, binds: binds)
        }.get()
    }

    @discardableResult
    public func execute(_ sql: String, _ binds: [SQLValue]) async throws -> Int {
        let prepared = renderQuery(sql, binds: binds)
        logger.debug("SQLite execute: \(prepared)")
        return try await pool.runIfActive(eventLoop: group.next()) {
            try self.execStatement(prepared, binds: binds)
        }.get()
    }

    public func close() async throws {
        _isOpen = false
        if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    // MARK: - Transactions

    public func begin() async throws    { _ = try await execute("BEGIN") }
    public func commit() async throws   { _ = try await execute("COMMIT") }
    public func rollback() async throws { _ = try await execute("ROLLBACK") }

    public func withTransaction<T: Sendable>(
        _ body: @Sendable (SQLiteConnection) async throws -> T
    ) async throws -> T {
        try await begin()
        do {
            let result = try await body(self)
            try await commit()
            return result
        } catch {
            try? await rollback()
            throw error
        }
    }

    // MARK: - Multi-statement (split on ";")

    public func queryMulti(_ sql: String, _ binds: [SQLValue] = []) async throws -> [[SQLRow]] {
        let stmts = sql
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var results: [[SQLRow]] = []
        for stmt in stmts {
            results.append(try await query(stmt, binds))
        }
        return results
    }

    // MARK: - Blocking internals (run on thread pool)

    private func execQuery(_ sql: String, binds: [SQLValue]) throws -> [SQLRow] {
        guard let db else { throw SQLError.connectionClosed }

        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw sqliteError(db: db, code: rc, context: "prepare")
        }
        defer { sqlite3_finalize(stmt) }

        try bindParams(stmt: stmt, binds: binds, db: db)

        let colCount = Int(sqlite3_column_count(stmt))
        let columns  = makeColumns(stmt: stmt, count: colCount)

        var rows: [SQLRow] = []
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                let values = (0..<colCount).map { readColumn(stmt: stmt, index: Int32($0)) }
                rows.append(SQLRow(columns: columns, values: values))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw sqliteError(db: db, code: rc, context: "step")
            }
        }
        return rows
    }

    private func execStatement(_ sql: String, binds: [SQLValue]) throws -> Int {
        guard let db else { throw SQLError.connectionClosed }

        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw sqliteError(db: db, code: rc, context: "prepare")
        }
        defer { sqlite3_finalize(stmt) }

        try bindParams(stmt: stmt, binds: binds, db: db)

        rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw sqliteError(db: db, code: rc, context: "step")
        }
        return Int(sqlite3_changes(db))
    }

    // MARK: - Helpers

    /// Replace @p1, @p2, … with SQLite's native ?1, ?2, … numbered placeholders.
    private func renderQuery(_ sql: String, binds: [SQLValue]) -> String {
        var rendered = sql
        for idx in stride(from: binds.count, through: 1, by: -1) {
            rendered = rendered.replacingOccurrences(of: "@p\(idx)", with: "?\(idx)")
        }
        return rendered
    }

    private func bindParams(stmt: OpaquePointer, binds: [SQLValue], db: OpaquePointer) throws {
        for (i, value) in binds.enumerated() {
            let rc = value.sqliteBind(stmt: stmt, at: Int32(i + 1))
            guard rc == SQLITE_OK else {
                throw sqliteError(db: db, code: rc, context: "bind[\(i)]")
            }
        }
    }

    private func makeColumns(stmt: OpaquePointer, count: Int) -> [SQLColumn] {
        (0..<count).map { i in
            let name = sqlite3_column_name(stmt, Int32(i))
                .map { String(cString: $0) } ?? "col\(i)"
            let declType = sqlite3_column_decltype(stmt, Int32(i))
                .map { String(cString: $0) } ?? ""
            return SQLColumn(name: name, table: nil,
                             dataTypeID: declTypeID(declType))
        }
    }

    private func readColumn(stmt: OpaquePointer, index: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .int64(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(stmt, index))
        case SQLITE_TEXT:
            let text = sqlite3_column_text(stmt, index)
                .map { String(cString: $0) } ?? ""
            // Attempt UUID detection for CHAR(36) style UUID text columns
            let declType = sqlite3_column_decltype(stmt, index)
                .map { String(cString: $0).uppercased() } ?? ""
            if declType.contains("UUID"), let uuid = UUID(uuidString: text) {
                return .uuid(uuid)
            }
            return .string(text)
        case SQLITE_BLOB:
            guard let ptr = sqlite3_column_blob(stmt, index) else { return .bytes([]) }
            let len = Int(sqlite3_column_bytes(stmt, index))
            let buf = UnsafeBufferPointer(
                start: ptr.assumingMemoryBound(to: UInt8.self), count: len)
            return .bytes(Array(buf))
        default:
            return .null
        }
    }

    private func declTypeID(_ type: String) -> UInt32 {
        let up = type.uppercased()
        if up.contains("INT")                                   { return 1 }
        if up.contains("REAL") || up.contains("FLOAT")
            || up.contains("DOUBLE")                            { return 2 }
        if up.contains("BLOB")                                  { return 4 }
        return 3  // TEXT / default
    }

    private func sqliteError(db: OpaquePointer, code: Int32, context: String) -> SQLError {
        let msg = String(cString: sqlite3_errmsg(db))
        return SQLError.serverError(code: Int(code), message: "[\(context)] \(msg)")
    }
}

// MARK: - SQLValue → sqlite3 binding

private extension SQLValue {
    func sqliteBind(stmt: OpaquePointer, at index: Int32) -> Int32 {
        switch self {
        case .null:
            return sqlite3_bind_null(stmt, index)
        case .bool(let v):
            return sqlite3_bind_int(stmt, index, v ? 1 : 0)
        case .int(let v):
            return sqlite3_bind_int64(stmt, index, Int64(v))
        case .int8(let v):
            return sqlite3_bind_int(stmt, index, Int32(v))
        case .int16(let v):
            return sqlite3_bind_int(stmt, index, Int32(v))
        case .int32(let v):
            return sqlite3_bind_int(stmt, index, v)
        case .int64(let v):
            return sqlite3_bind_int64(stmt, index, v)
        case .float(let v):
            return sqlite3_bind_double(stmt, index, Double(v))
        case .double(let v):
            return sqlite3_bind_double(stmt, index, v)
        case .decimal(let v):
            let s = (v as NSDecimalNumber).stringValue
            return s.withCString { ptr in
                sqlite3_bind_text(stmt, index, ptr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
        case .string(let v):
            return v.withCString { ptr in
                sqlite3_bind_text(stmt, index, ptr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
        case .bytes(let v):
            return v.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, index,
                                  raw.baseAddress, Int32(v.count),
                                  SQLITE_TRANSIENT_DESTRUCTOR)
            }
        case .uuid(let v):
            return v.uuidString.withCString { ptr in
                sqlite3_bind_text(stmt, index, ptr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
        case .date(let v):
            let s = ISO8601DateFormatter().string(from: v)
            return s.withCString { ptr in
                sqlite3_bind_text(stmt, index, ptr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
        }
    }
}
