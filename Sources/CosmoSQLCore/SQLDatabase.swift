import Foundation

public protocol SQLDatabase: Sendable {
    func query(_ sql: String, _ binds: [SQLValue]) async throws -> [SQLRow]
    func execute(_ sql: String, _ binds: [SQLValue]) async throws -> Int
    func close() async throws
    var advanced: any AdvancedSQLDatabase { get }
}

public protocol AdvancedSQLDatabase: Sendable {
    func queryStream(_ sql: String, _ binds: [SQLValue]) -> AsyncThrowingStream<SQLRow, any Error>
    func queryJsonStream(_ sql: String, _ binds: [SQLValue]) -> AsyncThrowingStream<Data, any Error>
}

public extension SQLDatabase {
    func query(_ sql: String, _ binds: [SQLValue] = []) async throws -> [SQLRow] {
        return try await query(sql, binds)
    }
    func execute(_ sql: String, _ binds: [SQLValue] = []) async throws -> Int {
        return try await execute(sql, binds)
    }
    func query<T: Decodable>(_ sql: String, _ binds: [SQLValue] = [], as type: T.Type = T.self) async throws -> [T] {
        let rows = try await query(sql, binds)
        return try rows.map { row in try SQLRowDecoder().decode(T.self, from: row) }
    }
}

public extension AdvancedSQLDatabase {
    func queryStream(_ sql: String) -> AsyncThrowingStream<SQLRow, any Error> {
        return queryStream(sql, [])
    }
    func queryJsonStream(_ sql: String) -> AsyncThrowingStream<Data, any Error> {
        return queryJsonStream(sql, [])
    }
    func queryJsonStream(_ sql: String, _ binds: [SQLValue]) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { cont in
            cont.finish(throwing: SQLError.unsupported("JSON streaming not supported by this driver"))
        }
    }
}
