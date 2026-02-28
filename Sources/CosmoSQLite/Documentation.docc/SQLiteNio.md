# ``SQLiteNio``

Embedded SQLite database — no server required, no network, no Docker.

## Overview

`SQLiteNio` wraps the system `sqlite3` C library using `NIOThreadPool` to keep blocking SQLite calls off the event loop. It provides the same ``SQLDatabase`` API as the three network drivers, plus native binary backup via `sqlite3_backup_*`.

SQLite is ideal for:

- **Unit and integration testing** — in-memory databases spin up instantly with no Docker
- **Local data storage** — mobile apps (iOS), desktop apps (macOS), embedded devices
- **Prototyping** — get a working schema without running a server
- **Offline-capable apps** — sync a remote database down to a local SQLite file

```swift
import CosmoSQLite

// In-memory database — fastest, great for testing
let conn = try SQLiteConnection.open()

// File-based database
let conn = try SQLiteConnection.open(
    configuration: .init(storage: .file(path: "/var/db/myapp.sqlite"))
)
defer { Task { try? await conn.close() } }

try await conn.execute("""
    CREATE TABLE IF NOT EXISTS tasks (
        id      INTEGER PRIMARY KEY AUTOINCREMENT,
        title   TEXT    NOT NULL,
        done    INTEGER NOT NULL DEFAULT 0,
        due     TEXT
    )
""")

_ = try await conn.execute(
    "INSERT INTO tasks (title, due) VALUES (@p1, @p2)",
    [.string("Ship v1.0"), .date(Date().addingTimeInterval(86400 * 7))]
)

let tasks = try await conn.query("SELECT * FROM tasks WHERE done = @p1", [.bool(false)])
```

## Topics

### Connection

- ``SQLiteConnection``
- ``SQLiteConnectionPool``

### Articles

- <doc:SQLiteBackupGuide>
- <doc:SQLiteForTesting>
