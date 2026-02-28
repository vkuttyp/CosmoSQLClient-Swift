import NIOCore
import CosmoSQLCore
import Crypto
import Foundation

// ── MySQL Packet Decoder ──────────────────────────────────────────────────────

// MARK: - Handshake packet (v10)

struct MySQLHandshakeV10 {
    var protocolVersion:   UInt8
    var serverVersion:     String
    var connectionID:      UInt32
    var authPluginName:    String
    var authPluginData:    [UInt8]   // challenge bytes for auth
    var capabilities:      MySQLCapabilities
    var characterSet:      UInt8
    var statusFlags:       MySQLServerStatus

    static func decode(from packet: inout ByteBuffer) throws -> MySQLHandshakeV10 {
        // Skip 4-byte header
        packet.moveReaderIndex(forwardBy: 4)

        guard let proto:    UInt8  = packet.readInteger() else { throw MySQLError.incomplete }
        let serverVersion = packet.readNullTerminatedString() ?? ""
        guard let connID:   UInt32 = packet.readInteger(endianness: .little) else { throw MySQLError.incomplete }

        // auth-plugin-data-part-1 (8 bytes) + filler
        guard let part1 = packet.readBytes(length: 8) else { throw MySQLError.incomplete }
        packet.moveReaderIndex(forwardBy: 1)  // filler 0x00

        // capability flags lower 2 bytes
        guard let capLo: UInt16 = packet.readInteger(endianness: .little) else { throw MySQLError.incomplete }
        guard let charset: UInt8 = packet.readInteger() else { throw MySQLError.incomplete }
        guard let status: UInt16 = packet.readInteger(endianness: .little) else { throw MySQLError.incomplete }
        guard let capHi: UInt16 = packet.readInteger(endianness: .little) else { throw MySQLError.incomplete }

        let capabilities = MySQLCapabilities(rawValue: UInt32(capLo) | (UInt32(capHi) << 16))

        guard let authDataLen: UInt8 = packet.readInteger() else { throw MySQLError.incomplete }
        packet.moveReaderIndex(forwardBy: 10)  // reserved

        // auth-plugin-data-part-2
        let part2Len = max(13, Int(authDataLen) - 8)
        guard let part2 = packet.readBytes(length: part2Len) else { throw MySQLError.incomplete }
        var authData = part1 + part2
        if authData.last == 0 { authData.removeLast() }  // strip trailing null

        let authPluginName = packet.readNullTerminatedString() ?? "mysql_native_password"

        return MySQLHandshakeV10(
            protocolVersion: proto,
            serverVersion:   serverVersion,
            connectionID:    connID,
            authPluginName:  authPluginName,
            authPluginData:  authData,
            capabilities:    capabilities,
            characterSet:    charset,
            statusFlags:     MySQLServerStatus(rawValue: status)
        )
    }
}

// MARK: - OK / ERR / EOF packets

enum MySQLResponse {
    case ok(affectedRows: UInt64, lastInsertID: UInt64, statusFlags: MySQLServerStatus, info: String)
    case err(code: UInt16, sqlState: String, message: String)
    case eof(statusFlags: MySQLServerStatus)
    case localInfile(filename: String)
    case data(ByteBuffer)

    static func decode(packet: inout ByteBuffer, capabilities: MySQLCapabilities) throws -> MySQLResponse {
        // Skip 4-byte header
        let savedIndex = packet.readerIndex
        packet.moveReaderIndex(forwardBy: 4)

        guard let indicator: UInt8 = packet.readInteger() else { throw MySQLError.incomplete }

        switch indicator {
        case 0x00:  // OK
            let affected = packet.readLengthEncodedInt() ?? 0
            let lastID   = packet.readLengthEncodedInt() ?? 0
            let status   = packet.readInteger(endianness: .little) as UInt16? ?? 0
            let _        = packet.readInteger(endianness: .little) as UInt16?  // warnings
            let info     = packet.readString(length: packet.readableBytes) ?? ""
            return .ok(affectedRows: affected, lastInsertID: lastID,
                       statusFlags: MySQLServerStatus(rawValue: status), info: info)

        case 0xFE where packet.readableBytes < 9:  // EOF
            let status = packet.readInteger(endianness: .little) as UInt16? ?? 0
            return .eof(statusFlags: MySQLServerStatus(rawValue: status))

        case 0xFF:  // ERR
            guard let code: UInt16 = packet.readInteger(endianness: .little) else {
                throw MySQLError.incomplete
            }
            // SQL state marker '#' + 5-char state
            var sqlState = ""
            if let marker: UInt8 = packet.readInteger(), marker == UInt8(ascii: "#") {
                sqlState = packet.readString(length: 5) ?? ""
            }
            let message = packet.readString(length: packet.readableBytes) ?? ""
            return .err(code: code, sqlState: sqlState, message: message)

        case 0xFB:  // Local infile
            let filename = packet.readString(length: packet.readableBytes) ?? ""
            return .localInfile(filename: filename)

        default:
            // It's a result-set packet; restore reader and return raw
            packet.moveReaderIndex(to: savedIndex)
            return .data(packet)
        }
    }
}

// MARK: - Column definition

struct MySQLColumnDef {
    let catalog:     String
    let schema:      String
    let table:       String
    let orgTable:    String
    let name:        String
    let orgName:     String
    let charSet:     UInt16
    let columnLength: UInt32
    let columnType:  UInt8
    let flags:       UInt16
    let decimals:    UInt8

    static func decode(packet: inout ByteBuffer) throws -> MySQLColumnDef {
        packet.moveReaderIndex(forwardBy: 4)  // skip header
        let catalog  = packet.readLengthEncodedString() ?? ""
        let schema   = packet.readLengthEncodedString() ?? ""
        let table    = packet.readLengthEncodedString() ?? ""
        let orgTable = packet.readLengthEncodedString() ?? ""
        let name     = packet.readLengthEncodedString() ?? ""
        let orgName  = packet.readLengthEncodedString() ?? ""
        packet.moveReaderIndex(forwardBy: 1)  // length of fixed-length fields (0x0C)
        guard
            let charSet: UInt16      = packet.readInteger(endianness: .little),
            let colLen:  UInt32      = packet.readInteger(endianness: .little),
            let colType: UInt8       = packet.readInteger(),
            let flags:   UInt16      = packet.readInteger(endianness: .little),
            let decimals: UInt8      = packet.readInteger()
        else { throw MySQLError.incomplete }
        packet.moveReaderIndex(forwardBy: 2)  // filler
        return MySQLColumnDef(catalog: catalog, schema: schema, table: table,
                              orgTable: orgTable, name: name, orgName: orgName,
                              charSet: charSet, columnLength: colLen,
                              columnType: colType, flags: flags, decimals: decimals)
    }
}

// MARK: - auth_native_password  (SHA1 based)

func mysqlNativePassword(password: String, challenge: [UInt8]) -> [UInt8] {
    // token = SHA1(password) XOR SHA1(challenge + SHA1(SHA1(password)))
    let passwordData = Data(password.utf8)
    let sha1pw   = Data(Insecure.SHA1.hash(data: passwordData))
    let sha1sha1 = Data(Insecure.SHA1.hash(data: sha1pw))
    var combined = Data(challenge)
    combined.append(sha1sha1)
    let sha1combined = Array(Insecure.SHA1.hash(data: combined))
    return zip(Array(sha1pw), sha1combined).map { $0 ^ $1 }
}

// MARK: - caching_sha2_password scramble (SHA256 based)

/// Computes the scrambled password for `caching_sha2_password` fast-auth path.
/// token = SHA256(password) XOR SHA256(nonce || SHA256(SHA256(password)))
func mysqlCachingSHA2Password(password: String, nonce: [UInt8]) -> [UInt8] {
    let passwordData     = Data(password.utf8)
    let sha256pw         = Data(SHA256.hash(data: passwordData))          // SHA256(pw)
    let sha256sha256pw   = Data(SHA256.hash(data: sha256pw))              // SHA256(SHA256(pw))
    var combined         = Data(nonce)
    combined.append(sha256sha256pw)                                       // nonce || SHA256(SHA256(pw))
    let sha256combined   = Array(SHA256.hash(data: combined))             // SHA256(nonce || SHA256(SHA256(pw)))
    return zip(Array(sha256pw), sha256combined).map { $0 ^ $1 }
}

// MARK: - MySQL type → SQLValue

// Static formatters — DateFormatter construction is expensive; allocating one per cell
// (old behaviour) added significant overhead for date/datetime-heavy result sets.
private nonisolated(unsafe) let _mysqlDateFmt: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"; return f
}()
private nonisolated(unsafe) let _mysqlDateTimeFmt: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
}()

func mysqlDecode(columnType: UInt8, isUnsigned: Bool, text: String?) -> SQLValue {
    guard let text = text else { return .null }
    switch columnType {
    case 0x01:  // TINYINT
        return (isUnsigned ? UInt8(text).map { SQLValue.int(Int($0)) }
                           : Int8(text).map { SQLValue.int(Int($0)) }) ?? .string(text)
    case 0x02:  // SMALLINT
        return Int(text).map { .int($0) } ?? .string(text)
    case 0x03:  // INT
        return Int32(text).map { .int32($0) } ?? .string(text)
    case 0x08:  // BIGINT
        return Int64(text).map { .int64($0) } ?? .string(text)
    case 0x04:  // FLOAT
        return Float(text).map { .float($0) } ?? .string(text)
    case 0x05, 0x00: // DOUBLE, old DECIMAL
        return Double(text).map { .double($0) } ?? .string(text)
    case 0xF6:  // NEWDECIMAL (MySQL 5.0+)
        return Decimal(string: text).map { .decimal($0) } ?? .string(text)
    case 0x10:  // BIT
        return .bool(text != "0" && !text.isEmpty)
    case 0xFE where text.count == 36:  // CHAR(36) — likely UUID
        return UUID(uuidString: text).map { .uuid($0) } ?? .string(text)
    case 0x0A:  // DATE
        return _mysqlDateFmt.date(from: text).map { .date($0) } ?? .string(text)
    case 0x0B, 0x0C, 0x07: // TIME, DATETIME, TIMESTAMP
        return _mysqlDateTimeFmt.date(from: text).map { .date($0) } ?? .string(text)
    default:
        return .string(text)
    }
}
