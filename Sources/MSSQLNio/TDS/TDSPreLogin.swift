import NIOCore
import Foundation

// ── TDS Pre-Login ─────────────────────────────────────────────────────────────
//
// Sent by the client BEFORE Login7 to negotiate TLS and gather server info.
// Format: list of (option_token, offset, length) tuples, then the values.
//
// Options we send:
//   0x00 VERSION   – client TDS version (4 bytes version + 2 bytes sub-build)
//   0x01 ENCRYPTION – TLS preference
//   0x02 INSTOPT   – instance name (empty → "\0")
//   0x03 THREADID  – thread ID (4 bytes)
//   0xFF TERMINATOR

enum PreLoginEncryption: UInt8 {
    case off         = 0x00   // server does not support, client does not want
    case on          = 0x01   // server supports, client wants
    case notSupported = 0x02  // server does not support encryption
    case required    = 0x03   // client requires encryption
}

struct TDSPreLoginRequest {
    var clientVersion: (UInt8, UInt8, UInt8, UInt8) = (8, 0, 0, 0)
    var encryption: PreLoginEncryption

    init(encryption: PreLoginEncryption = .on) {
        self.encryption = encryption
    }

    func encode(allocator: ByteBufferAllocator) -> ByteBuffer {
        // Values
        let version: [UInt8]    = [clientVersion.0, clientVersion.1,
                                   clientVersion.2, clientVersion.3, 0x00, 0x00]
        let encByte: [UInt8]    = [encryption.rawValue]
        let instance: [UInt8]   = [0x00]          // empty instance name
        let threadID: [UInt8]   = [0x00, 0x00, 0x00, 0x00]

        // Option tokens + offset/length table: 5 bytes per entry, terminated by 0xFF
        let numOptions     = 4
        let headerSize     = numOptions * 5 + 1   // 5 bytes each + terminator
        let versionOffset  = UInt16(headerSize)
        let encOffset      = versionOffset  + UInt16(version.count)
        let instOffset     = encOffset      + UInt16(encByte.count)
        let threadOffset   = instOffset     + UInt16(instance.count)

        var buf = allocator.buffer(capacity: headerSize + version.count +
                                   encByte.count + instance.count + threadID.count)

        // Option table
        buf.writeInteger(UInt8(0x00));  buf.writeInteger(versionOffset, endianness: .big);  buf.writeInteger(UInt16(version.count), endianness: .big)
        buf.writeInteger(UInt8(0x01));  buf.writeInteger(encOffset,     endianness: .big);  buf.writeInteger(UInt16(encByte.count), endianness: .big)
        buf.writeInteger(UInt8(0x02));  buf.writeInteger(instOffset,    endianness: .big);  buf.writeInteger(UInt16(instance.count), endianness: .big)
        buf.writeInteger(UInt8(0x03));  buf.writeInteger(threadOffset,  endianness: .big);  buf.writeInteger(UInt16(threadID.count), endianness: .big)
        buf.writeInteger(UInt8(0xFF))   // terminator

        buf.writeBytes(version)
        buf.writeBytes(encByte)
        buf.writeBytes(instance)
        buf.writeBytes(threadID)
        return buf
    }
}

struct TDSPreLoginResponse {
    var serverVersion: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0)
    var encryption: PreLoginEncryption = .off

    /// Parses the payload (without packet header) of a pre-login response.
    static func decode(from buffer: inout ByteBuffer) throws -> TDSPreLoginResponse {
        var response = TDSPreLoginResponse()
        let start = buffer.readerIndex

        // Read option table
        var options: [(token: UInt8, offset: UInt16, length: UInt16)] = []
        while let token: UInt8 = buffer.readInteger() {
            if token == 0xFF { break }
            guard
                let offset: UInt16 = buffer.readInteger(endianness: .big),
                let length: UInt16 = buffer.readInteger(endianness: .big)
            else { throw TDSError.incomplete }
            options.append((token, offset, length))
        }

        for opt in options {
            let absIdx = start + Int(opt.offset)
            guard absIdx + Int(opt.length) <= buffer.writerIndex else { continue }
            var slice = buffer.getSlice(at: absIdx, length: Int(opt.length)) ?? ByteBuffer()
            switch opt.token {
            case 0x00 where opt.length >= 6:
                let bytes = slice.readBytes(length: 6)!
                response.serverVersion = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5])
            case 0x01 where opt.length >= 1:
                let byte = slice.readBytes(length: 1)![0]
                response.encryption = PreLoginEncryption(rawValue: byte) ?? .off
            default:
                break
            }
        }
        return response
    }
}
