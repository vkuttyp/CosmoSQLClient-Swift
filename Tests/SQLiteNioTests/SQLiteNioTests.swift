// SQLiteNioTests.swift
//
// Comprehensive tests for SQLiteNio driver.
// Uses in-memory SQLite — no external dependencies required.
//
// Run with:
//   swift test --filter SQLiteNioTests

import XCTest
@testable import SQLiteNio
import SQLNioCore

// MARK: - Test helpers

private func withConn(_ body: @escaping @Sendable (SQLiteConnection) async throws -> Void) {
    let exp = XCTestExpectation(description: "sqlite-async")
    Task {
        do {
            let conn = try SQLiteConnection.open()
            defer { Task { try? await conn.close() } }
            try await body(conn)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        exp.fulfill()
    }
    XCTWaiter().wait(for: [exp], timeout: 10)
}

// Schema helper used in many tests
private func makeTestSchema(_ conn: SQLiteConnection) async throws {
    try await conn.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            name    TEXT    NOT NULL,
            email   TEXT    UNIQUE,
            age     INTEGER,
            active  INTEGER NOT NULL DEFAULT 1
        )
    """)
    try await conn.execute("""
        CREATE TABLE IF NOT EXISTS products (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            name     TEXT    NOT NULL,
            price    REAL    NOT NULL,
            stock    INTEGER NOT NULL DEFAULT 0,
            category TEXT
        )
    """)
}

// MARK: - Connection Tests

final class SQLiteConnectionTests: XCTestCase {

    func testOpenMemory() {
        withConn { conn in
            XCTAssertTrue(conn.isOpen)
        }
    }

    func testOpenFile() {
        let path = NSTemporaryDirectory() + "sqlite_test_\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let exp = XCTestExpectation(description: "file")
        Task {
            do {
                let conn = try SQLiteConnection.open(configuration: .init(storage: .file(path: path)))
                XCTAssertTrue(conn.isOpen)
                try await conn.close()
                XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            } catch {
                XCTFail("Error: \(error)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testClose() {
        withConn { conn in
            try await conn.close()
            XCTAssertFalse(conn.isOpen)
        }
    }

    func testMultipleConnections() {
        let exp = XCTestExpectation(description: "multi")
        Task {
            do {
                let c1 = try SQLiteConnection.open()
                let c2 = try SQLiteConnection.open()
                let r1 = try await c1.query("SELECT 1 AS n", [])
                let r2 = try await c2.query("SELECT 2 AS n", [])
                XCTAssertEqual(r1[0]["n"].asInt64(), 1)
                XCTAssertEqual(r2[0]["n"].asInt64(), 2)
                try await c1.close(); try await c2.close()
            } catch { XCTFail("\(error)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }
}

// MARK: - Basic Query Tests

final class SQLiteBasicQueryTests: XCTestCase {

    func testSelectScalar() {
        withConn { conn in
            let rows = try await conn.query("SELECT 42 AS answer", [])
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0]["answer"].asInt64(), 42)
        }
    }

    func testSelectString() {
        withConn { conn in
            let rows = try await conn.query("SELECT 'Hello SQLite' AS msg", [])
            XCTAssertEqual(rows[0]["msg"].asString(), "Hello SQLite")
        }
    }

    func testSelectNull() {
        withConn { conn in
            let rows = try await conn.query("SELECT NULL AS val", [])
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0]["val"], .null)
        }
    }

    func testSelectFloat() {
        withConn { conn in
            let rows = try await conn.query("SELECT 3.14 AS pi", [])
            let pi = rows[0]["pi"].asDouble() ?? 0
            XCTAssertEqual(pi, 3.14, accuracy: 0.001)
        }
    }

    func testSelectBool() {
        withConn { conn in
            let rows = try await conn.query("SELECT 1 AS t, 0 AS f", [])
            XCTAssertEqual(rows[0]["t"].asInt64(), 1)
            XCTAssertEqual(rows[0]["f"].asInt64(), 0)
        }
    }

    func testSelectEmptyResult() {
        withConn { conn in
            _ = try await conn.execute(
                "CREATE TABLE empty_tbl (id INTEGER PRIMARY KEY)")
            let rows = try await conn.query("SELECT * FROM empty_tbl", [])
            XCTAssertEqual(rows.count, 0)
        }
    }

    func testSelectMultipleColumns() {
        withConn { conn in
            let rows = try await conn.query(
                "SELECT 1 AS a, 'hello' AS b, 2.5 AS c", [])
            XCTAssertEqual(rows[0]["a"].asInt64(), 1)
            XCTAssertEqual(rows[0]["b"].asString(), "hello")
            XCTAssertEqual(rows[0]["c"].asDouble(), 2.5)
        }
    }

    func testSelectCurrentTimestamp() {
        withConn { conn in
            let rows = try await conn.query(
                "SELECT datetime('now') AS ts", [])
            XCTAssertNotNil(rows[0]["ts"].asString())
        }
    }
}

// MARK: - Parameter Tests

final class SQLiteParameterTests: XCTestCase {

    func testQuestionMarkParam() {
        withConn { conn in
            let rows = try await conn.query("SELECT ? AS val", [.int64(99)])
            XCTAssertEqual(rows[0]["val"].asInt64(), 99)
        }
    }

    func testAtP1StyleParam() {
        withConn { conn in
            // @p1 is translated to ?1 by renderQuery
            let rows = try await conn.query("SELECT @p1 AS name", [.string("Alice")])
            XCTAssertEqual(rows[0]["name"].asString(), "Alice")
        }
    }

    func testMultipleParams() {
        withConn { conn in
            let rows = try await conn.query(
                "SELECT ?1 AS a, ?2 AS b", [.int64(10), .string("x")])
            XCTAssertEqual(rows[0]["a"].asInt64(), 10)
            XCTAssertEqual(rows[0]["b"].asString(), "x")
        }
    }

    func testNullParam() {
        withConn { conn in
            let rows = try await conn.query("SELECT ? AS val", [.null])
            XCTAssertEqual(rows[0]["val"], .null)
        }
    }

    func testSpecialCharsInString() {
        withConn { conn in
            let s = "O'Brien & \"Co\" \\ Ltd"
            let rows = try await conn.query("SELECT ? AS name", [.string(s)])
            XCTAssertEqual(rows[0]["name"].asString(), s)
        }
    }

    func testFloatParam() {
        withConn { conn in
            let rows = try await conn.query("SELECT ? AS val", [.double(2.718)])
            let v = rows[0]["val"].asDouble() ?? 0
            XCTAssertEqual(v, 2.718, accuracy: 0.001)
        }
    }

    func testBoolParam() {
        withConn { conn in
            // .bool(true) → bind_int(1)
            let rows = try await conn.query("SELECT ? AS val", [.bool(true)])
            XCTAssertEqual(rows[0]["val"].asInt64(), 1)
        }
    }

    func testBlobParam() {
        withConn { conn in
            let bytes: [UInt8] = [0x01, 0x02, 0x03, 0xFF]
            let rows = try await conn.query("SELECT ? AS val", [.bytes(bytes)])
            XCTAssertEqual(rows[0]["val"].asBytes(), bytes)
        }
    }
}

// MARK: - DDL + DML Tests

final class SQLiteDMLTests: XCTestCase {

    func testCreateTableAndInsert() {
        withConn { conn in
            try await conn.execute("""
                CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)
            """)
            let affected = try await conn.execute(
                "INSERT INTO items (name) VALUES (?)", [.string("Widget")])
            XCTAssertEqual(affected, 1)
        }
    }

    func testInsertAndSelect() {
        withConn { conn in
            try await makeTestSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name, email, age) VALUES (?, ?, ?)",
                [.string("Alice"), .string("alice@test.com"), .int64(30)])
            let rows = try await conn.query(
                "SELECT name, age FROM users WHERE email = ?",
                [.string("alice@test.com")])
            XCTAssertEqual(rows[0]["name"].asString(), "Alice")
            XCTAssertEqual(rows[0]["age"].asInt64(), 30)
        }
    }

    func testUpdate() {
        withConn { conn in
            try await makeTestSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name, email) VALUES (?, ?)",
                [.string("Bob"), .string("bob@test.com")])
            let affected = try await conn.execute(
                "UPDATE users SET name = ? WHERE email = ?",
                [.string("Robert"), .string("bob@test.com")])
            XCTAssertEqual(affected, 1)
            let rows = try await conn.query(
                "SELECT name FROM users WHERE email = ?",
                [.string("bob@test.com")])
            XCTAssertEqual(rows[0]["name"].asString(), "Robert")
        }
    }

    func testDelete() {
        withConn { conn in
            try await makeTestSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name) VALUES (?)", [.string("Temp")])
            let affected = try await conn.execute(
                "DELETE FROM users WHERE name = ?", [.string("Temp")])
            XCTAssertEqual(affected, 1)
            let rows = try await conn.query(
                "SELECT COUNT(*) AS cnt FROM users", [])
            XCTAssertEqual(rows[0]["cnt"].asInt64(), 0)
        }
    }

    func testAutoincrement() {
        withConn { conn in
            try await makeTestSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name) VALUES (?)", [.string("A")])
            _ = try await conn.execute(
                "INSERT INTO users (name) VALUES (?)", [.string("B")])
            let rows = try await conn.query(
                "SELECT id FROM users ORDER BY id", [])
            XCTAssertEqual(rows.count, 2)
            let id1 = rows[0]["id"].asInt64() ?? 0
            let id2 = rows[1]["id"].asInt64() ?? 0
            XCTAssertGreaterThan(id2, id1)
        }
    }

    func testMultipleInserts() {
        withConn { conn in
            try await makeTestSchema(conn)
            for i in 1...10 {
                _ = try await conn.execute(
                    "INSERT INTO users (name) VALUES (?)",
                    [.string("User\(i)")])
            }
            let rows = try await conn.query(
                "SELECT COUNT(*) AS cnt FROM users", [])
            XCTAssertEqual(rows[0]["cnt"].asInt64(), 10)
        }
    }
}

// MARK: - Data Type Tests

final class SQLiteDataTypeTests: XCTestCase {

    private func typeConn(_ body: @escaping @Sendable (SQLiteConnection) async throws -> Void) {
        withConn { conn in
            try await conn.execute("""
                CREATE TABLE types (
                    col_int     INTEGER,
                    col_real    REAL,
                    col_text    TEXT,
                    col_blob    BLOB,
                    col_null    INTEGER
                )
            """)
            try await body(conn)
        }
    }

    func testIntegerType() {
        typeConn { conn in
            _ = try await conn.execute(
                "INSERT INTO types (col_int) VALUES (?)", [.int64(12345)])
            let rows = try await conn.query("SELECT col_int FROM types", [])
            XCTAssertEqual(rows[0]["col_int"].asInt64(), 12345)
        }
    }

    func testRealType() {
        typeConn { conn in
            _ = try await conn.execute(
                "INSERT INTO types (col_real) VALUES (?)", [.double(9.99)])
            let rows = try await conn.query("SELECT col_real FROM types", [])
            XCTAssertEqual(rows[0]["col_real"].asDouble() ?? 0, 9.99, accuracy: 0.001)
        }
    }

    func testTextType() {
        typeConn { conn in
            _ = try await conn.execute(
                "INSERT INTO types (col_text) VALUES (?)", [.string("hello")])
            let rows = try await conn.query("SELECT col_text FROM types", [])
            XCTAssertEqual(rows[0]["col_text"].asString(), "hello")
        }
    }

    func testBlobType() {
        typeConn { conn in
            let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
            _ = try await conn.execute(
                "INSERT INTO types (col_blob) VALUES (?)", [.bytes(bytes)])
            let rows = try await conn.query("SELECT col_blob FROM types", [])
            XCTAssertEqual(rows[0]["col_blob"].asBytes(), bytes)
        }
    }

    func testNullType() {
        typeConn { conn in
            _ = try await conn.execute(
                "INSERT INTO types (col_null) VALUES (NULL)", [])
            let rows = try await conn.query("SELECT col_null FROM types", [])
            XCTAssertTrue(rows[0]["col_null"].isNull)
        }
    }

    func testLargeInteger() {
        withConn { conn in
            let big: Int64 = Int64.max
            let rows = try await conn.query("SELECT ? AS val", [.int64(big)])
            XCTAssertEqual(rows[0]["val"].asInt64(), big)
        }
    }

    func testNegativeInteger() {
        withConn { conn in
            let rows = try await conn.query("SELECT ? AS val", [.int64(-42)])
            XCTAssertEqual(rows[0]["val"].asInt64(), -42)
        }
    }

    func testUnicodeString() {
        withConn { conn in
            let s = "日本語 🎌 Español"
            let rows = try await conn.query("SELECT ? AS val", [.string(s)])
            XCTAssertEqual(rows[0]["val"].asString(), s)
        }
    }
}

// MARK: - Transaction Tests

final class SQLiteTransactionTests: XCTestCase {

    func testCommit() {
        withConn { conn in
            try await makeTestSchema(conn)
            try await conn.begin()
            _ = try await conn.execute(
                "INSERT INTO users (name) VALUES (?)", [.string("TX User")])
            try await conn.commit()
            let rows = try await conn.query("SELECT COUNT(*) AS cnt FROM users", [])
            XCTAssertEqual(rows[0]["cnt"].asInt64(), 1)
        }
    }

    func testRollback() {
        withConn { conn in
            try await makeTestSchema(conn)
            try await conn.begin()
            _ = try await conn.execute(
                "INSERT INTO users (name) VALUES (?)", [.string("TX User")])
            try await conn.rollback()
            let rows = try await conn.query("SELECT COUNT(*) AS cnt FROM users", [])
            XCTAssertEqual(rows[0]["cnt"].asInt64(), 0)
        }
    }

    func testWithTransactionCommit() {
        withConn { conn in
            try await makeTestSchema(conn)
            try await conn.withTransaction { c in
                _ = try await c.execute(
                    "INSERT INTO users (name) VALUES (?)", [.string("Alice")])
            }
            let rows = try await conn.query("SELECT COUNT(*) AS cnt FROM users", [])
            XCTAssertEqual(rows[0]["cnt"].asInt64(), 1)
        }
    }

    func testWithTransactionRollbackOnError() {
        withConn { conn in
            try await makeTestSchema(conn)
            do {
                try await conn.withTransaction { c in
                    _ = try await c.execute(
                        "INSERT INTO users (name) VALUES (?)", [.string("Bob")])
                    throw SQLError.serverError(code: -1, message: "forced")
                }
            } catch {}
            let rows = try await conn.query("SELECT COUNT(*) AS cnt FROM users", [])
            XCTAssertEqual(rows[0]["cnt"].asInt64(), 0)
        }
    }

    func testTransactionIsolation() {
        withConn { conn in
            try await makeTestSchema(conn)
            try await conn.begin()
            _ = try await conn.execute(
                "INSERT INTO users (name) VALUES (?)", [.string("Pending")])
            // Visible inside transaction
            let inner = try await conn.query("SELECT COUNT(*) AS cnt FROM users", [])
            XCTAssertEqual(inner[0]["cnt"].asInt64(), 1)
            try await conn.rollback()
            // Gone after rollback
            let outer = try await conn.query("SELECT COUNT(*) AS cnt FROM users", [])
            XCTAssertEqual(outer[0]["cnt"].asInt64(), 0)
        }
    }
}

// MARK: - Advanced Query Tests

final class SQLiteAdvancedQueryTests: XCTestCase {

    func testOrderBy() {
        withConn { conn in
            try await makeTestSchema(conn)
            for name in ["Charlie", "Alice", "Bob"] {
                _ = try await conn.execute(
                    "INSERT INTO users (name) VALUES (?)", [.string(name)])
            }
            let rows = try await conn.query(
                "SELECT name FROM users ORDER BY name", [])
            XCTAssertEqual(rows.map { $0["name"].asString()! }, ["Alice", "Bob", "Charlie"])
        }
    }

    func testLimitOffset() {
        withConn { conn in
            try await makeTestSchema(conn)
            for i in 1...10 {
                _ = try await conn.execute(
                    "INSERT INTO users (name) VALUES (?)", [.string("User\(i)")])
            }
            let rows = try await conn.query(
                "SELECT name FROM users ORDER BY id LIMIT 3 OFFSET 2", [])
            XCTAssertEqual(rows.count, 3)
        }
    }

    func testAggregates() {
        withConn { conn in
            try await makeTestSchema(conn)
            for age in [20, 25, 30, 35, 40] {
                _ = try await conn.execute(
                    "INSERT INTO users (name, age) VALUES (?, ?)",
                    [.string("U"), .int64(Int64(age))])
            }
            let rows = try await conn.query("""
                SELECT COUNT(*) AS cnt, MIN(age) AS mn, MAX(age) AS mx, AVG(age) AS avg
                FROM users
            """, [])
            XCTAssertEqual(rows[0]["cnt"].asInt64(), 5)
            XCTAssertEqual(rows[0]["mn"].asInt64(), 20)
            XCTAssertEqual(rows[0]["mx"].asInt64(), 40)
            XCTAssertEqual(rows[0]["avg"].asDouble() ?? 0, 30.0, accuracy: 0.1)
        }
    }

    func testJoin() {
        withConn { conn in
            try await conn.execute("""
                CREATE TABLE depts (id INTEGER PRIMARY KEY, name TEXT)
            """)
            try await conn.execute("""
                CREATE TABLE emps (id INTEGER PRIMARY KEY, name TEXT, dept_id INTEGER)
            """)
            _ = try await conn.execute(
                "INSERT INTO depts VALUES (1, 'Eng')")
            _ = try await conn.execute(
                "INSERT INTO emps VALUES (1, 'Alice', 1)")
            let rows = try await conn.query("""
                SELECT e.name AS emp, d.name AS dept
                FROM emps e JOIN depts d ON e.dept_id = d.id
            """, [])
            XCTAssertEqual(rows[0]["emp"].asString(), "Alice")
            XCTAssertEqual(rows[0]["dept"].asString(), "Eng")
        }
    }

    func testLike() {
        withConn { conn in
            try await makeTestSchema(conn)
            for n in ["Apple", "Apricot", "Banana"] {
                _ = try await conn.execute(
                    "INSERT INTO users (name) VALUES (?)", [.string(n)])
            }
            let rows = try await conn.query(
                "SELECT name FROM users WHERE name LIKE ?", [.string("Ap%")])
            XCTAssertEqual(rows.count, 2)
        }
    }

    func testGroupBy() {
        withConn { conn in
            try await makeTestSchema(conn)
            for (n, a) in [("A", 20), ("B", 20), ("C", 30)] {
                _ = try await conn.execute(
                    "INSERT INTO users (name, age) VALUES (?, ?)",
                    [.string(n), .int64(Int64(a))])
            }
            let rows = try await conn.query("""
                SELECT age, COUNT(*) AS cnt FROM users GROUP BY age ORDER BY age
            """, [])
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0]["cnt"].asInt64(), 2)
            XCTAssertEqual(rows[1]["cnt"].asInt64(), 1)
        }
    }

    func testSubquery() {
        withConn { conn in
            try await makeTestSchema(conn)
            for (n, a) in [("Young", 20), ("Old", 50)] {
                _ = try await conn.execute(
                    "INSERT INTO users (name, age) VALUES (?, ?)",
                    [.string(n), .int64(Int64(a))])
            }
            let rows = try await conn.query("""
                SELECT name FROM users WHERE age > (SELECT AVG(age) FROM users)
            """, [])
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0]["name"].asString(), "Old")
        }
    }

    func testCTE() {
        withConn { conn in
            let rows = try await conn.query("""
                WITH nums AS (SELECT 1 AS n UNION SELECT 2 UNION SELECT 3)
                SELECT SUM(n) AS total FROM nums
            """, [])
            XCTAssertEqual(rows[0]["total"].asInt64(), 6)
        }
    }
}

// MARK: - Multi-statement Tests

final class SQLiteMultiQueryTests: XCTestCase {

    func testQueryMultiBasic() {
        withConn { conn in
            let results = try await conn.queryMulti(
                "SELECT 1 AS a; SELECT 2 AS b")
            XCTAssertEqual(results.count, 2)
            XCTAssertEqual(results[0][0]["a"].asInt64(), 1)
            XCTAssertEqual(results[1][0]["b"].asInt64(), 2)
        }
    }

    func testQueryMultiMixed() {
        withConn { conn in
            try await makeTestSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name) VALUES (?)", [.string("Alice")])
            let results = try await conn.queryMulti("""
                SELECT COUNT(*) AS cnt FROM users;
                SELECT name FROM users WHERE id = 1
            """)
            XCTAssertEqual(results.count, 2)
            XCTAssertEqual(results[0][0]["cnt"].asInt64(), 1)
            XCTAssertEqual(results[1][0]["name"].asString(), "Alice")
        }
    }
}

// MARK: - Error Tests

final class SQLiteErrorTests: XCTestCase {

    func testSyntaxError() {
        withConn { conn in
            do {
                _ = try await conn.query("SELEKT 1", [])
                XCTFail("Expected error")
            } catch SQLError.serverError {
                // expected
            }
        }
    }

    func testTableNotFound() {
        withConn { conn in
            do {
                _ = try await conn.query("SELECT * FROM no_such_table", [])
                XCTFail("Expected error")
            } catch SQLError.serverError {
                // expected
            }
        }
    }

    func testUniqueConstraintViolation() {
        withConn { conn in
            try await makeTestSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name, email) VALUES (?, ?)",
                [.string("A"), .string("dup@test.com")])
            do {
                _ = try await conn.execute(
                    "INSERT INTO users (name, email) VALUES (?, ?)",
                    [.string("B"), .string("dup@test.com")])
                XCTFail("Expected unique constraint error")
            } catch SQLError.serverError {
                // expected
            }
        }
    }

    func testConnectionRecoveryAfterError() {
        withConn { conn in
            // Error query
            do { _ = try await conn.query("BAD SQL HERE !!!", []) } catch {}
            // Connection should still work
            let rows = try await conn.query("SELECT 1 AS ok", [])
            XCTAssertEqual(rows[0]["ok"].asInt64(), 1)
        }
    }
}

// MARK: - Decodable Tests

final class SQLiteDecodableTests: XCTestCase {

    struct User: Decodable {
        let id:   Int64
        let name: String
        let age:  Int64?
    }

    func testDecodeStruct() {
        withConn { conn in
            try await makeTestSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name, age) VALUES (?, ?)",
                [.string("Alice"), .int64(30)])
            let users: [User] = try await conn.query(
                "SELECT id, name, age FROM users", [], as: User.self)
            XCTAssertEqual(users.count, 1)
            XCTAssertEqual(users[0].name, "Alice")
            XCTAssertEqual(users[0].age, 30)
        }
    }

    func testDecodeNullableField() {
        withConn { conn in
            try await makeTestSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name) VALUES (?)", [.string("Bob")])
            let users: [User] = try await conn.query(
                "SELECT id, name, age FROM users", [], as: User.self)
            XCTAssertNil(users[0].age)
        }
    }
}

// MARK: - DataTable Tests

final class SQLiteDataTableTests: XCTestCase {

    func testAsDataTable() {
        withConn { conn in
            try await makeTestSchema(conn)
            for i in 1...3 {
                _ = try await conn.execute(
                    "INSERT INTO users (name, age) VALUES (?, ?)",
                    [.string("User\(i)"), .int64(Int64(20 + i))])
            }
            let rows = try await conn.query("SELECT name, age FROM users ORDER BY id", [])
            let table = rows.asDataTable()
            XCTAssertEqual(table.columns.count, 2)
            XCTAssertEqual(table.rows.count, 3)
            XCTAssertEqual(table.columns[0].name, "name")
        }
    }
}

// MARK: - Pool Tests

final class SQLitePoolTests: XCTestCase {

    func testPoolBasicUsage() {
        let exp = XCTestExpectation(description: "pool")
        Task {
            do {
                let pool = SQLiteConnectionPool(
                    configuration: .init(), maxConnections: 3)
                let result = try await pool.withConnection { conn in
                    let rows = try await conn.query("SELECT 42 AS n", [])
                    return rows[0]["n"].asInt64() ?? -1
                }
                XCTAssertEqual(result, 42)
                let idle = await pool.idleCount
                XCTAssertEqual(idle, 1)
                await pool.closeAll()
            } catch { XCTFail("\(error)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }

    func testPoolMultipleConnections() {
        let exp = XCTestExpectation(description: "pool-concurrent")
        Task {
            do {
                let pool = SQLiteConnectionPool(
                    configuration: .init(), maxConnections: 4)
                try await withThrowingTaskGroup(of: Int64.self) { group in
                    for i in 1...4 {
                        let val = Int64(i)
                        group.addTask {
                            try await pool.withConnection { conn in
                                let rows = try await conn.query(
                                    "SELECT ? AS v", [.int64(val)])
                                return rows[0]["v"].asInt64() ?? -1
                            }
                        }
                    }
                    var results: [Int64] = []
                    for try await r in group { results.append(r) }
                    XCTAssertEqual(results.sorted(), [1, 2, 3, 4])
                }
                await pool.closeAll()
            } catch { XCTFail("\(error)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
    }

    func testPoolCloseAll() {
        let exp = XCTestExpectation(description: "pool-close")
        Task {
            do {
                let pool = SQLiteConnectionPool(
                    configuration: .init(), maxConnections: 2)
                _ = try await pool.withConnection { conn in
                    try await conn.query("SELECT 1", [])
                }
                await pool.closeAll()
                do {
                    _ = try await pool.acquire()
                    XCTFail("Should have thrown connectionClosed")
                } catch SQLError.connectionClosed {
                    // expected
                }
            } catch { XCTFail("\(error)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }

    func testPoolFileDatabase() {
        let path = NSTemporaryDirectory() + "pool_test_\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let exp = XCTestExpectation(description: "pool-file")
        Task {
            do {
                let pool = SQLiteConnectionPool(
                    configuration: .init(storage: .file(path: path)),
                    maxConnections: 2)
                try await pool.withConnection { conn in
                    _ = try await conn.execute(
                        "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
                }
                try await pool.withConnection { conn in
                    _ = try await conn.execute(
                        "INSERT INTO t (v) VALUES (?)", [.string("hello")])
                }
                let result = try await pool.withConnection { conn in
                    try await conn.query("SELECT v FROM t", [])
                }
                XCTAssertEqual(result[0]["v"].asString(), "hello")
                await pool.closeAll()
            } catch { XCTFail("\(error)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }
}

// MARK: - SQLDatabase Protocol Tests

final class SQLiteSQLDatabaseTests: XCTestCase {

    func testConformsToSQLDatabase() {
        let exp = XCTestExpectation(description: "protocol")
        Task {
            do {
                let conn = try SQLiteConnection.open()
                let db: any SQLDatabase = conn
                let rows = try await db.query("SELECT 'works' AS val")
                XCTAssertEqual(rows[0]["val"].asString(), "works")
                try await db.close()
            } catch { XCTFail("\(error)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testExecuteReturnsAffectedRows() {
        withConn { conn in
            try await makeTestSchema(conn)
            let n = try await conn.execute(
                "INSERT INTO users (name) VALUES (?)", [.string("X")])
            XCTAssertEqual(n, 1)
        }
    }

    func testConvenienceQueryNoBinds() {
        withConn { conn in
            let rows = try await conn.query("SELECT 99 AS val")
            XCTAssertEqual(rows[0]["val"].asInt64(), 99)
        }
    }
}

// MARK: - Backup & Restore Tests

final class SQLiteBackupTests: XCTestCase {

    // MARK: Native binary backup

    func testNativeBinaryBackup() {
        let path = NSTemporaryDirectory() + "backup_\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        withConn { conn in
            try await makeTestSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name, age) VALUES (?, ?)",
                [.string("Alice"), .int64(30)])
            // Backup to file
            try await conn.backup(to: path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            // Open backup and verify content
            let backup = try SQLiteConnection.open(
                configuration: .init(storage: .file(path: path)))
            defer { Task { try? await backup.close() } }
            let rows = try await backup.query("SELECT name FROM users", [])
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0]["name"].asString(), "Alice")
        }
    }

    func testNativeBinaryRestore() {
        let path = NSTemporaryDirectory() + "restore_src_\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        withConn { source in
            try await makeTestSchema(source)
            _ = try await source.execute(
                "INSERT INTO users (name) VALUES (?)", [.string("Bob")])
            try await source.backup(to: path)
        }
        // Restore into a fresh in-memory DB
        withConn { dest in
            try await dest.restore(fromBackup: path)
            let rows = try await dest.query("SELECT name FROM users", [])
            XCTAssertEqual(rows[0]["name"].asString(), "Bob")
        }
    }

    func testSerialize() {
        withConn { conn in
            try await makeTestSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name) VALUES (?)", [.string("Charlie")])
            let data = try await conn.serialize()
            XCTAssertGreaterThan(data.count, 0)
            // The SQLite magic header starts with "SQLite format 3"
            let header = String(bytes: data.prefix(15), encoding: .utf8) ?? ""
            XCTAssertTrue(header.hasPrefix("SQLite format"))
        }
    }

    // MARK: Logical SQL dump

    func testLogicalDump() {
        withConn { conn in
            try await makeTestSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name, email, age) VALUES (?, ?, ?)",
                [.string("Dave"), .string("dave@test.com"), .int64(40)])
            let sql = try await conn.dump()
            XCTAssertTrue(sql.contains("-- sql-nio dump"))
            XCTAssertTrue(sql.contains("INSERT INTO"))
            XCTAssertTrue(sql.contains("Dave"))
        }
    }

    func testLogicalDumpIncludesCreateTable() {
        withConn { conn in
            try await makeTestSchema(conn)
            let sql = try await conn.dump()
            XCTAssertTrue(sql.contains("CREATE TABLE"))
        }
    }

    func testLogicalDumpSpecificTables() {
        withConn { conn in
            try await makeTestSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name) VALUES (?)", [.string("Eve")])
            _ = try await conn.execute(
                "INSERT INTO products (name, price) VALUES (?, ?)",
                [.string("Widget"), .double(9.99)])
            // Dump only users
            let sql = try await conn.dump(tables: ["users"])
            XCTAssertTrue(sql.contains("users"))
            XCTAssertFalse(sql.contains("products"))
        }
    }

    func testLogicalDumpAndRestore() {
        withConn { conn in
            try await makeTestSchema(conn)
            for i in 1...5 {
                _ = try await conn.execute(
                    "INSERT INTO users (name, age) VALUES (?, ?)",
                    [.string("User\(i)"), .int64(Int64(20 + i))])
            }
            let sql = try await conn.dump()

            // Restore into a new in-memory DB
            let dest = try SQLiteConnection.open()
            defer { Task { try? await dest.close() } }
            // Create schema first (logical dump doesn't require pre-existing schema
            // since SQLite includes CREATE TABLE in its dump)
            try await dest.restore(from: sql)
            let rows = try await dest.query(
                "SELECT COUNT(*) AS cnt FROM users", [])
            XCTAssertEqual(rows[0]["cnt"].asInt64(), 5)
        }
    }

    func testDumpToFile() {
        let path = NSTemporaryDirectory() + "dump_\(UUID()).sql"
        defer { try? FileManager.default.removeItem(atPath: path) }
        withConn { conn in
            try await makeTestSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name) VALUES (?)", [.string("Frank")])
            try await conn.dump(to: path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            let content = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertTrue(content.contains("Frank"))
        }
    }

    func testRestoreFromFile() {
        let path = NSTemporaryDirectory() + "restore_\(UUID()).sql"
        defer { try? FileManager.default.removeItem(atPath: path) }
        withConn { source in
            try await makeTestSchema(source)
            _ = try await source.execute(
                "INSERT INTO users (name, age) VALUES (?, ?)",
                [.string("Grace"), .int64(28)])
            try await source.dump(to: path)
        }
        withConn { dest in
            try await dest.restore(fromFile: path)
            let rows = try await dest.query("SELECT name FROM users", [])
            XCTAssertEqual(rows[0]["name"].asString(), "Grace")
        }
    }

    func testDumpHandlesSpecialChars() {
        withConn { conn in
            try await makeTestSchema(conn)
            let tricky = "O'Brien's \"quote\" & <tag>"
            _ = try await conn.execute(
                "INSERT INTO users (name) VALUES (?)", [.string(tricky)])
            let sql = try await conn.dump()
            // Restore it
            let dest = try SQLiteConnection.open()
            defer { Task { try? await dest.close() } }
            try await dest.restore(from: sql)
            let rows = try await dest.query("SELECT name FROM users", [])
            XCTAssertEqual(rows[0]["name"].asString(), tricky)
        }
    }

    func testDumpHandlesNullValues() {
        withConn { conn in
            try await makeTestSchema(conn)
            // Insert row with NULL age and NULL email
            _ = try await conn.execute(
                "INSERT INTO users (name) VALUES (?)", [.string("Hal")])
            let sql = try await conn.dump()
            XCTAssertTrue(sql.contains("NULL"))
            let dest = try SQLiteConnection.open()
            defer { Task { try? await dest.close() } }
            try await dest.restore(from: sql)
            let rows = try await dest.query("SELECT name, age FROM users", [])
            XCTAssertEqual(rows[0]["name"].asString(), "Hal")
            XCTAssertTrue(rows[0]["age"].isNull)
        }
    }

    func testDumpEmptyTable() {
        withConn { conn in
            try await makeTestSchema(conn)
            let sql = try await conn.dump()
            // No INSERT statements since tables are empty
            XCTAssertFalse(sql.contains("INSERT INTO"))
            XCTAssertTrue(sql.contains("-- sql-nio dump"))
        }
    }
}
