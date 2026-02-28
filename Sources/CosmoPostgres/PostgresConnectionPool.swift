import NIOCore
import NIOPosix
import CosmoSQLCore

// ── PostgresConnectionPool ────────────────────────────────────────────────────
//
// A thread-safe async connection pool for PostgresConnection.
//
// Usage:
// ```swift
// let pool = PostgresConnectionPool(
//     configuration: .init(host: "localhost", database: "mydb",
//                          username: "pguser", password: "secret"),
//     maxConnections: 10
// )
//
// // Acquire / release manually
// let conn = try await pool.acquire()
// defer { await pool.release(conn) }
// let rows = try await conn.query("SELECT ...", [])
//
// // Preferred: auto-release via withConnection
// let result = try await pool.withConnection { conn in
//     try await conn.query("SELECT ...", [])
// }
//
// // On shutdown:
// await pool.closeAll()
// ```

public actor PostgresConnectionPool {

    // MARK: - Configuration

    public let configuration:  PostgresConnection.Configuration
    public let maxConnections: Int
    public let eventLoopGroup: any EventLoopGroup

    // MARK: - State

    private var idle:     [PostgresConnection] = []
    private var active:   Int = 0
    private var waiters:  [CheckedContinuation<PostgresConnection, any Error>] = []
    private var isClosed: Bool = false

    // MARK: - Init

    public init(
        configuration:  PostgresConnection.Configuration,
        maxConnections: Int = 10,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.configuration  = configuration
        self.maxConnections = max(1, maxConnections)
        self.eventLoopGroup = eventLoopGroup
    }

    // MARK: - Acquire

    /// Acquire a connection from the pool.
    /// Reuses an idle connection if available, opens a new one if under the limit,
    /// or waits until one is released.
    public func acquire() async throws -> PostgresConnection {
        guard !isClosed else { throw SQLError.connectionClosed }

        // Drain stale/closed idle connections first
        idle.removeAll(where: { !$0.isOpen })

        if let conn = idle.popLast() {
            active += 1
            return conn
        }

        if active < maxConnections {
            active += 1
            return try await openConnection()
        }

        // Pool is full — wait for a release
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    // MARK: - Release

    /// Return a connection to the pool.
    /// If there are waiters, the connection is handed directly to the next waiter.
    public func release(_ conn: PostgresConnection) {
        active = max(0, active - 1)

        guard !isClosed else {
            Task { try? await conn.close() }
            drainWaiters(with: .connectionClosed)
            return
        }

        if !waiters.isEmpty {
            let continuation = waiters.removeFirst()
            if conn.isOpen {
                active += 1
                continuation.resume(returning: conn)
            } else {
                Task {
                    do {
                        let fresh = try await self.openConnection()
                        self.incrementActive()
                        continuation.resume(returning: fresh)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            return
        }

        if conn.isOpen {
            idle.append(conn)
        }
    }

    // MARK: - withConnection helper

    /// Acquire a connection, run `work`, then release it automatically.
    @discardableResult
    public func withConnection<T: Sendable>(
        _ work: @Sendable (PostgresConnection) async throws -> T
    ) async throws -> T {
        let conn = try await acquire()
        do {
            let result = try await work(conn)
            release(conn)
            return result
        } catch {
            release(conn)
            throw error
        }
    }

    // MARK: - Shutdown

    /// Close all idle connections and fail pending waiters.
    public func closeAll() async {
        isClosed = true
        drainWaiters(with: .connectionClosed)
        let toClose = idle
        idle = []
        for conn in toClose {
            try? await conn.close()
        }
    }

    // MARK: - Pool stats

    /// Number of idle connections ready for immediate use.
    public var idleCount:  Int { idle.count }
    /// Number of connections currently checked out.
    public var activeCount: Int { active }
    /// Number of callers waiting for a connection.
    public var waiterCount: Int { waiters.count }

    // MARK: - Private helpers

    private func openConnection() async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            configuration: configuration,
            eventLoopGroup: eventLoopGroup
        )
    }

    private func incrementActive() {
        active += 1
    }

    private func drainWaiters(with error: SQLError) {
        let pending = waiters
        waiters = []
        for c in pending { c.resume(throwing: error) }
    }
}
