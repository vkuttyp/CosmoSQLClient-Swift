/// A single row returned by a SQL query.
///
/// Access values by column name or zero-based index:
/// ```swift
/// let name = try row["name"].require().asString()
/// let id   = row[0].asInt64()
/// ```
public struct SQLRow: Sendable {
    public let columns: [SQLColumn]
    public let values:  [SQLValue]

    public init(columns: [SQLColumn], values: [SQLValue]) {
        precondition(columns.count == values.count, "Column / value count mismatch")
        self.columns = columns
        self.values  = values
    }

    // MARK: - Subscript by index

    public subscript(index: Int) -> SQLValue {
        values[index]
    }

    // MARK: - Subscript by column name (case-insensitive)

    /// Returns the value for the first column whose name matches (case-insensitively).
    /// Returns `.null` if no such column exists.
    public subscript(column: String) -> SQLValue {
        let lower = column.lowercased()
        guard let idx = columns.firstIndex(where: { $0.name.lowercased() == lower }) else {
            return .null
        }
        return values[idx]
    }
}

// MARK: - Helpers

public extension SQLValue {
    /// Throws ``SQLError/columnNotFound(_:)`` when the value is `.null` and was
    /// produced by a missing column lookup.
    func require(column: String = "<unknown>") throws -> SQLValue {
        if case .null = self {
            throw SQLError.columnNotFound(column)
        }
        return self
    }
}
