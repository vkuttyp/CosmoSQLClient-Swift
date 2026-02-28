@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL
import Logging
import CosmoSQLCore
import Foundation

// ── MySQLConnection ───────────────────────────────────────────────────────────
//
// A single async/await connection to a MySQL / MariaDB server.
// Implements the MySQL Client/Server Protocol (v10) natively over swift-nio.
//
// Usage:
// ```swift
// let config = MySQLConnection.Configuration(host: "localhost", port: 3306,
//                                             database: "mydb",
//                                             username: "root", password: "secret")
// let conn = try await MySQLConnection.connect(configuration: config)
// defer { try? await conn.close() }
//
// let rows = try await conn.query("SELECT id, name FROM users WHERE active = ?", [.bool(true)])
// ```

public final class MySQLConnection: SQLDatabase, @unchecked Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var host:     String
        public var port:     Int    = 3306
        public var database: String
        public var username: String
        public var password: String
        public var tls:      SQLTLSConfiguration = .prefer
        public var logger:   Logger = Logger(label: "MySQLNio")
        /// Timeout for the TCP + TLS + handshake (seconds). nil = no limit.
        public var connectTimeout: TimeInterval? = 30
        /// Per-query timeout (seconds). nil = no limit.
        /// Applied via `SET SESSION max_execution_time=N` before the query.
        public var queryTimeout:   TimeInterval? = nil

        public init(host: String, port: Int = 3306,
                    database: String, username: String, password: String,
                    tls: SQLTLSConfiguration = .prefer,
                    connectTimeout: TimeInterval? = 30,
                    queryTimeout:   TimeInterval? = nil) {
            self.host           = host
            self.port           = port
            self.database       = database
            self.username       = username
            self.password       = password
            self.tls            = tls
            self.connectTimeout = connectTimeout
            self.queryTimeout   = queryTimeout
        }
    }

    // MARK: - State

    private let channel:      any Channel
    let config:               Configuration  // internal — used by backup extension
    private let logger:       Logger
    private var capabilities: MySQLCapabilities = .clientDefault
    private var sequenceID:   UInt8 = 0
    private var isClosed:     Bool  = false
    private var msgReader:    MessageReader?   // AsyncThrowingStream-based; no eventLoop hop per read
    private var inTransaction: Bool = false

    // Called for each MySQL warning/note message received from the server.
    public var onWarning: (@Sendable (String) -> Void)?

    // MARK: - Connect

    public static func connect(
        configuration: Configuration,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        sslContext: NIOSSLContext? = nil   // supply pre-built context from pool to avoid per-connect creation cost
    ) async throws -> MySQLConnection {
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)

        let channel = try await bootstrap.connect(host: configuration.host,
                                                   port: configuration.port).get()
        let conn = MySQLConnection(channel: channel, config: configuration,
                                   logger: configuration.logger)
        try await conn.handshake(sslContext: sslContext)
        return conn
    }

    private init(channel: any Channel, config: Configuration, logger: Logger) {
        self.channel = channel
        self.config  = config
        self.logger  = logger
    }

    // MARK: - Handshake

    private func handshake(sslContext: NIOSSLContext? = nil) async throws {
        let bridge = AsyncStreamBridge()
        // Swift 6: ByteToMessageHandler has Sendable marked unavailable (event-loop-bound).
        let bridgeBox = _UnsafeSendable(bridge)
        let frameBox  = _UnsafeSendable(ByteToMessageHandler(MySQLFramingHandler()))
        try await channel.eventLoop.submit {
            try self.channel.pipeline.syncOperations.addHandlers([frameBox.value, bridgeBox.value])
        }.get()
        msgReader = MessageReader(bridge)

        // 1. Receive server handshake
        var serverHSPacket = try await receivePacket()
        let serverHS = try MySQLHandshakeV10.decode(from: &serverHSPacket)
        logger.debug("MySQL server v\(serverHS.serverVersion), auth=\(serverHS.authPluginName)")

        let useTLS: Bool
        switch config.tls {
        case .require: useTLS = true
        case .prefer:  useTLS = serverHS.capabilities.contains(.ssl)
        case .disable: useTLS = false
        }

        if useTLS && serverHS.capabilities.contains(.ssl) {
            try await sendSSLRequest(serverCapabilities: serverHS.capabilities)
            try await upgradeTLS(sslContext: sslContext)
            logger.debug("MySQL TLS established")
        }

        // 2. Send HandshakeResponse41
        try await sendHandshakeResponse(serverHS: serverHS)

        // 3. Read auth result
        try await readAuthResult(authPlugin: serverHS.authPluginName,
                                  challenge: serverHS.authPluginData)
        logger.debug("MySQL logged in as \(config.username)")
    }

    private func sendSSLRequest(serverCapabilities: MySQLCapabilities) async throws {
        var caps = capabilities
        caps.insert(.ssl)
        caps.formIntersection(serverCapabilities)

        var body = channel.allocator.buffer(capacity: 36)
        body.writeInteger(caps.rawValue, endianness: .little)
        body.writeInteger(UInt32(16_777_216), endianness: .little)  // max packet size
        body.writeInteger(UInt8(0xFF))                               // charset (utf8mb4)
        body.writeBytes([UInt8](repeating: 0, count: 23))            // reserved

        sequenceID = 1
        let pkt = ByteBuffer.mysqlPacket(sequenceID: sequenceID,
                                          body: body,
                                          allocator: channel.allocator)
        send(pkt)
    }

    // sslContext: reuse the pool-level NIOSSLContext instead of constructing one per connection.
    private func upgradeTLS(sslContext: NIOSSLContext? = nil) async throws {
        let ctx: NIOSSLContext
        if let provided = sslContext {
            ctx = provided
        } else {
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .none
            ctx = try NIOSSLContext(configuration: tlsConfig)
        }
        // SNI requires a hostname, not an IP address
        let sni = config.host.first?.isNumber == false ? config.host : nil
        let sslHandler = try NIOSSLClientHandler(context: ctx, serverHostname: sni)
        // Swift 6: NIOSSLHandler has Sendable marked unavailable (event-loop-bound).
        let sslBox = _UnsafeSendable(sslHandler)
        try await channel.eventLoop.submit {
            try self.channel.pipeline.syncOperations.addHandler(sslBox.value, position: .first)
        }.get()
    }

    private func sendHandshakeResponse(serverHS: MySQLHandshakeV10) async throws {
        let authResponse: [UInt8]
        switch serverHS.authPluginName {
        case "mysql_native_password":
            authResponse = mysqlNativePassword(password: config.password,
                                               challenge: serverHS.authPluginData)
        case "caching_sha2_password":
            // SHA256-scrambled password for fast-auth path
            authResponse = mysqlCachingSHA2Password(password: config.password,
                                                     nonce: serverHS.authPluginData)
        default:
            // Fallback: send cleartext password (works over TLS for unknown plugins)
            authResponse = Array(config.password.utf8) + [0]
        }

        var caps = capabilities
        caps.formIntersection(serverHS.capabilities)
        capabilities = caps

        var body = channel.allocator.buffer(capacity: 256)
        body.writeInteger(caps.rawValue, endianness: .little)
        body.writeInteger(UInt32(16_777_216), endianness: .little)
        body.writeInteger(UInt8(0xFF))           // charset utf8mb4
        body.writeBytes([UInt8](repeating: 0, count: 23))
        body.writeNullTerminatedString(config.username)
        body.writeLengthEncodedInt(UInt64(authResponse.count))
        body.writeBytes(authResponse)
        body.writeNullTerminatedString(config.database)
        body.writeNullTerminatedString(serverHS.authPluginName)
        // CLIENT_CONNECT_ATTRS: send 0-length attrs if negotiated
        if caps.contains(.connectAttrs) {
            body.writeLengthEncodedInt(0)
        }

        sequenceID += 1
        let pkt = ByteBuffer.mysqlPacket(sequenceID: sequenceID,
                                          body: body,
                                          allocator: channel.allocator)
        send(pkt)
    }

    private func readAuthResult(authPlugin: String, challenge: [UInt8]) async throws {
        var packet = try await receivePacket()
        // Extract server's sequence ID from the 4-byte MySQL packet header (byte 3)
        let serverSeqID = packet.getInteger(at: packet.readerIndex + 3, as: UInt8.self) ?? sequenceID
        sequenceID = serverSeqID  // our next send = serverSeqID + 1

        let response = try MySQLResponse.decode(packet: &packet, capabilities: capabilities)
        switch response {
        case .ok:
            return
        case .err(let code, _, let message):
            throw SQLError.authenticationFailed("[\(code)] \(message)")
        case .data(var raw):
            // caching_sha2_password sends AuthMoreData (indicator=0x01)
            raw.moveReaderIndex(forwardBy: 4)  // skip MySQL packet header
            guard let indicator: UInt8 = raw.readInteger(), indicator == 0x01,
                  let subtype: UInt8 = raw.readInteger() else {
                throw SQLError.protocolError("Unexpected auth data packet")
            }
            switch subtype {
            case 0x03:
                // Fast auth success — cached entry matched; next packet is OK
                try await readAuthResult(authPlugin: authPlugin, challenge: challenge)
            case 0x04:
                // Full auth required: send cleartext password (works over TLS)
                var body = channel.allocator.buffer(capacity: config.password.utf8.count + 1)
                body.writeBytes(Array(config.password.utf8) + [0])
                sequenceID += 1
                let pkt = ByteBuffer.mysqlPacket(sequenceID: sequenceID, body: body,
                                                  allocator: channel.allocator)
                send(pkt)
                try await readAuthResult(authPlugin: authPlugin, challenge: challenge)
            case 0x02:
                // Server requesting RSA public key (non-TLS path) — not implemented
                throw SQLError.unsupported("caching_sha2_password RSA key exchange (use TLS)")
            default:
                throw SQLError.protocolError("Unknown caching_sha2 subtype: \(subtype)")
            }
        default:
            throw SQLError.protocolError("Unexpected auth response")
        }
    }

    // MARK: - SQLDatabase

    public func query(_ sql: String, _ binds: [SQLValue]) async throws -> [SQLRow] {
        guard !isClosed else { throw SQLError.connectionClosed }
        let rendered = renderQuery(sql, binds: binds)
        logger.debug("MySQL query: \(rendered)")
        try await sendQuery(rendered)
        return try await readResultSet()
    }

    public func execute(_ sql: String, _ binds: [SQLValue]) async throws -> Int {
        guard !isClosed else { throw SQLError.connectionClosed }
        let rendered = renderQuery(sql, binds: binds)
        logger.debug("MySQL execute: \(rendered)")
        try await sendQuery(rendered)
        var packet = try await receivePacket()
        let resp = try MySQLResponse.decode(packet: &packet, capabilities: capabilities)
        switch resp {
        case .ok(let affected, _, _, _):
            return Int(affected)
        case .err(let code, _, let message):
            throw SQLError.serverError(code: Int(code), message: message)
        default:
            return 0
        }
    }

    /// Execute one or more SQL statements separated by `;` and return each result set.
    ///
    /// Note: MySQL requires the `CLIENT_MULTI_STATEMENTS` capability for this to work.
    /// The driver negotiates this automatically during handshake.
    public func queryMulti(_ sql: String, _ binds: [SQLValue] = []) async throws -> [[SQLRow]] {
        guard !isClosed else { throw SQLError.connectionClosed }
        let rendered = renderQuery(sql, binds: binds)
        logger.debug("MySQL queryMulti: \(rendered)")
        try await sendQuery(rendered)

        var allSets: [[SQLRow]] = []
        // MySQL returns one result set at a time; the OK/EOF has a "more results" flag
        while true {
            let resultSet = try await readResultSetMulti()
            allSets.append(resultSet.rows)
            if !resultSet.hasMore { break }
        }
        return allSets
    }

    // MARK: - Transaction API

    /// Begin an explicit transaction.
    public func beginTransaction() async throws {
        _ = try await execute("START TRANSACTION", [])
        inTransaction = true
    }

    /// Commit the current transaction.
    public func commitTransaction() async throws {
        _ = try await execute("COMMIT", [])
        inTransaction = false
    }

    /// Roll back the current transaction.
    public func rollbackTransaction() async throws {
        _ = try await execute("ROLLBACK", [])
        inTransaction = false
    }

    /// Execute `work` inside a transaction, committing on success or rolling back on error.
    @discardableResult
    public func withTransaction<T: Sendable>(
        _ work: @Sendable (MySQLConnection) async throws -> T
    ) async throws -> T {
        try await beginTransaction()
        do {
            let result = try await work(self)
            try await commitTransaction()
            return result
        } catch {
            try? await rollbackTransaction()
            throw error
        }
    }

    // MARK: - Reachability

    /// `true` while the underlying channel is open.
    public var isOpen: Bool { !isClosed }

    public func close() async throws {
        guard !isClosed else { return }
        isClosed = true
        // Send COM_QUIT (0x01)
        var body = channel.allocator.buffer(capacity: 1)
        body.writeInteger(UInt8(0x01))
        sequenceID = 0
        let pkt = ByteBuffer.mysqlPacket(sequenceID: sequenceID, body: body,
                                          allocator: channel.allocator)
        send(pkt)
        try await channel.close().get()
    }

    // MARK: - COM_QUERY

    private func sendQuery(_ sql: String) async throws {
        var body = channel.allocator.buffer(capacity: 1 + sql.utf8.count)
        body.writeInteger(UInt8(0x03))   // COM_QUERY
        body.writeString(sql)
        sequenceID = 0
        let pkt = ByteBuffer.mysqlPacket(sequenceID: sequenceID, body: body,
                                          allocator: channel.allocator)
        send(pkt)
    }

    // MARK: - Result set reading

    private func readResultSet() async throws -> [SQLRow] {
        // First packet: column count OR OK/ERR
        var firstPacket = try await receivePacket()
        let firstResponse = try MySQLResponse.decode(packet: &firstPacket, capabilities: capabilities)

        switch firstResponse {
        case .ok:
            return []
        case .err(let code, _, let message):
            throw SQLError.serverError(code: Int(code), message: message)
        case .data(var countPacket):
            countPacket.moveReaderIndex(forwardBy: 4)  // skip header
            let columnCount = countPacket.readLengthEncodedInt() ?? 0
            return try await readColumns(count: Int(columnCount))
        default:
            return []
        }
    }

    private func readColumns(count: Int) async throws -> [SQLRow] {
        var columnDefs: [MySQLColumnDef] = []
        for _ in 0..<count {
            var pkt = try await receivePacket()
            let col = try MySQLColumnDef.decode(packet: &pkt)
            columnDefs.append(col)
        }

        // Read EOF or OK packet (deprecateEOF changes this)
        if !capabilities.contains(.deprecateEOF) {
            _ = try await receivePacket()  // EOF packet
        }

        // Read rows — inspect the first payload byte directly to avoid 0xFB ambiguity
        // (0xFB is both a NULL indicator in text rows and a LOCAL INFILE indicator)
        let sqlCols = columnDefs.map {
            SQLColumn(name: $0.name, table: $0.table, dataTypeID: UInt32($0.columnType))
        }
        var rows: [SQLRow] = []
        while true {
            var pkt = try await receivePacket()
            // Skip 4-byte packet header (3-byte length + 1-byte sequence)
            guard pkt.readableBytes > 4 else { break }
            let firstByte = pkt.getInteger(at: pkt.readerIndex + 4, as: UInt8.self)

            // 0xFF = ERR
            if firstByte == 0xFF {
                pkt.moveReaderIndex(forwardBy: 5)  // header + indicator
                let code = pkt.readInteger(endianness: .little) as UInt16? ?? 0
                if let marker: UInt8 = pkt.readInteger(), marker == UInt8(ascii: "#") {
                    pkt.moveReaderIndex(forwardBy: 5)  // skip SQL state
                }
                let message = pkt.readString(length: pkt.readableBytes) ?? ""
                throw SQLError.serverError(code: Int(code), message: message)
            }
            // 0xFE (small packet) = EOF  |  0x00 with deprecateEOF = OK
            if (firstByte == 0xFE && pkt.readableBytes < 13) ||
               (firstByte == 0x00 && capabilities.contains(.deprecateEOF)) {
                return rows
            }

            // Data row
            pkt.moveReaderIndex(forwardBy: 4)  // skip header
            var values: [SQLValue] = []
            for col in columnDefs {
                // 0xFB = NULL indicator in text result protocol
                if let b: UInt8 = pkt.getInteger(at: pkt.readerIndex), b == 0xFB {
                    pkt.moveReaderIndex(forwardBy: 1)
                    values.append(.null)
                } else {
                    let text = pkt.readLengthEncodedString()
                    let isUnsigned = (col.flags & 0x0020) != 0
                    values.append(mysqlDecode(columnType: col.columnType,
                                              isUnsigned: isUnsigned,
                                              text: text))
                }
            }
            rows.append(SQLRow(columns: sqlCols, values: values))
        }
        return rows
    }

    // MARK: - Wire helpers

    private struct ResultSetChunk {
        let rows: [SQLRow]
        let hasMore: Bool
    }

    // Reads one result set and returns whether more are pending (SERVER_MORE_RESULTS_EXISTS flag)
    private func readResultSetMulti() async throws -> ResultSetChunk {
        var firstPacket = try await receivePacket()
        let firstResponse = try MySQLResponse.decode(packet: &firstPacket, capabilities: capabilities)
        switch firstResponse {
        case .ok(_, _, let status, _):
            return ResultSetChunk(rows: [], hasMore: status.contains(.moreResultsExist))
        case .err(let code, _, let message):
            throw SQLError.serverError(code: Int(code), message: message)
        case .data(var countPacket):
            countPacket.moveReaderIndex(forwardBy: 4)
            let columnCount = countPacket.readLengthEncodedInt() ?? 0
            return try await readColumnsMulti(count: Int(columnCount))
        default:
            return ResultSetChunk(rows: [], hasMore: false)
        }
    }

    private func readColumnsMulti(count: Int) async throws -> ResultSetChunk {
        var columnDefs: [MySQLColumnDef] = []
        for _ in 0..<count {
            var pkt = try await receivePacket()
            let col = try MySQLColumnDef.decode(packet: &pkt)
            columnDefs.append(col)
        }
        if !capabilities.contains(.deprecateEOF) {
            _ = try await receivePacket()
        }
        let sqlCols = columnDefs.map {
            SQLColumn(name: $0.name, table: $0.table, dataTypeID: UInt32($0.columnType))
        }
        var rows: [SQLRow] = []
        while true {
            var pkt = try await receivePacket()
            guard pkt.readableBytes > 4 else { break }
            let firstByte = pkt.getInteger(at: pkt.readerIndex + 4, as: UInt8.self)

            if firstByte == 0xFF {
                pkt.moveReaderIndex(forwardBy: 5)
                let code = pkt.readInteger(endianness: .little) as UInt16? ?? 0
                if let marker: UInt8 = pkt.readInteger(), marker == UInt8(ascii: "#") {
                    pkt.moveReaderIndex(forwardBy: 5)
                }
                let message = pkt.readString(length: pkt.readableBytes) ?? ""
                throw SQLError.serverError(code: Int(code), message: message)
            }
            if firstByte == 0xFE && pkt.readableBytes < 13 {
                // EOF — check hasMore
                pkt.moveReaderIndex(forwardBy: 5)  // header + indicator
                _ = pkt.readInteger(endianness: .little) as UInt16?  // warnings
                let statusRaw = pkt.readInteger(endianness: .little) as UInt16? ?? 0
                let status = MySQLServerStatus(rawValue: statusRaw)
                return ResultSetChunk(rows: rows, hasMore: status.contains(.moreResultsExist))
            }
            if firstByte == 0x00 && capabilities.contains(.deprecateEOF) {
                // OK (deprecateEOF style)
                pkt.moveReaderIndex(forwardBy: 5)
                _ = pkt.readLengthEncodedInt()  // affected rows
                _ = pkt.readLengthEncodedInt()  // last insert id
                let statusRaw = pkt.readInteger(endianness: .little) as UInt16? ?? 0
                let status = MySQLServerStatus(rawValue: statusRaw)
                return ResultSetChunk(rows: rows, hasMore: status.contains(.moreResultsExist))
            }

            // Data row
            pkt.moveReaderIndex(forwardBy: 4)
            var values: [SQLValue] = []
            for col in columnDefs {
                if let b: UInt8 = pkt.getInteger(at: pkt.readerIndex), b == 0xFB {
                    pkt.moveReaderIndex(forwardBy: 1)
                    values.append(.null)
                } else {
                    let text = pkt.readLengthEncodedString()
                    let isUnsigned = (col.flags & 0x0020) != 0
                    values.append(mysqlDecode(columnType: col.columnType,
                                               isUnsigned: isUnsigned, text: text))
                }
            }
            rows.append(SQLRow(columns: sqlCols, values: values))
        }
        return ResultSetChunk(rows: rows, hasMore: false)
    }

    private func send(_ buffer: ByteBuffer) {
        channel.writeAndFlush(buffer, promise: nil)
    }

    private func receivePacket() async throws -> ByteBuffer {
        guard let reader = msgReader, let buf = try await reader.next() else {
            throw SQLError.connectionClosed
        }
        return buf
    }

    // MARK: - Bind substitution

    private func renderQuery(_ sql: String, binds: [SQLValue]) -> String {
        // Replace @p1, @p2 ... style placeholders (1-indexed, replaced in reverse order to avoid @p1 matching @p10)
        var rendered = sql
        for idx in stride(from: binds.count, through: 1, by: -1) {
            rendered = rendered.replacingOccurrences(of: "@p\(idx)", with: binds[idx - 1].mysqlLiteral)
        }
        // Replace ? style placeholders
        var result  = ""
        var bindIdx = 0
        for char in rendered {
            if char == "?" && bindIdx < binds.count {
                result += binds[bindIdx].mysqlLiteral
                bindIdx += 1
            } else {
                result.append(char)
            }
        }
        return result
    }
}

// Shared ISO8601 formatter — avoids allocating one per date value in mysqlLiteral.
private nonisolated(unsafe) let _mysqlDateFmt: ISO8601DateFormatter = ISO8601DateFormatter()

// MARK: - SQLValue → MySQL literal

private extension SQLValue {
    var mysqlLiteral: String {
        switch self {
        case .null:           return "NULL"
        case .bool(let v):   return v ? "1" : "0"
        case .int(let v):    return "\(v)"
        case .int8(let v):   return "\(v)"
        case .int16(let v):  return "\(v)"
        case .int32(let v):  return "\(v)"
        case .int64(let v):  return "\(v)"
        case .float(let v):  return "\(v)"
        case .double(let v): return "\(v)"
        case .decimal(let v): return (v as NSDecimalNumber).stringValue
        case .string(let v):
            // Escape backslash first, then single-quote (order matters)
            let escaped = v.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "'",  with: "\\'")
            return "'\(escaped)'"
        case .bytes(let v):  return "0x" + v.map { String(format: "%02X", $0) }.joined()
        case .uuid(let v):   return "'\(v.uuidString)'"
        case .date(let v):
            return "'\(_mysqlDateFmt.string(from: v))'"
        }
    }
}
