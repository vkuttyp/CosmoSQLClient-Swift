import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import CosmoSQLCore

public actor MySQLConnectionPool: SQLDatabase {
    public let configuration:  MySQLConnection.Configuration
    public let maxConnections: Int
    public let eventLoopGroup: any EventLoopGroup
    private var idle: [MySQLConnection] = []
    private var active: Int = 0
    private var waiters: [CheckedContinuation<MySQLConnection, any Error>] = []
    private var isClosed: Bool = false
    private let sslContext: NIOSSLContext?

    public nonisolated var advanced: any AdvancedSQLDatabase { MySQLConnectionPoolAdvanced(pool: self) }

    public init(configuration: MySQLConnection.Configuration, maxConnections: Int = 10, eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.configuration = configuration; self.maxConnections = max(1, maxConnections); self.eventLoopGroup = eventLoopGroup
        if configuration.tls != .disable {
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .none
            self.sslContext = try? NIOSSLContext(configuration: tlsConfig)
        } else { self.sslContext = nil }
    }

    public func acquire() async throws -> MySQLConnection {
        guard !isClosed else { throw SQLError.connectionClosed }
        idle.removeAll(where: { c in !c.isOpen })
        if let conn = idle.popLast() { active += 1; return conn }
        if active < maxConnections { active += 1; return try await openConnection() }
        return try await withCheckedThrowingContinuation { cont in waiters.append(cont) }
    }

    public func release(_ conn: MySQLConnection) {
        active = max(0, active - 1)
        if isClosed { Task { try? await conn.close() }; return }
        if !waiters.isEmpty {
            let continuation = waiters.removeFirst()
            active += 1; continuation.resume(returning: conn)
            return
        }
        if conn.isOpen { idle.append(conn) }
    }

    public func query(_ sql: String, _ binds: [SQLValue]) async throws -> [SQLRow] {
        return try await withConnection { c in try await c.query(sql, binds) }
    }

    public func execute(_ sql: String, _ binds: [SQLValue]) async throws -> Int {
        return try await withConnection { c in try await c.execute(sql, binds) }
    }

    public func close() async throws {
        isClosed = true
        for c in idle { try? await c.close() }; idle = []
        for w in waiters { w.resume(throwing: SQLError.connectionClosed) }; waiters = []
    }

    public func closeAll() async { try? await close() }
    public var idleCount: Int { idle.count }
    public var activeCount: Int { active }
    public var waiterCount: Int { waiters.count }

    @discardableResult
    public func withConnection<T: Sendable>(_ work: @Sendable (MySQLConnection) async throws -> T) async throws -> T {
        let conn = try await acquire()
        do { let res = try await work(conn); release(conn); return res }
        catch { release(conn); throw error }
    }

    private func openConnection() async throws -> MySQLConnection {
        try await MySQLConnection.connect(configuration: configuration, eventLoopGroup: eventLoopGroup, sslContext: sslContext)
    }
}

struct MySQLConnectionPoolAdvanced: AdvancedSQLDatabase {
    let pool: MySQLConnectionPool
    func queryStream(_ sql: String, _ binds: [SQLValue]) -> AsyncThrowingStream<SQLRow, any Error> {
        AsyncThrowingStream { cont in
            Task {
                do {
                    let conn = try await pool.acquire()
                    do {
                        for try await row in conn.advanced.queryStream(sql, binds) { cont.yield(row) }
                        await pool.release(conn); cont.finish()
                    } catch { await pool.release(conn); cont.finish(throwing: error) }
                } catch { cont.finish(throwing: error) }
            }
        }
    }
    func queryJsonStream(_ sql: String, _ binds: [SQLValue]) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { cont in
            Task {
                do {
                    let conn = try await pool.acquire()
                    do {
                        for try await data in conn.advanced.queryJsonStream(sql, binds) { cont.yield(data) }
                        await pool.release(conn); cont.finish()
                    } catch { await pool.release(conn); cont.finish(throwing: error) }
                } catch { cont.finish(throwing: error) }
            }
        }
    }
}
