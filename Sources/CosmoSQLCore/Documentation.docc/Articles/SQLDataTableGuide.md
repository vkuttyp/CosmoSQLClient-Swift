# SQLDataTable and SQLDataSet

Work with structured, Codable result tables — render Markdown, encode to JSON, and decode to Swift types.

## Overview

``SQLDataTable`` is a structured representation of a query result that can be:

- **Serialized** to JSON and stored or sent over a network
- **Rendered** as a Markdown table for logging or display
- **Decoded** into arrays of `Codable` structs
- **Passed** between application layers without database dependencies

``SQLDataSet`` holds multiple named tables — ideal for stored procedure results or batched queries.

## Creating a SQLDataTable

```swift
// From a query result
let rows  = try await conn.query("SELECT id, name, salary FROM employees")
let table = SQLDataTable(name: "employees", rows: rows)

print("Rows: \(table.rowCount), Columns: \(table.columnCount)")

// Access column metadata
for col in table.columns {
    print("Column: \(col.name)")
}
```

## Accessing Data

### By row and column name

```swift
// row(at:) returns [String: SQLCellValue]
let firstRow = table.row(at: 0)
let name     = firstRow["name"]?.displayString ?? "—"
let salary   = firstRow["salary"]    // → SQLCellValue?
```

### Entire column as an array

```swift
// column(named:) returns [SQLCellValue]
let allNames: [SQLCellValue] = table.column(named: "name")
let allSalaries = table.column(named: "salary")
    .compactMap { $0.sqlValue.asDecimal() }
let totalPayroll = allSalaries.reduce(Decimal.zero, +)
```

## Markdown Rendering

`toMarkdown()` formats the table as a GitHub-flavored Markdown table:

```swift
let rows  = try await conn.query("SELECT id, name, department FROM employees LIMIT 5")
let table = SQLDataTable(name: "employees", rows: rows)
print(table.toMarkdown())
```

Output:
```
| id | name    | department  |
|----|---------|-------------|
| 1  | Alice   | Engineering |
| 2  | Bob     | Marketing   |
| 3  | Charlie | Engineering |
```

Useful for logging, CLI tools, Slack messages, or test output.

## JSON Encoding and Decoding

`SQLDataTable` conforms to `Codable`:

```swift
// Encode to JSON
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let json = try encoder.encode(table)

// Store in a file, send over HTTP, save to UserDefaults, etc.
try json.write(to: URL(fileURLWithPath: "/tmp/employees.json"))

// Decode back
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let restored = try decoder.decode(SQLDataTable.self, from: json)
```

## Decoding into Codable Structs

```swift
struct Employee: Codable {
    let id:         Int
    let name:       String
    let department: String
}

let employees: [Employee] = try table.decode(as: Employee.self)
print(employees.map(\.name))
```

## SQLDataSet — Multiple Tables

`SQLDataSet` groups multiple named tables, typically from a stored procedure or multi-statement batch:

```swift
// SQL Server stored procedure returning 2 result sets
let result = try await conn.callProcedure("GetDashboard", parameters: [
    SQLParameter(name: "@UserID", value: .int32(userId))
])

// Access by index
let summaryTable = result.tables[0]
let detailTable  = result.tables[1]

// Wrap in a SQLDataSet for named access
let dataSet = SQLDataSet(tables: [
    SQLDataTable(name: "summary", rows: result.tables[0].toSQLRows()),
    SQLDataTable(name: "detail",  rows: result.tables[1].toSQLRows()),
])

let summary = dataSet["summary"]   // → SQLDataTable?
let detail  = dataSet["detail"]

// Serialize the whole dataset to JSON
let json = try JSONEncoder().encode(dataSet)
```

## Converting Back to SQLRow

``SQLDataTable`` can round-trip back to `[SQLRow]` for driver interop:

```swift
let sqlRows: [SQLRow] = table.toSQLRows()
// Use with any SQLDatabase method that expects [SQLRow]
```

## See Also

- ``SQLDataTable``
- ``SQLDataSet``
- ``SQLCellValue``
- <doc:DecodingRows>
