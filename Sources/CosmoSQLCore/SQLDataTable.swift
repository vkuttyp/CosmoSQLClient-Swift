import Foundation

// MARK: - SQLCellValue

/// A strongly-typed, Codable cell value for use in SQLDataTable.
/// Maps directly from SQLValue with JSON-round-trip fidelity.
public enum SQLCellValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case decimal(Decimal)
    case string(String)
    case bytes([UInt8])
    case uuid(UUID)
    case date(Date)

    /// Convert from SQLValue.
    public init(_ value: SQLValue) {
        switch value {
        case .null:              self = .null
        case .bool(let v):       self = .bool(v)
        case .int(let v):        self = .int(v)
        case .int8(let v):       self = .int(Int(v))
        case .int16(let v):      self = .int(Int(v))
        case .int32(let v):      self = .int(Int(v))
        case .int64(let v):      self = .int64(v)
        case .float(let v):      self = .double(Double(v))
        case .double(let v):     self = .double(v)
        case .decimal(let v):    self = .decimal(v)
        case .string(let v):     self = .string(v)
        case .bytes(let v):      self = .bytes(v)
        case .uuid(let v):       self = .uuid(v)
        case .date(let v):       self = .date(v)
        }
    }

    /// Convert back to SQLValue.
    public var sqlValue: SQLValue {
        switch self {
        case .null:           return .null
        case .bool(let v):    return .bool(v)
        case .int(let v):     return .int(v)
        case .int64(let v):   return .int64(v)
        case .double(let v):  return .double(v)
        case .decimal(let v): return .decimal(v)
        case .string(let v):  return .string(v)
        case .bytes(let v):   return .bytes(v)
        case .uuid(let v):    return .uuid(v)
        case .date(let v):    return .date(v)
        }
    }

    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Native value for use with JSONSerialization (nil = JSON null).
    var jsonValue: Any? {
        switch self {
        case .null:           return nil
        case .bool(let v):    return v
        case .int(let v):     return v
        case .int64(let v):   return v
        case .double(let v):  return v
        case .decimal(let v): return NSDecimalNumber(decimal: v)
        case .string(let v):  return v
        case .bytes(let v):   return Data(v).base64EncodedString()
        case .uuid(let v):    return v.uuidString
        case .date(let v):
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: v)
        }
    }

    /// Human-readable string for display / Markdown rendering.
    public var displayString: String {
        switch self {
        case .null:           return "NULL"
        case .bool(let v):    return v ? "true" : "false"
        case .int(let v):     return String(v)
        case .int64(let v):   return String(v)
        case .double(let v):  return String(v)
        case .decimal(let v): return "\(v)"
        case .string(let v):  return v
        case .bytes(let v):   return "0x" + v.map { String(format: "%02X", $0) }.joined()
        case .uuid(let v):    return v.uuidString
        case .date(let v):
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: v)
        }
    }
}

// MARK: - SQLCellValue: Codable

extension SQLCellValue: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:           try c.encode("null",    forKey: .type)
        case .bool(let v):    try c.encode("bool",    forKey: .type); try c.encode(v, forKey: .value)
        case .int(let v):     try c.encode("int",     forKey: .type); try c.encode(v, forKey: .value)
        case .int64(let v):   try c.encode("int64",   forKey: .type); try c.encode(v, forKey: .value)
        case .double(let v):  try c.encode("double",  forKey: .type); try c.encode(v, forKey: .value)
        case .decimal(let v): try c.encode("decimal", forKey: .type); try c.encode("\(v)", forKey: .value)
        case .string(let v):  try c.encode("string",  forKey: .type); try c.encode(v, forKey: .value)
        case .bytes(let v):   try c.encode("bytes",   forKey: .type); try c.encode(Data(v).base64EncodedString(), forKey: .value)
        case .uuid(let v):    try c.encode("uuid",    forKey: .type); try c.encode(v.uuidString, forKey: .value)
        case .date(let v):    try c.encode("date",    forKey: .type); try c.encode(v.timeIntervalSince1970, forKey: .value)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "null":    self = .null
        case "bool":    self = .bool(try c.decode(Bool.self,   forKey: .value))
        case "int":     self = .int(try c.decode(Int.self,     forKey: .value))
        case "int64":   self = .int64(try c.decode(Int64.self, forKey: .value))
        case "double":  self = .double(try c.decode(Double.self, forKey: .value))
        case "decimal":
            let s = try c.decode(String.self, forKey: .value)
            self = .decimal(Decimal(string: s) ?? 0)
        case "string":  self = .string(try c.decode(String.self, forKey: .value))
        case "bytes":
            let b64 = try c.decode(String.self, forKey: .value)
            self = .bytes([UInt8](Data(base64Encoded: b64) ?? Data()))
        case "uuid":
            let s = try c.decode(String.self, forKey: .value)
            self = .uuid(UUID(uuidString: s) ?? UUID())
        case "date":
            let ts = try c.decode(Double.self, forKey: .value)
            self = .date(Date(timeIntervalSince1970: ts))
        default:        self = .null
        }
    }
}

// MARK: - SQLDataColumn

public struct SQLDataColumn: Sendable, Codable, Equatable {
    public let name:  String
    public let table: String?
    public init(name: String, table: String? = nil) {
        self.name  = name
        self.table = table
    }
}

// MARK: - SQLDataTable

/// A named, typed result table — the sql-nio equivalent of .NET DataTable.
/// Built from `[SQLRow]`; provides column/row access, Markdown rendering,
/// Codable serialization, and automatic Decodable mapping.
public struct SQLDataTable: Sendable {

    // MARK: Public state

    public let name:    String?
    public let columns: [SQLDataColumn]
    public let rows:    [[SQLCellValue]]

    // MARK: Dimensions

    public var rowCount:    Int { rows.count }
    public var columnCount: Int { columns.count }

    // MARK: Init from SQLRows

    public init(name: String? = nil, rows sqlRows: [SQLRow]) {
        self.name    = name
        self.columns = (sqlRows.first?.columns ?? []).map {
            SQLDataColumn(name: $0.name, table: $0.table)
        }
        self.rows = sqlRows.map { row in row.values.map { SQLCellValue($0) } }
    }

    // MARK: Subscript access

    /// Access a cell by row index and column index.
    public subscript(row: Int, column: Int) -> SQLCellValue {
        guard rows.indices.contains(row),
              rows[row].indices.contains(column) else { return .null }
        return rows[row][column]
    }

    /// Access a cell by row index and column name (case-insensitive).
    public subscript(row: Int, column: String) -> SQLCellValue {
        guard let idx = columnIndex(for: column) else { return .null }
        return self[row, idx]
    }

    // MARK: Row / column helpers

    /// Returns the row at the given index as a name → value dictionary.
    public func row(at index: Int) -> [String: SQLCellValue] {
        guard rows.indices.contains(index) else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(columns.map(\.name), rows[index]))
    }

    /// Returns all values for the named column across every row.
    public func column(named name: String) -> [SQLCellValue] {
        guard let idx = columnIndex(for: name) else { return [] }
        return rows.map { $0.indices.contains(idx) ? $0[idx] : .null }
    }

    // MARK: Conversion

    /// Convert back to `[SQLRow]` for use with other sql-nio APIs.
    public func toSQLRows() -> [SQLRow] {
        let cols = columns.map { SQLColumn(name: $0.name, table: $0.table) }
        return rows.map { cells in
            SQLRow(columns: cols, values: cells.map(\.sqlValue))
        }
    }

    // MARK: Decodable mapping

    /// Decode all rows into an array of the given `Decodable` type.
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> [T] {
        let decoder = SQLRowDecoder()
        return try toSQLRows().map { try decoder.decode(T.self, from: $0) }
    }

    // MARK: JSON rendering

    /// Renders the table as a JSON array of objects (column name → native value).
    /// SQL NULL becomes JSON `null`. Dates are ISO-8601 strings.
    public func toJson(pretty: Bool = true) -> String {
        let array = rows.map { row -> [String: Any?] in
            Dictionary(uniqueKeysWithValues: zip(columns.map(\.name), row.map(\.jsonValue)))
        }
        // JSONSerialization needs [String: Any] with NSNull for nulls
        let sanitized = array.map { dict in
            dict.mapValues { $0 ?? NSNull() as Any }
        }
        let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : []
        let data = (try? JSONSerialization.data(withJSONObject: sanitized, options: opts)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: Markdown rendering

    /// Renders the table as a GitHub-flavored Markdown table string.
    public func toMarkdown() -> String {
        guard !columns.isEmpty else { return "" }

        // Compute column widths
        var widths = columns.map(\.name.count)
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.displayString.replacingOccurrences(of: "|", with: "\\|").count)
            }
        }

        func pad(_ s: String, _ w: Int) -> String { s + String(repeating: " ", count: max(0, w - s.count)) }

        var lines: [String] = []
        // Header
        lines.append("| " + zip(columns, widths).map { pad($0.name, $1) }.joined(separator: " | ") + " |")
        // Separator
        lines.append("| " + widths.map { String(repeating: "-", count: $0) }.joined(separator: " | ") + " |")
        // Rows
        for row in rows {
            let cells = columns.indices.map { i -> String in
                let raw = i < row.count ? row[i].displayString : ""
                let escaped = raw.replacingOccurrences(of: "|", with: "\\|")
                return pad(escaped, widths[i])
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Private helpers

    private func columnIndex(for name: String) -> Int? {
        let lower = name.lowercased()
        return columns.firstIndex { $0.name.lowercased() == lower }
    }
}

// MARK: - SQLDataTable: Codable

extension SQLDataTable: Codable {
    private enum CodingKeys: String, CodingKey { case name, columns, rows }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(columns, forKey: .columns)
        try c.encode(rows, forKey: .rows)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name    = try c.decodeIfPresent(String.self, forKey: .name)
        self.columns = try c.decode([SQLDataColumn].self, forKey: .columns)
        self.rows    = try c.decode([[SQLCellValue]].self, forKey: .rows)
    }
}

// MARK: - SQLDataSet

/// A collection of named SQLDataTables — the sql-nio equivalent of .NET DataSet.
public struct SQLDataSet: Sendable, Codable {

    public let tables: [SQLDataTable]

    public var count: Int { tables.count }

    public init(tables: [SQLDataTable]) { self.tables = tables }

    /// Access table by index.
    public subscript(index: Int) -> SQLDataTable? {
        tables.indices.contains(index) ? tables[index] : nil
    }

    /// Access table by name (case-insensitive).
    public subscript(name: String) -> SQLDataTable? {
        let lower = name.lowercased()
        return tables.first { $0.name?.lowercased() == lower }
    }
}

// MARK: - Convenience extensions on result types

extension Array where Element == SQLRow {
    /// Convert to a `SQLDataTable` with an optional name.
    public func asDataTable(name: String? = nil) -> SQLDataTable {
        SQLDataTable(name: name, rows: self)
    }
}

extension Array where Element == [SQLRow] {
    /// Convert multi-result-set rows to a `SQLDataSet`.
    public func asDataSet(names: [String?]? = nil) -> SQLDataSet {
        let tables = enumerated().map { (i, rows) in
            SQLDataTable(name: names?[safe: i] ?? nil, rows: rows)
        }
        return SQLDataSet(tables: tables)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
