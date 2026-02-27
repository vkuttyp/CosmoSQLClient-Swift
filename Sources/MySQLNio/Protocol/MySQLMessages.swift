import NIOCore

// ── MySQL Wire Protocol v10 ───────────────────────────────────────────────────
//
// Packet layout:
//  [3]  payload length (little-endian)
//  [1]  sequence number
//  [n]  payload
//
// Reference: https://dev.mysql.com/doc/dev/mysql-server/latest/PAGE_PROTOCOL.html

// MARK: - Packet header

struct MySQLPacketHeader {
    static let size = 4
    let payloadLength: Int
    let sequenceID:    UInt8
}

// MARK: - Client capability flags

struct MySQLCapabilities: OptionSet, Sendable {
    let rawValue: UInt32

    static let longPassword           = MySQLCapabilities(rawValue: 1 << 0)
    static let foundRows              = MySQLCapabilities(rawValue: 1 << 1)
    static let longFlag               = MySQLCapabilities(rawValue: 1 << 2)
    static let connectWithDB          = MySQLCapabilities(rawValue: 1 << 3)
    static let noSchema               = MySQLCapabilities(rawValue: 1 << 4)
    static let compress               = MySQLCapabilities(rawValue: 1 << 5)
    static let odbc                   = MySQLCapabilities(rawValue: 1 << 6)
    static let localFiles             = MySQLCapabilities(rawValue: 1 << 7)
    static let ignoreSpace            = MySQLCapabilities(rawValue: 1 << 8)
    static let protocol41             = MySQLCapabilities(rawValue: 1 << 9)
    static let interactive            = MySQLCapabilities(rawValue: 1 << 10)
    static let ssl                    = MySQLCapabilities(rawValue: 1 << 11)
    static let ignoreSIGPIPE          = MySQLCapabilities(rawValue: 1 << 12)
    static let transactions           = MySQLCapabilities(rawValue: 1 << 13)
    static let reserved               = MySQLCapabilities(rawValue: 1 << 14)
    static let secureConnection       = MySQLCapabilities(rawValue: 1 << 15)
    static let multiStatements        = MySQLCapabilities(rawValue: 1 << 16)
    static let multiResults           = MySQLCapabilities(rawValue: 1 << 17)
    static let psMultiResults         = MySQLCapabilities(rawValue: 1 << 18)
    static let pluginAuth             = MySQLCapabilities(rawValue: 1 << 19)
    static let connectAttrs           = MySQLCapabilities(rawValue: 1 << 20)
    static let pluginAuthLenEncData   = MySQLCapabilities(rawValue: 1 << 21)
    static let canHandleExpiredPasswords = MySQLCapabilities(rawValue: 1 << 22)
    static let sessionTrack           = MySQLCapabilities(rawValue: 1 << 23)
    static let deprecateEOF           = MySQLCapabilities(rawValue: 1 << 24)

    /// Capabilities we advertise to the server
    static let clientDefault: MySQLCapabilities = [
        .longPassword, .foundRows, .longFlag, .connectWithDB,
        .protocol41, .transactions, .secureConnection,
        .multiStatements, .multiResults, .pluginAuth,
        .pluginAuthLenEncData, .connectAttrs, .deprecateEOF,
    ]
}

// MARK: - Server status flags

struct MySQLServerStatus: OptionSet {
    let rawValue: UInt16
    static let inTransaction      = MySQLServerStatus(rawValue: 1 << 0)
    static let autoCommit         = MySQLServerStatus(rawValue: 1 << 1)
    static let moreResultsExist   = MySQLServerStatus(rawValue: 1 << 3)
    static let noGoodIndexUsed    = MySQLServerStatus(rawValue: 1 << 4)
    static let noIndexUsed        = MySQLServerStatus(rawValue: 1 << 5)
    static let cursorExists       = MySQLServerStatus(rawValue: 1 << 6)
    static let lastRowSent        = MySQLServerStatus(rawValue: 1 << 7)
    static let dbDropped          = MySQLServerStatus(rawValue: 1 << 8)
    static let noBackslashEscape  = MySQLServerStatus(rawValue: 1 << 9)
    static let metadataChanged    = MySQLServerStatus(rawValue: 1 << 10)
    static let queryWasSlow       = MySQLServerStatus(rawValue: 1 << 11)
    static let psOutParams        = MySQLServerStatus(rawValue: 1 << 12)
    static let inTransactionReadonly = MySQLServerStatus(rawValue: 1 << 13)
    static let sessionStateChanged = MySQLServerStatus(rawValue: 1 << 14)
}

// MARK: - NIO framing handler

final class MySQLFramingHandler: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= 4 else { return .needMoreData }

        let savedIndex = buffer.readerIndex
        // 3-byte little-endian length
        let b0 = UInt32(buffer.readInteger(endianness: .little) as UInt8? ?? 0)
        let b1 = UInt32(buffer.readInteger(endianness: .little) as UInt8? ?? 0)
        let b2 = UInt32(buffer.readInteger(endianness: .little) as UInt8? ?? 0)
        let _: UInt8? = buffer.readInteger()   // sequence ID
        let payloadLen = Int(b0 | (b1 << 8) | (b2 << 16))
        buffer.moveReaderIndex(to: savedIndex)

        guard buffer.readableBytes >= 4 + payloadLen else { return .needMoreData }

        let packet = buffer.readSlice(length: 4 + payloadLen)!
        context.fireChannelRead(wrapInboundOut(packet))
        return .continue
    }

    func decodeLast(context: ChannelHandlerContext,
                    buffer: inout ByteBuffer,
                    seenEOF: Bool) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}

// MARK: - Packet builder helpers

extension ByteBuffer {
    /// Encode a MySQL length-encoded integer
    mutating func writeLengthEncodedInt(_ value: UInt64) {
        if value < 251 {
            writeInteger(UInt8(value))
        } else if value < 65536 {
            writeInteger(UInt8(0xFC))
            writeInteger(UInt16(value), endianness: .little)
        } else if value < 16777216 {
            writeInteger(UInt8(0xFD))
            writeInteger(UInt8(value & 0xFF))
            writeInteger(UInt8((value >> 8) & 0xFF))
            writeInteger(UInt8((value >> 16) & 0xFF))
        } else {
            writeInteger(UInt8(0xFE))
            writeInteger(value, endianness: .little)
        }
    }

    /// Read a MySQL length-encoded integer; returns nil if buffer is too short.
    mutating func readLengthEncodedInt() -> UInt64? {
        guard let first: UInt8 = readInteger() else { return nil }
        switch first {
        case 0xFB:              return nil          // NULL
        case 0xFC:
            guard let v: UInt16 = readInteger(endianness: .little) else { return nil }
            return UInt64(v)
        case 0xFD:
            guard let b0: UInt8 = readInteger(),
                  let b1: UInt8 = readInteger(),
                  let b2: UInt8 = readInteger() else { return nil }
            return UInt64(b0) | (UInt64(b1) << 8) | (UInt64(b2) << 16)
        case 0xFE:
            guard let v: UInt64 = readInteger(endianness: .little) else { return nil }
            return v
        default:
            return UInt64(first)
        }
    }

    /// Read a null-terminated C string
    mutating func readNullTerminatedString() -> String? {
        guard let end = readableBytesView.firstIndex(of: 0) else { return nil }
        let len = end - readerIndex
        let s = readString(length: len)
        moveReaderIndex(forwardBy: 1)
        return s
    }

    /// Read a length-encoded string
    mutating func readLengthEncodedString() -> String? {
        guard let len = readLengthEncodedInt() else { return nil }
        return readString(length: Int(len))
    }

    /// Build a framed MySQL packet
    static func mysqlPacket(sequenceID: UInt8, body: ByteBuffer,
                             allocator: ByteBufferAllocator) -> ByteBuffer {
        let len = body.readableBytes
        var out = allocator.buffer(capacity: 4 + len)
        out.writeInteger(UInt8(len & 0xFF))
        out.writeInteger(UInt8((len >> 8) & 0xFF))
        out.writeInteger(UInt8((len >> 16) & 0xFF))
        out.writeInteger(sequenceID)
        var b = body; out.writeBuffer(&b)
        return out
    }
}

// MARK: - Protocol errors

enum MySQLError: Error {
    case incomplete
    case unknownPacket
    case malformed(String)
}
