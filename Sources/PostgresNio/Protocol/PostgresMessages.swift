import NIOCore

// ── PostgreSQL Wire Protocol v3 ───────────────────────────────────────────────
//
// All messages (both frontend/client and backend/server) have the form:
//   [1]    message type byte  (frontend startup message has no type byte)
//   [4]    length (int32, big-endian, includes the 4 bytes itself)
//   [...] body
//
// Reference: https://www.postgresql.org/docs/current/protocol-message-formats.html

// MARK: - Message type identifiers

enum PGFrontendMessageType: UInt8 {
    case query          = 0x51  // 'Q'
    case parse          = 0x50  // 'P'
    case bind           = 0x42  // 'B'
    case execute        = 0x45  // 'E'
    case describe       = 0x44  // 'D'
    case sync           = 0x53  // 'S'
    case terminate      = 0x58  // 'X'
    case passwordMessage = 0x70 // 'p'
    case flush          = 0x48  // 'H'
    case copyData       = 0x64  // 'd'
    case copyDone       = 0x63  // 'c'
    case copyFail       = 0x66  // 'f'
    case close          = 0x43  // 'C'
}

enum PGBackendMessageType: UInt8 {
    case authentication     = 0x52  // 'R'
    case backendKeyData     = 0x4B  // 'K'
    case bindComplete       = 0x32  // '2'
    case closeComplete      = 0x33  // '3'
    case commandComplete    = 0x43  // 'C'
    case copyData           = 0x64  // 'd'
    case copyDone           = 0x63  // 'c'
    case copyInResponse     = 0x47  // 'G'
    case copyOutResponse    = 0x48  // 'H'
    case copyBothResponse   = 0x57  // 'W'
    case dataRow            = 0x44  // 'D'
    case emptyQueryResponse = 0x49  // 'I'
    case errorResponse      = 0x45  // 'E'
    case functionCallResponse = 0x56 // 'V'
    case negotiateProtocol  = 0x76  // 'v'
    case noData             = 0x6E  // 'n'
    case noticeResponse     = 0x4E  // 'N'
    case notificationResponse = 0x41 // 'A'
    case parameterDescription = 0x74 // 't'
    case parameterStatus    = 0x53  // 'S'
    case parseComplete      = 0x31  // '1'
    case portalSuspended    = 0x73  // 's'
    case readyForQuery      = 0x5A  // 'Z'
    case rowDescription     = 0x54  // 'T'
}

enum PGAuthType: Int32 {
    case ok                 = 0
    case kerberosV5         = 2
    case clearTextPassword  = 3
    case md5Password        = 5
    case scmCredential      = 6
    case gss                = 7
    case gssApiData         = 8
    case sspi               = 9
    case sasl               = 10
    case saslContinue       = 11
    case saslFinal          = 12
}

// MARK: - NIO framing handler

final class PGFramingHandler: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // Need at least type (1) + length (4) = 5 bytes
        guard buffer.readableBytes >= 5 else { return .needMoreData }

        let savedIndex = buffer.readerIndex
        let _: UInt8 = buffer.readInteger()!         // type byte (peek)
        let length: Int32 = buffer.readInteger(endianness: .big)!  // includes itself (4 bytes)
        buffer.moveReaderIndex(to: savedIndex)

        let totalLen = 1 + Int(length)   // type byte + length field + body
        guard buffer.readableBytes >= totalLen else { return .needMoreData }

        let msg = buffer.readSlice(length: totalLen)!
        context.fireChannelRead(wrapInboundOut(msg))
        return .continue
    }

    func decodeLast(context: ChannelHandlerContext,
                    buffer: inout ByteBuffer,
                    seenEOF: Bool) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}

// MARK: - Message builders

enum PGFrontend {
    /// Startup message (no type byte, special layout)
    static func startup(user: String, database: String,
                        allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: 64)
        body.writeInteger(Int32(196608), endianness: .big)  // protocol version 3.0
        body.writeCString("user");     body.writeCString(user)
        body.writeCString("database"); body.writeCString(database)
        body.writeCString("client_encoding"); body.writeCString("UTF8")
        body.writeInteger(UInt8(0))  // terminator

        var out = allocator.buffer(capacity: 4 + body.writerIndex)
        out.writeInteger(Int32(4 + body.writerIndex), endianness: .big)
        out.writeBuffer(&body)
        return out
    }

    /// SSL request (special startup: length=8, code=80877103)
    static func sslRequest(allocator: ByteBufferAllocator) -> ByteBuffer {
        var out = allocator.buffer(capacity: 8)
        out.writeInteger(Int32(8),        endianness: .big)
        out.writeInteger(Int32(80877103), endianness: .big)   // SSLRequest code
        return out
    }

    static func message(_ type: PGFrontendMessageType, body: ByteBuffer,
                        allocator: ByteBufferAllocator) -> ByteBuffer {
        var out = allocator.buffer(capacity: 5 + body.readableBytes)
        out.writeInteger(type.rawValue)
        out.writeInteger(Int32(4 + body.readableBytes), endianness: .big)
        var b = body; out.writeBuffer(&b)
        return out
    }

    static func query(_ sql: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: sql.utf8.count + 1)
        body.writeCString(sql)
        return message(.query, body: body, allocator: allocator)
    }

    static func terminate(allocator: ByteBufferAllocator) -> ByteBuffer {
        var out = allocator.buffer(capacity: 5)
        out.writeInteger(PGFrontendMessageType.terminate.rawValue)
        out.writeInteger(Int32(4), endianness: .big)
        return out
    }

    static func passwordMessage(_ password: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: password.utf8.count + 1)
        body.writeCString(password)
        return message(.passwordMessage, body: body, allocator: allocator)
    }

    // SASLInitialResponse: sent after server requests SASL auth.
    // Format: 'p' + len + mechanism (null-terminated) + client-message-len (int32) + client-message
    static func saslInitialResponse(
        mechanism: String,
        clientFirstMessage: String,
        allocator: ByteBufferAllocator
    ) -> ByteBuffer {
        let msgBytes = [UInt8](clientFirstMessage.utf8)
        var body = allocator.buffer(capacity: mechanism.utf8.count + 1 + 4 + msgBytes.count)
        body.writeCString(mechanism)
        body.writeInteger(Int32(msgBytes.count), endianness: .big)
        body.writeBytes(msgBytes)
        return message(.passwordMessage, body: body, allocator: allocator)
    }

    // SASLResponse: sent after server's SASL continue message.
    static func saslResponse(_ clientFinalMessage: String, allocator: ByteBufferAllocator) -> ByteBuffer {
        var body = allocator.buffer(capacity: clientFinalMessage.utf8.count)
        body.writeString(clientFinalMessage)
        return message(.passwordMessage, body: body, allocator: allocator)
    }
}

private extension ByteBuffer {
    mutating func writeCString(_ s: String) {
        writeString(s)
        writeInteger(UInt8(0))
    }
}
