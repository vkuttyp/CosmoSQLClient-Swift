# Getting Started with sql-nio

Connect to SQL Server, PostgreSQL, MySQL, or SQLite using a single unified API.

## Overview

sql-nio is a pure-Swift, NIO-based SQL driver that supports four database engines through one consistent `async/await` API. You import only the driver(s) you need, and all of them conform to the same ``SQLDatabase`` protocol.

## Installation

Add sql-nio to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/vkuttyp/sql-nio.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            // Pick the drivers you need:
            .product(name: "MSSQLNio",    package: "sql-nio"),
            .product(name: "PostgresNio", package: "sql-nio"),
            .product(name: "MySQLNio",    package: "sql-nio"),
            .product(name: "SQLiteNio",   package: "sql-nio"),
            // Or just the shared types:
            .product(name: "SQLNioCore",  package: "sql-nio"),
        ]
    ),
]
```

## Connecting

Each driver has a `Configuration` struct and a static `connect()` method:

### Microsoft SQL Server

```swift
import MSSQLNio

let conn = try await MSSQLConnection.connect(configuration: .init(
    host:     "sqlserver.example.com",
    database: "AdventureWorks",
    username: "sa",
    password: "YourPassword!"
))
defer { Task { try? await conn.close() } }
```

### PostgreSQL

```swift
import PostgresNio

let conn = try await PostgresConnection.connect(configuration: .init(
    host:     "pg.example.com",
    database: "mydb",
    username: "postgres",
    password: "secret"
))
defer { Task { try? await conn.close() } }
```

### MySQL / MariaDB

```swift
import MySQLNio

let conn = try await MySQLConnection.connect(configuration: .init(
    host:     "mysql.example.com",
    database: "mydb",
    username: "root",
    password: "secret"
))
defer { Task { try? await conn.close() } }
```

### SQLite

```swift
import SQLiteNio

// In-memory (perfect for testing)
let conn = try SQLiteConnection.open()

// File-based (WAL mode enabled automatically)
let conn = try SQLiteConnection.open(
    configuration: .init(storage: .file(path: "/var/db/myapp.sqlite"))
)
defer { Task { try? await conn.close() } }
```

## Your First Query

```swift
// Returns [SQLRow]
let rows = try await conn.query(
    "SELECT id, name, email FROM users WHERE active = @p1",
    [.bool(true)]
)

for row in rows {
    let id    = row["id"].asInt32()!
    let name  = row["name"].asString()!
    let email = row["email"].asString() ?? "(no email)"
    print("\(id): \(name) — \(email)")
}
```

## Placeholder Syntax

All drivers accept `@p1`, `@p2`, … for maximum portability. Each driver's native style is also accepted:

| Driver | Universal | Native |
|--------|-----------|--------|
| SQL Server | `@p1` | `@p1` |
| PostgreSQL | `@p1` | `$1` |
| MySQL | `@p1` | `?` |
| SQLite | `@p1` | `?`, `?1` |

## Executing Statements

Use `execute()` for statements that don't return rows (INSERT / UPDATE / DELETE / DDL).
It returns the number of rows affected:

```swift
let affected = try await conn.execute(
    "UPDATE users SET last_login = @p1 WHERE id = @p2",
    [.date(Date()), .int32(userId)]
)
print("\(affected) row(s) updated")
```

## Writing Database-Agnostic Code

Because all drivers conform to ``SQLDatabase``, you can write functions that work with any engine:

```swift
import SQLNioCore

func archiveOldOrders(db: any SQLDatabase, before cutoff: Date) async throws -> Int {
    try await db.execute(
        "INSERT INTO orders_archive SELECT * FROM orders WHERE created_at < @p1",
        [.date(cutoff)]
    )
}
```

## Error Handling

All errors are thrown as ``SQLError``:

```swift
do {
    let rows = try await conn.query("SELECT * FROM users")
} catch SQLError.serverError(let code, let message, _) {
    print("Server error \(code): \(message)")
} catch SQLError.authenticationFailed(let msg) {
    print("Auth failed: \(msg)")
} catch SQLError.timeout {
    print("Query timed out")
} catch {
    print("Unexpected error: \(error)")
}
```

## See Also

- <doc:WorkingWithSQLValue>
- <doc:DecodingRows>
- <doc:TransactionsAndPools>
