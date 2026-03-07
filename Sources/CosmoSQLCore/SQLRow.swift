/// A result set returned by a SQL query, containing column metadata and zero or more rows.
public struct SQLResultSet: Sendable {
    public let columns: [SQLColumn]
    public let rows:    [SQLRow]

    public init(columns: [SQLColumn], rows: [SQLRow]) {
        self.columns = columns
        self.rows    = rows
    }

    public var isEmpty: Bool { rows.isEmpty }
    public var count: Int { rows.count }
    public subscript(index: Int) -> SQLRow { rows[index] }
}

/// A single row returned by a SQL query.
public struct SQLRow: Sendable {
    public let columns: [SQLColumn]
    public let values:  [SQLValue]

    public init(columns: [SQLColumn], values: [SQLValue]) {
        precondition(columns.count == values.count, "Column / value count mismatch")
        self.columns = columns
        self.values  = values
    }

    public subscript(index: Int) -> SQLValue {
        values[index]
    }

    public subscript(column: String) -> SQLValue {
        let lower = column.lowercased()
        guard let idx = columns.firstIndex(where: { $0.name.lowercased() == lower }) else {
            return .null
        }
        return values[idx]
    }
}

public extension SQLValue {
    func require(column: String = "<unknown>") throws -> SQLValue {
        if case .null = self {
            throw SQLError.columnNotFound(column)
        }
        return self
    }
}
