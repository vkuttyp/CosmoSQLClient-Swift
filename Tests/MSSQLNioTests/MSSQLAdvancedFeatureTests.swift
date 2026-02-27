import XCTest
@testable import MSSQLNio
import SQLNioCore

// ── Tests for TEXT/NTEXT/IMAGE, SQLDataTable, bulkInsert, checkReachability ──

final class MSSQLAdvancedFeatureTests: XCTestCase {

    override func setUp() async throws {
        try skipUnlessIntegration()
    }

    // ── TEXT / NTEXT / IMAGE ─────────────────────────────────────────────────

    func testTextColumn() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_text FROM TypesTable WHERE id = 1")
                XCTAssertFalse(rows.isEmpty)
                let v = rows[0]["col_text"].asString()
                XCTAssertEqual(v, "Hello from TEXT")
            }
        }
    }

    func testNtextColumn() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_ntext FROM TypesTable WHERE id = 1")
                XCTAssertFalse(rows.isEmpty)
                let v = rows[0]["col_ntext"].asString()
                XCTAssertEqual(v, "Hello from NTEXT")
            }
        }
    }

    func testImageColumn() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_image FROM TypesTable WHERE id = 1")
                XCTAssertFalse(rows.isEmpty)
                let v = rows[0]["col_image"].asBytes()
                XCTAssertNotNil(v)
                XCTAssertEqual(v, [0xDE, 0xAD, 0xBE, 0xEF])
            }
        }
    }

    func testTextNullColumn() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT col_text FROM TypesTable WHERE id = 2")
                XCTAssertFalse(rows.isEmpty)
                XCTAssertEqual(rows[0]["col_text"], .null)
            }
        }
    }

    // ── SQLDataTable ─────────────────────────────────────────────────────────

    func testAsDataTable() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id, col_nvarchar FROM TypesTable ORDER BY id")
                let table = rows.asDataTable(name: "TestTable")

                XCTAssertEqual(table.name, "TestTable")
                XCTAssertEqual(table.columnCount, 2)
                XCTAssertGreaterThanOrEqual(table.rowCount, 2)

                // Access by index
                let idCell = table[0, 0]
                if case .int   = idCell { } else if case .int64 = idCell { } else {
                    XCTFail("Expected numeric cell, got \(idCell)")
                }

                // Access by name
                let nameCell = table[0, "col_nvarchar"]
                XCTAssertFalse(nameCell.isNull)
                if case .string(let s) = nameCell {
                    XCTAssertFalse(s.isEmpty)
                } else {
                    XCTFail("Expected string cell, got \(nameCell)")
                }
            }
        }
    }

    func testDataTableRowAccess() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id, col_nvarchar FROM TypesTable WHERE id = 1")
                let table = rows.asDataTable()
                let dict = table.row(at: 0)
                XCTAssertNotNil(dict["id"])
                XCTAssertNotNil(dict["col_nvarchar"])
            }
        }
    }

    func testDataTableColumnAccess() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id FROM TypesTable ORDER BY id")
                let table = rows.asDataTable()
                let ids = table.column(named: "id")
                XCTAssertGreaterThanOrEqual(ids.count, 2)
                XCTAssertFalse(ids[0].isNull)
            }
        }
    }

    func testDataTableToMarkdown() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT TOP 2 id, col_nvarchar FROM TypesTable ORDER BY id")
                let table = rows.asDataTable()
                let md = table.toMarkdown()
                XCTAssertTrue(md.contains("| id"))
                XCTAssertTrue(md.contains("| col_nvarchar"))
                XCTAssertTrue(md.contains("---"))
            }
        }
    }

    func testDataTableDecode() {
        runAsync {
            struct Row: Decodable {
                let id: Int
                let colNvarchar: String
            }
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT TOP 2 id, col_nvarchar FROM TypesTable ORDER BY id")
                let table = rows.asDataTable()
                let decoded = try table.decode(as: Row.self)
                XCTAssertGreaterThanOrEqual(decoded.count, 2)
                XCTAssertGreaterThan(decoded[0].id, 0)
                XCTAssertFalse(decoded[0].colNvarchar.isEmpty)
            }
        }
    }

    func testDataTableCodable() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT TOP 1 id, col_nvarchar, col_decimal FROM TypesTable")
                let table = rows.asDataTable(name: "Snap")
                let data = try JSONEncoder().encode(table)
                let decoded = try JSONDecoder().decode(SQLDataTable.self, from: data)
                XCTAssertEqual(decoded.name, "Snap")
                XCTAssertEqual(decoded.columnCount, table.columnCount)
                XCTAssertEqual(decoded.rowCount, table.rowCount)
            }
        }
    }

    func testDataSetFromMultiResult() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let resultSets = try await conn.queryMulti(
                    "SELECT TOP 1 id FROM TypesTable; SELECT TOP 1 id FROM Employees", [])
                let ds = resultSets.asDataSet(names: ["Types", "Employees"])
                XCTAssertEqual(ds.count, 2)
                XCTAssertNotNil(ds["Types"])
                XCTAssertNotNil(ds["Employees"])
                XCTAssertEqual(ds[0]?.name, "Types")
            }
        }
    }

    // ── Bulk Insert ──────────────────────────────────────────────────────────

    func testBulkInsertColumnsRows() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                // Clean slate
                _ = try await conn.execute("DELETE FROM BulkTestTable")

                let columns = ["name", "amount", "active"]
                let rows: [[SQLValue]] = [
                    [.string("Alice"), .decimal(Decimal(string: "19.99")!), .bool(true)],
                    [.string("Bob"),   .decimal(Decimal(string: "9.49")!),  .bool(false)],
                    [.string("Carol"), .decimal(Decimal(string: "99.00")!), .bool(true)],
                ]
                let inserted = try await conn.bulkInsert(
                    table: "BulkTestTable", columns: columns, rows: rows)
                XCTAssertEqual(inserted, 3)

                let check = try await conn.query(
                    "SELECT COUNT(*) AS cnt FROM BulkTestTable")
                XCTAssertEqual(check[0]["cnt"].asInt32(), 3)
            }
        }
    }

    func testBulkInsertDictionaries() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                _ = try await conn.execute("DELETE FROM BulkTestTable")

                let rows: [[String: SQLValue]] = [
                    ["name": .string("Delta"), "amount": .decimal(1.23), "active": .bool(true)],
                    ["name": .string("Echo"),  "amount": .decimal(4.56), "active": .bool(false)],
                ]
                let inserted = try await conn.bulkInsert(table: "BulkTestTable", rows: rows)
                XCTAssertEqual(inserted, 2)

                let check = try await conn.query(
                    "SELECT name, amount FROM BulkTestTable ORDER BY name")
                XCTAssertEqual(check[0]["name"].asString(), "Delta")
                XCTAssertEqual(check[1]["name"].asString(), "Echo")
            }
        }
    }

    func testBulkInsertEmpty() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let inserted = try await conn.bulkInsert(
                    table: "BulkTestTable", columns: ["name", "amount", "active"], rows: [])
                XCTAssertEqual(inserted, 0)
            }
        }
    }

    // ── checkReachability ────────────────────────────────────────────────────

    func testCheckReachabilitySuccess() {
        runAsync {
            let env = ProcessInfo.processInfo.environment
            let host = env["MSSQL_TEST_HOST"] ?? "127.0.0.1"
            let port = Int(env["MSSQL_TEST_PORT"] ?? "1433") ?? 1433
            // Should not throw — server is running
            try await MSSQLConnection.checkReachability(host: host, port: port, timeout: 5)
        }
    }

    func testCheckReachabilityFailure() {
        runAsync {
            do {
                // Port 19999 should be unreachable
                try await MSSQLConnection.checkReachability(
                    host: "127.0.0.1", port: 19999, timeout: 2)
                XCTFail("Expected error for unreachable port")
            } catch {
                // Any error is acceptable — server not reachable
            }
        }
    }
}
