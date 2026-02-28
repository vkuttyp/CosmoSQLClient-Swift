import NIOCore
import NIOPosix
import CosmoSQLCore

// ── SQLiteConnectionPool ──────────────────────────────────────────────────────
//
// A thread-safe async connection pool for SQLiteConnection.
//
// Note: For in-memory databases (.memory), all connections share separate
// in-memory stores. Use a single shared connection or named shared-memory
// databases if you need to share data across pool connections.
//
// Usage:
// ```swift
// let pool = SQLiteConnectionPool(
//     configuration: .init(storage: .file(path: "/var/db/app.sqlite")),
//     maxConnections: 5
// )
//
// let rows = try await pool.withConnection { conn in
//     try await conn.query("SELECT * FROM users", [])
// }
//
// await pool.closeAll()
// ```

public actor SQLiteConnectionPool {

    // MARK: - Configuration

    public let configuration:  SQLiteConnection.Configuration
    public let maxConnections: Int
    public let threadPool:     NIOThreadPool
    public let eventLoopGroup: any EventLoopGroup

    // MARK: - State

    private var idle:     [SQLiteConnection] = []
    private var active:   Int = 0
    private var waiters:  [CheckedContinuation<SQLiteConnection, any Error>] = []
    private var isClosed: Bool = false

    // MARK: - Computed stats

    public var idleCount:   Int { idle.count }
    public var activeCount: Int { active }

    // MARK: - Init

    public init(
        configuration:  SQLiteConnection.Configuration,
        maxConnections: Int            = 5,
        threadPool:     NIOThreadPool  = .singleton,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.configuration  = configuration
        self.maxConnections = max(1, maxConnections)
        self.threadPool     = threadPool
        self.eventLoopGroup = eventLoopGroup
    }

    // MARK: - Acquire

    public func acquire() async throws -> SQLiteConnection {
        guard !isClosed else { throw SQLError.connectionClosed }

        // Prune dead connections
        idle.removeAll(where: { !$0.isOpen })

        if let conn = idle.popLast() {
            active += 1
            return conn
        }

        if active < maxConnections {
            active += 1
            return try openConnection()
        }

        // Wait for a connection to become available
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    // MARK: - Release

    public func release(_ conn: SQLiteConnection) {
        active = max(0, active - 1)

        guard !isClosed else {
            Task { try? await conn.close() }
            drainWaiters(with: .connectionClosed)
            return
        }

        if conn.isOpen, !waiters.isEmpty {
            active += 1
            waiters.removeFirst().resume(returning: conn)
            return
        }

        if conn.isOpen {
            idle.append(conn)
        }

        if !waiters.isEmpty {
            if let newConn = try? openConnection() {
                active += 1
                waiters.removeFirst().resume(returning: newConn)
            }
        }
    }

    // MARK: - withConnection

    public func withConnection<T: Sendable>(
        _ body: @Sendable (SQLiteConnection) async throws -> T
    ) async throws -> T {
        let conn = try await acquire()
        defer { release(conn) }
        return try await body(conn)
    }

    // MARK: - Close all

    public func closeAll() async {
        isClosed = true
        drainWaiters(with: .connectionClosed)
        let toClose = idle
        idle = []
        for conn in toClose {
            try? await conn.close()
        }
    }

    // MARK: - Private

    private func openConnection() throws -> SQLiteConnection {
        try SQLiteConnection.open(
            configuration:  configuration,
            threadPool:     threadPool,
            eventLoopGroup: eventLoopGroup
        )
    }

    private func drainWaiters(with error: SQLError) {
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
        waiters = []
    }
}
