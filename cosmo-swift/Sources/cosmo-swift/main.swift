import CosmoMSSQL
import CosmoSQLCore

print("Hello, World!")

let conn = try await MSSQLConnection.connect(configuration: .init(
    connectionString: "Server=localhost,1433;Database=MurshiDb;User Id=sa;Password=aBCD111;Encrypt=true;TrustServerCertificate=true"
))
defer { Task { try? await conn.close() } }

let rows = try await conn.query("SELECT TOP 3 AccountNo, AccountName, AccountTypeID, IsMain FROM Accounts", [])
let table = rows.asDataTable(name: "Accounts")

print("Rows: \(table.rowCount), Columns: \(table.columnCount)")
print(table.toJson())
