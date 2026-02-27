# Using SQLite for Testing

Write fast, isolated integration tests with no Docker, no server, and no cleanup.

## Overview

SQLite's in-memory mode creates a private database that is automatically destroyed when the connection closes. This makes it perfect for integration tests:

- ✅ No external dependencies — works in CI out of the box
- ✅ Tests run in milliseconds
- ✅ Perfect isolation — each test gets a fresh database
- ✅ Supports all sql-nio features: transactions, pools, `Codable` decoding, `SQLDataTable`, backup

## Basic Test Setup

```swift
import XCTest
import SQLiteNio
import SQLNioCore

final class UserRepositoryTests: XCTestCase {

    // Helper: open a fresh in-memory DB, run the test, close it
    func withDB(_ body: @escaping (SQLiteConnection) async throws -> Void) {
        let exp = expectation(description: "db")
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
        wait(for: [exp], timeout: 10)
    }

    // Create the schema before each test
    func makeSchema(_ conn: SQLiteConnection) async throws {
        try await conn.execute("""
            CREATE TABLE users (
                id    INTEGER PRIMARY KEY AUTOINCREMENT,
                name  TEXT    NOT NULL,
                email TEXT,
                age   INTEGER
            )
        """)
    }

    func testInsertAndQuery() {
        withDB { conn in
            try await makeSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name, email, age) VALUES (@p1, @p2, @p3)",
                [.string("Alice"), .string("alice@example.com"), .int32(30)]
            )
            let rows = try await conn.query("SELECT * FROM users")
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0]["name"].asString(), "Alice")
            XCTAssertEqual(rows[0]["age"].asInt64(), 30)
        }
    }

    func testNullHandling() {
        withDB { conn in
            try await makeSchema(conn)
            _ = try await conn.execute(
                "INSERT INTO users (name) VALUES (@p1)", [.string("Bob")]
            )
            let rows = try await conn.query("SELECT email, age FROM users")
            XCTAssertTrue(rows[0]["email"].isNull)
            XCTAssertTrue(rows[0]["age"].isNull)
        }
    }
}
```

## Testing with Codable Models

```swift
struct User: Codable {
    let id:    Int
    let name:  String
    let email: String?
    let age:   Int?
}

func testCodableDecoding() {
    withDB { conn in
        try await makeSchema(conn)
        _ = try await conn.execute(
            "INSERT INTO users (name, email, age) VALUES (@p1, @p2, @p3)",
            [.string("Carol"), .string("carol@test.com"), .int32(25)]
        )

        let users: [User] = try await conn.query(
            "SELECT id, name, email, age FROM users",
            as: User.self
        )
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users[0].name, "Carol")
        XCTAssertEqual(users[0].age, 25)
    }
}
```

## Testing Transactions

```swift
func testTransactionRollback() {
    withDB { conn in
        try await makeSchema(conn)
        do {
            try await conn.withTransaction {
                _ = try await conn.execute(
                    "INSERT INTO users (name) VALUES (@p1)", [.string("Dave")]
                )
                throw NSError(domain: "test", code: 1)  // force rollback
            }
        } catch { /* expected */ }

        let rows = try await conn.query("SELECT COUNT(*) AS cnt FROM users")
        XCTAssertEqual(rows[0]["cnt"].asInt64(), 0)  // rolled back
    }
}
```

## Testing with SQLDataTable

```swift
func testDataTable() {
    withDB { conn in
        try await makeSchema(conn)
        for i in 1...5 {
            _ = try await conn.execute(
                "INSERT INTO users (name, age) VALUES (@p1, @p2)",
                [.string("User\(i)"), .int32(Int32(20 + i))]
            )
        }

        let rows  = try await conn.query("SELECT * FROM users ORDER BY age")
        let table = SQLDataTable(name: "users", rows: rows)

        XCTAssertEqual(table.rowCount, 5)
        XCTAssertEqual(table.column(named: "name").count, 5)

        // Render as Markdown for debug output
        print(table.toMarkdown())
    }
}
```

## Testing the Same Logic Against Multiple Databases

Because all drivers conform to ``SQLDatabase``, you can run the same test body against SQLite (in CI) and a network database (in integration testing):

```swift
func runBusinessLogicTests(db: any SQLDatabase) async throws {
    // Setup
    try await db.execute("CREATE TABLE IF NOT EXISTS orders (id INTEGER PRIMARY KEY, total REAL)")

    // Test
    _ = try await db.execute("INSERT INTO orders (total) VALUES (@p1)", [.double(99.95)])
    let rows = try await db.query("SELECT total FROM orders")
    XCTAssertEqual(rows[0]["total"].asDouble(), 99.95)
}

// In CI — no Docker needed:
func testWithSQLite() {
    withDB { conn in try await runBusinessLogicTests(db: conn) }
}

// In full integration test — with Docker:
func testWithMySQL() {
    mysqlRunAsync {
        let conn = try await MySQLConnection.connect(configuration: mysqlConfig)
        defer { Task { try? await conn.close() } }
        try await runBusinessLogicTests(db: conn)
    }
}
```

## See Also

- ``SQLiteConnection``
- <doc:SQLiteBackupGuide>
- <doc:TransactionsAndPools>
