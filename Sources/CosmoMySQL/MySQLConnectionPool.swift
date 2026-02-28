import NIOCore
import NIOPosix
import CosmoSQLCore

// ── MySQLConnectionPool ───────────────────────────────────────────────────────
//
// A thread-safe async connection pool for MySQLConnection.
//
// Usage:
// ```swift
// let pool = MySQLConnectionPool(
//     configuration: .init(host: "localhost", database: "mydb",
//                          username: "root", password: "secret"),
//     maxConnections: 10
// )
//
// let result = try await pool.withConnection { conn in
//     try await conn.query("SELECT ...", [])
// }
//
// await pool.closeAll()
// ```

public actor MySQLConnectionPool {

    // MARK: - Configuration

    public let configuration:  MySQLConnection.Configuration
    public let maxConnections: Int
    public let eventLoopGroup: any EventLoopGroup

    // MARK: - State

    private var idle:     [MySQLConnection] = []
    private var active:   Int = 0
    private var waiters:  [CheckedContinuation<MySQLConnection, any Error>] = []
    private var isClosed: Bool = false

    // MARK: - Init

    public init(
        configuration:  MySQLConnection.Configuration,
        maxConnections: Int = 10,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.configuration  = configuration
        self.maxConnections = max(1, maxConnections)
        self.eventLoopGroup = eventLoopGroup
    }

    // MARK: - Acquire

    public func acquire() async throws -> MySQLConnection {
        guard !isClosed else { throw SQLError.connectionClosed }

        idle.removeAll(where: { !$0.isOpen })

        if let conn = idle.popLast() {
            active += 1
            return conn
        }

        if active < maxConnections {
            active += 1
            return try await openConnection()
        }

        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    // MARK: - Release

    public func release(_ conn: MySQLConnection) {
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

    @discardableResult
    public func withConnection<T: Sendable>(
        _ work: @Sendable (MySQLConnection) async throws -> T
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

    public var idleCount:   Int { idle.count }
    public var activeCount: Int { active }
    public var waiterCount: Int { waiters.count }

    // MARK: - Private helpers

    private func openConnection() async throws -> MySQLConnection {
        try await MySQLConnection.connect(
            configuration: configuration,
            eventLoopGroup: eventLoopGroup
        )
    }

    private func incrementActive() { active += 1 }

    private func drainWaiters(with error: SQLError) {
        let pending = waiters
        waiters = []
        for c in pending { c.resume(throwing: error) }
    }
}
