# Working with SQLValue

Bind parameters and read result columns using the unified `SQLValue` type.

## Overview

``SQLValue`` is the single value type used for both **binding parameters** to queries and **reading values** from result rows. It covers all common SQL types and maps correctly across all four database engines.

## Constructing Values

### Using case syntax

```swift
let binds: [SQLValue] = [
    .string("Alice"),
    .int32(42),
    .bool(true),
    .null,
    .uuid(UUID()),
    .date(Date()),
    .double(3.14),
    .decimal(Decimal(string: "1234.56")!),
    .bytes([0xDE, 0xAD, 0xBE, 0xEF]),
]
```

### Using literal syntax

`SQLValue` conforms to all Swift literal protocols, so you can skip the case label entirely:

```swift
let binds: [SQLValue] = [
    "Alice",     // .string("Alice")
    42,          // .int(42)
    3.14,        // .double(3.14)
    true,        // .bool(true)
    nil,         // .null
]
```

## Reading Values from Rows

After a query, each ``SQLRow`` contains ``SQLValue`` instances. Extract them with typed accessors:

```swift
let row = rows[0]

// Signed integers
let count: Int?   = row["count"].asInt()
let id:    Int32? = row["id"].asInt32()
let big:   Int64? = row["big_col"].asInt64()

// Floating point
let price:  Double?  = row["price"].asDouble()
let tax:    Float?   = row["tax"].asFloat()

// Exact decimal (DECIMAL, NUMERIC, MONEY)
let amount: Decimal? = row["amount"].asDecimal()

// Text
let name:   String?  = row["name"].asString()

// Boolean
let active: Bool?    = row["active"].asBool()

// Date/time
let created: Date?   = row["created_at"].asDate()

// UUID
let uid: UUID?       = row["uid"].asUUID()

// Binary / BLOB
let data: [UInt8]?   = row["data"].asBytes()

// Null check
if row["deleted_at"].isNull {
    print("Record is active")
}
```

## Unsigned Accessors

When you know a value is non-negative, unsigned accessors perform a safe widening conversion and return `nil` if the stored value is negative:

```swift
let b:  UInt8?  = row["byte_col"].asUInt8()
let s:  UInt16? = row["short_col"].asUInt16()
let u:  UInt32? = row["uint_col"].asUInt32()
let ul: UInt64? = row["bigcol"].asUInt64()
```

## Integer Width Differences Between Databases

Different databases return different integer widths for literal expressions and computed columns. When writing portable code, prefer widening fallback chains:

```swift
// MySQL returns literal integers as BIGINT (Int64), not Int32
let count = row["cnt"].asInt64()

// SQL Server returns INT as Int32
let id = row["id"].asInt32()

// Safe fallback — works regardless of database:
let value = row["n"].asInt32() ?? row["n"].asInt64().map { Int32($0) }
```

## Type Mapping Reference

| `SQLValue` case | SQL Server | PostgreSQL | MySQL | SQLite |
|---|---|---|---|---|
| `.bool` | BIT | BOOLEAN | TINYINT(1) | INTEGER |
| `.int32` | INT | INTEGER | INT | INTEGER |
| `.int64` | BIGINT | BIGINT | BIGINT | INTEGER |
| `.double` | FLOAT | DOUBLE PRECISION | DOUBLE | REAL |
| `.decimal` | DECIMAL / MONEY | NUMERIC | DECIMAL | TEXT |
| `.string` | NVARCHAR / TEXT | TEXT | VARCHAR | TEXT |
| `.bytes` | VARBINARY | BYTEA | BLOB | BLOB |
| `.uuid` | UNIQUEIDENTIFIER | UUID | CHAR(36) | TEXT |
| `.date` | DATETIME2 | TIMESTAMPTZ | DATETIME | TEXT |
| `.null` | NULL | NULL | NULL | NULL |

## See Also

- <doc:DecodingRows>
- ``SQLRow``
- ``SQLColumn``
