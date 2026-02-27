import NIOCore

// ── TDS Packet Header ─────────────────────────────────────────────────────────
//
// Each TDS packet on the wire:
//  [0]   Type      – see TDSPacketType
//  [1]   Status    – 0x00 = more packets, 0x01 = last packet, 0x08 = reset conn
//  [2-3] Length    – total packet length including this 8-byte header (big-endian)
//  [4-5] SPID      – server process ID (big-endian, set to 0 from client)
//  [6]   PacketID  – incremented per packet (wraps at 255→1)
//  [7]   Window    – always 0x00

public enum TDSPacketType: UInt8 {
    case sqlBatch        = 0x01
    case preLogin        = 0x12
    case tdsLogin7       = 0x10
    case rpc             = 0x03
    case tabularResult   = 0x04
    case attention       = 0x06
    case bulkLoad        = 0x07
    case fedAuthToken    = 0x08
    case sspiAuth        = 0x11   // SSPI / NTLM authentication response packet
}

public enum TDSPacketStatus: UInt8 {
    case normal      = 0x00   // more packets follow
    case eom         = 0x01   // end of message
    case resetConn   = 0x08   // reset connection before message
}

public struct TDSPacketHeader {
    public static let size = 8

    public var type:     TDSPacketType
    public var status:   TDSPacketStatus
    public var length:   UInt16          // total packet length
    public var spid:     UInt16
    public var packetID: UInt8
    public var window:   UInt8

    public init(type: TDSPacketType, status: TDSPacketStatus = .eom,
                length: UInt16, spid: UInt16 = 0, packetID: UInt8 = 1) {
        self.type     = type
        self.status   = status
        self.length   = length
        self.spid     = spid
        self.packetID = packetID
        self.window   = 0
    }

    // MARK: - Encode

    public func encode(into buffer: inout ByteBuffer) {
        buffer.writeInteger(type.rawValue)
        buffer.writeInteger(status.rawValue)
        buffer.writeInteger(length, endianness: .big)
        buffer.writeInteger(spid,   endianness: .big)
        buffer.writeInteger(packetID)
        buffer.writeInteger(window)
    }

    // MARK: - Decode

    public static func decode(from buffer: inout ByteBuffer) throws -> TDSPacketHeader {
        guard buffer.readableBytes >= size else {
            throw TDSError.incomplete
        }
        guard
            let typeByte:  UInt8 = buffer.readInteger(),
            let statusByte: UInt8 = buffer.readInteger(),
            let length:  UInt16 = buffer.readInteger(endianness: .big),
            let spid:    UInt16 = buffer.readInteger(endianness: .big),
            let pid:     UInt8  = buffer.readInteger(),
            let win:     UInt8  = buffer.readInteger()
        else { throw TDSError.incomplete }

        guard let type = TDSPacketType(rawValue: typeByte) else {
            throw TDSError.unknownPacketType(typeByte)
        }
        let status = TDSPacketStatus(rawValue: statusByte) ?? .normal
        return TDSPacketHeader(type: type, status: status, length: length,
                               spid: spid, packetID: pid)
    }
}

// MARK: - TDS-level errors (distinct from SQLError)

enum TDSError: Error {
    case incomplete
    case unknownPacketType(UInt8)
    case unknownTokenType(UInt8)
    case malformed(String)
}
