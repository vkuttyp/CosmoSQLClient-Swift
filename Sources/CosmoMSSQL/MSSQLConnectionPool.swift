import Foundation
import NIOCore
import NIOPosix
import CosmoSQLCore

// ── MSSQLConnectionPool ───────────────────────────────────────────────────────
//
// A thread-safe async connection pool for MSSQLConnection.
//
// Usage:
// ```swift
// let pool = MSSQLConnectionPool(
//     configuration: .init(host: "localhost", database: "mydb",
//                          username: "sa", password: "secret"),
//     maxConnections: 10
// )
//
// // Acquire / release manually
// let conn = try await pool.acquire()
// defer { await pool.release(conn) }
// let rows = try await conn.query("SELECT ...", [])
//
// // Preferred: auto-release via withConnection
// let rows = try await pool.withConnection { conn in
//     try await conn.query("SELECT ...", [])
// }
//
// // On shutdown:
// await pool.closeAll()
// ```

public actor MSSQLConnectionPool {

    // MARK: - Configuration

    public let configuration:  MSSQLConnection.Configuration
    public let maxConnections: Int
    public let eventLoopGroup: any EventLoopGroup

    // MARK: - State

    private var idle:           [MSSQLConnection] = []
    private var active:         Int = 0
    private var waiters:        [CheckedContinuation<MSSQLConnection, any Error>] = []
    private var isClosed:       Bool = false
    private var keepAliveTask:  Task<Void, Never>? = nil
    private var minIdleTarget:  Int = 0

    // MARK: - Init / deinit

    public init(
        configuration:  MSSQLConnection.Configuration,
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
    public func acquire() async throws -> MSSQLConnection {
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
    /// If the connection is no longer open, it is discarded (a new one will be opened later).
    public func release(_ conn: MSSQLConnection) {
        active = max(0, active - 1)

        guard !isClosed else {
            Task { try? await conn.close() }
            // Fail all waiters
            drainWaiters(with: .connectionClosed)
            return
        }

        if !waiters.isEmpty {
            let continuation = waiters.removeFirst()
            if conn.isOpen {
                active += 1
                continuation.resume(returning: conn)
            } else {
                // Connection died — open a fresh one for the waiter
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
        // If closed, just let it be garbage collected
    }

    // MARK: - withConnection helper

    /// Acquire a connection, run `work`, then release it automatically.
    @discardableResult
    public func withConnection<T: Sendable>(
        _ work: @Sendable (MSSQLConnection) async throws -> T
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
    /// After calling this, `acquire()` will throw ``SQLError/connectionClosed``.
    public func closeAll() async {
        isClosed = true
        keepAliveTask?.cancel()
        keepAliveTask = nil
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

    // MARK: - Warm-up / keep-alive

    /// Pre-open `minIdle` connections so first requests don't pay connection latency.
    /// Starts a background keep-alive loop that pings idle connections every `pingInterval`
    /// seconds and replaces any that have gone stale.
    public func warmUp(minIdle: Int = 2, pingInterval: TimeInterval = 30) async {
        guard !isClosed else { return }
        minIdleTarget = minIdle
        let needed = max(0, minIdle - (idle.count + active))
        for _ in 0..<needed {
            guard idle.count + active < maxConnections, !isClosed else { break }
            do { idle.append(try await openConnection()) } catch { break }
        }
        keepAliveTask?.cancel()
        keepAliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pingInterval))
                guard !Task.isCancelled else { break }
                await self.pingIdleConnections()
            }
        }
    }

    private func pingIdleConnections() async {
        guard !isClosed else { return }
        idle.removeAll(where: { !$0.isOpen })
        var healthy: [MSSQLConnection] = []
        for conn in idle {
            do { _ = try await conn.query("SELECT 1", []); healthy.append(conn) }
            catch { try? await conn.close() }
        }
        idle = healthy
        let toOpen = max(0, minIdleTarget - idle.count)
        for _ in 0..<toOpen {
            guard idle.count + active < maxConnections, !isClosed else { break }
            do { idle.append(try await openConnection()) } catch { break }
        }
    }

    // MARK: - Private helpers

    private func openConnection() async throws -> MSSQLConnection {
        try await MSSQLConnection.connect(
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



