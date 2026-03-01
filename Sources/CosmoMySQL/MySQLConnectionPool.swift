import Foundation
import NIOCore
import NIOPosix
import NIOSSL
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

    private var idle:           [MySQLConnection] = []
    private var active:         Int = 0
    private var waiters:        [CheckedContinuation<MySQLConnection, any Error>] = []
    private var isClosed:       Bool = false
    private var keepAliveTask:  Task<Void, Never>? = nil
    private var minIdleTarget:  Int = 0
    // Pre-built SSL context shared across all connections — avoids per-connect NIOSSLContext creation.
    private let sslContext:     NIOSSLContext?

    // MARK: - Init

    public init(
        configuration:  MySQLConnection.Configuration,
        maxConnections: Int = 10,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.configuration  = configuration
        self.maxConnections = max(1, maxConnections)
        self.eventLoopGroup = eventLoopGroup
        if configuration.tls != .disable {
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .none
            self.sslContext = try? NIOSSLContext(configuration: tlsConfig)
        } else {
            self.sslContext = nil
        }
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

    // MARK: - Streaming

    /// Stream rows from a query, holding a pool connection for the duration of iteration.
    public func queryStream(_ sql: String, _ binds: [SQLValue] = []) -> AsyncThrowingStream<SQLRow, Error> {
        AsyncThrowingStream { cont in
            let task = Task { [self] in
                do {
                    let conn = try await self.acquire()
                    do {
                        for try await row in conn.queryStream(sql, binds) {
                            cont.yield(row)
                        }
                        self.release(conn)
                        cont.finish()
                    } catch {
                        self.release(conn)
                        cont.finish(throwing: error)
                    }
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Stream JSON objects where each row's first column is a JSON value.
    public func queryJsonStream(_ sql: String, _ binds: [SQLValue] = []) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let task = Task { [self] in
                do {
                    let conn = try await self.acquire()
                    do {
                        for try await data in conn.queryJsonStream(sql, binds) {
                            cont.yield(data)
                        }
                        self.release(conn)
                        cont.finish()
                    } catch {
                        self.release(conn)
                        cont.finish(throwing: error)
                    }
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Stream decoded `Decodable` objects where each row's first column is JSON.
    public func queryJsonStream<T: Decodable & Sendable>(
        _ type: T.Type, _ sql: String, _ binds: [SQLValue] = []
    ) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { cont in
            let task = Task { [self] in
                do {
                    let conn = try await self.acquire()
                    do {
                        for try await obj in conn.queryJsonStream(type, sql, binds) {
                            cont.yield(obj)
                        }
                        self.release(conn)
                        cont.finish()
                    } catch {
                        self.release(conn)
                        cont.finish(throwing: error)
                    }
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
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

    public var idleCount:   Int { idle.count }
    public var activeCount: Int { active }
    public var waiterCount: Int { waiters.count }

    // MARK: - Warm-up / keep-alive

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
        var healthy: [MySQLConnection] = []
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

    private func openConnection() async throws -> MySQLConnection {
        try await MySQLConnection.connect(
            configuration: configuration,
            eventLoopGroup: eventLoopGroup,
            sslContext: sslContext
        )
    }

    private func incrementActive() { active += 1 }

    private func drainWaiters(with error: SQLError) {
        let pending = waiters
        waiters = []
        for c in pending { c.resume(throwing: error) }
    }
}
