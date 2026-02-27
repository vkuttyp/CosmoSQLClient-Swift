/// Metadata for a single column returned by a query.
public struct SQLColumn: Sendable, Hashable {
    /// Column name as reported by the server.
    public let name: String
    /// Table name, if available.
    public let table: String?
    /// The raw data type identifier (driver-specific).
    public let dataTypeID: UInt32?
    /// Scale (decimal places) for numeric/decimal types; 0 for all others.
    public let scale: UInt8

    public init(name: String, table: String? = nil, dataTypeID: UInt32? = nil, scale: UInt8 = 0) {
        self.name = name
        self.table = table
        self.dataTypeID = dataTypeID
        self.scale = scale
    }
}
