import SQLNioCore
import Foundation

/// The full result of a stored procedure call via ``MSSQLConnection/callProcedure(_:parameters:)``.
public struct MSSQLProcResult: Sendable {

    /// All result sets returned by the procedure (one per SELECT statement).
    public let resultSets: [[SQLRow]]

    /// First result set — convenience shorthand for `resultSets.first ?? []`.
    public var rows: [SQLRow] { resultSets.first ?? [] }

    /// Output parameter values keyed by name **including** the leading `@`
    /// (e.g. `outputParameters["@NewId"]`).
    public let outputParameters: [String: SQLValue]

    /// Value from the procedure's `RETURN` statement, or `nil` if absent.
    public let returnStatus: Int?

    /// Total rows affected by DML statements inside the procedure.
    public let rowsAffected: Int

    /// Informational messages emitted by `PRINT` or low-severity `RAISERROR`.
    public let infoMessages: [(code: Int, message: String)]

    // MARK: - Decodable convenience

    /// Decode the first result set into an array of `T`.
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> [T] {
        try rows.map { try SQLRowDecoder().decode(T.self, from: $0) }
    }

    /// Decode result set at `index` into an array of `T`.
    public func decode<T: Decodable>(_ index: Int, as type: T.Type = T.self) throws -> [T] {
        guard index < resultSets.count else { return [] }
        return try resultSets[index].map { try SQLRowDecoder().decode(T.self, from: $0) }
    }
}
