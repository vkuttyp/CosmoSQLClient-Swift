# ``MSSQLNio``

Connect to Microsoft SQL Server using the TDS 7.4 wire protocol over SwiftNIO.

## Overview

`MSSQLNio` implements the full TDS 7.4 wire protocol in pure Swift, with no dependency on FreeTDS, ODBC, or any C library. It supports:

- SQL authentication and Windows / NTLM domain authentication
- TLS encryption (negotiated via TDS pre-login)
- Parameterized queries with `@p1` placeholders
- Transactions, connection pooling, stored procedures
- Multiple result sets from batched statements
- `DATETIME2`, `UNIQUEIDENTIFIER`, `DECIMAL`, `MONEY`, `NVARCHAR(MAX)`, `VARBINARY(MAX)`, and all standard types

```swift
import CosmoMSSQL

let conn = try await MSSQLConnection.connect(configuration: .init(
    host:     "sqlserver.example.com",
    database: "AdventureWorks",
    username: "sa",
    password: "YourPassword!"
))
defer { Task { try? await conn.close() } }

let rows = try await conn.query(
    "SELECT TOP 10 ProductID, Name, ListPrice FROM Production.Product ORDER BY ListPrice DESC",
    []
)
for row in rows {
    print("\(row["ProductID"].asInt32()!): \(row["Name"].asString()!) — \(row["ListPrice"].asDecimal()!)")
}
```

## Topics

### Connection

- ``MSSQLConnection``
- ``MSSQLConnectionPool``

### Results

- ``MSSQLProcResult``

### Articles

- <doc:ConnectingToSQLServer>
- <doc:StoredProceduresGuide>
- <doc:WindowsAuthGuide>
