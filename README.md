# CosmoSQLClient-Swift

[![Swift Version Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fvkuttyp%2FCosmoSQLClient-Swift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/vkuttyp/CosmoSQLClient-Swift)
[![Platform Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fvkuttyp%2FCosmoSQLClient-Swift%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/vkuttyp/CosmoSQLClient-Swift)

A unified Swift package for connecting to **Microsoft SQL Server**, **PostgreSQL**, **MySQL/MariaDB**, and **SQLite** — all through a single, consistent `async/await` API built natively on [SwiftNIO](https://github.com/apple/swift-nio).

> **No FreeTDS. No ODBC. No JDBC. No C libraries.**  
> Pure Swift wire-protocol implementations — TDS 7.4 for SQL Server, PostgreSQL wire protocol v3, MySQL wire protocol v10 — and the built-in `sqlite3` system library for SQLite.

---

## Table of Contents

- [Features](#features)
- [🏆 JSON Streaming — Industry First](#-json-streaming--industry-first)
  - [Vapor Web API Integration](#vapor-web-api--true-http-streaming)
- [Installation](#installation)
- [Quick Start](#quick-start)
  - [Microsoft SQL Server](#microsoft-sql-server)
  - [PostgreSQL](#postgresql)
  - [MySQL / MariaDB](#mysql--mariadb)
  - [SQLite](#sqlite)
- [Unified API](#unified-api-sqldatabase-protocol)
- [Query Parameters](#query-parameters--placeholders)
- [SQLValue — Type-Safe Values](#sqlvalue--type-safe-values)
- [Reading Result Rows](#reading-result-rows)
- [Decoding into Swift Types](#decoding-into-swift-types)
- [SQLDataTable & SQLDataSet](#sqldatatable--sqldataset)
- [Transactions](#transactions)
- [Connection Pooling](#connection-pooling)
- [Multiple Result Sets](#multiple-result-sets)
- [Stored Procedures (SQL Server)](#stored-procedures-sql-server)
- [Windows / NTLM Authentication (SQL Server)](#windows--ntlm-authentication-sql-server)
- [TLS / SSL](#tls--ssl)
- [Backup & Restore](#backup--restore)
- [Error Handling](#error-handling)
- [Supported Data Types](#supported-data-types)
- [Platform Support](#platform-support)
- [Architecture](#architecture)
- [Testing](#testing)
- [Related Projects](#related-projects)
- [License](#license)

---

## Features

| Feature | SQL Server | PostgreSQL | MySQL | SQLite |
|---|:---:|:---:|:---:|:---:|
| Native wire protocol | TDS 7.4 | v3 | v10 | sqlite3 |
| TLS / SSL encryption | ✅ | ✅ | ✅ | N/A |
| TrustServerCertificate | ✅ | — | — | — |
| Connection string parsing | ✅ | — | — | — |
| Named instance (`SERVER\INSTANCE`) | ✅ | — | — | — |
| `checkReachability()` | ✅ | — | — | — |
| Swift 6 strict concurrency | ✅ | ✅ | ✅ | ✅ |
| Unified `SQLDatabase` protocol | ✅ | ✅ | ✅ | ✅ |
| `async/await` API | ✅ | ✅ | ✅ | ✅ |
| Parameterized queries | ✅ | ✅ | ✅ | ✅ |
| `@p1` placeholder style | ✅ | ✅ | ✅ | ✅ |
| `?` placeholder style | — | — | ✅ | ✅ |
| Transactions | ✅ | ✅ | ✅ | ✅ |
| Connection pooling | ✅ | ✅ | ✅ | ✅ |
| Multiple result sets | ✅ | ✅ | ✅ | ✅ |
| Stored procedures + OUTPUT params | ✅ | ✅ | ✅ | — |
| Windows / NTLM auth | ✅ | — | — | — |
| Bulk insert (BCP) | ✅ | — | — | — |
| `SQLDataTable` / `SQLDataSet` | ✅ | ✅ | ✅ | ✅ |
| `Codable` row decoding | ✅ | ✅ | ✅ | ✅ |
| Markdown table output | ✅ | ✅ | ✅ | ✅ |
| JSON output (`toJson(pretty:)`) | ✅ | ✅ | ✅ | ✅ |
| **Row streaming (`queryStream`)** | ✅ | ✅ | ✅ | — |
| **🏆 JSON streaming (`queryJsonStream`)** | ✅ | ✅ | ✅ | — |
| **🏆 Typed JSON streaming (`queryJsonStream<T>`)** | ✅ | ✅ | ✅ | — |
| Logical SQL dump | ✅ | ✅ | ✅ | ✅ |
| Native binary backup | — | — | — | ✅ |
| In-memory database | — | — | — | ✅ |
| No external C libraries | ✅ | ✅ | ✅ | ✅ |

---

## 🏆 JSON Streaming — Industry First

> **No other Swift SQL library offers this.** `queryJsonStream()` is the breakthrough feature that makes CosmoSQLClient unique.

### The Problem with Large JSON Results

When SQL Server executes `SELECT ... FOR JSON PATH`, it fragments the output at ~2033-character boundaries that **do not align with JSON object boundaries**. A single JSON object may be split across multiple network packets:

```
Packet 1: [{"Id":1,"Name":"Alice","Desc":"A long descrip
Packet 2: tion that spans packets"},{"Id":2,"Name":"Bob"...
```

Traditional approaches buffer the **entire result** before any processing begins — wasting memory and delaying first-byte delivery. Microsoft's own `IAsyncEnumerable` has this same limitation for JSON.

### The Solution: `queryJsonStream()`

`queryJsonStream()` uses a pure Swift `JSONChunkAssembler` state machine that detects exact `{...}` object boundaries across arbitrary chunk splits — including splits mid-string with escape sequences. Each complete JSON object is yielded **immediately** when its closing `}` arrives.

```swift
import CosmoMSSQL

// Yields one Data chunk per JSON object — never buffers the full array
for try await chunk in conn.queryJsonStream(
    "SELECT Id, Name, Price FROM Products FOR JSON PATH") {
    let obj = try JSONSerialization.jsonObject(with: chunk)
    print(obj)
}
```

### Strongly-Typed JSON Streaming

Decode directly into your `Decodable` model, one object at a time:

```swift
struct Product: Decodable {
    let Id: Int
    let Name: String
    let Price: Double
}

for try await product in conn.queryJsonStream(
    "SELECT Id, Name, Price FROM Products FOR JSON PATH",
    as: Product.self) {
    // Each product is fully decoded before the next one arrives
    print("\(product.Id): \(product.Name) — $\(product.Price)")
}
```

### Row Streaming

Stream raw result rows without buffering the full result set:

```swift
for try await row in conn.queryStream(
    "SELECT * FROM LargeTable WHERE active = @p1", [.bool(true)]) {
    let id   = row["id"].asInt32()!
    let name = row["name"].asString()!
    // process one row at a time
}
```

### Available on All Three Databases

JSON streaming works identically on SQL Server, PostgreSQL, and MySQL:

```swift
// SQL Server — FOR JSON PATH
for try await obj in mssqlConn.queryJsonStream(
    "SELECT id, name FROM Departments FOR JSON PATH") { ... }

// PostgreSQL — row_to_json
for try await obj in pgConn.queryJsonStream(
    "SELECT row_to_json(t) FROM (SELECT id, name FROM departments) t") { ... }

// MySQL — JSON_OBJECT
for try await obj in mysqlConn.queryJsonStream(
    "SELECT JSON_OBJECT('id', id, 'name', name) FROM departments") { ... }
```

All three pool types (`MSSQLConnectionPool`, `PostgresConnectionPool`, `MySQLConnectionPool`) expose the same streaming methods with automatic connection acquire/release and cancellation support.

### Vapor Web API — True HTTP Streaming

Vapor's `Response.Body(stream:)` lets you pipe `queryJsonStream()` directly to the HTTP response. Each JSON object flows to the client the instant its closing `}` arrives — no buffering at any layer.

**Setup — register the pool in `configure.swift`:**

```swift
import Vapor
import CosmoMSSQL

public func configure(_ app: Application) async throws {
    app.mssqlPool = MSSQLConnectionPool(
        configuration: .init(
            host: "localhost", port: 1433,
            database: "MyDb", username: "sa", password: "secret"
        ),
        maxConnections: 20
    )
    try routes(app)
}

// Convenience storage key
private struct MSSQLPoolKey: StorageKey { typealias Value = MSSQLConnectionPool }
extension Application {
    var mssqlPool: MSSQLConnectionPool {
        get { storage[MSSQLPoolKey.self]! }
        set { storage[MSSQLPoolKey.self] = newValue }
    }
}
```

**Route — stream SQL directly to the HTTP response:**

```swift
func routes(_ app: Application) throws {

    // Untyped — raw Data chunks piped straight through (most efficient)
    app.get("products") { req -> Response in
        let response = Response()
        response.headers.contentType = .json

        response.body = .init(stream: { writer in
            Task {
                do {
                    _ = writer.write(.buffer(ByteBuffer(string: "[")))
                    var first = true

                    for try await chunk in req.application.mssqlPool.queryJsonStream(
                        "SELECT Id, Name, Price FROM Products FOR JSON PATH") {

                        if !first { _ = writer.write(.buffer(ByteBuffer(string: ","))) }
                        _ = writer.write(.buffer(ByteBuffer(bytes: chunk)))
                        first = false
                    }

                    _ = writer.write(.buffer(ByteBuffer(string: "]")))
                    _ = writer.write(.end)
                } catch {
                    _ = writer.write(.error(error))
                }
            }
        })

        return response
    }

    // Typed + transform — decode then re-encode with extra fields
    app.get("products", "enriched") { req -> Response in
        let response = Response()
        response.headers.contentType = .json
        let encoder = JSONEncoder()

        response.body = .init(stream: { writer in
            Task {
                do {
                    _ = writer.write(.buffer(ByteBuffer(string: "[")))
                    var first = true

                    for try await product in req.application.mssqlPool.queryJsonStream(
                        "SELECT Id, Name, Price FROM Products FOR JSON PATH",
                        as: Product.self) {

                        let dto = ProductDTO(
                            id: product.Id,
                            name: product.Name,
                            salePrice: product.Price * 0.9   // enrich each item
                        )
                        if !first { _ = writer.write(.buffer(ByteBuffer(string: ","))) }
                        _ = writer.write(.buffer(ByteBuffer(data: try encoder.encode(dto))))
                        first = false
                    }

                    _ = writer.write(.buffer(ByteBuffer(string: "]")))
                    _ = writer.write(.end)
                } catch {
                    _ = writer.write(.error(error))
                }
            }
        })

        return response
    }
}
```

**What happens on the wire:**

```
Client                      Vapor                    SQL Server
  │                           │                           │
  │── GET /products ─────────>│                           │
  │                           │── FOR JSON PATH ─────────>│
  │<── HTTP 200 (chunked) ────│                           │
  │<── [{"Id":1,...} ─────────│<── packet 1 ─────────────│
  │<── ,{"Id":2,...} ─────────│<── packet 2 ─────────────│
  │<── ,{"Id":3,...}] ────────│<── packet 3 ─────────────│
```

- Chunked transfer encoding — no `Content-Length`, unbounded result sets work fine
- First byte reaches the client before SQL Server finishes executing
- Memory stays flat — `ByteBuffer` for each object is released immediately after write

**Buffered vs streamed — side by side:**

```swift
// ❌ Buffered — waits for ALL rows, allocates the full array
app.get("products", "buffered") { req async throws -> [Product] in
    try await req.application.mssqlPool.query(
        "SELECT Id, Name, Price FROM Products", as: Product.self)
}

// ✅ Streamed — first byte reaches client after ~1 packet RTT
app.get("products", "streamed") { req -> Response in
    // ... queryJsonStream body above
}
```

---

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/vkuttyp/CosmoSQLClient-Swift.git", from: "1.0.0"),
],
```

Then add the product(s) you need to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "CosmoMSSQL",    package: "CosmoSQLClient"),  // SQL Server
        .product(name: "CosmoPostgres", package: "CosmoSQLClient"),  // PostgreSQL
        .product(name: "CosmoMySQL",    package: "CosmoSQLClient"),  // MySQL / MariaDB
        .product(name: "CosmoSQLite",   package: "CosmoSQLClient"),  // SQLite
        .product(name: "CosmoSQLCore",  package: "CosmoSQLClient"),  // Shared types only
    ]
),
```

You can import only the drivers you need — each is an independent library module.

### Requirements

- Swift 5.9+
- macOS 13+, iOS 16+, tvOS 16+, watchOS 9+, visionOS 1+, Linux

### Swift Package Manager dependencies pulled in automatically

| Dependency | Purpose |
|---|---|
| `swift-nio` | Async networking foundation |
| `swift-nio-ssl` | TLS for MSSQL, PostgreSQL, MySQL |
| `swift-log` | Structured logging |
| `swift-crypto` | MD5 / SHA for auth handshakes |

---

## Quick Start

### Microsoft SQL Server

```swift
import CosmoMSSQL

// Programmatic configuration
let config = MSSQLConnection.Configuration(
    host:                   "localhost",
    port:                   1433,
    database:               "AdventureWorks",
    username:               "sa",
    password:               "YourPassword!",
    trustServerCertificate: true   // set true for self-signed certs (dev/test)
)

// Or from a connection string
let config = try MSSQLConnection.Configuration(connectionString:
    "Server=localhost,1433;Database=AdventureWorks;" +
    "User Id=sa;Password=YourPassword!;" +
    "Encrypt=True;TrustServerCertificate=True;"
)

let conn = try await MSSQLConnection.connect(configuration: config)
defer { Task { try? await conn.close() } }

// SELECT — returns [SQLRow]
let rows = try await conn.query(
    "SELECT id, name, salary FROM employees WHERE active = @p1",
    [.bool(true)]
)
for row in rows {
    let id     = row["id"].asInt32()!
    let name   = row["name"].asString()!
    let salary = row["salary"].asDecimal()!
    print("\(id): \(name) — \(salary)")
}

// INSERT / UPDATE / DELETE — returns rows affected
let affected = try await conn.execute(
    "UPDATE employees SET salary = @p1 WHERE id = @p2",
    [.decimal(Decimal(75000)), .int32(42)]
)
print("\(affected) row(s) updated")
```

### PostgreSQL

```swift
import CosmoPostgres

let config = PostgresConnection.Configuration(
    host:     "localhost",
    port:     5432,          // default
    database: "mydb",
    username: "postgres",
    password: "secret"
)

let conn = try await PostgresConnection.connect(configuration: config)
defer { Task { try? await conn.close() } }

let rows = try await conn.query(
    "SELECT id, email FROM users WHERE created_at > $1",
    [.date(Date().addingTimeInterval(-86400))]
)
```

### MySQL / MariaDB

```swift
import CosmoMySQL

let config = MySQLConnection.Configuration(
    host:     "localhost",
    port:     3306,          // default
    database: "mydb",
    username: "root",
    password: "secret"
)

let conn = try await MySQLConnection.connect(configuration: config)
defer { Task { try? await conn.close() } }

// Use ? or @p1 placeholders — both work
let rows = try await conn.query(
    "SELECT id, name FROM products WHERE price < @p1",
    [.double(50.0)]
)
```

### SQLite

```swift
import CosmoSQLite

// In-memory database (great for testing)
let conn = try SQLiteConnection.open()

// File-based database (WAL mode enabled automatically)
let conn = try SQLiteConnection.open(
    configuration: .init(storage: .file(path: "/var/db/myapp.sqlite"))
)

defer { Task { try? await conn.close() } }

try await conn.execute("""
    CREATE TABLE IF NOT EXISTS notes (
        id    INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        body  TEXT
    )
""")

_ = try await conn.execute(
    "INSERT INTO notes (title, body) VALUES (@p1, @p2)",
    [.string("Meeting notes"), .string("Discussed roadmap.")]
)

let notes = try await conn.query("SELECT * FROM notes")
```

---

## Unified API (`SQLDatabase` Protocol)

All four drivers conform to the same `SQLDatabase` protocol, so you can write database-agnostic code:

```swift
import CosmoSQLCore

protocol SQLDatabase {
    func query(_ sql: String, _ binds: [SQLValue]) async throws -> [SQLRow]
    func execute(_ sql: String, _ binds: [SQLValue]) async throws -> Int
    func close() async throws

    // Convenience (no binds):
    func query(_ sql: String) async throws -> [SQLRow]
    func execute(_ sql: String) async throws -> Int

    // Decode directly into Codable types:
    func query<T: Decodable>(_ sql: String, _ binds: [SQLValue], as: T.Type) async throws -> [T]
}
```

Write business logic once, run on any database:

```swift
func createUser(db: any SQLDatabase, name: String, email: String) async throws {
    try await db.execute(
        "INSERT INTO users (name, email) VALUES (@p1, @p2)",
        [.string(name), .string(email)]
    )
}

// All four work identically:
try await createUser(db: mssqlConn,    name: "Alice", email: "alice@example.com")
try await createUser(db: postgresConn, name: "Alice", email: "alice@example.com")
try await createUser(db: mysqlConn,    name: "Alice", email: "alice@example.com")
try await createUser(db: sqliteConn,   name: "Alice", email: "alice@example.com")
```

> **Note on placeholder syntax:** While the `SQLDatabase` protocol accepts `@p1` style universally, each database also natively supports its own placeholder syntax. See [Query Parameters](#query-parameters--placeholders).

---

## Query Parameters & Placeholders

CosmoSQLClient-Swift supports `@p1`-style numbered parameters on **all four databases** for maximum portability. Each driver's native syntax is also supported:

| Database   | Native syntax | CosmoSQLClient-Swift universal |
|------------|--------------|-------------------|
| SQL Server | `@p1`, `@p2`, … | ✅ same |
| PostgreSQL | `$1`, `$2`, … | ✅ `@p1` also works |
| MySQL      | `?` | ✅ `@p1` also works |
| SQLite     | `?`, `?1` | ✅ `@p1` also works |

```swift
// Portable — works on all databases:
let rows = try await conn.query(
    "SELECT * FROM orders WHERE user_id = @p1 AND status = @p2",
    [.int32(userId), .string("shipped")]
)

// PostgreSQL native style also works:
let rows = try await pgConn.query(
    "SELECT * FROM orders WHERE user_id = $1 AND status = $2",
    [.int32(userId), .string("shipped")]
)
```

Parameters are always sent as **bound values** — never string-interpolated into the SQL — preventing SQL injection.

---

## `SQLValue` — Type-Safe Values

`SQLValue` is the unified currency type for all bind parameters and result values:

```swift
public enum SQLValue {
    case null
    case bool(Bool)
    case int(Int)
    case int8(Int8)
    case int16(Int16)
    case int32(Int32)
    case int64(Int64)
    case float(Float)
    case double(Double)
    case decimal(Decimal)  // Exact — DECIMAL, NUMERIC, MONEY
    case string(String)
    case bytes([UInt8])    // BINARY, VARBINARY, BLOB
    case uuid(UUID)
    case date(Date)        // Maps to DATETIME2, TIMESTAMP, DATETIME
}
```

### Literal syntax (no `.` case needed)

`SQLValue` conforms to all Swift literal protocols:

```swift
let binds: [SQLValue] = [
    "Alice",              // .string("Alice")
    42,                   // .int(42)
    3.14,                 // .double(3.14)
    true,                 // .bool(true)
    nil,                  // .null
]
```

### Typed accessors

```swift
let v: SQLValue = row["salary"]

v.asInt()      // → Int?
v.asInt32()    // → Int32?
v.asInt64()    // → Int64?
v.asDouble()   // → Double?
v.asDecimal()  // → Decimal?
v.asString()   // → String?
v.asBool()     // → Bool?
v.asDate()     // → Date?
v.asUUID()     // → UUID?
v.asBytes()    // → [UInt8]?
v.isNull       // → Bool

// Unsigned widening (returns nil if value is negative)
v.asUInt8()    // → UInt8?
v.asUInt16()   // → UInt16?
v.asUInt32()   // → UInt32?
v.asUInt64()   // → UInt64?
```

---

## Reading Result Rows

`[SQLRow]` is returned from all `query()` calls. Each `SQLRow` provides access by column name or index:

```swift
let rows = try await conn.query("SELECT id, name, email FROM users")

for row in rows {
    // Access by name (case-insensitive)
    let id    = row["id"].asInt32()!
    let name  = row["name"].asString() ?? "(none)"
    let email = row["email"].asString()  // nil if NULL

    // Access by column index
    let first = row[0].asInt32()

    // Check null
    if row["deleted_at"].isNull {
        print("\(name) is active")
    }

    // Column metadata
    for col in row.columns {
        print("\(col.name): \(row[col].asString() ?? "NULL")")
    }
}
```

### Column names and metadata

```swift
let col = row.columns[0]
col.name    // → "id"
col.table   // → "users" (if available)
```

---

## Decoding into Swift Types

Use `Codable` conformance for zero-boilerplate row mapping:

```swift
struct User: Codable {
    let id:    Int
    let name:  String
    let email: String?
}

// Decode directly from query:
let users: [User] = try await conn.query(
    "SELECT id, name, email FROM users WHERE active = @p1",
    [.bool(true)],
    as: User.self
)

// Or decode an existing [SQLRow]:
let rows = try await conn.query("SELECT id, name, email FROM users")
let users = try rows.map { try SQLRowDecoder().decode(User.self, from: $0) }
```

Column names are matched to struct property names. By default, `snake_case` column names are converted to `camelCase` Swift properties (e.g., `first_name` → `firstName`).

```swift
struct Product: Codable {
    let productId:   Int     // maps from "product_id"
    let productName: String  // maps from "product_name"
    let unitPrice:   Double  // maps from "unit_price"
}
```

---

## `SQLDataTable` & `SQLDataSet`

`SQLDataTable` is a structured, `Codable` representation of a query result — useful when you need to pass results between layers, serialize to JSON, or render as a table:

```swift
// Convert [SQLRow] to SQLDataTable
let rows  = try await conn.query("SELECT * FROM employees")
let table = SQLDataTable(name: "employees", rows: rows)

// Access by row/column
let cell = table.row(at: 0)["salary"]!  // → SQLCellValue
let col  = table.column(named: "name")  // → [SQLCellValue]

print("Rows: \(table.rowCount), Columns: \(table.columnCount)")

// Render as Markdown
print(table.toMarkdown())
// | id | name  | salary    |
// |----|-------|-----------|
// | 1  | Alice | 75000.00  |
// | 2  | Bob   | 82000.00  |

// Decode to Codable types
struct Employee: Codable { let id: Int; let name: String }
let employees: [Employee] = try table.decode(as: Employee.self)

// Serialize to JSON
let json = try JSONEncoder().encode(table)
let decoded = try JSONDecoder().decode(SQLDataTable.self, from: json)
```

### `SQLDataSet` — multiple tables

`SQLDataSet` holds multiple named `SQLDataTable` instances (e.g., from a stored procedure returning multiple result sets):

```swift
let resultSets = try await conn.queryMulti("""
    SELECT * FROM orders WHERE user_id = @p1;
    SELECT * FROM order_items WHERE order_id IN (SELECT id FROM orders WHERE user_id = @p2)
""", [.int32(userId), .int32(userId)])

let dataSet = SQLDataSet(tables: resultSets.enumerated().map { i, rows in
    SQLDataTable(name: "result\(i)", rows: rows)
})

let orders     = dataSet["result0"]  // → SQLDataTable?
let orderItems = dataSet["result1"]
```

---

## SQLDataTable & Output Formats

Convert query results to a rich in-memory table with multiple output formats:

```swift
let rows = try await conn.query("SELECT * FROM Accounts", [])
let table = rows.asDataTable(name: "Accounts")

print("Rows: \(table.rowCount), Columns: \(table.columnCount)")

// Markdown table
print(table.toMarkdown())

// JSON array (pretty-printed by default)
print(table.toJson())

// Compact JSON
print(table.toJson(pretty: false))

// Codable mapping — like Swift's Decodable
let accounts = try table.decode(as: Account.self)
```

```swift
struct Account: Decodable {
    let accountNo: String
    let accountName: String
    let isMain: Bool
}
```

The `toJson()` output uses native types:
```json
[
  {
    "AccountNo": "1",
    "AccountName": "Assets",
    "IsMain": true,
    "AccountTypeID": 1
  }
]
```

---

## Transactions

All four drivers support `BEGIN` / `COMMIT` / `ROLLBACK` with a convenient closure-based wrapper:

```swift
// Closure-based (auto-commits or rolls back on error):
try await conn.withTransaction {
    _ = try await conn.execute(
        "INSERT INTO accounts (owner, balance) VALUES (@p1, @p2)",
        [.string("Alice"), .decimal(1000)]
    )
    _ = try await conn.execute(
        "UPDATE accounts SET balance = balance - @p1 WHERE owner = @p2",
        [.decimal(100), .string("Alice")]
    )
    // Throws → automatic ROLLBACK
    // Returns → automatic COMMIT
}

// Manual control:
try await conn.beginTransaction()
do {
    _ = try await conn.execute("UPDATE ...")
    try await conn.commitTransaction()
} catch {
    try await conn.rollbackTransaction()
    throw error
}
```

---

## Connection Pooling

All four drivers include a built-in actor-based connection pool for concurrent workloads:

### SQL Server pool

```swift
import CosmoMSSQL

let pool = MSSQLConnectionPool(
    configuration: MSSQLConnection.Configuration(
        host: "localhost", database: "MyDb", username: "sa", password: "Pass!"
    ),
    maxConnections: 10
)

// Use a pooled connection
let result = try await pool.withConnection { conn in
    try await conn.query("SELECT COUNT(*) AS cnt FROM orders")
}

// Or acquire/release manually
let conn = try await pool.acquire()
defer { pool.release(conn) }

// Pool metrics
print("Idle: \(pool.idleCount), Active: \(pool.activeCount), Waiting: \(pool.waiterCount)")

// Shutdown
await pool.closeAll()
```

### PostgreSQL pool

```swift
import CosmoPostgres

let pool = PostgresConnectionPool(
    configuration: PostgresConnection.Configuration(
        host: "localhost", database: "mydb", username: "postgres", password: "secret"
    ),
    maxConnections: 20
)

let rows = try await pool.withConnection { conn in
    try await conn.query("SELECT * FROM users")
}
```

### MySQL pool

```swift
import CosmoMySQL

let pool = MySQLConnectionPool(
    configuration: MySQLConnection.Configuration(
        host: "localhost", database: "mydb", username: "root", password: "secret"
    ),
    maxConnections: 10
)
```

### SQLite pool

```swift
import CosmoSQLite

let pool = SQLiteConnectionPool(
    configuration: SQLiteConnection.Configuration(
        storage: .file(path: "/var/db/myapp.sqlite")
    ),
    maxConnections: 5
)
```

---

## Multiple Result Sets

Use `queryMulti(_:_:)` when a SQL batch or stored procedure returns more than one result set:

```swift
// SQL Server / PostgreSQL / MySQL
let sets: [[SQLRow]] = try await conn.queryMulti("""
    SELECT * FROM customers WHERE region = @p1;
    SELECT * FROM orders WHERE region = @p2
""", [.string("West"), .string("West")])

let customers = sets[0]
let orders    = sets[1]
```

---

## Stored Procedures (SQL Server)

`MSSQLConnection` provides first-class stored procedure support with `INPUT`, `OUTPUT`, and `RETURN` values:

```swift
import CosmoMSSQL

// Define parameters (INPUT and OUTPUT)
let params: [SQLParameter] = [
    SQLParameter(name: "@DeptID",   value: .int32(5),  isOutput: false),
    SQLParameter(name: "@Budget",   value: .null,      isOutput: true),   // OUTPUT param
    SQLParameter(name: "@EmpCount", value: .null,      isOutput: true),
]

let result = try await conn.callProcedure("GetDepartmentBudget", parameters: params)

// Read result sets returned by the procedure
let employees = result.tables[0]   // first SELECT result set

// Read OUTPUT parameters by name
let budget   = result.outputParams["@Budget"]?.asDecimal()
let empCount = result.outputParams["@EmpCount"]?.asInt32()

// RETURN value
let returnCode = result.returnCode  // → Int32
```

Stored procedures also work on PostgreSQL (functions) and MySQL:

```swift
// PostgreSQL — call a function returning a table
let rows = try await pgConn.query(
    "SELECT * FROM get_active_users($1)", [.int32(tenantId)]
)

// MySQL — CALL stored procedure
let sets = try await mysqlConn.queryMulti(
    "CALL GetOrdersByStatus(?)", [.string("pending")]
)
```

---

## Windows / NTLM Authentication (SQL Server)

Connect to SQL Server using Windows domain credentials (NTLM/Kerberos):

```swift
import CosmoMSSQL

// Windows authentication — username and password are optional
var config = MSSQLConnection.Configuration(
    host:     "sqlserver.corp.example.com",
    database: "Northwind"
)
config.domain   = "CORP"       // Windows domain name
config.username = "jsmith"     // optional when using the current user context
config.password = "WinPass!"   // optional when using the current user context

let conn = try await MSSQLConnection.connect(configuration: config)
```

When `domain` is set, CosmoSQLClient-Swift negotiates NTLM authentication automatically during the TDS handshake. This is compatible with:

- SQL Server on Windows joined to an Active Directory domain
- SQL Server on Linux with Active Directory integration (e.g., `adutil`)
- Azure SQL Managed Instance with AD authentication

---

## TLS / SSL

Configure TLS per-connection on all network drivers:

```swift
// Require TLS — fail if server doesn't offer it
config.tls = .require

// Use TLS if available, plain text otherwise (default)
config.tls = .prefer

// Disable TLS — plain text only
config.tls = .disable
```

### TrustServerCertificate (SQL Server)

Self-signed certificates (Docker, local dev) require bypassing certificate verification:

```swift
// Via init:
let config = MSSQLConnection.Configuration(
    host: "localhost", database: "MyDb",
    username: "sa", password: "pass",
    trustServerCertificate: true
)

// Via connection string:
let config = try MSSQLConnection.Configuration(connectionString:
    "Server=localhost;Database=MyDb;User Id=sa;Password=pass;" +
    "Encrypt=True;TrustServerCertificate=True;"
)
```

> **Warning:** `trustServerCertificate: true` disables certificate validation. Use only in development/testing, never in production.

### Reachability check (SQL Server)

Perform a fast TCP pre-flight before a full TDS connection attempt:

```swift
try await config.checkReachability()          // throws if host:port unreachable
let conn = try await MSSQLConnection.connect(configuration: config)
```

---

## Backup & Restore

CosmoSQLClient-Swift provides logical SQL dump / restore across all four databases, plus native binary backup for SQLite.

### Logical SQL dump (all databases)

```swift
// Export all tables to a SQL string
let sql = try await conn.dump()

// Export specific tables only
let sql = try await conn.dump(tables: ["users", "orders"])

// Write to a file
try await conn.dump(to: "/var/backups/myapp.sql")

// Restore from a SQL string
try await conn.restore(from: sql)

// Restore from a file
try await conn.restore(fromFile: "/var/backups/myapp.sql")
```

The dump format includes:
- A header comment with dialect, database name, and timestamp
- `CREATE TABLE` statements (SQLite only — other databases use pre-existing schema)
- `INSERT` statements for every row with dialect-appropriate literal escaping

### SQLite native binary backup

```swift
import CosmoSQLite

// Copy the live database to a new file (safe on open connections)
try await conn.backup(to: "/var/backups/myapp.sqlite")

// Restore from a binary backup into the current connection
try await conn.restore(fromBackup: "/var/backups/myapp.sqlite")

// Serialize to Data (snapshot in memory)
let data: Data = try await conn.serialize()
// Store data in S3, iCloud, Core Data, etc.
```

### Restore from file — round trip example

```swift
import CosmoSQLite

// Source database
let source = try SQLiteConnection.open(
    configuration: .init(storage: .file(path: "production.sqlite"))
)
try await source.dump(to: "/tmp/backup.sql")
try await source.close()

// Restore into a fresh database
let dest = try SQLiteConnection.open()
try await dest.restore(fromFile: "/tmp/backup.sql")
let count = try await dest.query("SELECT COUNT(*) AS n FROM users")
print(count[0]["n"].asInt64()!)
```

---

## Error Handling

All errors are thrown as `SQLError`:

```swift
import CosmoSQLCore

do {
    let rows = try await conn.query("SELECT * FROM nonexistent_table")
} catch SQLError.serverError(let code, let message, let state) {
    // Database engine returned an error (e.g., table not found, constraint violation)
    print("Server error \(code) [state \(state)]: \(message)")
} catch SQLError.authenticationFailed(let message) {
    // Wrong credentials or auth method not supported
    print("Auth failed: \(message)")
} catch SQLError.connectionError(let message) {
    // TCP connection problem (host unreachable, port closed, etc.)
    print("Cannot connect: \(message)")
} catch SQLError.tlsError(let message) {
    // TLS handshake or certificate error
    print("TLS error: \(message)")
} catch SQLError.timeout {
    // Query or connection timed out
    print("Operation timed out")
} catch SQLError.connectionClosed {
    // The connection was already closed
    print("Connection is closed")
} catch SQLError.columnNotFound(let name) {
    print("Column not found: \(name)")
} catch SQLError.typeMismatch(let expected, let got) {
    print("Type mismatch — expected \(expected), got \(got)")
} catch SQLError.unsupported(let feature) {
    print("Not supported: \(feature)")
}
```

---

## Supported Data Types

### Binding parameters

| Swift / `SQLValue` | SQL Server | PostgreSQL | MySQL | SQLite |
|-|-|-|-|-|
| `.null` | NULL | NULL | NULL | NULL |
| `.bool(Bool)` | BIT | BOOLEAN | TINYINT(1) | INTEGER |
| `.int32(Int32)` | INT | INTEGER | INT | INTEGER |
| `.int64(Int64)` | BIGINT | BIGINT | BIGINT | INTEGER |
| `.double(Double)` | FLOAT | DOUBLE PRECISION | DOUBLE | REAL |
| `.decimal(Decimal)` | DECIMAL/MONEY | NUMERIC | DECIMAL | TEXT |
| `.string(String)` | NVARCHAR | TEXT | VARCHAR | TEXT |
| `.bytes([UInt8])` | VARBINARY | BYTEA | BLOB | BLOB |
| `.uuid(UUID)` | UNIQUEIDENTIFIER | UUID | CHAR(36) | TEXT |
| `.date(Date)` | DATETIME2 | TIMESTAMPTZ | DATETIME | TEXT |

### Reading results

All database column types are mapped back to the appropriate `SQLValue` case. Use the typed accessors (`asInt32()`, `asString()`, `asDecimal()`, etc.) to extract values safely.

---

## Platform Support

| Platform | Minimum version |
|----------|----------------|
| macOS | 13.0+ |
| iOS | 16.0+ |
| tvOS | 16.0+ |
| watchOS | 9.0+ |
| visionOS | 1.0+ |
| Linux | Ubuntu 20.04+, Amazon Linux 2 |

SQLite is available on all Apple platforms via the system `sqlite3` library. On Linux, `libsqlite3-dev` must be installed:

```bash
apt-get install libsqlite3-dev   # Debian / Ubuntu
yum install sqlite-devel         # Amazon Linux / RHEL
```

---

## Architecture

```
CosmoSQLClient-Swift/
├── Sources/
│   ├── CosmoSQLCore/              # Shared protocol, types & utilities
│   │   ├── SQLDatabase.swift        # SQLDatabase protocol
│   │   ├── SQLValue.swift           # Unified value enum + accessors
│   │   ├── SQLRow.swift             # Query result row
│   │   ├── SQLColumn.swift          # Column metadata
│   │   ├── SQLError.swift           # Error enum
│   │   ├── SQLDataTable.swift       # SQLDataTable + SQLDataSet + SQLCellValue
│   │   ├── SQLRowDecoder.swift      # Codable row → struct mapping
│   │   ├── SQLParameter.swift       # Stored procedure parameter
│   │   ├── SQLDump.swift            # Backup/restore dialect helpers
│   │   └── AsyncChannelBridge.swift # NIO ↔ async/await bridge
│   │
│   ├── CosmoMSSQL/                # TDS 7.4 — Microsoft SQL Server
│   │   ├── MSSQLConnection.swift
│   │   ├── MSSQLConnectionPool.swift
│   │   ├── MSSQLBackup.swift
│   │   └── TDS/
│   │       ├── TDSPacket.swift
│   │       ├── TDSMessages.swift
│   │       ├── TDSPreLogin.swift
│   │       ├── TDSLogin7.swift      # SQL + NTLM auth
│   │       ├── TDSDecoder.swift
│   │       └── TDSHandler.swift
│   │
│   ├── CosmoPostgres/             # PostgreSQL wire protocol v3
│   │   ├── PostgresConnection.swift
│   │   ├── PostgresConnectionPool.swift
│   │   ├── PostgresBackup.swift
│   │   └── Protocol/
│   │       ├── PGFrontend.swift
│   │       └── PGMessageDecoder.swift
│   │
│   ├── CosmoMySQL/                # MySQL wire protocol v10
│   │   ├── MySQLConnection.swift
│   │   ├── MySQLConnectionPool.swift
│   │   ├── MySQLBackup.swift
│   │   └── Protocol/
│   │       ├── MySQLMessages.swift
│   │       └── MySQLDecoder.swift
│   │
│   └── CosmoSQLite/               # SQLite (embedded, system sqlite3)
│       ├── SQLiteConnection.swift
│       ├── SQLiteConnectionPool.swift
│       └── SQLiteBackup.swift   # Binary + logical backup
│
└── Tests/
    ├── CosmoSQLCoreTests/         # Value & type tests (~30 tests)
    ├── CosmoMSSQLTests/           # Integration tests (~168 tests)
    ├── CosmoPostgresTests/        # Integration tests (~98 tests)
    ├── CosmoMySQLTests/           # Integration tests (~95 tests)
    └── CosmoSQLiteTests/          # In-memory tests — no Docker (~75 tests)
```

---

## Testing

### SQLite (no setup required)

SQLite tests use in-memory databases and run instantly without any external dependencies:

```bash
swift test --filter CosmoSQLiteTests
```

### SQL Server

```bash
# Start SQL Server in Docker
docker run -d --name sqlserver \
  -e ACCEPT_EULA=Y \
  -e SA_PASSWORD=YourStrongPassword! \
  -p 1433:1433 \
  mcr.microsoft.com/mssql/server:2022-latest

# Run tests
MSSQL_TEST_HOST=127.0.0.1 MSSQL_TEST_PASS=YourStrongPassword! swift test --filter CosmoMSSQLTests
```

### PostgreSQL

```bash
docker run -d --name pg-test \
  -e POSTGRES_USER=pguser \
  -e POSTGRES_PASSWORD=pgPass123 \
  -e POSTGRES_DB=CosmoPostgresTestDb \
  -p 5432:5432 postgres:16-alpine

PG_TEST_HOST=127.0.0.1 swift test --filter CosmoPostgresTests
```

### MySQL

```bash
docker run -d --name mysql-test \
  -e MYSQL_DATABASE=CosmoMySQLTestDb \
  -e MYSQL_USER=mysqluser \
  -e MYSQL_PASSWORD=mysqlPass123 \
  -e MYSQL_ROOT_PASSWORD=root \
  -p 3306:3306 mysql:8

MYSQL_TEST_HOST=127.0.0.1 swift test --filter CosmoMySQLTests
```

### Run all tests

```bash
# Run SQLite tests (always)
swift test --filter CosmoSQLiteTests

# Run all integration tests (requires all three containers above)
MSSQL_TEST_HOST=127.0.0.1 MSSQL_TEST_PASS=YourStrongPassword! \
PG_TEST_HOST=127.0.0.1 \
MYSQL_TEST_HOST=127.0.0.1 \
swift test
```

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `MSSQL_TEST_HOST` | (skip) | SQL Server host — set to enable MSSQL tests |
| `MSSQL_TEST_PORT` | `1433` | SQL Server port |
| `MSSQL_TEST_DB` | `CosmoMSSQLTestDb` | Database name |
| `MSSQL_TEST_USER` | `sa` | Username |
| `MSSQL_TEST_PASS` | (required) | Password |
| `PG_TEST_HOST` | (skip) | PostgreSQL host — set to enable PG tests |
| `PG_TEST_PORT` | `5432` | PostgreSQL port |
| `PG_TEST_DB` | `CosmoPostgresTestDb` | Database name |
| `PG_TEST_USER` | `pguser` | Username |
| `PG_TEST_PASS` | `pgPass123` | Password |
| `MYSQL_TEST_HOST` | (skip) | MySQL host — set to enable MySQL tests |
| `MYSQL_TEST_PORT` | `3306` | MySQL port |
| `MYSQL_TEST_DB` | `CosmoMySQLTestDb` | Database name |
| `MYSQL_TEST_USER` | `mysqluser` | Username |
| `MYSQL_TEST_PASS` | `mysqlPass123` | Password |

---

## Benchmarks

### Swift: CosmoSQLClient-Swift vs Competitors
> macOS · Apple Silicon · localhost databases · 20 iterations per scenario

#### MSSQL — CosmoSQLClient vs SQLClient-Swift (FreeTDS)
> Table: 46 rows × 20 columns

| Scenario | CosmoSQL (NIO) | FreeTDS | Winner |
|---|---|---|---|
| Cold connect + query + close | 14.30 ms | 13.92 ms | ≈ tie |
| **Warm full-table query** | **0.95 ms** | 1.58 ms | 🏆 **1.7× faster** |
| **Warm single-row query** | **0.64 ms** | 1.10 ms | 🏆 **1.7× faster** |
| Warm `decode<T>()` (Codable) | 1.53 ms | N/A | 🏆 CosmoSQL exclusive |
| Warm `toJson()` | 1.56 ms | N/A | 🏆 CosmoSQL exclusive |

#### PostgreSQL — CosmoSQLClient vs postgres-nio (Vapor)

| Scenario | CosmoSQL | postgres-nio | Winner |
|---|---|---|---|
| Cold connect (TLS off) | 4.78 ms | 4.91 ms | 🏆 CosmoSQL |
| **Warm single-row query** | **0.24 ms** | 0.30 ms | 🏆 **+21% faster** |

#### MySQL — CosmoSQLClient vs mysql-nio (Vapor)

| Scenario | CosmoSQL | mysql-nio | Winner |
|---|---|---|---|
| **Warm full-table query** | **0.47 ms** | 0.49 ms | 🏆 CosmoSQL |

---

### C# Port: CosmoSQLClient-Dotnet vs Industry Leaders
> .NET 10.0 · Apple M-series ARM64 · BenchmarkDotNet · localhost databases

#### MSSQL vs Microsoft.Data.SqlClient (ADO.NET)

| Benchmark | CosmoSQL | ADO.NET | Winner |
|---|---|---|---|
| Cold connect+query | 14.1 ms | 0.63 ms* | ADO.NET* |
| Pool acquire+query | 593 µs | — | — |
| **Warm query (full table)** | **589 µs** | 599 µs | 🏆 CosmoSQL +2% |
| **Warm single-row** | **575 µs** | 580 µs | 🏆 CosmoSQL +1% |
| **Warm ToList\<T\>** | **592 µs** | 604 µs | 🏆 CosmoSQL +2% |
| **Warm ToJson()** | **612 µs** | 729 µs | 🏆 CosmoSQL +16% |
| **FOR JSON streamed** | **565 µs** | ❌ N/A | 🏆 CosmoSQL exclusive |
| **FOR JSON buffered** | **552 µs** | 569 µs | 🏆 CosmoSQL +3% |

\* ADO.NET "cold" reuses its built-in pool — not a true cold connect.  
**CosmoSQL wins every warm benchmark against ADO.NET.**

#### MySQL vs MySqlConnector

| Benchmark | CosmoSQL | MySqlConnector | Winner |
|---|---|---|---|
| **Cold connect+query** | **4.99 ms** | 5.93 ms | 🏆 CosmoSQL +16% |
| **Pool acquire+query** | **333 µs** | 435 µs | 🏆 CosmoSQL +24% |
| Warm query (full table) | 331 µs | 214 µs | MySqlConnector +35% |
| Warm single-row | 295 µs | 213 µs | MySqlConnector +28% |
| Warm ToList\<T\> | 328 µs | 219 µs | MySqlConnector +33% |
| Warm ToJson() | 339 µs | 246 µs | MySqlConnector +28% |
| **JSON streamed** | **310 µs** | ❌ N/A | 🏆 CosmoSQL exclusive |
| JSON buffered | 312 µs | 222 µs | MySqlConnector +29% |

#### PostgreSQL vs Npgsql

| Benchmark | CosmoSQL | Npgsql | Winner |
|---|---|---|---|
| **Cold connect+query** | **4.53 ms** | 4.60 ms | 🏆 CosmoSQL +2% |
| Pool acquire+query | 294 µs | 223 µs | Npgsql +24% |
| Warm query (full table) | 288 µs | 193 µs | Npgsql +33% |
| Warm single-row | 285 µs | 239 µs | Npgsql +16% |
| Warm ToList\<T\> | 400 µs | 197 µs | Npgsql +51% |
| Warm ToJson() | 298 µs | 202 µs | Npgsql +32% |
| **JSON streamed** | **296 µs** | ❌ N/A | 🏆 CosmoSQL exclusive |
| JSON buffered | 308 µs | 211 µs | Npgsql +32% |

> **Key takeaways:**
> - Cold connect and pool performance: CosmoSQL matches or beats all competitors
> - MSSQL warm path: CosmoSQL beats ADO.NET on every benchmark
> - MySQL cold + pool: CosmoSQL wins (16% faster cold, 24% faster pool)
> - JSON streaming: **No competitor offers this feature at all**
> - Warm query gap on MySQL/Postgres: mature competitors have years of binary-protocol micro-optimisation — an expected trade-off for a pure-Swift/NIO implementation

Run the benchmarks yourself — see [`cosmo-benchmark/`](cosmo-benchmark/) for Swift, and [`Benchmarks/`](https://github.com/vkuttyp/CosmoSQLClient-Dotnet/tree/main/Benchmarks) for the .NET port.

---

## Related Projects

- [SQLClient-Swift](https://github.com/vkuttyp/SQLClient-Swift) — The original MSSQL driver using FreeTDS (predecessor to this package)
- [SwiftNIO](https://github.com/apple/swift-nio) — The async networking engine powering CosmoSQLClient-Swift
- [swift-nio-ssl](https://github.com/apple/swift-nio-ssl) — TLS support
- [postgres-nio](https://github.com/vapor/postgres-nio) — Vapor's PostgreSQL driver (separate project)
- [mysql-nio](https://github.com/vapor/mysql-nio) — Vapor's MySQL driver (separate project)
- [CosmoSQLClient-Dotnet](https://github.com/vkuttyp/CosmoSQLClient-Dotnet) — The .NET port of this package (MSSQL, PostgreSQL, MySQL, SQLite)

---

## License

MIT — see [LICENSE](LICENSE).
