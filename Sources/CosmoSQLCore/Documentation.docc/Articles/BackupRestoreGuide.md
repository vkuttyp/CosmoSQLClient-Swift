# Backup and Restore

Export database contents to SQL files and restore them — with native binary backup for SQLite.

## Overview

sql-nio provides two backup strategies:

1. **Logical SQL dump** — available on all four databases. Exports data as `INSERT` statements in a portable SQL file. Supports selective table export and round-trip restore.
2. **Native binary backup** — SQLite only. Uses `sqlite3_backup_*` API for an exact, byte-for-byte copy of the database file.

## Logical SQL Dump

The same API is available on `MSSQLConnection`, `PostgresConnection`, `MySQLConnection`, and `SQLiteConnection`.

### Exporting data

```swift
// Dump all tables to a SQL string
let sql: String = try await conn.dump()

// Dump specific tables only
let sql = try await conn.dump(tables: ["users", "orders", "products"])

// Write directly to a file
try await conn.dump(to: "/var/backups/myapp_\(Date()).sql")
```

### Restoring data

```swift
// Restore from a SQL string
try await conn.restore(from: sql)

// Restore from a file
try await conn.restore(fromFile: "/var/backups/myapp.sql")
```

### Dump format

The generated SQL file includes:

- A header comment with dialect, database name, and timestamp
- `CREATE TABLE` statements (SQLite only — other databases use your pre-existing schema)
- One `INSERT` per row, using dialect-appropriate literal escaping

```sql
-- sql-nio dump
-- dialect: sqlite
-- database: sqlite
-- created: 2026-02-27T20:00:00Z
-- Restore with: conn.restore(fromFile: path)

-- Table: users
CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT);
INSERT INTO "users" ("id", "name", "email") VALUES (1, 'Alice', 'alice@example.com');
INSERT INTO "users" ("id", "name", "email") VALUES (2, 'Bob', NULL);
```

### Full round-trip example

```swift
import CosmoSQLite

// Source database
let source = try SQLiteConnection.open(
    configuration: .init(storage: .file(path: "production.sqlite"))
)
defer { Task { try? await source.close() } }

// Export
try await source.dump(to: "/tmp/backup.sql")

// Restore into a fresh database for inspection
let staging = try SQLiteConnection.open()
defer { Task { try? await staging.close() } }
try await staging.restore(fromFile: "/tmp/backup.sql")

let count = try await staging.query("SELECT COUNT(*) AS n FROM users")
print("Restored \(count[0]["n"].asInt64()!) users")
```

## SQLite Native Binary Backup

SQLite supports an additional fast binary backup using the `sqlite3_backup_*` C API.
This creates an exact copy of the database file, including schema and indexes.

### Backup to a file

```swift
import CosmoSQLite

let conn = try SQLiteConnection.open(
    configuration: .init(storage: .file(path: "production.sqlite"))
)

// Safe to call on a live, open database
try await conn.backup(to: "/var/backups/production_snapshot.sqlite")
```

### Restore from a binary backup

```swift
let dest = try SQLiteConnection.open()
try await dest.restore(fromBackup: "/var/backups/production_snapshot.sqlite")
```

### Serialize to Data

`serialize()` returns the entire database as a `Data` blob — useful for storing snapshots in memory, uploading to cloud storage, or embedding in another database:

```swift
let data: Data = try await conn.serialize()

// Upload to S3, store in Core Data, send over a WebSocket, etc.
let base64 = data.base64EncodedString()

// The returned Data starts with "SQLite format 3\0" — a valid .sqlite file
try data.write(to: URL(fileURLWithPath: "/tmp/snapshot.sqlite"))
```

## Dialect-Aware Literal Escaping

When generating SQL dumps, values are escaped correctly for each database:

| Value type | SQLite / MySQL | PostgreSQL | SQL Server |
|---|---|---|---|
| String | `'O''Brien'` | `'O''Brien'` | `'O''Brien'` |
| Bool | `1` / `0` | `TRUE` / `FALSE` | `1` / `0` |
| Bytes | `X'DEADBEEF'` | `E'\\xDEADBEEF'` | `0xDEADBEEF` |
| Date | `'2026-02-27T20:00:00Z'` | `'2026-02-27T20:00:00Z'::timestamptz` | `'2026-02-27T20:00:00Z'` |
| NULL | `NULL` | `NULL` | `NULL` |

## See Also

- ``SQLDialect``
- <doc:GettingStarted>
