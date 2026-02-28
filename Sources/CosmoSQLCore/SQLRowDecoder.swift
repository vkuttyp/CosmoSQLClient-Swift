import Foundation

// ── SQLRowDecoder ─────────────────────────────────────────────────────────────
//
// Decodes a SQLRow into any Decodable type.
//
// Usage:
// ```swift
// struct User: Decodable {
//     let id: Int
//     let name: String
//     let email: String?
//     let createdAt: Date
// }
// let users = try await conn.query("SELECT id, name, email, created_at FROM users", as: User.self)
// ```
//
// Column name matching:
//   1. Exact match (case-insensitive)
//   2. snake_case ↔ camelCase conversion  (created_at ↔ createdAt)
//
// Type coercion:
//   - Any integer SQLValue → Int / Int32 / Int64 / UInt / etc. (widening)
//   - Any numeric SQLValue → Float / Double (widening)
//   - .string → Bool ("true"/"1"/"yes"), Date (ISO8601), UUID, URL
//   - .null    → Optional<T>.none (throws if non-optional)

public struct SQLRowDecoder {
    public var keyDecodingStrategy: KeyDecodingStrategy = .convertFromSnakeCase

    public enum KeyDecodingStrategy {
        case useDefaultKeys          // exact match only (case-insensitive)
        case convertFromSnakeCase    // also try snake_case ↔ camelCase
    }

    public init(keyDecodingStrategy: KeyDecodingStrategy = .convertFromSnakeCase) {
        self.keyDecodingStrategy = keyDecodingStrategy
    }

    /// Decode a single row into `T`.
    public func decode<T: Decodable>(_ type: T.Type = T.self, from row: SQLRow) throws -> T {
        let decoder = _RowDecoder(row: row, strategy: keyDecodingStrategy)
        return try T(from: decoder)
    }
}

// MARK: - Internal row decoder

private final class _RowDecoder: Decoder {
    let row: SQLRow
    let strategy: SQLRowDecoder.KeyDecodingStrategy
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    init(row: SQLRow, strategy: SQLRowDecoder.KeyDecodingStrategy) {
        self.row = row
        self.strategy = strategy
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(_KeyedContainer(decoder: self))
    }
    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch([Any].self,
            DecodingError.Context(codingPath: codingPath,
                                  debugDescription: "SQLRowDecoder does not support unkeyed containers"))
    }
    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        throw DecodingError.typeMismatch(Any.self,
            DecodingError.Context(codingPath: codingPath,
                                  debugDescription: "SQLRowDecoder does not support single-value containers at top level"))
    }

    /// Find the SQLValue for a given coding key, trying multiple name variations.
    func value(for key: any CodingKey) -> SQLValue? {
        let candidates = nameCandidates(for: key.stringValue)
        for name in candidates {
            let lower = name.lowercased()
            if let idx = row.columns.firstIndex(where: { $0.name.lowercased() == lower }) {
                return row.values[idx]
            }
        }
        return nil
    }

    private func nameCandidates(for key: String) -> [String] {
        var result = [key]
        if strategy == .convertFromSnakeCase {
            result.append(contentsOf: [
                toSnakeCase(key),       // camelCase → snake_case
                toCamelCase(key),       // snake_case → camelCase
            ])
        }
        return result
    }

    private func toSnakeCase(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var result = ""
        for (i, c) in s.enumerated() {
            if c.isUppercase, i > 0 {
                result.append("_")
            }
            result.append(c.lowercased())
        }
        return result
    }

    private func toCamelCase(_ s: String) -> String {
        let parts = s.split(separator: "_", omittingEmptySubsequences: true)
        guard let first = parts.first else { return s }
        return parts.dropFirst().reduce(String(first)) { $0 + $1.capitalized }
    }
}

// MARK: - Keyed container

private struct _KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: _RowDecoder
    var codingPath: [any CodingKey] { decoder.codingPath }
    var allKeys: [Key] {
        decoder.row.columns.compactMap { Key(stringValue: $0.name) }
    }

    func contains(_ key: Key) -> Bool { decoder.value(for: key) != nil }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let v = decoder.value(for: key) else { return true }
        if case .null = v { return true }
        return false
    }

    func decode(_ type: Bool.Type,   forKey key: Key) throws -> Bool   { try decode(key: key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try decode(key: key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try decode(key: key) }
    func decode(_ type: Float.Type,  forKey key: Key) throws -> Float  { try decode(key: key) }
    func decode(_ type: Int.Type,    forKey key: Key) throws -> Int    { try decode(key: key) }
    func decode(_ type: Int8.Type,   forKey key: Key) throws -> Int8   { try decode(key: key) }
    func decode(_ type: Int16.Type,  forKey key: Key) throws -> Int16  { try decode(key: key) }
    func decode(_ type: Int32.Type,  forKey key: Key) throws -> Int32  { try decode(key: key) }
    func decode(_ type: Int64.Type,  forKey key: Key) throws -> Int64  { try decode(key: key) }
    func decode(_ type: UInt.Type,   forKey key: Key) throws -> UInt   { try decode(key: key) }
    func decode(_ type: UInt8.Type,  forKey key: Key) throws -> UInt8  { try decode(key: key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try decode(key: key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try decode(key: key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try decode(key: key) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let v = try requireValue(for: key)

        // Direct type matches
        if T.self == UUID.self,    let u = v.asUUID()   { return u as! T }
        if T.self == Date.self,    let d = v.asDate()   { return d as! T }
        if T.self == URL.self,     let s = v.asString(), let u = URL(string: s) { return u as! T }
        if T.self == Data.self {
            if case .bytes(let b) = v { return Data(b) as! T }
            if let s = v.asString(), let d = Data(base64Encoded: s) { return d as! T }
        }
        // Date from string
        if T.self == Date.self, let s = v.asString() {
            if let d = parseDate(s) { return d as! T }
        }
        // UUID from string
        if T.self == UUID.self, let s = v.asString(), let u = UUID(uuidString: s) { return u as! T }
        // Decimal — intercept before T.init(from:) to avoid Decimal's own keyed Codable format
        if T.self == Decimal.self {
            if case .decimal(let d) = v { return d as! T }
            if let d = v.asDouble() { return Decimal(d) as! T }
            if let s = v.asString(), let d = Decimal(string: s) { return d as! T }
        }

        // Nested Decodable
        let child = _RowDecoder(row: decoder.row, strategy: decoder.strategy)
        child.codingPath = codingPath + [key]
        return try T(from: child)
    }

    func nestedContainer<NK: CodingKey>(keyedBy type: NK.Type, forKey key: Key) throws -> KeyedDecodingContainer<NK> {
        throw DecodingError.typeMismatch(Any.self, context(key, "Nested containers not supported"))
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch(Any.self, context(key, "Nested unkeyed containers not supported"))
    }
    func superDecoder() throws -> any Decoder { decoder }
    func superDecoder(forKey key: Key) throws -> any Decoder { decoder }

    // MARK: - Helpers

    private func requireValue(for key: Key) throws -> SQLValue {
        guard let v = decoder.value(for: key) else {
            throw DecodingError.keyNotFound(key,
                DecodingError.Context(codingPath: codingPath,
                                      debugDescription: "Column '\(key.stringValue)' not found"))
        }
        return v
    }

    /// Generic decode for primitive types with widening coercion.
    private func decode<T>(key: Key) throws -> T {
        let v = try requireValue(for: key)
        if case .null = v {
            throw DecodingError.valueNotFound(T.self,
                DecodingError.Context(codingPath: codingPath + [key],
                                      debugDescription: "Expected \(T.self), got null"))
        }
        if let result = coerce(v, to: T.self) { return result }
        throw DecodingError.typeMismatch(T.self, context(key, "Cannot convert \(v) to \(T.self)"))
    }

    private func coerce<T>(_ v: SQLValue, to type: T.Type) -> T? {
        // Numeric widening: any integer or float → requested numeric type
        let intVal: Int64? = {
            switch v {
            case .int(let x):   return Int64(x)
            case .int8(let x):  return Int64(x)
            case .int16(let x): return Int64(x)
            case .int32(let x): return Int64(x)
            case .int64(let x): return x
            case .bool(let x):  return x ? 1 : 0
            case .string(let s): return Int64(s)
            default: return nil
            }
        }()
        let dblVal: Double? = {
            switch v {
            case .double(let x):  return x
            case .float(let x):   return Double(x)
            case .decimal(let x): return NSDecimalNumber(decimal: x).doubleValue
            case .string(let s):  return Double(s)
            default: return intVal.map(Double.init)
            }
        }()
        let decVal: Decimal? = {
            switch v {
            case .decimal(let x): return x
            case .double(let x):  return Decimal(x)
            case .float(let x):   return Decimal(Double(x))
            case .string(let s):  return Decimal(string: s)
            default: return intVal.map { Decimal($0) }
            }
        }()

        switch type {
        case is Bool.Type:
            if case .bool(let b) = v { return b as? T }
            if let i = intVal { return (i != 0) as? T }
            if let s = v.asString() { return ["true","yes","1"].contains(s.lowercased()) as? T }
        case is String.Type:
            switch v {
            case .string(let s):  return s as? T
            case .bool(let b):    return (b ? "true" : "false") as? T
            case .int(let i):     return "\(i)" as? T
            case .int32(let i):   return "\(i)" as? T
            case .int64(let i):   return "\(i)" as? T
            case .double(let d):  return "\(d)" as? T
            case .decimal(let d): return (d as NSDecimalNumber).stringValue as? T
            case .uuid(let u):    return u.uuidString as? T
            case .date(let d):    return ISO8601DateFormatter().string(from: d) as? T
            default:              return nil
            }
        case is Decimal.Type: return decVal as? T
        case is Int.Type:    return intVal.flatMap { Int(exactly: $0) } as? T
        case is Int8.Type:   return intVal.flatMap { Int8(exactly: $0) } as? T
        case is Int16.Type:  return intVal.flatMap { Int16(exactly: $0) } as? T
        case is Int32.Type:  return intVal.flatMap { Int32(exactly: $0) } as? T
        case is Int64.Type:  return intVal as? T
        case is UInt.Type:   return intVal.flatMap { $0 >= 0 ? UInt(exactly: $0) : nil } as? T
        case is UInt8.Type:  return intVal.flatMap { $0 >= 0 ? UInt8(exactly: $0) : nil } as? T
        case is UInt16.Type: return intVal.flatMap { $0 >= 0 ? UInt16(exactly: $0) : nil } as? T
        case is UInt32.Type: return intVal.flatMap { $0 >= 0 ? UInt32(exactly: $0) : nil } as? T
        case is UInt64.Type: return intVal.flatMap { $0 >= 0 ? UInt64(exactly: $0) : nil } as? T
        case is Float.Type:  return dblVal.map { Float($0) } as? T
        case is Double.Type: return dblVal as? T
        default:             return nil
        }
        return nil
    }

    private func parseDate(_ s: String) -> Date? {
        let formatters: [DateFormatter] = [
            { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"; return f }(),
            { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }(),
            { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }(),
        ]
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        for f in formatters { if let d = f.date(from: s) { return d } }
        return nil
    }

    private func context(_ key: Key, _ msg: String) -> DecodingError.Context {
        DecodingError.Context(codingPath: codingPath + [key], debugDescription: msg)
    }
}
