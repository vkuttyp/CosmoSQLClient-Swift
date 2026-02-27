# SQLite Backup and Native Binary Copy

Export, restore, and snapshot SQLite databases using both logical SQL dumps and the native binary backup API.

## Overview

`SQLiteConnection` supports two backup strategies:

1. **Native binary backup** — uses `sqlite3_backup_*` for an exact byte-for-byte copy. Fast, safe on live databases, preserves schema and indexes.
2. **Logical SQL dump** — exports `CREATE TABLE` and `INSERT` statements as portable SQL text. Can be restored into any compatible SQLite version.

## Native Binary Backup

### Backup to a file

```swift
import SQLiteNio

let conn = try SQLiteConnection.open(
    configuration: .init(storage: .file(path: "production.sqlite"))
)
defer { Task { try? await conn.close() } }

// Safe to call on a live, open database — uses the SQLite online backup API
try await conn.backup(to: "/var/backups/production_\(Date()).sqlite")
```

### Restore from a binary backup

```swift
let dest = try SQLiteConnection.open()  // fresh in-memory DB
try await dest.restore(fromBackup: "/var/backups/production.sqlite")

let rows = try await dest.query("SELECT COUNT(*) AS n FROM users")
print("Restored \(rows[0]["n"].asInt64()!) users")
```

### Serialize to Data

`serialize()` returns the database as a `Data` blob — the binary content of a valid `.sqlite` file. Useful for cloud storage, iCloud sync, sharing, or embedding:

```swift
let data: Data = try await conn.serialize()

// Upload to cloud storage
try await s3Client.upload(data, key: "backups/snapshot.sqlite")

// Verify: starts with SQLite magic header
let header = String(bytes: data.prefix(15), encoding: .utf8)!
// → "SQLite format 3"

// Write to disk
try data.write(to: URL(fileURLWithPath: "/tmp/snapshot.sqlite"))
```

## Logical SQL Dump

The logical dump produces a human-readable SQL file that can be opened in any text editor, inspected, and restored into any SQLite version.

### Dump all tables

```swift
let sql: String = try await conn.dump()
```

The output includes `CREATE TABLE` statements (so you can restore into an empty database) followed by `INSERT` statements for every row.

### Dump specific tables

```swift
let sql = try await conn.dump(tables: ["users", "orders"])
```

### Write to a file

```swift
try await conn.dump(to: "/var/backups/myapp.sql")
```

### Restore from a SQL string

```swift
try await conn.restore(from: sql)
```

### Restore from a file

```swift
try await conn.restore(fromFile: "/var/backups/myapp.sql")
```

## Full Round-Trip Example

```swift
import SQLiteNio

// --- Step 1: Populate source database ---
let source = try SQLiteConnection.open()
defer { Task { try? await source.close() } }

try await source.execute("""
    CREATE TABLE products (
        id    INTEGER PRIMARY KEY AUTOINCREMENT,
        name  TEXT NOT NULL,
        price REAL NOT NULL
    )
""")

for (name, price) in [("Widget", 9.99), ("Gadget", 24.99), ("Doohickey", 4.49)] {
    _ = try await source.execute(
        "INSERT INTO products (name, price) VALUES (@p1, @p2)",
        [.string(name), .double(price)]
    )
}

// --- Step 2: Dump to file ---
try await source.dump(to: "/tmp/products.sql")

// --- Step 3: Restore into fresh database ---
let dest = try SQLiteConnection.open()
defer { Task { try? await dest.close() } }
try await dest.restore(fromFile: "/tmp/products.sql")

// --- Step 4: Verify ---
let rows = try await dest.query("SELECT name, price FROM products ORDER BY price")
for row in rows {
    print("\(row["name"].asString()!): \(row["price"].asDouble()!)")
}
// Widget: 4.49
// Widget: 9.99
// Gadget: 24.99
```

## Automated Scheduled Backups

```swift
import SQLiteNio
import Foundation

actor DatabaseBackupManager {
    let connection: SQLiteConnection
    let backupDir: String

    init(connection: SQLiteConnection, backupDir: String) {
        self.connection = connection
        self.backupDir = backupDir
    }

    func performBackup() async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let dateStr = formatter.string(from: Date())
        let path = "\(backupDir)/backup_\(dateStr).sqlite"
        try await connection.backup(to: path)
        print("Backup saved to \(path)")
    }
}
```

## See Also

- <doc:SQLiteForTesting>
- <doc:BackupRestoreGuide>
