import XCTest
import MSSQLNio

// ── Integration test gate ─────────────────────────────────────────────────────
//
// Integration tests are skipped unless the environment variables below are set.
// When running against the Docker SQL Server on localhost use:
//
//   MSSQL_TEST_HOST=127.0.0.1 \
//   MSSQL_TEST_PORT=1433 \
//   MSSQL_TEST_USER=sa \
//   MSSQL_TEST_PASS=aBCD111 \
//   MSSQL_TEST_DB=MSSQLNioTestDb \
//   swift test --filter MSSQLNio
//
// Or simply set MSSQL_TEST_HOST=127.0.0.1 and the defaults fill in the rest.

struct TestDatabase {

    // MARK: - Connection configuration

    static var isAvailable: Bool { ProcessInfo.processInfo.environment["MSSQL_TEST_HOST"] != nil }

    static var configuration: MSSQLConnection.Configuration {
        let env = ProcessInfo.processInfo.environment
        return MSSQLConnection.Configuration(
            host:     env["MSSQL_TEST_HOST"] ?? "127.0.0.1",
            port:     Int(env["MSSQL_TEST_PORT"] ?? "1433") ?? 1433,
            database: env["MSSQL_TEST_DB"]   ?? "MSSQLNioTestDb",
            username: env["MSSQL_TEST_USER"] ?? "sa",
            password: env["MSSQL_TEST_PASS"] ?? "aBCD111"
        )
    }

    // MARK: - Helpers

    /// Open a fresh connection. Caller is responsible for closing it.
    static func connect() async throws -> MSSQLConnection {
        try await MSSQLConnection.connect(configuration: configuration)
    }

    /// Run a block with a managed connection (auto-closed on exit).
    static func withConnection<T>(
        _ body: (MSSQLConnection) async throws -> T
    ) async throws -> T {
        let conn = try await connect()
        defer { Task { try? await conn.close() } }
        return try await body(conn)
    }
}

// MARK: - XCTestCase extension

extension XCTestCase {

    /// Skip an integration test if no SQL Server env var is set.
    func skipUnlessIntegration(file: StaticString = #file, line: UInt = #line) throws {
        try XCTSkipUnless(
            TestDatabase.isAvailable,
            "Set MSSQL_TEST_HOST to run integration tests"
        )
    }

    /// Run an async throwing body as a synchronous XCTest.
    func runAsync(
        timeout: TimeInterval = 30,
        file: StaticString = #file, line: UInt = #line,
        _ body: @escaping @Sendable () async throws -> Void
    ) {
        let exp = expectation(description: "async")
        Task {
            do {
                try await body()
            } catch {
                XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
    }
}
