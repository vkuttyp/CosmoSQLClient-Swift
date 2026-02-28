@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL
import Logging
import SQLNioCore
import Foundation

// ── PostgresConnection ────────────────────────────────────────────────────────
//
// A single async/await connection to a PostgreSQL server.
// Implements the PostgreSQL wire protocol v3 natively over swift-nio.
//
// Usage:
// ```swift
// let config = PostgresConnection.Configuration(host: "localhost", port: 5432,
//                                               database: "mydb",
//                                               username: "postgres", password: "secret")
// let conn = try await PostgresConnection.connect(configuration: config)
// defer { try? await conn.close() }
//
// let rows = try await conn.query("SELECT id, email FROM users WHERE active = $1", [.bool(true)])
// ```

public final class PostgresConnection: SQLDatabase, @unchecked Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var host:          String
        public var port:          Int     = 5432
        public var database:      String
        public var username:      String
        public var password:      String
        public var tls:           SQLTLSConfiguration = .prefer
        public var logger:        Logger = Logger(label: "PostgresNio")
        /// Timeout for the TCP + TLS + auth handshake (seconds). nil = no limit.
        public var connectTimeout: TimeInterval? = 30
        /// Per-query timeout applied via `SET LOCAL statement_timeout`. nil = no limit.
        public var queryTimeout:   TimeInterval? = nil

        public init(host: String, port: Int = 5432,
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

    private let channel:  any Channel
    let config:           Configuration  // internal — used by backup extension
    private let logger:   Logger
    private var isClosed: Bool = false
    private var bridge:   AsyncChannelBridge?
    private var inTransaction: Bool = false

    // Called for each NOTICE message received from the server.
    public var onNotice: (@Sendable (String) -> Void)?

    // MARK: - Connect

    public static func connect(
        configuration: Configuration,
        eventLoopGroup: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> PostgresConnection {
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)

        let channel = try await bootstrap.connect(host: configuration.host,
                                                   port: configuration.port).get()
        let conn = PostgresConnection(channel: channel, config: configuration,
                                      logger: configuration.logger)
        try await conn.handshake()
        return conn
    }

    private init(channel: any Channel, config: Configuration, logger: Logger) {
        self.channel = channel
        self.config  = config
        self.logger  = logger
    }

    // MARK: - Handshake

    private func handshake() async throws {
        // The PostgreSQL SSL negotiation uses a single raw byte response ('S'/'N')
        // which predates the standard PG framing format. We handle it by using a
        // temporary raw bridge handler before installing the proper framing handler.
        let rawBridge = AsyncChannelBridge()
        try await channel.pipeline.addHandler(rawBridge).get()

        // 1. Optionally request TLS
        if config.tls != .disable {
            let sslReq = PGFrontend.sslRequest(allocator: channel.allocator)
            try await send(sslReq)
            // SSL response is a single raw byte, not a framed PG message
            var sslResponse = try await rawBridge.waitForMessage(on: channel.eventLoop)
            let sslByte = sslResponse.readInteger(as: UInt8.self) ?? UInt8(ascii: "N")
            if sslByte == UInt8(ascii: "S") {
                try await upgradeTLS()
                logger.debug("PostgreSQL TLS established")
            } else if config.tls == .require {
                throw SQLError.tlsError("Server does not support TLS")
            }
        }

        // 2. Now switch to proper PG message framing
        try await channel.pipeline.removeHandler(rawBridge).get()
        let b = AsyncChannelBridge()
        bridge = b
        // Swift 6: ByteToMessageHandler has Sendable marked unavailable (event-loop-bound).
        // Use syncOperations from within the event loop to avoid the Sendable requirement.
        let frameBox = _UnsafeSendable(ByteToMessageHandler(PGFramingHandler()))
        try await channel.eventLoop.submit {
            try self.channel.pipeline.syncOperations.addHandlers([frameBox.value, b])
        }.get()

        // 3. Startup + authentication
        let startup = PGFrontend.startup(user: config.username,
                                          database: config.database,
                                          allocator: channel.allocator)
        try await send(startup)
        try await authenticate()
        logger.debug("PostgreSQL connected as \(config.username)")
    }

    private func upgradeTLS() async throws {
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        let sslHandler = try NIOSSLClientHandler(context: sslContext,
                                                  serverHostname: config.host)
        // Swift 6: NIOSSLHandler has Sendable marked unavailable (event-loop-bound).
        let sslBox = _UnsafeSendable(sslHandler)
        try await channel.eventLoop.submit {
            try self.channel.pipeline.syncOperations.addHandler(sslBox.value, position: .first)
        }.get()
    }

    private func authenticate() async throws {
        while true {
            let msg = try await receiveMessage()
            switch msg {
            case .authOK:
                // Continue reading until ReadyForQuery
                try await waitForReady()
                return
            case .authRequestClearText:
                let reply = PGFrontend.passwordMessage(config.password,
                                                        allocator: channel.allocator)
                try await send(reply)
            case .authRequestMD5(let salt):
                let hashed = pgMD5Password(user: config.username,
                                            password: config.password,
                                            salt: salt)
                let reply = PGFrontend.passwordMessage(hashed, allocator: channel.allocator)
                try await send(reply)
            case .authRequestSASL(let mechanisms):
                guard mechanisms.contains("SCRAM-SHA-256") else {
                    throw SQLError.unsupported("No supported SASL mechanism (got: \(mechanisms.joined(separator: ", ")))")
                }
                try await authenticateSCRAM()
                return
            case .error(_, _, let message):
                throw SQLError.authenticationFailed(message)
            case .parameterStatus, .backendKeyData, .notice:
                continue
            default:
                throw SQLError.protocolError("Unexpected message during auth: \(msg)")
            }
        }
    }

    private func authenticateSCRAM() async throws {
        let nonce = SCRAMSHA256.generateNonce()
        let (payload, clientFirstMessageBare) = SCRAMSHA256.clientFirstMessage(
            username: config.username, nonce: nonce)

        // 1. Send SASLInitialResponse
        let initMsg = PGFrontend.saslInitialResponse(
            mechanism: "SCRAM-SHA-256",
            clientFirstMessage: payload,
            allocator: channel.allocator)
        try await send(initMsg)

        // 2. Receive AuthSASLContinue
        var serverFirstMessage = ""
        var expectedServerSignature: [UInt8] = []
        loop: while true {
            let msg = try await receiveMessage()
            switch msg {
            case .authSASLContinue(let data):
                serverFirstMessage = String(bytes: data, encoding: .utf8) ?? ""
                let (clientFinal, serverSig) = try SCRAMSHA256.clientFinalMessage(
                    password: config.password,
                    clientFirstMessageBare: clientFirstMessageBare,
                    serverFirstMessage: serverFirstMessage,
                    nonce: nonce)
                expectedServerSignature = serverSig

                // 3. Send SASLResponse (client-final-message)
                let finalMsg = PGFrontend.saslResponse(clientFinal, allocator: channel.allocator)
                try await send(finalMsg)
                break loop
            case .error(_, _, let message):
                throw SQLError.authenticationFailed(message)
            default:
                throw SQLError.protocolError("Expected SASL continue, got: \(msg)")
            }
        }

        // 4. Receive AuthSASLFinal + AuthOK
        while true {
            let msg = try await receiveMessage()
            switch msg {
            case .authSASLFinal(let data):
                let serverFinal = String(bytes: data, encoding: .utf8) ?? ""
                try SCRAMSHA256.verifyServerFinal(serverFinal,
                                                  expectedServerSignature: expectedServerSignature)
            case .authOK:
                try await waitForReady()
                return
            case .error(_, _, let message):
                throw SQLError.authenticationFailed(message)
            case .parameterStatus, .backendKeyData, .notice:
                continue
            default:
                throw SQLError.protocolError("Unexpected message during SCRAM final: \(msg)")
            }
        }
    }

    private func waitForReady() async throws {
        while true {
            let msg = try await receiveMessage()
            switch msg {
            case .readyForQuery: return
            case .parameterStatus, .backendKeyData, .notice: continue
            case .error(_, _, let m): throw SQLError.serverError(code: 0, message: m)
            default: continue
            }
        }
    }

    // MARK: - SQLDatabase

    public func query(_ sql: String, _ binds: [SQLValue]) async throws -> [SQLRow] {
        guard !isClosed else { throw SQLError.connectionClosed }
        let rendered = renderQuery(sql, binds: binds)
        logger.debug("PostgreSQL query: \(rendered)")

        let msg = PGFrontend.query(rendered, allocator: channel.allocator)
        try await send(msg)
        return try await collectResults()
    }

    public func execute(_ sql: String, _ binds: [SQLValue]) async throws -> Int {
        guard !isClosed else { throw SQLError.connectionClosed }
        let rendered = renderQuery(sql, binds: binds)
        logger.debug("PostgreSQL execute: \(rendered)")

        let msg = PGFrontend.query(rendered, allocator: channel.allocator)
        try await send(msg)
        var rowsAffected = 0
        var pendingError: (any Error)?
        // Drain until ReadyForQuery so the connection stays clean after errors
        loop: while true {
            let m = try await receiveMessage()
            switch m {
            case .commandComplete(let tag):
                rowsAffected = tag.rowsAffected
            case .readyForQuery:
                break loop
            case .error(_, _, let message):
                pendingError = SQLError.serverError(code: 0, message: message)
            case .notice(let msg):
                onNotice?(msg)
            default:
                break
            }
        }
        if let err = pendingError { throw err }
        return rowsAffected
    }

    /// Execute one or more SQL statements and return each result set separately.
    ///
    /// PostgreSQL allows multiple statements separated by `;` in a single query string.
    /// Each statement that returns rows produces one element in the returned array.
    public func queryMulti(_ sql: String, _ binds: [SQLValue] = []) async throws -> [[SQLRow]] {
        guard !isClosed else { throw SQLError.connectionClosed }
        let rendered = renderQuery(sql, binds: binds)
        logger.debug("PostgreSQL queryMulti: \(rendered)")

        let msg = PGFrontend.query(rendered, allocator: channel.allocator)
        try await send(msg)

        var allSets:    [[SQLRow]] = []
        var current:    [SQLRow]   = []
        var columns:    [PGColumnDesc] = []
        var pendingError: (any Error)?

        loop: while true {
            let m = try await receiveMessage()
            switch m {
            case .rowDescription(let cols):
                columns = cols
                current = []
            case .dataRow(let rawValues):
                if pendingError == nil {
                    let sqlCols = columns.map { SQLColumn(name: $0.name, dataTypeID: $0.typeOID) }
                    let values  = zip(columns, rawValues).map { col, raw -> SQLValue in
                        guard var buf = raw else { return .null }
                        return pgDecode(typeOID: col.typeOID, buffer: &buf)
                    }
                    current.append(SQLRow(columns: sqlCols, values: values))
                }
            case .commandComplete:
                if !current.isEmpty || !columns.isEmpty {
                    allSets.append(current)
                    current  = []
                    columns  = []
                }
            case .readyForQuery:
                break loop
            case .error(_, _, let message):
                pendingError = SQLError.serverError(code: 0, message: message)
            case .notice(let msg):
                onNotice?(msg)
            case .emptyQueryResponse:
                continue
            default:
                break
            }
        }
        if let err = pendingError { throw err }
        return allSets
    }

    // MARK: - Transaction API

    /// Begin an explicit transaction.
    public func beginTransaction() async throws {
        _ = try await execute("BEGIN", [])
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
        _ work: @Sendable (PostgresConnection) async throws -> T
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
        let terminate = PGFrontend.terminate(allocator: channel.allocator)
        try? await send(terminate)
        try await channel.close().get()
    }

    // MARK: - Result collection

    private func collectResults() async throws -> [SQLRow] {
        var columns: [PGColumnDesc] = []
        var rows: [SQLRow] = []
        var pendingError: (any Error)?

        loop: while true {
            let msg = try await receiveMessage()
            switch msg {
            case .rowDescription(let cols):
                columns = cols
            case .dataRow(let rawValues):
                if pendingError == nil {
                    let sqlCols = columns.map {
                        SQLColumn(name: $0.name, dataTypeID: $0.typeOID)
                    }
                    let values = zip(columns, rawValues).map { col, raw -> SQLValue in
                        guard var buf = raw else { return .null }
                        return pgDecode(typeOID: col.typeOID, buffer: &buf)
                    }
                    rows.append(SQLRow(columns: sqlCols, values: values))
                }
            case .commandComplete:
                continue
            case .readyForQuery:
                break loop
            case .error(_, _, let message):
                // Record error but keep draining until ReadyForQuery so connection stays clean
                pendingError = SQLError.serverError(code: 0, message: message)
            case .notice(let msg):
                onNotice?(msg)
            case .emptyQueryResponse:
                continue
            default:
                break
            }
        }
        if let err = pendingError { throw err }
        return rows
    }

    // MARK: - Wire I/O

    private func send(_ buffer: ByteBuffer) async throws {
        try await channel.writeAndFlush(buffer).get()
    }

    private func receiveMessage() async throws -> PGBackendMessage {
        guard let b = bridge else { throw SQLError.connectionClosed }
        var buf = try await b.waitForMessage(on: channel.eventLoop)
        return try PGMessageDecoder.decode(buffer: &buf)
    }

    // MARK: - Query rendering (text protocol inline bind substitution)

    private func renderQuery(_ sql: String, binds: [SQLValue]) -> String {
        var result = sql
        // Replace in reverse order so $1 doesn't incorrectly match $10, $11, etc.
        for (i, bind) in binds.enumerated().reversed() {
            result = result.replacingOccurrences(of: "$\(i + 1)", with: bind.pgLiteral)
        }
        return result
    }
}

// MARK: - PostgreSQL text decoder

func pgDecode(typeOID: UInt32, buffer: inout ByteBuffer) -> SQLValue {
    let text = buffer.readString(length: buffer.readableBytes) ?? ""
    switch typeOID {
    case 16:   // bool
        return .bool(text == "t" || text == "true" || text == "1")
    case 20:   // int8
        return Int64(text).map { .int64($0) } ?? .string(text)
    case 21:   // int2
        return Int(text).map { .int($0) } ?? .string(text)
    case 23:   // int4
        return Int32(text).map { .int32($0) } ?? .string(text)
    case 700:  // float4
        return Float(text).map { .float($0) } ?? .string(text)
    case 701:  // float8
        return Double(text).map { .double($0) } ?? .string(text)
    case 2950: // uuid
        return UUID(uuidString: text).map { .uuid($0) } ?? .string(text)
    case 1082: // date
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: text).map { .date($0) } ?? .string(text)
    case 1114, 1184: // timestamp, timestamptz
        let fmt = ISO8601DateFormatter()
        return fmt.date(from: text).map { .date($0) } ?? .string(text)
    default:
        return .string(text)
    }
}

// MARK: - SQLValue → PostgreSQL literal

private extension SQLValue {
    var pgLiteral: String {
        switch self {
        case .null:           return "NULL"
        case .bool(let v):   return v ? "TRUE" : "FALSE"
        case .int(let v):    return "\(v)"
        case .int8(let v):   return "\(v)"
        case .int16(let v):  return "\(v)"
        case .int32(let v):  return "\(v)"
        case .int64(let v):  return "\(v)"
        case .float(let v):  return "\(v)"
        case .double(let v): return "\(v)"
        case .decimal(let v): return (v as NSDecimalNumber).stringValue
        case .string(let v): return "'\(v.replacingOccurrences(of: "'", with: "''"))'"
        case .bytes(let v):  return "E'\\\\x" + v.map { String(format: "%02x", $0) }.joined() + "'"
        case .uuid(let v):   return "'\(v.uuidString)'"
        case .date(let v):
            let fmt = ISO8601DateFormatter()
            return "'\(fmt.string(from: v))'"
        }
    }
}
