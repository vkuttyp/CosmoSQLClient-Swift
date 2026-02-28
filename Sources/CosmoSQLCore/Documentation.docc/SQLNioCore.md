# ``SQLNioCore``

Shared protocol, types, and utilities for sql-nio — the unified Swift SQL driver.

## Overview

`SQLNioCore` defines the `SQLDatabase` protocol and all shared value types that every sql-nio driver conforms to.
Import this module when writing code that works across multiple databases without depending on a specific driver.

```swift
import CosmoSQLCore

// Write once — run on SQL Server, PostgreSQL, MySQL, or SQLite
func findActiveUsers(db: any SQLDatabase) async throws -> [SQLRow] {
    try await db.query(
        "SELECT id, name, email FROM users WHERE active = @p1",
        [.bool(true)]
    )
}
```

## Topics

### Protocol

- ``SQLDatabase``

### Values & Rows

- ``SQLValue``
- ``SQLRow``
- ``SQLColumn``

### Rich Result Types

- ``SQLDataTable``
- ``SQLDataSet``
- ``SQLCellValue``

### Decoding

- ``SQLRowDecoder``

### Stored Procedure Parameters

- ``SQLParameter``

### Backup & Restore

- ``SQLDialect``

### Errors

- ``SQLError``

### Articles

- <doc:GettingStarted>
- <doc:WorkingWithSQLValue>
- <doc:DecodingRows>
- <doc:SQLDataTableGuide>
- <doc:BackupRestoreGuide>
- <doc:TransactionsAndPools>
