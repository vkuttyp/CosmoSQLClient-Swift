import NIOCore
import SQLNioCore
import Foundation
import Crypto

// ── PostgreSQL message decoder ────────────────────────────────────────────────

struct PGRow {
    let columns: [PGColumnDesc]
    let values:  [ByteBuffer?]   // nil = NULL
}

struct PGColumnDesc {
    let name:       String
    let tableOID:   UInt32
    let attrNum:    Int16
    let typeOID:    UInt32
    let typeSize:   Int16
    let typeMod:    Int32
    let format:     Int16      // 0 = text, 1 = binary
}

struct PGCommandTag {
    let tag:          String
    let rowsAffected: Int

    init(raw: String) {
        tag = raw
        // Tags like "INSERT 0 1", "UPDATE 5", "SELECT 10"
        let parts = raw.split(separator: " ")
        rowsAffected = parts.last.flatMap { Int($0) } ?? 0
    }
}

// MARK: - Decoder

struct PGMessageDecoder {

    // MARK: - Parse a fully-framed backend message

    static func decode(buffer: inout ByteBuffer) throws -> PGBackendMessage {
        guard
            let typeByte: UInt8  = buffer.readInteger(),
            let length:   Int32  = buffer.readInteger(endianness: .big)
        else { throw PGError.incomplete }

        let bodyLen = Int(length) - 4   // length field includes itself
        guard bodyLen >= 0, var body = buffer.readSlice(length: bodyLen) else {
            throw PGError.incomplete
        }

        guard let msgType = PGBackendMessageType(rawValue: typeByte) else {
            throw PGError.unknownMessageType(typeByte)
        }
        return try decodeBody(type: msgType, body: &body)
    }

    private static func decodeBody(type: PGBackendMessageType,
                                   body: inout ByteBuffer) throws -> PGBackendMessage {
        switch type {
        case .authentication:
            guard let code: Int32 = body.readInteger(endianness: .big) else {
                throw PGError.incomplete
            }
            switch PGAuthType(rawValue: code) {
            case .ok:
                return .authOK
            case .clearTextPassword:
                return .authRequestClearText
            case .md5Password:
                guard let salt = body.readBytes(length: 4) else { throw PGError.incomplete }
                return .authRequestMD5(salt: salt)
            case .sasl:
                var mechanisms: [String] = []
                while let mech = body.readNullTerminatedString(), !mech.isEmpty {
                    mechanisms.append(mech)
                }
                return .authRequestSASL(mechanisms: mechanisms)
            case .saslContinue:
                let data = body.readBytes(length: body.readableBytes) ?? []
                return .authSASLContinue(data: data)
            case .saslFinal:
                let data = body.readBytes(length: body.readableBytes) ?? []
                return .authSASLFinal(data: data)
            default:
                return .authUnknown(code)
            }

        case .rowDescription:
            guard let count: Int16 = body.readInteger(endianness: .big) else {
                throw PGError.incomplete
            }
            var columns: [PGColumnDesc] = []
            for _ in 0..<count {
                let name     = body.readNullTerminatedString() ?? ""
                guard
                    let tableOID: UInt32 = body.readInteger(endianness: .big),
                    let attrNum:  Int16  = body.readInteger(endianness: .big),
                    let typeOID:  UInt32 = body.readInteger(endianness: .big),
                    let typeSize: Int16  = body.readInteger(endianness: .big),
                    let typeMod:  Int32  = body.readInteger(endianness: .big),
                    let format:   Int16  = body.readInteger(endianness: .big)
                else { throw PGError.incomplete }
                columns.append(PGColumnDesc(name: name, tableOID: tableOID,
                                            attrNum: attrNum, typeOID: typeOID,
                                            typeSize: typeSize, typeMod: typeMod,
                                            format: format))
            }
            return .rowDescription(columns)

        case .dataRow:
            guard let count: Int16 = body.readInteger(endianness: .big) else {
                throw PGError.incomplete
            }
            var values: [ByteBuffer?] = []
            for _ in 0..<count {
                guard let len: Int32 = body.readInteger(endianness: .big) else {
                    throw PGError.incomplete
                }
                if len == -1 {
                    values.append(nil)
                } else {
                    let slice = body.readSlice(length: Int(len))
                    values.append(slice)
                }
            }
            return .dataRow(values)

        case .commandComplete:
            let tag = body.readNullTerminatedString() ?? ""
            return .commandComplete(PGCommandTag(raw: tag))

        case .errorResponse:
            var fields: [UInt8: String] = [:]
            while let code: UInt8 = body.readInteger(), code != 0 {
                let value = body.readNullTerminatedString() ?? ""
                fields[code] = value
            }
            let message  = fields[0x4D] ?? "Unknown error"   // 'M' = message
            let severity = fields[0x53] ?? "ERROR"            // 'S' = severity
            let sqlState = fields[0x43] ?? "00000"            // 'C' = code
            return .error(severity: severity, sqlState: sqlState, message: message)

        case .noticeResponse:
            var fields: [UInt8: String] = [:]
            while let code: UInt8 = body.readInteger(), code != 0 {
                fields[code] = body.readNullTerminatedString() ?? ""
            }
            return .notice(fields[0x4D] ?? "")

        case .parameterStatus:
            let name  = body.readNullTerminatedString() ?? ""
            let value = body.readNullTerminatedString() ?? ""
            return .parameterStatus(name: name, value: value)

        case .readyForQuery:
            guard let status: UInt8 = body.readInteger() else { throw PGError.incomplete }
            return .readyForQuery(status: Character(UnicodeScalar(status)))

        case .backendKeyData:
            guard
                let pid: Int32 = body.readInteger(endianness: .big),
                let key: Int32 = body.readInteger(endianness: .big)
            else { throw PGError.incomplete }
            return .backendKeyData(pid: pid, secretKey: key)

        case .parseComplete:      return .parseComplete
        case .bindComplete:       return .bindComplete
        case .noData:             return .noData
        case .emptyQueryResponse: return .emptyQueryResponse
        case .portalSuspended:    return .portalSuspended

        default:
            // Skip unhandled message types
            return .unhandled(type.rawValue)
        }
    }
}

// MARK: - Backend message enum

enum PGBackendMessage {
    case authOK
    case authRequestClearText
    case authRequestMD5(salt: [UInt8])
    case authRequestSASL(mechanisms: [String])
    case authSASLContinue(data: [UInt8])
    case authSASLFinal(data: [UInt8])
    case authUnknown(Int32)
    case rowDescription([PGColumnDesc])
    case dataRow([ByteBuffer?])
    case commandComplete(PGCommandTag)
    case error(severity: String, sqlState: String, message: String)
    case notice(String)
    case parameterStatus(name: String, value: String)
    case readyForQuery(status: Character)
    case backendKeyData(pid: Int32, secretKey: Int32)
    case parseComplete
    case bindComplete
    case noData
    case emptyQueryResponse
    case portalSuspended
    case unhandled(UInt8)
}

// MARK: - MD5 auth helper

func pgMD5Password(user: String, password: String, salt: [UInt8]) -> String {
    // md5(md5(password + user) + salt)
    let inner = Insecure.MD5.hash(data: Data((password + user).utf8))
    let innerHex = inner.map { String(format: "%02x", $0) }.joined()
    let outer = Insecure.MD5.hash(data: Data((innerHex + String(bytes: salt, encoding: .utf8)!).utf8))
    let outerHex = outer.map { String(format: "%02x", $0) }.joined()
    return "md5" + outerHex
}

// MARK: - Protocol errors

enum PGError: Error {
    case incomplete
    case unknownMessageType(UInt8)
    case malformed(String)
}

// MARK: - ByteBuffer extension

private extension ByteBuffer {
    mutating func readNullTerminatedString() -> String? {
        guard let end = readableBytesView.firstIndex(of: 0) else { return nil }
        let len = end - readerIndex
        let str = readString(length: len)
        moveReaderIndex(forwardBy: 1)   // skip null byte
        return str
    }
}
