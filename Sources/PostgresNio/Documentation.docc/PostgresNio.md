# ``PostgresNio``

Connect to PostgreSQL using the PostgreSQL wire protocol v3 over SwiftNIO.

## Overview

`PostgresNio` implements the PostgreSQL wire protocol v3 in pure Swift with no external C dependencies. It supports:

- MD5 and SCRAM-SHA-256 password authentication
- TLS encryption (negotiated via SSLRequest)
- `$1`, `$2`, … and `@p1`, `@p2`, … parameterized queries
- Transactions, connection pooling, and stored functions
- PostgreSQL-native types: `UUID`, `TIMESTAMPTZ`, `NUMERIC`, `BYTEA`, `BOOLEAN`, and all standard types

```swift
import PostgresNio

let conn = try await PostgresConnection.connect(configuration: .init(
    host:     "pg.example.com",
    database: "mydb",
    username: "postgres",
    password: "secret"
))
defer { Task { try? await conn.close() } }

let rows = try await conn.query(
    "SELECT id, email, created_at FROM users WHERE active = $1 ORDER BY created_at DESC",
    [.bool(true)]
)
```

## Topics

### Connection

- ``PostgresConnection``
- ``PostgresConnectionPool``

### Articles

- <doc:ConnectingToPostgres>
