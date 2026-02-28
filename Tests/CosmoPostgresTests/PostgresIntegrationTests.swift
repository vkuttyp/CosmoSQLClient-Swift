// PostgresIntegrationTests.swift
//
// Comprehensive integration tests for PostgresNio driver.
//
// Requires the Docker container:
//   docker run -d --name pg-nio-test \
//     -e POSTGRES_DB=PostgresNioTestDb \
//     -e POSTGRES_USER=pguser \
//     -e POSTGRES_PASSWORD=pgPass123 \
//     -p 5432:5432 postgres:16-alpine
//
// Run with:
//   PG_TEST_HOST=127.0.0.1 swift test --filter PostgresNio

import XCTest
@testable import CosmoPostgres
import CosmoSQLCore

// MARK: - Test support

struct PGTestDatabase {

    static var isAvailable: Bool {
        ProcessInfo.processInfo.environment["PG_TEST_HOST"] != nil
    }

    static var configuration: PostgresConnection.Configuration {
        let env = ProcessInfo.processInfo.environment
        return PostgresConnection.Configuration(
            host:     env["PG_TEST_HOST"]  ?? "127.0.0.1",
            port:     Int(env["PG_TEST_PORT"] ?? "5432") ?? 5432,
            database: env["PG_TEST_DB"]    ?? "PostgresNioTestDb",
            username: env["PG_TEST_USER"]  ?? "pguser",
            password: env["PG_TEST_PASS"]  ?? "pgPass123",
            tls:      .disable
        )
    }

    static func connect() async throws -> PostgresConnection {
        try await PostgresConnection.connect(configuration: configuration)
    }

    static func withConnection<T>(
        _ body: (PostgresConnection) async throws -> T
    ) async throws -> T {
        let conn = try await connect()
        defer { Task { try? await conn.close() } }
        return try await body(conn)
    }
}

extension XCTestCase {
    func skipUnlessPG(file: StaticString = #file, line: UInt = #line) throws {
        try XCTSkipUnless(PGTestDatabase.isAvailable,
                          "Set PG_TEST_HOST to run PostgreSQL integration tests")
    }

    func pgRunAsync(
        timeout: TimeInterval = 30,
        file: StaticString = #file, line: UInt = #line,
        _ body: @escaping @Sendable () async throws -> Void
    ) {
        let exp = expectation(description: "pg-async")
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

// MARK: - Connection Tests

final class PGConnectionTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testBasicConnect() {
        pgRunAsync {
            let conn = try await PGTestDatabase.connect()
            try? await conn.close()
        }
    }

    func testConnectWithWrongPasswordFails() {
        pgRunAsync {
            var bad = PGTestDatabase.configuration
            bad.password = "WRONG_PASSWORD"
            do {
                _ = try await PostgresConnection.connect(configuration: bad)
                XCTFail("Expected auth failure")
            } catch SQLError.authenticationFailed {
                // expected
            }
        }
    }

    func testConnectionClosedThrows() {
        pgRunAsync {
            let conn = try await PGTestDatabase.connect()
            try? await conn.close()
            do {
                _ = try await conn.query("SELECT 1", [])
                XCTFail("Expected connectionClosed")
            } catch SQLError.connectionClosed {
                // expected
            }
        }
    }
}

// MARK: - Basic Query Tests

final class PGBasicQueryTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testSelectScalarInt() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT 42 AS answer", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["answer"].asInt32(), 42)
            }
        }
    }

    func testSelectScalarString() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT 'Hello Postgres' AS msg", [])
                XCTAssertEqual(rows[0]["msg"].asString(), "Hello Postgres")
            }
        }
    }

    func testSelectNull() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT NULL AS val", [])
                XCTAssertEqual(rows[0]["val"], .null)
            }
        }
    }

    func testSelectBoolTrue() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT TRUE AS flag", [])
                XCTAssertEqual(rows[0]["flag"].asBool(), true)
            }
        }
    }

    func testSelectBoolFalse() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT FALSE AS flag", [])
                XCTAssertEqual(rows[0]["flag"].asBool(), false)
            }
        }
    }

    func testSelectFloat() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT 3.14::float8 AS pi", [])
                let pi = rows[0]["pi"].asDouble() ?? 0
                XCTAssertEqual(pi, 3.14, accuracy: 0.001)
            }
        }
    }

    func testSelectMultipleRows() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT generate_series(1,5) AS n", [])
                XCTAssertEqual(rows.count, 5)
                let nums = rows.compactMap { $0["n"].asInt32() }
                XCTAssertEqual(nums, [1, 2, 3, 4, 5])
            }
        }
    }

    func testSelectEmptyResult() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT 1 WHERE FALSE", [])
                XCTAssertEqual(rows.count, 0)
            }
        }
    }

    func testSelectMultipleColumns() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT 1 AS a, 'hello' AS b, TRUE AS c", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["a"].asInt32(), 1)
                XCTAssertEqual(rows[0]["b"].asString(), "hello")
                XCTAssertEqual(rows[0]["c"].asBool(), true)
            }
        }
    }

    func testSelectCurrentTimestamp() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT NOW() AS ts", [])
                XCTAssertNotNil(rows[0]["ts"].asDate() ?? rows[0]["ts"].asString())
            }
        }
    }
}

// MARK: - Parameterized Query Tests

final class PGParameterizedTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testStringParameter() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT $1 AS name", [.string("Alice")])
                XCTAssertEqual(rows[0]["name"].asString(), "Alice")
            }
        }
    }

    func testIntParameter() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT $1 + $2 AS total", [.int32(10), .int32(20)])
                XCTAssertEqual(rows[0]["total"].asInt32(), 30)
            }
        }
    }

    func testNullParameter() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT $1 AS val", [.null])
                XCTAssertEqual(rows[0]["val"], .null)
            }
        }
    }

    func testBoolParameter() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT $1::boolean AS flag", [.bool(true)])
                XCTAssertEqual(rows[0]["flag"].asBool(), true)
            }
        }
    }

    func testFloatParameter() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT $1::float8 AS val", [.double(2.718)])
                let v = rows[0]["val"].asDouble() ?? 0
                XCTAssertEqual(v, 2.718, accuracy: 0.001)
            }
        }
    }

    func testSpecialCharInString() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT $1 AS name", [.string("O'Brien & Co")])
                XCTAssertEqual(rows[0]["name"].asString(), "O'Brien & Co")
            }
        }
    }
}

// MARK: - Data Type Tests

final class PGDataTypeTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testBoolType() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_bool FROM type_samples WHERE id = 1", [])
                XCTAssertEqual(rows[0]["col_bool"].asBool(), true)
            }
        }
    }

    func testSmallintType() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_int2 FROM type_samples WHERE id = 1", [])
                // int2 decoded as .int
                let v = rows[0]["col_int2"].asInt() ?? Int(rows[0]["col_int2"].asInt32() ?? 0)
                XCTAssertEqual(v, 32767)
            }
        }
    }

    func testIntType() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_int4 FROM type_samples WHERE id = 1", [])
                XCTAssertEqual(rows[0]["col_int4"].asInt32(), 2147483647)
            }
        }
    }

    func testBigintType() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_int8 FROM type_samples WHERE id = 1", [])
                XCTAssertEqual(rows[0]["col_int8"].asInt64(), 9223372036854775807)
            }
        }
    }

    func testFloat4Type() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_float4 FROM type_samples WHERE id = 1", [])
                let v = rows[0]["col_float4"].asFloat() ?? rows[0]["col_float4"].asDouble().map { Float($0) } ?? 0
                XCTAssertEqual(v, 3.14, accuracy: 0.01)
            }
        }
    }

    func testFloat8Type() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_float8 FROM type_samples WHERE id = 1", [])
                let v = rows[0]["col_float8"].asDouble() ?? 0
                XCTAssertEqual(v, 2.718281828, accuracy: 0.000000001)
            }
        }
    }

    func testNumericType() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_numeric FROM type_samples WHERE id = 1", [])
                // Numeric comes back as string in text protocol
                let raw = rows[0]["col_numeric"]
                let strVal = raw.asString() ?? (raw.asDecimal().map { "\($0)" } ?? "")
                XCTAssertTrue(strVal.hasPrefix("99999.9999"), "Got: \(strVal)")
            }
        }
    }

    func testTextType() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_text FROM type_samples WHERE id = 1", [])
                XCTAssertEqual(rows[0]["col_text"].asString(), "Hello PostgreSQL")
            }
        }
    }

    func testVarcharType() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_varchar FROM type_samples WHERE id = 1", [])
                XCTAssertEqual(rows[0]["col_varchar"].asString(), "VarChar Value")
            }
        }
    }

    func testDateType() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_date FROM type_samples WHERE id = 1", [])
                let val = rows[0]["col_date"]
                // Date may come as .date or .string depending on OID handling
                let dateStr = val.asDate().map { d -> String in
                    let cal = Calendar(identifier: .gregorian)
                    let comps = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: d)
                    return "\(comps.year!)-\(comps.month!)-\(comps.day!)"
                } ?? val.asString() ?? ""
                XCTAssertTrue(dateStr.hasPrefix("2025"), "Expected 2025 date, got: \(dateStr)")
            }
        }
    }

    func testTimestampType() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_ts FROM type_samples WHERE id = 1", [])
                let val = rows[0]["col_ts"]
                // Timestamp may decode as .date or .string
                XCTAssertNotNil(val.asDate() ?? val.asString().map { $0 as Any? } ?? nil,
                                "Expected non-null timestamp")
            }
        }
    }

    func testUUIDType() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_uuid FROM type_samples WHERE id = 1", [])
                let val = rows[0]["col_uuid"]
                let uuidStr = val.asUUID()?.uuidString ?? val.asString() ?? ""
                XCTAssertTrue(uuidStr.lowercased().contains("a0eebc99"), "Got: \(uuidStr)")
            }
        }
    }

    func testNullableColumn() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                // Insert a row with NULLs
                _ = try await conn.execute(
                    "INSERT INTO type_samples (col_text) VALUES ('null-test')", [])
                let rows = try await conn.query(
                    "SELECT col_bool, col_int4 FROM type_samples WHERE col_text = 'null-test'", [])
                XCTAssertEqual(rows[0]["col_bool"], .null)
                XCTAssertEqual(rows[0]["col_int4"], .null)
                // Clean up
                _ = try await conn.execute(
                    "DELETE FROM type_samples WHERE col_text = 'null-test'", [])
            }
        }
    }
}

// MARK: - Table Query Tests

final class PGTableQueryTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testSelectAllDepartments() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id, name, active FROM departments ORDER BY id", [])
                XCTAssertEqual(rows.count, 5)
                XCTAssertEqual(rows[0]["name"].asString(), "Engineering")
                XCTAssertEqual(rows[0]["active"].asBool(), true)
                XCTAssertEqual(rows[4]["name"].asString(), "Operations")
                XCTAssertEqual(rows[4]["active"].asBool(), false)
            }
        }
    }

    func testSelectWithWhere() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT name FROM employees WHERE department_id = 1 ORDER BY name", [])
                XCTAssertEqual(rows.count, 3)
                XCTAssertEqual(rows[0]["name"].asString(), "Alice Johnson")
            }
        }
    }

    func testSelectWithJoin() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT e.name AS emp_name, d.name AS dept_name
                    FROM employees e
                    JOIN departments d ON e.department_id = d.id
                    WHERE e.is_manager = TRUE
                    ORDER BY e.name
                """, [])
                XCTAssertGreaterThan(rows.count, 0)
                // All should have dept_name
                for row in rows {
                    XCTAssertNotNil(row["dept_name"].asString())
                }
            }
        }
    }

    func testSelectWithAggregate() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT COUNT(*) AS cnt FROM employees", [])
                XCTAssertEqual(rows[0]["cnt"].asInt64() ?? Int64(rows[0]["cnt"].asInt32() ?? 0), 8)
            }
        }
    }

    func testSelectWithGroupBy() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT department_id, COUNT(*) AS cnt
                    FROM employees
                    GROUP BY department_id
                    ORDER BY department_id
                """, [])
                XCTAssertEqual(rows.count, 5)
                // Engineering has 3 employees
                XCTAssertEqual(rows[0]["cnt"].asInt64() ?? Int64(rows[0]["cnt"].asInt32() ?? 0), 3)
            }
        }
    }

    func testSelectWithOrderByDesc() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT name, salary FROM employees ORDER BY salary DESC LIMIT 3", [])
                XCTAssertEqual(rows.count, 3)
                XCTAssertEqual(rows[0]["name"].asString(), "Alice Johnson")
            }
        }
    }

    func testSelectWithLimit() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id FROM products ORDER BY id LIMIT 3", [])
                XCTAssertEqual(rows.count, 3)
            }
        }
    }

    func testSelectWithParameterFilter() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT name FROM employees WHERE department_id = $1 ORDER BY name",
                    [.int32(1)])
                XCTAssertEqual(rows.count, 3)
            }
        }
    }

    func testSelectActiveProducts() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT name FROM products WHERE active = $1 ORDER BY id",
                    [.bool(true)])
                XCTAssertEqual(rows.count, 5)
                // PROD-006 (Discontinued) is not active
                let names = rows.compactMap { $0["name"].asString() }
                XCTAssertFalse(names.contains("Discontinued"))
            }
        }
    }

    func testComplexJoinQuery() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT o.id AS order_id, e.name AS employee, 
                           COUNT(oi.id) AS item_count, o.total_amount
                    FROM orders o
                    JOIN employees e ON o.employee_id = e.id
                    JOIN order_items oi ON o.id = oi.order_id
                    GROUP BY o.id, e.name, o.total_amount
                    ORDER BY o.id
                """, [])
                XCTAssertGreaterThan(rows.count, 0)
                for row in rows {
                    XCTAssertNotNil(row["employee"].asString())
                    XCTAssertNotNil(row["total_amount"].asString() ?? row["total_amount"].asDouble().map { "\($0)" })
                }
            }
        }
    }
}

// MARK: - DML Tests (INSERT / UPDATE / DELETE)

final class PGDMLTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testInsertAndSelect() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let affected = try await conn.execute("""
                    INSERT INTO departments (name, budget, active)
                    VALUES ('Test Dept', 50000.00, TRUE)
                """, [])
                XCTAssertEqual(affected, 1)

                let rows = try await conn.query(
                    "SELECT name, budget FROM departments WHERE name = 'Test Dept'", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["name"].asString(), "Test Dept")

                // Clean up
                _ = try await conn.execute(
                    "DELETE FROM departments WHERE name = 'Test Dept'", [])
            }
        }
    }

    func testInsertWithParameters() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let affected = try await conn.execute(
                    "INSERT INTO departments (name, budget) VALUES ($1, $2)",
                    [.string("Param Dept"), .double(75000.0)])
                XCTAssertEqual(affected, 1)

                let rows = try await conn.query(
                    "SELECT name FROM departments WHERE name = $1",
                    [.string("Param Dept")])
                XCTAssertEqual(rows.count, 1)

                _ = try await conn.execute(
                    "DELETE FROM departments WHERE name = $1",
                    [.string("Param Dept")])
            }
        }
    }

    func testUpdate() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                // Insert test row
                _ = try await conn.execute(
                    "INSERT INTO departments (name, budget) VALUES ('Update Test', 1000.00)", [])

                let affected = try await conn.execute(
                    "UPDATE departments SET budget = 2000.00 WHERE name = 'Update Test'", [])
                XCTAssertEqual(affected, 1)

                let rows = try await conn.query(
                    "SELECT budget FROM departments WHERE name = 'Update Test'", [])
                // Budget comes as string (numeric) or decimal
                let budgetStr = rows[0]["budget"].asString()
                    ?? rows[0]["budget"].asDecimal().map { "\($0)" }
                    ?? ""
                XCTAssertTrue(budgetStr.hasPrefix("2000"), "Got: \(budgetStr)")

                _ = try await conn.execute(
                    "DELETE FROM departments WHERE name = 'Update Test'", [])
            }
        }
    }

    func testDelete() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                _ = try await conn.execute(
                    "INSERT INTO departments (name, budget) VALUES ('Delete Me', 0.00)", [])

                let affected = try await conn.execute(
                    "DELETE FROM departments WHERE name = 'Delete Me'", [])
                XCTAssertEqual(affected, 1)

                let rows = try await conn.query(
                    "SELECT COUNT(*) AS cnt FROM departments WHERE name = 'Delete Me'", [])
                let cnt = rows[0]["cnt"].asInt64() ?? Int64(rows[0]["cnt"].asInt32() ?? 0)
                XCTAssertEqual(cnt, 0)
            }
        }
    }

    func testMultipleRowsAffected() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                // Insert 3 test rows
                for i in 1...3 {
                    _ = try await conn.execute(
                        "INSERT INTO departments (name, budget) VALUES ($1, $2)",
                        [.string("Bulk \(i)"), .double(Double(i) * 1000)])
                }

                let affected = try await conn.execute(
                    "DELETE FROM departments WHERE name LIKE 'Bulk %'", [])
                XCTAssertEqual(affected, 3)
            }
        }
    }

    func testInsertReturning() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    INSERT INTO departments (name, budget)
                    VALUES ('RETURNING Test', 9999.99)
                    RETURNING id, name
                """, [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertNotNil(rows[0]["id"].asInt32())
                XCTAssertEqual(rows[0]["name"].asString(), "RETURNING Test")

                _ = try await conn.execute(
                    "DELETE FROM departments WHERE name = 'RETURNING Test'", [])
            }
        }
    }
}

// MARK: - Transaction Tests

final class PGTransactionTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testCommitTransaction() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                _ = try await conn.execute("BEGIN", [])
                _ = try await conn.execute(
                    "INSERT INTO departments (name, budget) VALUES ('TXN Commit', 0.00)", [])
                _ = try await conn.execute("COMMIT", [])

                let rows = try await conn.query(
                    "SELECT name FROM departments WHERE name = 'TXN Commit'", [])
                XCTAssertEqual(rows.count, 1)

                _ = try await conn.execute(
                    "DELETE FROM departments WHERE name = 'TXN Commit'", [])
            }
        }
    }

    func testRollbackTransaction() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                _ = try await conn.execute("BEGIN", [])
                _ = try await conn.execute(
                    "INSERT INTO departments (name, budget) VALUES ('TXN Rollback', 0.00)", [])
                _ = try await conn.execute("ROLLBACK", [])

                let rows = try await conn.query(
                    "SELECT name FROM departments WHERE name = 'TXN Rollback'", [])
                XCTAssertEqual(rows.count, 0)
            }
        }
    }

    func testTransactionIsolation() {
        pgRunAsync {
            // Connection 1: start a transaction and insert (not committed)
            let conn1 = try await PGTestDatabase.connect()
            let conn2 = try await PGTestDatabase.connect()
            defer {
                Task { try? await conn1.close() }
                Task { try? await conn2.close() }
            }

            _ = try await conn1.execute("BEGIN", [])
            _ = try await conn1.execute(
                "INSERT INTO departments (name, budget) VALUES ('Isolation Test', 0.00)", [])

            // Connection 2 should NOT see the uncommitted row
            let rows2 = try await conn2.query(
                "SELECT COUNT(*) AS cnt FROM departments WHERE name = 'Isolation Test'", [])
            let cnt2 = rows2[0]["cnt"].asInt64() ?? Int64(rows2[0]["cnt"].asInt32() ?? 0)
            XCTAssertEqual(cnt2, 0, "Uncommitted data should not be visible to other connections")

            _ = try await conn1.execute("ROLLBACK", [])
        }
    }
}

// MARK: - Error Handling Tests

final class PGErrorTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testInvalidSQLThrows() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                do {
                    _ = try await conn.query("THIS IS NOT VALID SQL", [])
                    XCTFail("Expected server error")
                } catch SQLError.serverError {
                    // expected
                }
            }
        }
    }

    func testTableNotFoundThrows() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                do {
                    _ = try await conn.query("SELECT * FROM nonexistent_table_xyz", [])
                    XCTFail("Expected server error")
                } catch SQLError.serverError {
                    // expected
                }
            }
        }
    }

    func testUniqueConstraintViolation() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                do {
                    // 'alice@example.com' already exists
                    _ = try await conn.execute(
                        "INSERT INTO employees (department_id, name, email) VALUES (1, 'Dup', 'alice@example.com')",
                        [])
                    XCTFail("Expected unique constraint error")
                } catch SQLError.serverError {
                    // expected
                }
            }
        }
    }

    func testForeignKeyViolation() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                do {
                    _ = try await conn.execute(
                        "INSERT INTO employees (department_id, name, email) VALUES (9999, 'NoParent', 'noparent@test.com')",
                        [])
                    XCTFail("Expected FK violation")
                } catch SQLError.serverError {
                    // expected
                }
            }
        }
    }

    func testDivisionByZeroThrows() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                do {
                    _ = try await conn.query("SELECT 1/0 AS oops", [])
                    XCTFail("Expected division by zero error")
                } catch SQLError.serverError {
                    // expected
                }
            }
        }
    }

    func testConnectionRecoveryAfterError() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                // Cause an error
                do { _ = try await conn.query("SELECT * FROM does_not_exist", []) } catch {}
                // Connection should still work for subsequent queries
                let rows = try await conn.query("SELECT 1 AS ok", [])
                XCTAssertEqual(rows[0]["ok"].asInt32(), 1)
            }
        }
    }
}

// MARK: - Function Call Tests

final class PGFunctionTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testScalarFunction() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT add_numbers(15, 27) AS result", [])
                XCTAssertEqual(rows[0]["result"].asInt32(), 42)
            }
        }
    }

    func testFunctionWithTableColumn() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT get_department_budget(1) AS budget", [])
                let budget = rows[0]["budget"].asString()
                    ?? rows[0]["budget"].asDecimal().map { "\($0)" }
                    ?? ""
                XCTAssertTrue(budget.hasPrefix("1500000"), "Got: \(budget)")
            }
        }
    }

    func testCountFunction() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT get_employee_count(1) AS cnt", [])
                XCTAssertEqual(rows[0]["cnt"].asInt32(), 3)
            }
        }
    }

    func testBuiltinStringFunctions() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT
                        UPPER('hello') AS up,
                        LOWER('WORLD') AS lo,
                        LENGTH('Swift') AS len,
                        TRIM('  spaces  ') AS trimmed
                """, [])
                XCTAssertEqual(rows[0]["up"].asString(), "HELLO")
                XCTAssertEqual(rows[0]["lo"].asString(), "world")
                XCTAssertEqual(rows[0]["len"].asInt32(), 5)
                XCTAssertEqual(rows[0]["trimmed"].asString(), "spaces")
            }
        }
    }

    func testBuiltinMathFunctions() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT
                        ABS(-42) AS abs_val,
                        CEIL(3.2) AS ceil_val,
                        FLOOR(3.9) AS floor_val,
                        ROUND(3.567, 2) AS rounded
                """, [])
                XCTAssertEqual(rows[0]["abs_val"].asInt32(), 42)
                XCTAssertEqual(rows[0]["ceil_val"].asString() ?? rows[0]["ceil_val"].asDecimal().map { "\($0)" }, "4")
                XCTAssertEqual(rows[0]["floor_val"].asString() ?? rows[0]["floor_val"].asDecimal().map { "\($0)" }, "3")
                let rounded = rows[0]["rounded"].asString() ?? ""
                XCTAssertTrue(rounded.hasPrefix("3.57") || rounded.hasPrefix("3.56"), "Got: \(rounded)")
            }
        }
    }
}

// MARK: - Decodable Tests

final class PGDecodableTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    struct Department: Decodable {
        let id: Int32
        let name: String
        let active: Bool
    }

    struct Employee: Decodable {
        let id: Int32
        let name: String
        let salary: String  // Decimal comes as string
    }

    func testDecodeStruct() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id, name, active FROM departments WHERE id = 1", [])
                let dept = try SQLRowDecoder().decode(Department.self, from: rows[0])
                XCTAssertEqual(dept.id, 1)
                XCTAssertEqual(dept.name, "Engineering")
                XCTAssertEqual(dept.active, true)
            }
        }
    }

    func testDecodeMultipleRows() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id, name, active FROM departments ORDER BY id", [])
                let depts = try rows.map { try SQLRowDecoder().decode(Department.self, from: $0) }
                XCTAssertEqual(depts.count, 5)
                XCTAssertEqual(depts[0].name, "Engineering")
                XCTAssertEqual(depts[4].name, "Operations")
                XCTAssertEqual(depts[4].active, false)
            }
        }
    }
}

// MARK: - Concurrent Query Tests

final class PGConcurrencyTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testConcurrentConnections() {
        pgRunAsync(timeout: 60) {
            // Open 5 connections concurrently and run queries
            try await withThrowingTaskGroup(of: Int32.self) { group in
                for i in 1...5 {
                    let val = Int32(i)
                    group.addTask {
                        try await PGTestDatabase.withConnection { conn in
                            let rows = try await conn.query(
                                "SELECT $1::int4 AS val", [.int32(val)])
                            return rows[0]["val"].asInt32() ?? -1
                        }
                    }
                }
                var results: [Int32] = []
                for try await r in group { results.append(r) }
                XCTAssertEqual(results.sorted(), [1, 2, 3, 4, 5])
            }
        }
    }

    func testSequentialQueriesOnSameConnection() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                for i in 1...10 {
                    let rows = try await conn.query(
                        "SELECT $1::int4 AS n", [.int32(Int32(i))])
                    XCTAssertEqual(rows[0]["n"].asInt32(), Int32(i))
                }
            }
        }
    }
}

// MARK: - Advanced Query Tests

final class PGAdvancedQueryTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testSubquery() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT name FROM employees
                    WHERE salary > (SELECT AVG(salary) FROM employees)
                    ORDER BY name
                """, [])
                XCTAssertGreaterThan(rows.count, 0)
                // Alice (120k) and Grace (90k) are above average
                let names = rows.compactMap { $0["name"].asString() }
                XCTAssertTrue(names.contains("Alice Johnson"))
            }
        }
    }

    func testCTEQuery() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    WITH top_earners AS (
                        SELECT name, salary FROM employees WHERE salary > 80000
                    )
                    SELECT COUNT(*) AS cnt FROM top_earners
                """, [])
                let cnt = rows[0]["cnt"].asInt64() ?? Int64(rows[0]["cnt"].asInt32() ?? 0)
                XCTAssertGreaterThan(cnt, 0)
            }
        }
    }

    func testWindowFunction() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT name, salary,
                           RANK() OVER (ORDER BY salary DESC) AS rank
                    FROM employees
                    ORDER BY rank
                    LIMIT 3
                """, [])
                XCTAssertEqual(rows.count, 3)
                XCTAssertEqual(rows[0]["name"].asString(), "Alice Johnson")
                XCTAssertEqual(rows[0]["rank"].asInt64() ?? Int64(rows[0]["rank"].asInt32() ?? 0), 1)
            }
        }
    }

    func testCaseExpression() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT name,
                           CASE WHEN salary >= 100000 THEN 'Senior'
                                WHEN salary >= 70000  THEN 'Mid'
                                ELSE 'Junior' END AS level
                    FROM employees
                    ORDER BY salary DESC
                    LIMIT 1
                """, [])
                XCTAssertEqual(rows[0]["level"].asString(), "Senior")
            }
        }
    }

    func testStringConcatenation() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT 'Hello' || ', ' || 'World!' AS greeting
                """, [])
                XCTAssertEqual(rows[0]["greeting"].asString(), "Hello, World!")
            }
        }
    }

    func testLikePattern() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT COUNT(*) AS cnt FROM employees WHERE email LIKE '%@example.com'
                """, [])
                let cnt = rows[0]["cnt"].asInt64() ?? Int64(rows[0]["cnt"].asInt32() ?? 0)
                XCTAssertEqual(cnt, 8)
            }
        }
    }

    func testInClause() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT name FROM departments
                    WHERE id IN (1, 2, 3)
                    ORDER BY id
                """, [])
                XCTAssertEqual(rows.count, 3)
            }
        }
    }

    func testBetweenClause() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT name FROM employees
                    WHERE salary BETWEEN 70000 AND 100000
                    ORDER BY salary
                """, [])
                XCTAssertGreaterThan(rows.count, 0)
            }
        }
    }
}

// MARK: - Transaction API Tests (new)

final class PGTransactionAPITests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testBeginCommit() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                try await conn.beginTransaction()
                _ = try await conn.execute(
                    "INSERT INTO departments (name, budget) VALUES ('TX API Commit', 1.00)", [])
                try await conn.commitTransaction()

                let rows = try await conn.query(
                    "SELECT name FROM departments WHERE name = 'TX API Commit'", [])
                XCTAssertEqual(rows.count, 1)
                _ = try await conn.execute(
                    "DELETE FROM departments WHERE name = 'TX API Commit'", [])
            }
        }
    }

    func testBeginRollback() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                try await conn.beginTransaction()
                _ = try await conn.execute(
                    "INSERT INTO departments (name, budget) VALUES ('TX API Rollback', 1.00)", [])
                try await conn.rollbackTransaction()

                let rows = try await conn.query(
                    "SELECT name FROM departments WHERE name = 'TX API Rollback'", [])
                XCTAssertEqual(rows.count, 0)
            }
        }
    }

    func testWithTransactionCommit() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                try await conn.withTransaction { c in
                    _ = try await c.execute(
                        "INSERT INTO departments (name, budget) VALUES ('withTX Commit', 2.00)", [])
                }
                let rows = try await conn.query(
                    "SELECT name FROM departments WHERE name = 'withTX Commit'", [])
                XCTAssertEqual(rows.count, 1)
                _ = try await conn.execute(
                    "DELETE FROM departments WHERE name = 'withTX Commit'", [])
            }
        }
    }

    func testWithTransactionRollbackOnError() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                do {
                    try await conn.withTransaction { c in
                        _ = try await c.execute(
                            "INSERT INTO departments (name, budget) VALUES ('withTX Fail', 3.00)", [])
                        throw SQLError.serverError(code: 0, message: "deliberate failure")
                    }
                } catch {}

                let rows = try await conn.query(
                    "SELECT name FROM departments WHERE name = 'withTX Fail'", [])
                XCTAssertEqual(rows.count, 0)
            }
        }
    }
}

// MARK: - Multiple Result Sets Tests (new)

final class PGQueryMultiTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testQueryMultiTwoResultSets() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let sets = try await conn.queryMulti(
                    "SELECT 1 AS a; SELECT 2 AS b, 3 AS c", [])
                XCTAssertEqual(sets.count, 2)
                XCTAssertEqual(sets[0][0]["a"].asInt32(), 1)
                XCTAssertEqual(sets[1][0]["b"].asInt32(), 2)
                XCTAssertEqual(sets[1][0]["c"].asInt32(), 3)
            }
        }
    }

    func testQueryMultiFromTables() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let sets = try await conn.queryMulti(
                    "SELECT COUNT(*) AS cnt FROM departments; SELECT COUNT(*) AS cnt FROM employees", [])
                XCTAssertEqual(sets.count, 2)
                let deptCount = sets[0][0]["cnt"].asInt64() ?? 0
                let empCount  = sets[1][0]["cnt"].asInt64() ?? 0
                XCTAssertEqual(deptCount, 5)
                XCTAssertEqual(empCount, 8)
            }
        }
    }

    func testQueryMultiMixedStatements() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let sets = try await conn.queryMulti("""
                    SELECT name FROM departments WHERE id = 1;
                    SELECT name FROM employees WHERE department_id = 1 ORDER BY name;
                """, [])
                XCTAssertEqual(sets.count, 2)
                XCTAssertEqual(sets[0][0]["name"].asString(), "Engineering")
                XCTAssertEqual(sets[1].count, 3)
            }
        }
    }

    func testQueryMultiSingle() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let sets = try await conn.queryMulti("SELECT 42 AS answer", [])
                XCTAssertEqual(sets.count, 1)
                XCTAssertEqual(sets[0][0]["answer"].asInt32(), 42)
            }
        }
    }
}

// MARK: - Connection Pool Tests (new)

final class PGPoolTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    var pool: PostgresConnectionPool?

    override func tearDown() async throws {
        if let p = pool { await p.closeAll() }
        pool = nil
    }

    func testAcquireRelease() {
        pgRunAsync {
            let p = PostgresConnectionPool(
                configuration: PGTestDatabase.configuration, maxConnections: 3)
            self.pool = p
            let conn = try await p.acquire()
            let active1 = await p.activeCount
            XCTAssertEqual(active1, 1)
            await p.release(conn)
            let idle1 = await p.idleCount
            XCTAssertEqual(idle1, 1)
        }
    }

    func testWithConnection() {
        pgRunAsync {
            let p = PostgresConnectionPool(
                configuration: PGTestDatabase.configuration, maxConnections: 3)
            self.pool = p
            let result = try await p.withConnection { conn in
                let rows = try await conn.query("SELECT 42 AS n", [])
                return rows[0]["n"].asInt32() ?? -1
            }
            XCTAssertEqual(result, 42)
            let idle = await p.idleCount
            XCTAssertEqual(idle, 1)
        }
    }

    func testConcurrentPoolConnections() {
        pgRunAsync(timeout: 60) {
            let p = PostgresConnectionPool(
                configuration: PGTestDatabase.configuration, maxConnections: 4)
            self.pool = p
            try await withThrowingTaskGroup(of: Int32.self) { group in
                for i in 1...4 {
                    let val = Int32(i)
                    group.addTask {
                        try await p.withConnection { conn in
                            let rows = try await conn.query("SELECT $1::int4 AS v", [.int32(val)])
                            return rows[0]["v"].asInt32() ?? -1
                        }
                    }
                }
                var results: [Int32] = []
                for try await r in group { results.append(r) }
                XCTAssertEqual(results.sorted(), [1, 2, 3, 4])
            }
        }
    }

    func testPoolReusesConnections() {
        pgRunAsync {
            let p = PostgresConnectionPool(
                configuration: PGTestDatabase.configuration, maxConnections: 2)
            self.pool = p
            // Sequential uses should reuse the same connection
            for i in 1...5 {
                let v = try await p.withConnection { conn -> Int32 in
                    let rows = try await conn.query("SELECT $1::int4 AS v", [.int32(Int32(i))])
                    return rows[0]["v"].asInt32() ?? -1
                }
                XCTAssertEqual(v, Int32(i))
            }
            let idle = await p.idleCount
            XCTAssertEqual(idle, 1)  // only 1 connection was ever opened
        }
    }

    func testPoolClosed() {
        pgRunAsync {
            let p = PostgresConnectionPool(
                configuration: PGTestDatabase.configuration, maxConnections: 2)
            await p.closeAll()
            do {
                _ = try await p.acquire()
                XCTFail("Expected connectionClosed error")
            } catch let e as SQLError {
                guard case .connectionClosed = e else {
                    XCTFail("Expected connectionClosed, got \(e)")
                    return
                }
            }
        }
    }
}

// MARK: - Bulk Insert Tests (new)

final class PGBulkInsertTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testBulkInsertRows() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                // Insert 50 departments
                let columns = ["name", "budget", "active"]
                let rows: [[SQLValue]] = (1...50).map { i in
                    [.string("Bulk Dept \(i)"), .double(Double(i) * 1000), .bool(true)]
                }
                let inserted = try await conn.bulkInsert(table: "departments",
                                                         columns: columns, rows: rows)
                XCTAssertEqual(inserted, 50)

                let countRows = try await conn.query(
                    "SELECT COUNT(*) AS cnt FROM departments WHERE name LIKE 'Bulk Dept %'", [])
                let cnt = countRows[0]["cnt"].asInt64() ?? 0
                XCTAssertEqual(cnt, 50)

                _ = try await conn.execute(
                    "DELETE FROM departments WHERE name LIKE 'Bulk Dept %'", [])
            }
        }
    }

    func testBulkInsertDicts() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows: [[String: SQLValue]] = (1...20).map { i in
                    ["name": .string("Dict Dept \(i)"), "budget": .double(500.0), "active": .bool(false)]
                }
                let inserted = try await conn.bulkInsert(table: "departments", rows: rows)
                XCTAssertEqual(inserted, 20)

                let countRows = try await conn.query(
                    "SELECT COUNT(*) AS cnt FROM departments WHERE name LIKE 'Dict Dept %'", [])
                let cnt = countRows[0]["cnt"].asInt64() ?? 0
                XCTAssertEqual(cnt, 20)

                _ = try await conn.execute(
                    "DELETE FROM departments WHERE name LIKE 'Dict Dept %'", [])
            }
        }
    }

    func testBulkInsertEmpty() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let n = try await conn.bulkInsert(table: "departments", columns: ["name"], rows: [])
                XCTAssertEqual(n, 0)
            }
        }
    }
}

// MARK: - Notice Callback Tests (new)

final class PGNoticeTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testNoticeCallback() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                // Swift 6: @Sendable callback can't mutate a var capture; use a class ref instead.
                final class MutableList: @unchecked Sendable { var items: [String] = [] }
                let notices = MutableList()
                conn.onNotice = { msg in notices.items.append(msg) }

                // PostgreSQL RAISE NOTICE generates a notice message
                _ = try await conn.execute("""
                    DO $$BEGIN
                        RAISE NOTICE 'Test notice message';
                    END$$
                """, [])

                XCTAssertGreaterThan(notices.items.count, 0)
                XCTAssertTrue(notices.items.joined().contains("Test notice"))
            }
        }
    }

    func testNoNoticeWithoutCallback() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                // No callback set — should not crash
                conn.onNotice = nil
                _ = try await conn.execute("""
                    DO $$BEGIN
                        RAISE NOTICE 'Silent notice';
                    END$$
                """, [])
                // Just verifying no crash
            }
        }
    }
}

// MARK: - Backup & Restore Tests

final class PGBackupTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessPG() }

    func testLogicalDump() {
        pgRunAsync {
            let conn = try await PGTestDatabase.connect()
            defer { Task { try? await conn.close() } }
            _ = try await conn.execute(
                "CREATE TABLE IF NOT EXISTS backup_test (id SERIAL PRIMARY KEY, name TEXT)")
            _ = try await conn.execute(
                "INSERT INTO backup_test (name) VALUES ($1)", [.string("Alice")])
            let sql = try await conn.dump(tables: ["backup_test"])
            XCTAssertTrue(sql.contains("-- sql-nio dump"))
            XCTAssertTrue(sql.contains("Alice"))
            XCTAssertTrue(sql.contains("INSERT INTO"))
            _ = try await conn.execute("DROP TABLE IF EXISTS backup_test")
        }
    }

    func testDumpAndRestoreRoundTrip() {
        pgRunAsync {
            let conn = try await PGTestDatabase.connect()
            defer { Task { try? await conn.close() } }
            _ = try await conn.execute(
                "CREATE TABLE IF NOT EXISTS rt_test (id SERIAL PRIMARY KEY, val TEXT)")
            for i in 1...5 {
                _ = try await conn.execute(
                    "INSERT INTO rt_test (val) VALUES ($1)", [.string("item\(i)")])
            }
            let sql = try await conn.dump(tables: ["rt_test"])
            _ = try await conn.execute("DELETE FROM rt_test")
            try await conn.restore(from: sql)
            let rows = try await conn.query("SELECT COUNT(*) AS cnt FROM rt_test", [])
            XCTAssertEqual(rows[0]["cnt"].asInt64(), 5)
            _ = try await conn.execute("DROP TABLE IF EXISTS rt_test")
        }
    }

    func testDumpToFile() {
        let path = NSTemporaryDirectory() + "pg_dump_\(UUID()).sql"
        defer { try? FileManager.default.removeItem(atPath: path) }
        pgRunAsync {
            let conn = try await PGTestDatabase.connect()
            defer { Task { try? await conn.close() } }
            _ = try await conn.execute(
                "CREATE TABLE IF NOT EXISTS file_test (id SERIAL PRIMARY KEY, name TEXT)")
            _ = try await conn.execute(
                "INSERT INTO file_test (name) VALUES ($1)", [.string("Frank")])
            try await conn.dump(to: path, tables: ["file_test"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            let content = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertTrue(content.contains("Frank"))
            _ = try await conn.execute("DROP TABLE IF EXISTS file_test")
        }
    }

    func testDumpHandlesNulls() {
        pgRunAsync {
            let conn = try await PGTestDatabase.connect()
            defer { Task { try? await conn.close() } }
            _ = try await conn.execute(
                "CREATE TABLE IF NOT EXISTS null_test (id SERIAL PRIMARY KEY, val TEXT NULL)")
            _ = try await conn.execute(
                "INSERT INTO null_test (val) VALUES (NULL)")
            let sql = try await conn.dump(tables: ["null_test"])
            XCTAssertTrue(sql.contains("NULL"))
            _ = try await conn.execute("DROP TABLE IF EXISTS null_test")
        }
    }
}
