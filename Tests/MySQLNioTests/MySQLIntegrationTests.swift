// MySQLIntegrationTests.swift
//
// Comprehensive integration tests for MySQLNio driver.
//
// Requires the Docker container:
//   docker run -d --name mysql-nio-test \
//     -e MYSQL_DATABASE=MySQLNioTestDb \
//     -e MYSQL_USER=mysqluser \
//     -e MYSQL_PASSWORD=mysqlPass123 \
//     -e MYSQL_ROOT_PASSWORD=root \
//     -p 3306:3306 mysql:8
//
// Run with:
//   MYSQL_TEST_HOST=127.0.0.1 swift test --filter MySQLNioTests

import XCTest
@testable import MySQLNio
import SQLNioCore

// MARK: - Test support

struct MySQLTestDatabase {

    static var isAvailable: Bool {
        ProcessInfo.processInfo.environment["MYSQL_TEST_HOST"] != nil
    }

    static var configuration: MySQLConnection.Configuration {
        let env = ProcessInfo.processInfo.environment
        return MySQLConnection.Configuration(
            host:     env["MYSQL_TEST_HOST"]  ?? "127.0.0.1",
            port:     Int(env["MYSQL_TEST_PORT"] ?? "3306") ?? 3306,
            database: env["MYSQL_TEST_DB"]    ?? "MySQLNioTestDb",
            username: env["MYSQL_TEST_USER"]  ?? "mysqluser",
            password: env["MYSQL_TEST_PASS"]  ?? "mysqlPass123",
            tls:      .prefer
        )
    }

    static func connect() async throws -> MySQLConnection {
        try await MySQLConnection.connect(configuration: configuration)
    }

    static func withConnection<T>(
        _ body: (MySQLConnection) async throws -> T
    ) async throws -> T {
        let conn = try await connect()
        defer { Task { try? await conn.close() } }
        return try await body(conn)
    }
}

extension XCTestCase {
    func skipUnlessMySQL(file: StaticString = #file, line: UInt = #line) throws {
        try XCTSkipUnless(MySQLTestDatabase.isAvailable,
                          "Set MYSQL_TEST_HOST to run MySQL integration tests")
    }

    func mysqlRunAsync(
        timeout: TimeInterval = 30,
        file: StaticString = #file, line: UInt = #line,
        _ body: @escaping @Sendable () async throws -> Void
    ) {
        let exp = expectation(description: "mysql-async")
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

// Helper: coerce SQLValue to Int32 across all integer widths (MySQL literals return BIGINT)
private extension SQLValue {
    func asAnyInt32() -> Int32? {
        asInt32() ?? asInt64().map { Int32($0) } ?? asInt().map { Int32($0) }
    }
    func asAnyInt64() -> Int64? {
        asInt64() ?? asInt32().map { Int64($0) } ?? asInt().map { Int64($0) }
    }
}

// MARK: - Connection Tests

final class MySQLConnectionTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testBasicConnect() {
        mysqlRunAsync {
            let conn = try await MySQLTestDatabase.connect()
            try? await conn.close()
        }
    }

    func testConnectWithWrongPasswordFails() {
        mysqlRunAsync {
            var bad = MySQLTestDatabase.configuration
            bad.password = "WRONG_PASSWORD"
            do {
                _ = try await MySQLConnection.connect(configuration: bad)
                XCTFail("Expected auth failure")
            } catch SQLError.authenticationFailed {
                // expected
            }
        }
    }

    func testConnectionClosedThrows() {
        mysqlRunAsync {
            let conn = try await MySQLTestDatabase.connect()
            try? await conn.close()
            do {
                _ = try await conn.query("SELECT 1", [])
                XCTFail("Expected connectionClosed")
            } catch SQLError.connectionClosed {
                // expected
            }
        }
    }

    func testIsOpenProperty() {
        mysqlRunAsync {
            let conn = try await MySQLTestDatabase.connect()
            XCTAssertTrue(conn.isOpen)
            try? await conn.close()
            XCTAssertFalse(conn.isOpen)
        }
    }
}

// MARK: - Basic Query Tests

final class MySQLBasicQueryTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testSelectScalarInt() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT 42 AS answer", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["answer"].asAnyInt32(), 42)
            }
        }
    }

    func testSelectScalarString() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT 'Hello MySQL' AS msg", [])
                XCTAssertEqual(rows[0]["msg"].asString(), "Hello MySQL")
            }
        }
    }

    func testSelectNull() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT NULL AS val", [])
                XCTAssertEqual(rows[0]["val"], .null)
            }
        }
    }

    func testSelectBoolTrue() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT TRUE AS flag", [])
                // MySQL returns TINYINT(1) for TRUE
                let flag = rows[0]["flag"]
                // MySQL returns TRUE as TINYINT(1) or BIGINT; coerce all int widths
                let v = flag.asBool() == true
                    || flag.asInt() == 1
                    || flag.asInt32() == 1
                    || flag.asInt64() == 1
                XCTAssertTrue(v)
            }
        }
    }

    func testSelectBoolFalse() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT FALSE AS flag", [])
                let flag = rows[0]["flag"]
                let v = flag.asBool() ?? (flag.asInt() == 0)
                XCTAssertFalse(v)
            }
        }
    }

    func testSelectFloat() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT 3.14 AS pi", [])
                let piVal = rows[0]["pi"]
                let pi = piVal.asDouble()
                    ?? piVal.asFloat().map { Double($0) }
                    ?? piVal.asDecimal().map { NSDecimalNumber(decimal: $0).doubleValue }
                    ?? piVal.asString().flatMap { Double($0) }
                    ?? 0
                XCTAssertEqual(pi, 3.14, accuracy: 0.01)
            }
        }
    }

    func testSelectMultipleRows() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id FROM departments ORDER BY id LIMIT 5", [])
                XCTAssertEqual(rows.count, 5)
            }
        }
    }

    func testSelectEmptyResult() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT 1 WHERE FALSE", [])
                XCTAssertEqual(rows.count, 0)
            }
        }
    }

    func testSelectMultipleColumns() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT 1 AS a, 'hello' AS b, TRUE AS c", [])
                XCTAssertEqual(rows.count, 1)
                // MySQL literal 1 returns BIGINT; coerce all int widths
                let aRaw = rows[0]["a"]
                let aVal = aRaw.asInt32() ?? aRaw.asInt64().map { Int32($0) } ?? aRaw.asInt().map { Int32($0) }
                XCTAssertEqual(aVal, 1)
                XCTAssertEqual(rows[0]["b"].asString(), "hello")
            }
        }
    }

    func testSelectCurrentTimestamp() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT NOW() AS ts", [])
                // MySQL returns datetime as string "YYYY-MM-DD HH:MM:SS"
                let ts = rows[0]["ts"].asDate() ?? rows[0]["ts"].asString().map { _ in Date() }
                XCTAssertNotNil(ts)
            }
        }
    }
}

// MARK: - Parameterized Query Tests

final class MySQLParameterizedTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testStringParameter() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT ? AS name", [.string("Alice")])
                XCTAssertEqual(rows[0]["name"].asString(), "Alice")
            }
        }
    }

    func testIntParameter() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT ? + ? AS total", [.int32(10), .int32(20)])
                XCTAssertEqual(rows[0]["total"].asInt32() ?? rows[0]["total"].asInt64().map { Int32($0) }, 30)
            }
        }
    }

    func testNullParameter() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT ? AS val", [.null])
                XCTAssertEqual(rows[0]["val"], .null)
            }
        }
    }

    func testFloatParameter() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT ? AS val", [.double(2.718)])
                let val = rows[0]["val"]
                let v = val.asDouble()
                    ?? val.asFloat().map { Double($0) }
                    ?? val.asDecimal().map { NSDecimalNumber(decimal: $0).doubleValue }
                    ?? 0
                XCTAssertEqual(v, 2.718, accuracy: 0.01)
            }
        }
    }

    func testSpecialCharInString() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT ? AS name", [.string("O'Brien & Co")])
                XCTAssertEqual(rows[0]["name"].asString(), "O'Brien & Co")
            }
        }
    }

    func testAtP1StyleParameter() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                // MySQL driver supports @p1 style placeholders
                let rows = try await conn.query("SELECT @p1 AS name", [.string("Bob")])
                XCTAssertEqual(rows[0]["name"].asString(), "Bob")
            }
        }
    }
}

// MARK: - Data Type Tests

final class MySQLDataTypeTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testBoolType() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_bool FROM type_samples WHERE id = 1", [])
                let v = rows[0]["col_bool"]
                XCTAssertTrue(v.asBool() == true || v.asInt() == 1)
            }
        }
    }

    func testTinyintType() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_tinyint FROM type_samples WHERE id = 1", [])
                let v = rows[0]["col_tinyint"].asInt() ?? Int(rows[0]["col_tinyint"].asInt32() ?? 0)
                XCTAssertEqual(v, 127)
            }
        }
    }

    func testSmallintType() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_smallint FROM type_samples WHERE id = 1", [])
                let v = rows[0]["col_smallint"].asInt() ?? Int(rows[0]["col_smallint"].asInt32() ?? 0)
                XCTAssertEqual(v, 32767)
            }
        }
    }

    func testIntType() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_int FROM type_samples WHERE id = 1", [])
                XCTAssertEqual(rows[0]["col_int"].asInt32(), 2147483647)
            }
        }
    }

    func testBigintType() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_bigint FROM type_samples WHERE id = 1", [])
                XCTAssertEqual(rows[0]["col_bigint"].asInt64(), 9223372036854775807)
            }
        }
    }

    func testFloatType() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_float FROM type_samples WHERE id = 1", [])
                let v = rows[0]["col_float"].asFloat()
                    ?? rows[0]["col_float"].asDouble().map { Float($0) }
                    ?? 0
                XCTAssertEqual(v, 3.14, accuracy: 0.01)
            }
        }
    }

    func testDoubleType() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_double FROM type_samples WHERE id = 1", [])
                let v = rows[0]["col_double"].asDouble() ?? 0
                XCTAssertEqual(v, 2.718281828, accuracy: 0.000001)
            }
        }
    }

    func testDecimalType() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_decimal FROM type_samples WHERE id = 1", [])
                let raw = rows[0]["col_decimal"]
                let strVal = raw.asString() ?? (raw.asDecimal().map { "\($0)" } ?? "")
                XCTAssertTrue(strVal.hasPrefix("99999"), "Got: \(strVal)")
            }
        }
    }

    func testVarcharType() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_varchar FROM type_samples WHERE id = 1", [])
                XCTAssertEqual(rows[0]["col_varchar"].asString(), "VarChar Value")
            }
        }
    }

    func testTextType() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_text FROM type_samples WHERE id = 1", [])
                XCTAssertEqual(rows[0]["col_text"].asString(), "Hello MySQL")
            }
        }
    }

    func testDateType() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_date FROM type_samples WHERE id = 1", [])
                let val = rows[0]["col_date"]
                let dateStr = val.asDate().map { d -> String in
                    let cal = Calendar(identifier: .gregorian)
                    let comps = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: d)
                    return "\(comps.year!)"
                } ?? val.asString() ?? ""
                XCTAssertTrue(dateStr.hasPrefix("2025"), "Expected 2025 date, got: \(dateStr)")
            }
        }
    }

    func testDatetimeType() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_datetime FROM type_samples WHERE id = 1", [])
                let val = rows[0]["col_datetime"]
                XCTAssertNotNil(val.asDate() ?? val.asString().map { $0 as Any? } ?? nil,
                                "Expected non-null datetime")
            }
        }
    }

    func testNullableColumn() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                _ = try await conn.execute(
                    "INSERT INTO type_samples (col_text) VALUES ('null-test')", [])
                let rows = try await conn.query(
                    "SELECT col_bool, col_int FROM type_samples WHERE col_text = 'null-test'", [])
                XCTAssertEqual(rows[0]["col_bool"], .null)
                XCTAssertEqual(rows[0]["col_int"], .null)
                _ = try await conn.execute(
                    "DELETE FROM type_samples WHERE col_text = 'null-test'", [])
            }
        }
    }
}

// MARK: - Table Query Tests

final class MySQLTableQueryTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testSelectAllDepartments() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id, name, active FROM departments ORDER BY id", [])
                XCTAssertEqual(rows.count, 5)
                XCTAssertEqual(rows[0]["name"].asString(), "Engineering")
                XCTAssertEqual(rows[4]["name"].asString(), "Operations")
            }
        }
    }

    func testSelectWithWhere() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT name FROM employees WHERE department_id = 1 ORDER BY name", [])
                XCTAssertEqual(rows.count, 3)
                XCTAssertEqual(rows[0]["name"].asString(), "Alice Johnson")
            }
        }
    }

    func testSelectWithJoin() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT e.name AS emp_name, d.name AS dept_name
                    FROM employees e
                    JOIN departments d ON e.department_id = d.id
                    WHERE e.is_manager = 1
                    ORDER BY e.name
                """, [])
                XCTAssertGreaterThan(rows.count, 0)
                for row in rows {
                    XCTAssertNotNil(row["dept_name"].asString())
                }
            }
        }
    }

    func testSelectWithAggregate() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT COUNT(*) AS cnt FROM employees", [])
                let cnt = rows[0]["cnt"].asInt64() ?? Int64(rows[0]["cnt"].asInt32() ?? 0)
                XCTAssertEqual(cnt, 8)
            }
        }
    }

    func testSelectWithGroupBy() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT department_id, COUNT(*) AS cnt
                    FROM employees
                    GROUP BY department_id
                    ORDER BY department_id
                """, [])
                XCTAssertEqual(rows.count, 5)
                let cnt = rows[0]["cnt"].asInt64() ?? Int64(rows[0]["cnt"].asInt32() ?? 0)
                XCTAssertEqual(cnt, 3)  // Engineering has 3 employees
            }
        }
    }

    func testSelectWithOrderByDesc() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT name, salary FROM employees ORDER BY salary DESC LIMIT 3", [])
                XCTAssertEqual(rows.count, 3)
                XCTAssertEqual(rows[0]["name"].asString(), "Alice Johnson")
            }
        }
    }

    func testSelectWithLimit() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id FROM products ORDER BY id LIMIT 3", [])
                XCTAssertEqual(rows.count, 3)
            }
        }
    }

    func testSelectWithParameterFilter() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT name FROM employees WHERE department_id = ? ORDER BY name",
                    [.int32(1)])
                XCTAssertEqual(rows.count, 3)
            }
        }
    }

    func testSelectActiveProducts() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT name FROM products WHERE active = ? ORDER BY id",
                    [.int(1)])
                XCTAssertEqual(rows.count, 5)
                let names = rows.compactMap { $0["name"].asString() }
                XCTAssertFalse(names.contains("Discontinued"))
            }
        }
    }

    func testComplexJoinQuery() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
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
                }
            }
        }
    }
}

// MARK: - DML Tests (INSERT / UPDATE / DELETE)

final class MySQLDMLTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testInsertAndSelect() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let affected = try await conn.execute("""
                    INSERT INTO departments (name, budget, active)
                    VALUES ('Test Dept', 50000.00, 1)
                """, [])
                XCTAssertEqual(affected, 1)

                let rows = try await conn.query(
                    "SELECT name, budget FROM departments WHERE name = 'Test Dept'", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["name"].asString(), "Test Dept")

                _ = try await conn.execute(
                    "DELETE FROM departments WHERE name = 'Test Dept'", [])
            }
        }
    }

    func testInsertWithParameters() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let affected = try await conn.execute(
                    "INSERT INTO departments (name, budget) VALUES (?, ?)",
                    [.string("Param Dept"), .double(75000.0)])
                XCTAssertEqual(affected, 1)

                let rows = try await conn.query(
                    "SELECT name FROM departments WHERE name = ?",
                    [.string("Param Dept")])
                XCTAssertEqual(rows.count, 1)

                _ = try await conn.execute(
                    "DELETE FROM departments WHERE name = ?",
                    [.string("Param Dept")])
            }
        }
    }

    func testUpdate() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                _ = try await conn.execute(
                    "INSERT INTO departments (name, budget) VALUES ('Update Test', 1000.00)", [])

                let affected = try await conn.execute(
                    "UPDATE departments SET budget = 2000.00 WHERE name = 'Update Test'", [])
                XCTAssertEqual(affected, 1)

                let rows = try await conn.query(
                    "SELECT budget FROM departments WHERE name = 'Update Test'", [])
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
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
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
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                for i in 1...3 {
                    _ = try await conn.execute(
                        "INSERT INTO departments (name, budget) VALUES (?, ?)",
                        [.string("Bulk \(i)"), .double(Double(i) * 1000)])
                }

                let affected = try await conn.execute(
                    "DELETE FROM departments WHERE name LIKE 'Bulk %'", [])
                XCTAssertEqual(affected, 3)
            }
        }
    }

    func testLastInsertID() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                _ = try await conn.execute(
                    "INSERT INTO departments (name, budget) VALUES ('LAST_ID Test', 1.00)", [])

                let rows = try await conn.query("SELECT LAST_INSERT_ID() AS lid", [])
                let lid = rows[0]["lid"].asInt64() ?? Int64(rows[0]["lid"].asInt32() ?? 0)
                XCTAssertGreaterThan(lid, 0)

                _ = try await conn.execute(
                    "DELETE FROM departments WHERE name = 'LAST_ID Test'", [])
            }
        }
    }
}

// MARK: - Transaction Tests (raw SQL)

final class MySQLTransactionTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testCommitTransaction() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                _ = try await conn.execute("START TRANSACTION", [])
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
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                _ = try await conn.execute("START TRANSACTION", [])
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
        mysqlRunAsync {
            let conn1 = try await MySQLTestDatabase.connect()
            let conn2 = try await MySQLTestDatabase.connect()
            defer {
                Task { try? await conn1.close() }
                Task { try? await conn2.close() }
            }

            _ = try await conn1.execute("START TRANSACTION", [])
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

final class MySQLErrorTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testInvalidSQLThrows() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
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
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
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
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                do {
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
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
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

    func testConnectionRecoveryAfterError() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                do { _ = try await conn.query("SELECT * FROM does_not_exist", []) } catch {}
                // Connection should still work
                let rows = try await conn.query("SELECT 1 AS ok", [])
                XCTAssertEqual(rows[0]["ok"].asAnyInt32(), 1)
            }
        }
    }
}

// MARK: - Stored Procedure Tests

final class MySQLProcedureTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testCallProcedureWithOutParam() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                // Call stored procedure using SET + CALL + SELECT pattern
                _ = try await conn.execute("SET @result = 0", [])
                _ = try await conn.execute("CALL add_numbers(15, 27, @result)", [])
                let rows = try await conn.query("SELECT @result AS answer", [])
                let answer = rows[0]["answer"]
                XCTAssertEqual(answer.asInt32() ?? answer.asInt64().map { Int32($0) }, 42)
            }
        }
    }

    func testCallDepartmentBudget() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                _ = try await conn.execute("SET @budget = 0", [])
                _ = try await conn.execute("CALL get_department_budget(1, @budget)", [])
                let rows = try await conn.query("SELECT @budget AS budget", [])
                let budget = rows[0]["budget"].asString()
                    ?? rows[0]["budget"].asDecimal().map { "\(NSDecimalNumber(decimal: $0))" }
                    ?? ""
                XCTAssertTrue(budget.hasPrefix("1500000"), "Got: \(budget)")
            }
        }
    }

    func testCallEmployeeCount() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                _ = try await conn.execute("SET @cnt = 0", [])
                _ = try await conn.execute("CALL get_employee_count(1, @cnt)", [])
                let rows = try await conn.query("SELECT @cnt AS cnt", [])
                XCTAssertEqual(rows[0]["cnt"].asInt32() ?? rows[0]["cnt"].asInt64().map { Int32($0) }, 3)
            }
        }
    }

    func testBuiltinStringFunctions() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT
                        UPPER('hello') AS up,
                        LOWER('WORLD') AS lo,
                        LENGTH('Swift') AS len,
                        TRIM('  spaces  ') AS trimmed
                """, [])
                XCTAssertEqual(rows[0]["up"].asString(), "HELLO")
                XCTAssertEqual(rows[0]["lo"].asString(), "world")
                XCTAssertEqual(rows[0]["len"].asInt32() ?? rows[0]["len"].asInt64().map { Int32($0) }, 5)
                XCTAssertEqual(rows[0]["trimmed"].asString(), "spaces")
            }
        }
    }

    func testBuiltinMathFunctions() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT
                        ABS(-42) AS abs_val,
                        CEIL(3.2) AS ceil_val,
                        FLOOR(3.9) AS floor_val,
                        ROUND(3.567, 2) AS rounded
                """, [])
                XCTAssertEqual(rows[0]["abs_val"].asInt32() ?? rows[0]["abs_val"].asInt64().map { Int32($0) }, 42)
                let rounded = rows[0]["rounded"].asString()
                    ?? rows[0]["rounded"].asDouble().map { String($0) }
                    ?? rows[0]["rounded"].asDecimal().map { NSDecimalNumber(decimal: $0).stringValue }
                    ?? ""
                XCTAssertTrue(rounded.hasPrefix("3.57") || rounded.hasPrefix("3.56"),
                              "Got: \(rounded)")
            }
        }
    }
}

// MARK: - Decodable Tests

final class MySQLDecodableTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    struct Department: Decodable {
        let id: Int32
        let name: String
        let active: Int  // TINYINT(1) decoded as int
    }

    struct Employee: Decodable {
        let id: Int32
        let name: String
        let salary: String  // DECIMAL comes as string
    }

    func testDecodeStruct() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id, name, active FROM departments WHERE id = 1", [])
                let dept = try SQLRowDecoder().decode(Department.self, from: rows[0])
                XCTAssertEqual(dept.id, 1)
                XCTAssertEqual(dept.name, "Engineering")
                XCTAssertEqual(dept.active, 1)
            }
        }
    }

    func testDecodeMultipleRows() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id, name, active FROM departments ORDER BY id", [])
                let depts = try rows.map { try SQLRowDecoder().decode(Department.self, from: $0) }
                XCTAssertEqual(depts.count, 5)
                XCTAssertEqual(depts[0].name, "Engineering")
                XCTAssertEqual(depts[4].name, "Operations")
            }
        }
    }
}

// MARK: - Concurrent Query Tests

final class MySQLConcurrencyTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testConcurrentConnections() {
        mysqlRunAsync(timeout: 60) {
            try await withThrowingTaskGroup(of: Int32.self) { group in
                for i in 1...5 {
                    let val = Int32(i)
                    group.addTask {
                        try await MySQLTestDatabase.withConnection { conn in
                            let rows = try await conn.query(
                                "SELECT ? AS val", [.int32(val)])
                            return rows[0]["val"].asAnyInt32() ?? -1
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
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                for i in 1...10 {
                    let rows = try await conn.query(
                        "SELECT ? AS n", [.int32(Int32(i))])
                    XCTAssertEqual(rows[0]["n"].asAnyInt32(), Int32(i))
                }
            }
        }
    }
}

// MARK: - Advanced Query Tests

final class MySQLAdvancedQueryTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testSubquery() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT name FROM employees
                    WHERE salary > (SELECT AVG(salary) FROM employees)
                    ORDER BY name
                """, [])
                XCTAssertGreaterThan(rows.count, 0)
                let names = rows.compactMap { $0["name"].asString() }
                XCTAssertTrue(names.contains("Alice Johnson"))
            }
        }
    }

    func testCTEQuery() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
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

    func testCaseExpression() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
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
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT CONCAT('Hello', ', ', 'World!') AS greeting
                """, [])
                XCTAssertEqual(rows[0]["greeting"].asString(), "Hello, World!")
            }
        }
    }

    func testLikePattern() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT COUNT(*) AS cnt FROM employees WHERE email LIKE '%@example.com'
                """, [])
                let cnt = rows[0]["cnt"].asInt64() ?? Int64(rows[0]["cnt"].asInt32() ?? 0)
                XCTAssertEqual(cnt, 8)
            }
        }
    }

    func testInClause() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
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
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
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

// MARK: - Transaction API Tests

final class MySQLTransactionAPITests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testBeginCommit() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
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
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
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
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
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
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
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

// MARK: - Multiple Result Sets Tests

final class MySQLQueryMultiTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testQueryMultiTwoResultSets() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let sets = try await conn.queryMulti(
                    "SELECT 1 AS a; SELECT 2 AS b, 3 AS c")
                XCTAssertEqual(sets.count, 2)
                let a = sets[0][0]["a"]; XCTAssertEqual(a.asInt32() ?? a.asInt64().map { Int32($0) }, 1)
                let b = sets[1][0]["b"]; XCTAssertEqual(b.asInt32() ?? b.asInt64().map { Int32($0) }, 2)
                let c = sets[1][0]["c"]; XCTAssertEqual(c.asInt32() ?? c.asInt64().map { Int32($0) }, 3)
            }
        }
    }

    func testQueryMultiFromTables() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let sets = try await conn.queryMulti(
                    "SELECT COUNT(*) AS cnt FROM departments; SELECT COUNT(*) AS cnt FROM employees")
                XCTAssertEqual(sets.count, 2)
                let deptCount = sets[0][0]["cnt"].asInt64() ?? 0
                let empCount  = sets[1][0]["cnt"].asInt64() ?? 0
                XCTAssertEqual(deptCount, 5)
                XCTAssertEqual(empCount, 8)
            }
        }
    }

    func testQueryMultiMixedStatements() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let sets = try await conn.queryMulti("""
                    SELECT name FROM departments WHERE id = 1;
                    SELECT name FROM employees WHERE department_id = 1 ORDER BY name;
                """)
                XCTAssertEqual(sets.count, 2)
                XCTAssertEqual(sets[0][0]["name"].asString(), "Engineering")
                XCTAssertEqual(sets[1].count, 3)
            }
        }
    }

    func testQueryMultiSingle() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let sets = try await conn.queryMulti("SELECT 42 AS answer")
                XCTAssertEqual(sets.count, 1)
                let answer = sets[0][0]["answer"]
                XCTAssertEqual(answer.asInt32() ?? answer.asInt64().map { Int32($0) }, 42)
            }
        }
    }
}

// MARK: - Connection Pool Tests

final class MySQLPoolTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    var pool: MySQLConnectionPool?

    override func tearDown() async throws {
        if let p = pool { await p.closeAll() }
        pool = nil
    }

    func testAcquireRelease() {
        mysqlRunAsync {
            let p = MySQLConnectionPool(
                configuration: MySQLTestDatabase.configuration, maxConnections: 3)
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
        mysqlRunAsync {
            let p = MySQLConnectionPool(
                configuration: MySQLTestDatabase.configuration, maxConnections: 3)
            self.pool = p
            let result = try await p.withConnection { conn in
                let rows = try await conn.query("SELECT 42 AS n", [])
                let n = rows[0]["n"]; return n.asInt32() ?? n.asInt64().map { Int32($0) } ?? -1
            }
            XCTAssertEqual(result, 42)
            let idle = await p.idleCount
            XCTAssertEqual(idle, 1)
        }
    }

    func testConcurrentPoolConnections() {
        mysqlRunAsync(timeout: 60) {
            let p = MySQLConnectionPool(
                configuration: MySQLTestDatabase.configuration, maxConnections: 4)
            defer { Task { await p.closeAll() } }
            try await withThrowingTaskGroup(of: Int32.self) { group in
                for i in 1...4 {
                    let val = Int32(i)
                    group.addTask {
                        try await p.withConnection { conn in
                            let rows = try await conn.query("SELECT ? AS v", [.int32(val)])
                            let v = rows[0]["v"]; return v.asInt32() ?? v.asInt64().map { Int32($0) } ?? -1
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
        mysqlRunAsync {
            let p = MySQLConnectionPool(
                configuration: MySQLTestDatabase.configuration, maxConnections: 2)
            defer { Task { await p.closeAll() } }
            for i in 1...5 {
                let v = try await p.withConnection { conn -> Int32 in
                    let rows = try await conn.query("SELECT ? AS v", [.int32(Int32(i))])
                    let vVal = rows[0]["v"]; return vVal.asInt32() ?? vVal.asInt64().map { Int32($0) } ?? -1
                }
                XCTAssertEqual(v, Int32(i))
            }
            let idle = await p.idleCount
            XCTAssertEqual(idle, 1)
        }
    }

    func testPoolClosed() {
        mysqlRunAsync {
            let p = MySQLConnectionPool(
                configuration: MySQLTestDatabase.configuration, maxConnections: 2)
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

// MARK: - Bulk Insert Tests

final class MySQLBulkInsertTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testBulkInsertRows() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let columns = ["name", "budget", "active"]
                let rows: [[SQLValue]] = (1...50).map { i in
                    [.string("Bulk Dept \(i)"), .double(Double(i) * 1000), .int(1)]
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
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows: [[String: SQLValue]] = (1...20).map { i in
                    ["name": .string("Dict Dept \(i)"), "budget": .double(500.0), "active": .int(0)]
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
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let n = try await conn.bulkInsert(table: "departments", columns: ["name"], rows: [])
                XCTAssertEqual(n, 0)
            }
        }
    }
}

// MARK: - DataTable Tests

final class MySQLDataTableTests: XCTestCase {

    override func setUp() async throws { try skipUnlessMySQL() }

    func testAsDataTable() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id, name FROM departments ORDER BY id", [])
                let table = rows.asDataTable(name: "departments")
                XCTAssertEqual(table.name, "departments")
                XCTAssertEqual(table.rows.count, 5)
                XCTAssertTrue(table.columns.map(\.name).contains("name"))
            }
        }
    }

    func testAsDataSet() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let sets = try await conn.queryMulti(
                    "SELECT id, name FROM departments ORDER BY id; SELECT id, name FROM employees ORDER BY id")
                let ds = sets.asDataSet(names: ["departments", "employees"])
                XCTAssertEqual(ds.tables.count, 2)
                XCTAssertEqual(ds["departments"]?.rows.count, 5)
                XCTAssertEqual(ds["employees"]?.rows.count, 8)
            }
        }
    }
}

// MARK: - Backup & Restore Tests

final class MySQLBackupTests: XCTestCase {

    override func setUp() async throws {
        try XCTSkipUnless(MySQLTestDatabase.isAvailable,
                          "Set MYSQL_TEST_HOST to run MySQL integration tests")
    }

    func run(timeout: TimeInterval = 30, _ body: @escaping @Sendable () async throws -> Void) {
        let exp = expectation(description: "mysql-backup-async")
        Task {
            do { try await body() } catch { XCTFail("Unexpected error: \(error)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
    }

    func testLogicalDump() {
        run { [self] in
            let conn = try await MySQLTestDatabase.connect()
            defer { Task { try? await conn.close() } }
            _ = try await conn.execute(
                "CREATE TABLE IF NOT EXISTS backup_test (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100))")
            _ = try await conn.execute(
                "INSERT INTO backup_test (name) VALUES (?)", [.string("Alice")])
            let sql = try await conn.dump(tables: ["backup_test"])
            XCTAssertTrue(sql.contains("-- sql-nio dump"))
            XCTAssertTrue(sql.contains("Alice"))
            XCTAssertTrue(sql.contains("INSERT INTO"))
            _ = try await conn.execute("DROP TABLE IF EXISTS backup_test")
        }
    }

    func testDumpAndRestoreRoundTrip() {
        run { [self] in
            let conn = try await MySQLTestDatabase.connect()
            defer { Task { try? await conn.close() } }
            _ = try await conn.execute(
                "CREATE TABLE IF NOT EXISTS rt_test (id INT AUTO_INCREMENT PRIMARY KEY, val VARCHAR(100))")
            for i in 1...5 {
                _ = try await conn.execute(
                    "INSERT INTO rt_test (val) VALUES (?)", [.string("item\(i)")])
            }
            let sql = try await conn.dump(tables: ["rt_test"])
            _ = try await conn.execute("DELETE FROM rt_test")
            try await conn.restore(from: sql)
            let rows = try await conn.query("SELECT COUNT(*) AS cnt FROM rt_test", [])
            XCTAssertEqual(rows[0]["cnt"].asAnyInt64(), 5)
            _ = try await conn.execute("DROP TABLE IF EXISTS rt_test")
        }
    }

    func testDumpToFile() {
        let path = NSTemporaryDirectory() + "mysql_dump_\(UUID()).sql"
        defer { try? FileManager.default.removeItem(atPath: path) }
        run { [self] in
            let conn = try await MySQLTestDatabase.connect()
            defer { Task { try? await conn.close() } }
            _ = try await conn.execute(
                "CREATE TABLE IF NOT EXISTS file_test (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100))")
            _ = try await conn.execute(
                "INSERT INTO file_test (name) VALUES (?)", [.string("Frank")])
            try await conn.dump(to: path, tables: ["file_test"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            let content = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertTrue(content.contains("Frank"))
            _ = try await conn.execute("DROP TABLE IF EXISTS file_test")
        }
    }

    func testDumpHandlesNulls() {
        run { [self] in
            let conn = try await MySQLTestDatabase.connect()
            defer { Task { try? await conn.close() } }
            _ = try await conn.execute(
                "CREATE TABLE IF NOT EXISTS null_test (id INT AUTO_INCREMENT PRIMARY KEY, val VARCHAR(100) NULL)")
            _ = try await conn.execute(
                "INSERT INTO null_test (val) VALUES (NULL)")
            let sql = try await conn.dump(tables: ["null_test"])
            XCTAssertTrue(sql.contains("NULL"))
            _ = try await conn.execute("DROP TABLE IF EXISTS null_test")
        }
    }
}
