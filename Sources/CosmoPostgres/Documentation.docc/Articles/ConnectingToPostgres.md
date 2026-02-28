# Connecting to PostgreSQL

Configure and establish connections to PostgreSQL.

## Overview

`PostgresConnection` opens a TCP connection to PostgreSQL, optionally negotiates TLS via SSLRequest, and authenticates using MD5 or SCRAM-SHA-256 depending on the server's `pg_hba.conf` configuration.

## Configuration

```swift
import CosmoPostgres

var config = PostgresConnection.Configuration(
    host:     "pg.example.com",
    port:     5432,             // default
    database: "mydb",
    username: "postgres",
    password: "secret"
)

// TLS
config.tls            = .prefer    // .require / .prefer / .disable
config.connectTimeout = 30         // seconds
config.queryTimeout   = nil        // per-query timeout (nil = no limit)

let conn = try await PostgresConnection.connect(configuration: config)
defer { Task { try? await conn.close() } }
```

## Placeholder Syntax

PostgreSQL natively uses `$1`, `$2`, … positional placeholders. The universal `@p1` style also works:

```swift
// PostgreSQL native:
let rows = try await conn.query(
    "SELECT id FROM users WHERE email = $1 AND active = $2",
    [.string("alice@example.com"), .bool(true)]
)

// Universal (also works):
let rows = try await conn.query(
    "SELECT id FROM users WHERE email = @p1 AND active = @p2",
    [.string("alice@example.com"), .bool(true)]
)
```

## Server Notices

Capture PostgreSQL `NOTICE` messages (e.g., from `RAISE NOTICE` in PL/pgSQL functions):

```swift
conn.onNotice = { notice in
    print("PG Notice: \(notice)")
}
```

## Calling PostgreSQL Functions

PostgreSQL functions that return tables work like regular queries:

```swift
// RETURNS TABLE function
let rows = try await conn.query(
    "SELECT * FROM get_active_customers($1)", [.int32(regionId)]
)

// RETURNS SETOF
let rows = try await conn.query(
    "SELECT * FROM get_orders_by_status($1)", [.string("pending")]
)

// Scalar function
let rows = try await conn.query("SELECT version() AS v")
print(rows[0]["v"].asString()!)
```

## Connection Checks

```swift
if conn.isOpen {
    let rows = try await conn.query("SELECT NOW() AS ts")
    print(rows[0]["ts"].asDate()!)
}
```

## See Also

- ``PostgresConnection``
- ``PostgresConnectionPool``
