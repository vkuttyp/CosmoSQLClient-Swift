import Foundation

/// A named, optionally output-capable parameter for stored procedure calls.
///
/// Usage:
/// ```swift
/// let params: [SQLParameter] = [
///     SQLParameter(.int32(42), name: "@EmployeeId"),
///     SQLParameter(.null,      name: "@Result", isOutput: true),
/// ]
/// let result = try await conn.callProcedure("GetEmployee", parameters: params)
/// print(result.outputParameters["@Result"] ?? .null)
/// ```
public struct SQLParameter: Sendable {
    /// Parameter name including the leading `@` (e.g. `"@EmployeeId"`).
    public var name:     String
    /// The value to send. Use `.null` for OUTPUT-only parameters.
    public var value:    SQLValue
    /// When `true`, the server will populate this parameter on return.
    public var isOutput: Bool

    public init(_ value: SQLValue, name: String, isOutput: Bool = false) {
        self.name     = name
        self.value    = value
        self.isOutput = isOutput
    }

    /// Convenience: declare an OUTPUT parameter. Pass a typed placeholder (e.g. `.string("")`, `.int32(0)`)
    /// so SQL Server knows the output buffer type. Defaults to `.null` (INT) if no type hint needed.
    public static func output(_ name: String, type value: SQLValue = .null) -> SQLParameter {
        SQLParameter(value, name: name, isOutput: true)
    }
}
