import XCTest
@testable import CosmoMSSQL
import CosmoSQLCore

// ── Query scenario integration tests ─────────────────────────────────────────

final class MSSQLQueryTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws {
        try skipUnlessIntegration()
    }

    // ── Empty result set ─────────────────────────────────────────────────────

    func testEmptyResultSet() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT * FROM Employees WHERE name = N'NoSuchPerson'", [])
                XCTAssertEqual(rows.count, 0)
            }
        }
    }

    // ── Single row ───────────────────────────────────────────────────────────

    func testSingleRow() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT TOP 1 id, name FROM Departments ORDER BY id", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["name"].asString(), "Engineering")
            }
        }
    }

    // ── Multiple rows ────────────────────────────────────────────────────────

    func testMultipleRows() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id, name, budget FROM Departments ORDER BY id", [])
                XCTAssertEqual(rows.count, 5)
                XCTAssertEqual(rows[0]["name"].asString(), "Engineering")
                XCTAssertEqual(rows[4]["name"].asString(), "Marketing")
            }
        }
    }

    func testMultipleRowsAllEmployees() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id, name, salary, is_active FROM Employees ORDER BY name", [])
                XCTAssertEqual(rows.count, 5)
                XCTAssertEqual(rows[0]["name"].asString(), "Alice Johnson")
                XCTAssertEqual(rows[4]["name"].asString(), "Eve Davis")
            }
        }
    }

    // ── Parameterized query ──────────────────────────────────────────────────

    func testParameterizedString() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id, name FROM Departments WHERE name = @p1",
                    [.string("Engineering")])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["name"].asString(), "Engineering")
            }
        }
    }

    func testParameterizedInt() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                // Dept 1 = Engineering, 2 employees
                let rows = try await conn.query(
                    "SELECT id, name FROM Employees WHERE department_id = @p1 ORDER BY name",
                    [.int(1)])
                XCTAssertEqual(rows.count, 2)
                XCTAssertEqual(rows[0]["name"].asString(), "Alice Johnson")
                XCTAssertEqual(rows[1]["name"].asString(), "Bob Smith")
            }
        }
    }

    func testParameterizedDecimal() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT name FROM Employees WHERE salary >= @p1 ORDER BY salary DESC",
                    [.double(90000.00)])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["name"].asString(), "Alice Johnson")
            }
        }
    }

    func testParameterizedBool() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT name FROM Employees WHERE is_active = @p1 ORDER BY name",
                    [.bool(false)])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["name"].asString(), "Dave Brown")
            }
        }
    }

    // ── NULL column values in result ─────────────────────────────────────────

    func testNullColumnInResult() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT name, email, notes FROM Employees WHERE name = N'Bob Smith'", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["name"].asString(), "Bob Smith")
                XCTAssertEqual(rows[0]["email"].asString(), "bob@example.com")
                XCTAssertEqual(rows[0]["notes"], .null)
            }
        }
    }

    func testNullEmailInResult() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT name, email FROM Employees WHERE name = N'Carol White'", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["email"], .null)
            }
        }
    }

    // ── INSERT / execute ─────────────────────────────────────────────────────

    func testInsertAndRowsAffected() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let affected = try await conn.execute(
                    "INSERT INTO LargeData (payload, label) VALUES (@p1, @p2)",
                    [.string("test payload"), .string("test_insert")])
                XCTAssertEqual(affected, 1)
                _ = try await conn.execute(
                    "DELETE FROM LargeData WHERE label = @p1",
                    [.string("test_insert")])
            }
        }
    }

    func testInsertOutputId() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    INSERT INTO LargeData (payload, label)
                    OUTPUT INSERTED.id
                    VALUES (@p1, @p2)
                    """,
                    [.string("output test"), .string("output_insert")])
                XCTAssertEqual(rows.count, 1)
                let id = rows[0].values.first?.toInt()
                XCTAssertNotNil(id)
                XCTAssertGreaterThan(id!, 0)
                _ = try await conn.execute(
                    "DELETE FROM LargeData WHERE label = @p1",
                    [.string("output_insert")])
            }
        }
    }

    // ── Large data / multi-packet ────────────────────────────────────────────

    func testLargeNVarCharMax3000() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT payload FROM LargeData WHERE label = @p1",
                    [.string("medium_3000")])
                XCTAssertEqual(rows.count, 1)
                let s = rows[0]["payload"].asString()
                XCTAssertNotNil(s)
                XCTAssertEqual(s!.count, 3000)
            }
        }
    }

    func testLargeNVarCharMax5000() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT payload FROM LargeData WHERE label = @p1",
                    [.string("large_5000")])
                XCTAssertEqual(rows.count, 1)
                let s = rows[0]["payload"].asString()
                XCTAssertNotNil(s)
                XCTAssertEqual(s!.count, 5000)
            }
        }
    }

    func testLargeNVarCharMax10000() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT payload FROM LargeData WHERE label = @p1",
                    [.string("xlarge_10000")])
                XCTAssertEqual(rows.count, 1)
                let s = rows[0]["payload"].asString()
                XCTAssertNotNil(s)
                XCTAssertEqual(s!.count, 10000)
            }
        }
    }

    func testMultipleRowsLargeData() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT label, LEN(payload) AS payload_len FROM LargeData ORDER BY id", [])
                XCTAssertGreaterThanOrEqual(rows.count, 3)
                XCTAssertEqual(rows[0]["payload_len"].toInt(), 3000)
                XCTAssertEqual(rows[1]["payload_len"].toInt(), 5000)
                XCTAssertEqual(rows[2]["payload_len"].toInt(), 10000)
            }
        }
    }

    // ── FOR JSON PATH (PLP) ──────────────────────────────────────────────────

    func testForJsonPath() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT id, name FROM Departments FOR JSON PATH", [])
                let json = rows.compactMap { $0.values.first?.asString() }.joined()
                XCTAssertFalse(json.isEmpty)
                let data = json.data(using: .utf8)!
                let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                XCTAssertNotNil(arr)
                XCTAssertEqual(arr!.count, 5)
            }
        }
    }

    func testQueryJsonStream() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                var count = 0
                var firstData: Data?
                for try await data in conn.queryJsonStream(
                    "SELECT id, name FROM Departments FOR JSON PATH") {
                    count += 1
                    if firstData == nil { firstData = data }
                    // Verify each chunk is valid JSON object
                    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    XCTAssertNotNil(obj, "Each yielded Data must be a valid JSON object")
                }
                XCTAssertEqual(count, 5, "Should yield one object per department")
                XCTAssertNotNil(firstData)
            }
        }
    }

    func testQueryStream() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                var rows: [SQLRow] = []
                for try await row in conn.queryStream(
                    "SELECT id, name FROM Departments ORDER BY id") {
                    rows.append(row)
                }
                XCTAssertEqual(rows.count, 5)
                XCTAssertNotNil(rows[0]["name"].asString())
            }
        }
    }

    // ── Aggregation / computed columns ───────────────────────────────────────


    func testCountAggregation() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT COUNT(*) AS cnt FROM Employees", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["cnt"].toInt(), 5)
            }
        }
    }

    func testSumAggregation() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT SUM(salary) AS total FROM Employees", [])
                XCTAssertEqual(rows.count, 1)
                let total = rows[0]["total"].toDouble()
                XCTAssertNotNil(total)
                // 95000+85000+70000+65000+55000 = 370000
                XCTAssertEqual(total!, 370000.0, accuracy: 0.01)
            }
        }
    }

    func testJoinQuery() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT e.name AS employee, d.name AS department, e.salary
                    FROM Employees e
                    JOIN Departments d ON d.id = e.department_id
                    WHERE d.name = N'Engineering'
                    ORDER BY e.name
                    """, [])
                XCTAssertEqual(rows.count, 2)
                XCTAssertEqual(rows[0]["employee"].asString(),   "Alice Johnson")
                XCTAssertEqual(rows[0]["department"].asString(), "Engineering")
                XCTAssertEqual(rows[0]["salary"].toDouble() ?? 0, 95000.0, accuracy: 0.01)
            }
        }
    }

    // ── Connection reuse ─────────────────────────────────────────────────────

    func testMultipleQueriesSameConnection() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let r1 = try await conn.query("SELECT COUNT(*) AS cnt FROM Departments", [])
                let r2 = try await conn.query("SELECT COUNT(*) AS cnt FROM Employees", [])
                let r3 = try await conn.query("SELECT COUNT(*) AS cnt FROM LargeData", [])
                XCTAssertEqual(r1[0]["cnt"].toInt(), 5)
                XCTAssertEqual(r2[0]["cnt"].toInt(), 5)
                XCTAssertGreaterThanOrEqual(r3[0]["cnt"].toInt() ?? 0, 3)
            }
        }
    }

    func testSelectLiteralTypes() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("""
                    SELECT
                        CAST(1 AS INT)       AS int_val,
                        CAST(3.14 AS FLOAT)  AS float_val,
                        N'hello'             AS str_val,
                        CAST(1 AS BIT)       AS bit_val,
                        NEWID()              AS uuid_val,
                        GETDATE()            AS dt_val
                    """, [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["int_val"].toInt(), 1)
                let f = rows[0]["float_val"].toDouble()
                XCTAssertNotNil(f)
                XCTAssertEqual(f!, 3.14, accuracy: 0.001)
                XCTAssertEqual(rows[0]["str_val"].asString(), "hello")
                XCTAssertEqual(rows[0]["bit_val"].asBool(), true)
                XCTAssertNotNil(rows[0]["uuid_val"].asUUID())
                XCTAssertNotNil(rows[0]["dt_val"].asDate())
            }
        }
    }
}

// MARK: - Backup & Restore Tests

final class MSSQLBackupTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws { try skipUnlessIntegration() }

    func testLogicalDump() {
        runAsync {
            let conn = try await TestDatabase.connect()
            defer { Task { try? await conn.close() } }
            _ = try await conn.execute(
                "IF OBJECT_ID('backup_test','U') IS NULL CREATE TABLE backup_test (id INT IDENTITY PRIMARY KEY, name NVARCHAR(100))")
            _ = try await conn.execute(
                "INSERT INTO backup_test (name) VALUES (@p1)", [.string("Alice")])
            let sql = try await conn.dump(tables: ["backup_test"])
            XCTAssertTrue(sql.contains("-- sql-nio dump"))
            XCTAssertTrue(sql.contains("Alice"))
            XCTAssertTrue(sql.contains("INSERT INTO"))
            _ = try await conn.execute("DROP TABLE IF EXISTS backup_test")
        }
    }

    func testDumpAndRestoreRoundTrip() {
        runAsync {
            let conn = try await TestDatabase.connect()
            defer { Task { try? await conn.close() } }
            _ = try await conn.execute(
                "IF OBJECT_ID('rt_test','U') IS NULL CREATE TABLE rt_test (id INT IDENTITY PRIMARY KEY, val NVARCHAR(100))")
            for i in 1...5 {
                _ = try await conn.execute(
                    "INSERT INTO rt_test (val) VALUES (@p1)", [.string("item\(i)")])
            }
            let sql = try await conn.dump(tables: ["rt_test"])
            _ = try await conn.execute("DELETE FROM rt_test")
            try await conn.restore(from: sql)
            let rows = try await conn.query("SELECT COUNT(*) AS cnt FROM rt_test", [])
            XCTAssertEqual(rows[0]["cnt"].asInt32(), 5)
            _ = try await conn.execute("DROP TABLE IF EXISTS rt_test")
        }
    }

    func testDumpToFile() {
        let path = NSTemporaryDirectory() + "mssql_dump_\(UUID()).sql"
        defer { try? FileManager.default.removeItem(atPath: path) }
        runAsync {
            let conn = try await TestDatabase.connect()
            defer { Task { try? await conn.close() } }
            _ = try await conn.execute(
                "IF OBJECT_ID('file_test','U') IS NULL CREATE TABLE file_test (id INT IDENTITY PRIMARY KEY, name NVARCHAR(100))")
            _ = try await conn.execute(
                "INSERT INTO file_test (name) VALUES (@p1)", [.string("Frank")])
            try await conn.dump(to: path, tables: ["file_test"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            let content = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertTrue(content.contains("Frank"))
            _ = try await conn.execute("DROP TABLE IF EXISTS file_test")
        }
    }

    func testDumpHandlesNulls() {
        runAsync {
            let conn = try await TestDatabase.connect()
            defer { Task { try? await conn.close() } }
            _ = try await conn.execute(
                "IF OBJECT_ID('null_test','U') IS NULL CREATE TABLE null_test (id INT IDENTITY PRIMARY KEY, val NVARCHAR(100) NULL)")
            _ = try await conn.execute("INSERT INTO null_test (val) VALUES (NULL)")
            let sql = try await conn.dump(tables: ["null_test"])
            XCTAssertTrue(sql.contains("NULL"))
            _ = try await conn.execute("DROP TABLE IF EXISTS null_test")
        }
    }
}
