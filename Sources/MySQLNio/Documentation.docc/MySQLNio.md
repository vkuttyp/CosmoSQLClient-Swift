# ``MySQLNio``

Connect to MySQL and MariaDB using the MySQL wire protocol v10 over SwiftNIO.

## Overview

`MySQLNio` implements the MySQL wire protocol v10 in pure Swift, supporting both MySQL 8.x (`caching_sha2_password`) and MySQL 5.7 / MariaDB (`mysql_native_password`) authentication. Features include:

- `caching_sha2_password` (MySQL 8+) and `mysql_native_password` authentication
- TLS encryption (negotiated via CapabilityFlags)
- `?`, `@p1`, `@p2`, … parameterized queries
- Transactions, connection pooling, and stored procedures via `CALL`
- NEWDECIMAL, BIGINT, DATETIME, BLOB, and all MySQL column types

```swift
import MySQLNio

let conn = try await MySQLConnection.connect(configuration: .init(
    host:     "mysql.example.com",
    database: "mydb",
    username: "root",
    password: "secret"
))
defer { Task { try? await conn.close() } }

let rows = try await conn.query(
    "SELECT id, name, price FROM products WHERE category = @p1 AND active = @p2",
    [.string("Electronics"), .bool(true)]
)
```

## Topics

### Connection

- ``MySQLConnection``
- ``MySQLConnectionPool``

### Articles

- <doc:ConnectingToMySQL>
