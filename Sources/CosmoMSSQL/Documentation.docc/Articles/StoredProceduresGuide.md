# Stored Procedures

Call SQL Server stored procedures with INPUT and OUTPUT parameters.

## Overview

`MSSQLConnection.callProcedure(_:parameters:)` executes a stored procedure using the TDS RPC wire format, which allows you to pass typed parameters, retrieve OUTPUT parameter values, and capture all result sets in a single call.

## Defining Parameters

Use ``SQLParameter`` to describe each parameter:

```swift
import CosmoMSSQL

let params: [SQLParameter] = [
    // INPUT parameter
    SQLParameter(name: "@DepartmentID", value: .int32(5), isOutput: false),

    // OUTPUT parameters — initial value is .null
    SQLParameter(name: "@Budget",       value: .null, isOutput: true),
    SQLParameter(name: "@HeadCount",    value: .null, isOutput: true),
]
```

## Calling the Procedure

```swift
let result = try await conn.callProcedure(
    "GetDepartmentSummary",
    parameters: params
)
```

## Reading Results

`callProcedure` returns an `MSSQLProcResult`:

```swift
// Result sets (from SELECT statements inside the procedure)
let employees = result.tables[0]   // first result set as [SQLRow]
let projects  = result.tables[1]   // second result set

for row in employees {
    print(row["name"].asString()!)
}

// OUTPUT parameters — access by name
let budget     = result.outputParams["@Budget"]?.asDecimal()
let headCount  = result.outputParams["@HeadCount"]?.asInt32()
print("Budget: \(budget!), Headcount: \(headCount!)")

// RETURN value (from RETURN statement in the procedure)
let returnCode = result.returnCode   // → Int32
print("Return code: \(returnCode)")
```

## Example: Full Round-Trip

Suppose this stored procedure exists in SQL Server:

```sql
CREATE PROCEDURE TransferFunds
    @FromAccount INT,
    @ToAccount   INT,
    @Amount      DECIMAL(18,2),
    @Success     BIT OUTPUT
AS
BEGIN
    BEGIN TRANSACTION
        UPDATE accounts SET balance = balance - @Amount WHERE id = @FromAccount
        UPDATE accounts SET balance = balance + @Amount WHERE id = @ToAccount
        SET @Success = 1
    COMMIT
    SELECT id, balance FROM accounts WHERE id IN (@FromAccount, @ToAccount)
    RETURN 0
END
```

Call it from Swift:

```swift
let params: [SQLParameter] = [
    SQLParameter(name: "@FromAccount", value: .int32(1001)),
    SQLParameter(name: "@ToAccount",   value: .int32(2002)),
    SQLParameter(name: "@Amount",      value: .decimal(Decimal(500))),
    SQLParameter(name: "@Success",     value: .null, isOutput: true),
]

let result = try await conn.callProcedure("TransferFunds", parameters: params)

// The result set
for row in result.tables[0] {
    print("Account \(row["id"].asInt32()!): balance = \(row["balance"].asDecimal()!)")
}

// OUTPUT parameter
let success = result.outputParams["@Success"]?.asBool() ?? false
print("Transfer succeeded: \(success)")
print("Return code: \(result.returnCode)")
```

## Multiple Result Sets from Procedures

```swift
let result = try await conn.callProcedure("GetDashboard", parameters: [
    SQLParameter(name: "@UserID", value: .int32(userId))
])

let summaryRows = result.tables[0]   // e.g., KPI summary
let detailRows  = result.tables[1]   // e.g., recent transactions
let alertRows   = result.tables[2]   // e.g., alerts

print("KPIs: \(summaryRows.count), Transactions: \(detailRows.count)")
```

## See Also

- <doc:ConnectingToSQLServer>
- ``SQLParameter``
