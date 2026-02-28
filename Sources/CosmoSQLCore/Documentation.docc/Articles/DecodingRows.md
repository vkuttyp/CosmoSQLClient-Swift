# Decoding Rows into Swift Types

Map query results directly into `Codable` structs with zero boilerplate.

## Overview

sql-nio integrates with Swift's `Codable` system through ``SQLRowDecoder``.
You define a struct, and the decoder maps column names to property names automatically.

## Defining a Decodable Model

```swift
struct User: Codable {
    let id:        Int
    let name:      String
    let email:     String?   // nullable column → optional property
    let createdAt: Date      // snake_case column "created_at" → camelCase
}
```

By default, ``SQLRowDecoder`` converts `snake_case` column names to `camelCase` Swift property names:

| Column name | Swift property |
|---|---|
| `user_id` | `userId` |
| `first_name` | `firstName` |
| `created_at` | `createdAt` |
| `is_active` | `isActive` |

## Decoding Directly from a Query

The most concise approach uses the `as:` overload on `SQLDatabase`:

```swift
let users: [User] = try await conn.query(
    "SELECT id, name, email, created_at FROM users WHERE active = @p1",
    [.bool(true)],
    as: User.self
)

for user in users {
    print("\(user.id): \(user.name)")
}
```

## Decoding from `[SQLRow]`

When you already have rows, decode them with ``SQLRowDecoder``:

```swift
let rows = try await conn.query("SELECT id, name, email, created_at FROM users")
let decoder = SQLRowDecoder()
let users = try rows.map { try decoder.decode(User.self, from: $0) }
```

## Custom Coding Keys

Use `CodingKeys` when column names don't match Swift naming conventions:

```swift
struct Product: Codable {
    let productID:   Int
    let productName: String
    let unitPrice:   Double

    enum CodingKeys: String, CodingKey {
        case productID   = "ProductID"
        case productName = "ProductName"
        case unitPrice   = "UnitPrice"
    }
}

let products: [Product] = try await conn.query(
    "SELECT ProductID, ProductName, UnitPrice FROM products",
    as: Product.self
)
```

## Nested and Optional Types

```swift
struct Order: Codable {
    let id:          Int
    let customerId:  Int
    let shippedDate: Date?    // NULL if not yet shipped
    let total:       Decimal
}

let orders: [Order] = try await conn.query(
    "SELECT id, customer_id, shipped_date, total FROM orders WHERE customer_id = @p1",
    [.int32(customerId)],
    as: Order.self
)

let pending = orders.filter { $0.shippedDate == nil }
print("\(pending.count) unshipped orders")
```

## Decoding from SQLDataTable

``SQLDataTable`` also supports bulk decoding:

```swift
let rows  = try await conn.query("SELECT * FROM employees")
let table = SQLDataTable(name: "employees", rows: rows)

struct Employee: Codable {
    let id:         Int
    let firstName:  String
    let lastName:   String
    let salary:     Decimal
}

let employees: [Employee] = try table.decode(as: Employee.self)
```

## Key Decoding Strategy

``SQLRowDecoder`` uses `.convertFromSnakeCase` by default. To change it:

```swift
var decoder = SQLRowDecoder()
decoder.keyDecodingStrategy = .useDefaultKeys  // exact column name match

let users: [User] = try rows.map { try decoder.decode(User.self, from: $0) }
```

## See Also

- ``SQLRowDecoder``
- ``SQLRow``
- ``SQLDataTable``
- <doc:SQLDataTableGuide>
