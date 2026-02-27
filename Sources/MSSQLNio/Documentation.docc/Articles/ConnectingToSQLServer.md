# Connecting to SQL Server

Configure and establish connections to Microsoft SQL Server.

## Overview

`MSSQLConnection` opens a TCP connection to SQL Server, performs TDS pre-login negotiation (including optional TLS), and authenticates via SQL Server auth or Windows / NTLM auth.

## Configuration

```swift
import MSSQLNio

var config = MSSQLConnection.Configuration(
    host:     "sqlserver.example.com",
    port:     1433,                        // default
    database: "AdventureWorks",
    username: "sa",
    password: "YourStrongPassword!"
)

// Optional settings
config.tls            = .prefer            // .require / .prefer / .disable
config.connectTimeout = 30                 // seconds (default: 30)
config.queryTimeout   = nil                // per-query timeout in seconds (nil = no limit)
config.readOnly       = false              // mark connection as read-only hint

let conn = try await MSSQLConnection.connect(configuration: config)
defer { Task { try? await conn.close() } }
```

## Azure SQL Database

Azure SQL uses the same TDS protocol. Append the server suffix to the host name and ensure TLS is enabled:

```swift
var config = MSSQLConnection.Configuration(
    host:     "myserver.database.windows.net",
    database: "mydb",
    username: "myuser@myserver",
    password: "AzurePassword!"
)
config.tls = .require  // Azure requires TLS
```

## Named Instances

SQL Server named instances listen on a dynamic port. Resolve the port first (via SQL Server Browser on UDP 1434), then connect directly:

```swift
// After resolving the named instance port:
let config = MSSQLConnection.Configuration(
    host:     "sqlserver.example.com",
    port:     52108,           // resolved instance port
    database: "MyDb",
    username: "sa",
    password: "pass"
)
```

## Connection Lifecycle

Always close connections when finished to release server-side resources:

```swift
let conn = try await MSSQLConnection.connect(configuration: config)

// Using defer (recommended for scoped use):
defer { Task { try? await conn.close() } }

// Or explicit close at the end of a Task:
try await conn.close()

// Check if still open
if conn.isOpen {
    let rows = try await conn.query("SELECT GETDATE() AS now")
}
```

## See Also

- <doc:WindowsAuthGuide>
- <doc:StoredProceduresGuide>
