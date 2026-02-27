# Connecting to MySQL

Configure and establish connections to MySQL and MariaDB.

## Overview

`MySQLConnection` connects to MySQL 5.7+ and MariaDB using the MySQL wire protocol v10. Authentication is negotiated automatically — `caching_sha2_password` for MySQL 8+ or `mysql_native_password` for older servers and MariaDB.

## Configuration

```swift
import MySQLNio

var config = MySQLConnection.Configuration(
    host:     "mysql.example.com",
    port:     3306,            // default
    database: "mydb",
    username: "root",
    password: "secret"
)

// TLS
config.tls            = .prefer   // .require / .prefer / .disable
config.connectTimeout = 30        // seconds
config.queryTimeout   = nil       // per-query timeout (nil = no limit)

let conn = try await MySQLConnection.connect(configuration: config)
defer { Task { try? await conn.close() } }
```

## Placeholder Syntax

MySQL natively uses `?` positional placeholders. The universal `@p1` style also works — values are substituted as literals before sending:

```swift
// MySQL native:
let rows = try await conn.query(
    "SELECT id FROM users WHERE email = ? AND active = ?",
    [.string("alice@example.com"), .bool(true)]
)

// Universal (also works):
let rows = try await conn.query(
    "SELECT id FROM users WHERE email = @p1 AND active = @p2",
    [.string("alice@example.com"), .bool(true)]
)
```

## Calling Stored Procedures

Use `CALL` with `queryMulti` to capture multiple result sets returned by a procedure:

```swift
// Procedure returns two result sets
let sets = try await conn.queryMulti(
    "CALL GetOrderSummary(?)", [.int32(userId)]
)

let orders    = sets[0]    // first SELECT in the procedure
let lineItems = sets[1]    // second SELECT
```

## Warning Callback

MySQL servers often emit warnings alongside query results. Capture them with `onWarning`:

```swift
conn.onWarning = { warning in
    print("MySQL warning: \(warning)")
}

// Example: inserting a value that gets silently truncated
_ = try await conn.execute(
    "INSERT INTO tags (name) VALUES (?)",
    [.string(String(repeating: "x", count: 1000))]  // will warn if column is VARCHAR(255)
)
```

## Integer and Decimal Types

MySQL returns literal integer expressions as `BIGINT` (`.int64`) and literal decimals as `NEWDECIMAL` (`.decimal`). Use appropriate accessors:

```swift
let rows = try await conn.query("SELECT COUNT(*) AS cnt, AVG(price) AS avg_price FROM products")

let count    = rows[0]["cnt"].asInt64()!
let avgPrice = rows[0]["avg_price"].asDecimal()!
print("Products: \(count), Avg price: \(avgPrice)")
```

## Connection State

```swift
if conn.isOpen {
    let rows = try await conn.query("SELECT NOW() AS ts")
    print(rows[0]["ts"].asDate()!)
}
```

## See Also

- ``MySQLConnection``
- ``MySQLConnectionPool``
