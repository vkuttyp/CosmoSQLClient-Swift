# Connecting to SQL Server

Configure and establish connections to Microsoft SQL Server.

## Overview

`MSSQLConnection` opens a TCP connection to SQL Server, performs TDS pre-login negotiation (including optional TLS), and authenticates via SQL Server auth or Windows / NTLM auth.

## Configuration

### Programmatic configuration

```swift
import CosmoMSSQL

var config = MSSQLConnection.Configuration(
    host:                   "sqlserver.example.com",
    port:                   1433,                      // default
    database:               "AdventureWorks",
    username:               "sa",
    password:               "YourStrongPassword!",
    trustServerCertificate: false                      // true = skip cert verification
)

// Optional settings
config.tls            = .prefer   // .require / .prefer / .disable
config.connectTimeout = 30        // seconds (default: 30)
config.queryTimeout   = nil       // per-query timeout (nil = no limit)
config.readOnly       = false     // read-only hint for AG replicas

let conn = try await MSSQLConnection.connect(configuration: config)
defer { Task { try? await conn.close() } }
```

### Connection string

You can also initialise directly from a standard SQL Server connection string:

```swift
let config = try MSSQLConnection.Configuration(connectionString:
    "Server=sqlserver.example.com,1433;Database=AdventureWorks;" +
    "User Id=sa;Password=YourStrongPassword!;" +
    "Encrypt=True;TrustServerCertificate=False;Connect Timeout=30;"
)
let conn = try await MSSQLConnection.connect(configuration: config)
```

Supported keys (case-insensitive):

| Key | Aliases | Values |
|-----|---------|--------|
| `Server` | `Data Source` | `host` or `host,port` |
| `Database` | `Initial Catalog` | database name |
| `User Id` | `UID` | username |
| `Password` | `PWD` | password |
| `Domain` | — | enables NTLM/Windows auth |
| `Encrypt` | — | `True`/`False`/`Disable`/`Strict`/`Request` |
| `TrustServerCertificate` | — | `True` skips cert verification |
| `Connect Timeout` | `Connection Timeout` | seconds |
| `Application Intent` | — | `ReadOnly` |

## TLS and TrustServerCertificate

Self-signed certificates (common in dev/test environments including Docker) require `TrustServerCertificate=True`:

```swift
// Via init:
let config = MSSQLConnection.Configuration(
    host: "127.0.0.1", database: "MyDb",
    username: "sa", password: "pass",
    trustServerCertificate: true   // skip cert verification for self-signed certs
)

// Via connection string:
let config = try MSSQLConnection.Configuration(connectionString:
    "Server=127.0.0.1;Database=MyDb;User Id=sa;Password=pass;" +
    "Encrypt=True;TrustServerCertificate=True;"
)
```

## Reachability Check

Perform a fast TCP-level pre-flight check before attempting a full TDS connection:

```swift
// On Configuration (recommended):
try await config.checkReachability()  // throws SQLError.connectionError if unreachable
let conn = try await MSSQLConnection.connect(configuration: config)

// Static version with explicit host/port:
try await MSSQLConnection.checkReachability(host: "sqlserver.example.com", port: 1433, timeout: 5)
```

## Azure SQL Database

Azure SQL uses the same TDS protocol. Append the server suffix to the host and require TLS:

```swift
let config = try MSSQLConnection.Configuration(connectionString:
    "Server=myserver.database.windows.net;Database=mydb;" +
    "User Id=myuser@myserver;Password=AzurePassword!;" +
    "Encrypt=True;TrustServerCertificate=False;"
)
```

## Named Instances

SQL Server named instances listen on a dynamic port. Resolve the port first (via SQL Server Browser on UDP 1434), then connect directly:

```swift
let config = MSSQLConnection.Configuration(
    host: "sqlserver.example.com",
    port: 52108,          // resolved instance port
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

// Or explicit close:
try await conn.close()

// Check if still open:
if conn.isOpen {
    let rows = try await conn.query("SELECT GETDATE() AS now")
}
```

## See Also

- <doc:WindowsAuthGuide>
- <doc:StoredProceduresGuide>
