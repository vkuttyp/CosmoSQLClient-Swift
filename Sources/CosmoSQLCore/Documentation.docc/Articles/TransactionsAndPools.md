# Transactions and Connection Pools

Group statements atomically and manage connection lifecycles efficiently.

## Overview

All four sql-nio drivers support **transactions** (BEGIN / COMMIT / ROLLBACK) and ship with a built-in **actor-based connection pool** for concurrent workloads.

## Transactions

### Closure-based (recommended)

`withTransaction(_:)` automatically commits on success and rolls back on any thrown error:

```swift
// Works on MSSQLConnection, PostgresConnection, MySQLConnection, SQLiteConnection
try await conn.withTransaction {
    // Transfer funds — both statements succeed or both roll back
    _ = try await conn.execute(
        "UPDATE accounts SET balance = balance - @p1 WHERE id = @p2",
        [.decimal(100), .int32(fromAccountId)]
    )
    _ = try await conn.execute(
        "UPDATE accounts SET balance = balance + @p1 WHERE id = @p2",
        [.decimal(100), .int32(toAccountId)]
    )
    // INSERT into audit log
    _ = try await conn.execute(
        "INSERT INTO transfers (from_id, to_id, amount) VALUES (@p1, @p2, @p3)",
        [.int32(fromAccountId), .int32(toAccountId), .decimal(100)]
    )
    // Any throw here → automatic ROLLBACK
}
```

### Manual control

```swift
try await conn.beginTransaction()
do {
    _ = try await conn.execute("DELETE FROM temp_data WHERE session_id = @p1", [.string(sessionId)])
    _ = try await conn.execute("INSERT INTO archive_data SELECT * FROM temp_data WHERE ...")
    try await conn.commitTransaction()
} catch {
    try? await conn.rollbackTransaction()
    throw error
}
```

### SQLite shorthand

`SQLiteConnection` also exposes `begin()`, `commit()`, and `rollback()`:

```swift
import CosmoSQLite

try await conn.begin()
_ = try await conn.execute("INSERT INTO logs (msg) VALUES (@p1)", [.string("started")])
try await conn.commit()
```

## Connection Pools

For production workloads where multiple `Task`s may query the database concurrently, use a connection pool. Each driver ships with its own actor-based pool.

### SQL Server Pool

```swift
import CosmoMSSQL

let pool = MSSQLConnectionPool(
    configuration: .init(
        host: "sqlserver.example.com",
        database: "MyDb",
        username: "sa",
        password: "Pass!"
    ),
    maxConnections: 10
)

// Use the pool from concurrent tasks safely
async let result1 = pool.withConnection { conn in
    try await conn.query("SELECT * FROM orders WHERE status = @p1", [.string("new")])
}
async let result2 = pool.withConnection { conn in
    try await conn.query("SELECT COUNT(*) AS cnt FROM customers")
}
let (orders, counts) = try await (result1, result2)

// Shutdown when done
await pool.closeAll()
```

### PostgreSQL Pool

```swift
import CosmoPostgres

let pool = PostgresConnectionPool(
    configuration: .init(
        host: "pg.example.com",
        database: "mydb",
        username: "postgres",
        password: "secret"
    ),
    maxConnections: 20
)

let rows = try await pool.withConnection { conn in
    try await conn.query("SELECT id, name FROM users WHERE active = $1", [.bool(true)])
}
```

### MySQL Pool

```swift
import CosmoMySQL

let pool = MySQLConnectionPool(
    configuration: .init(
        host: "mysql.example.com",
        database: "mydb",
        username: "root",
        password: "secret"
    ),
    maxConnections: 10
)
```

### SQLite Pool

```swift
import CosmoSQLite

let pool = SQLiteConnectionPool(
    configuration: .init(storage: .file(path: "/var/db/myapp.sqlite")),
    maxConnections: 5
)
```

## Acquire and Release Manually

When you need to hold a connection across multiple operations in one `Task`:

```swift
let conn = try await pool.acquire()
defer { pool.release(conn) }

let rows = try await conn.query("SELECT * FROM items")
_ = try await conn.execute("UPDATE items SET processed = 1")
// Connection returned to pool by defer
```

## Pool Metrics

All pools expose diagnostic properties:

```swift
print("Idle connections:    \(pool.idleCount)")
print("Active connections:  \(pool.activeCount)")
print("Tasks waiting:       \(pool.waiterCount)")
```

## Combining Pools with Transactions

```swift
try await pool.withConnection { conn in
    try await conn.withTransaction {
        _ = try await conn.execute("INSERT INTO events (name) VALUES (@p1)", [.string("signup")])
        _ = try await conn.execute("UPDATE users SET event_count = event_count + 1 WHERE id = @p1", [.int32(userId)])
    }
}
```

## See Also

- <doc:GettingStarted>
- ``SQLDatabase``
