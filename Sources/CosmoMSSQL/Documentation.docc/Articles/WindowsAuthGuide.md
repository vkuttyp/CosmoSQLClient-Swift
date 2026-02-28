# Windows and NTLM Authentication

Connect to SQL Server using Windows domain credentials without SQL Server logins.

## Overview

When SQL Server is configured for **Windows Authentication** (also called Integrated Security), clients authenticate using Active Directory / NTLM credentials instead of SQL Server usernames and passwords. sql-nio implements the NTLM handshake natively in Swift as part of the TDS login sequence.

## Configuration

Set the `domain` property in `MSSQLConnection.Configuration`:

```swift
import CosmoMSSQL

var config = MSSQLConnection.Configuration(
    host:     "sqlserver.corp.example.com",
    database: "Northwind"
)

// Required — the Windows / Active Directory domain name
config.domain   = "CORP"

// Optional — omit to use the current OS user context (on macOS / Linux with Kerberos)
config.username = "jsmith"
config.password = "WinPassword!"

let conn = try await MSSQLConnection.connect(configuration: config)
defer { Task { try? await conn.close() } }
```

When `domain` is non-nil, sql-nio switches from SQL Server authentication to NTLM authentication automatically during the TDS pre-login and Login7 handshake.

## How NTLM Authentication Works

NTLM is a three-message challenge–response protocol embedded in the TDS login flow:

1. **NTLM Negotiate** — client sends capability flags
2. **NTLM Challenge** — server sends a random 8-byte nonce
3. **NTLM Authenticate** — client sends username, domain, and an NT hash response computed from the challenge using HMAC-MD5

sql-nio computes the NT response using `swift-crypto` — no external library is required.

## Compatibility

Windows authentication works with:

| Environment | Notes |
|---|---|
| SQL Server on Windows | Native AD integration |
| SQL Server on Linux | Requires `adutil` / `mssql-conf setup-ad-client` |
| Azure SQL Managed Instance | Supports AD auth with proper network configuration |
| SQL Server in Docker | Supports NTLM when joined to a domain |

## SQL Server Configuration

Ensure the SQL Server instance has Windows Authentication mode enabled. In SQL Server Management Studio:

1. Right-click the server → **Properties** → **Security**
2. Set **Server authentication** to **SQL Server and Windows Authentication mode**
3. Restart SQL Server

Or via T-SQL:

```sql
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'LoginMode', REG_DWORD, 2;
```

## Testing NTLM Authentication

Test without a domain by configuring SQL Server to accept NTLM for a local account:

```swift
var config = MSSQLConnection.Configuration(
    host:     "127.0.0.1",
    database: "TestDb"
)
config.domain   = "WORKGROUP"
config.username = "TestUser"
config.password = "TestPass!"

let conn = try await MSSQLConnection.connect(configuration: config)
let rows = try await conn.query("SELECT SYSTEM_USER AS login, USER_NAME() AS dbuser")
print(rows[0]["login"].asString()!)   // → WORKGROUP\TestUser
```

## See Also

- <doc:ConnectingToSQLServer>
