import XCTest
@testable import MSSQLNio
import SQLNioCore

// ── Stored procedure integration tests ───────────────────────────────────────

final class MSSQLStoredProcTests: XCTestCase {

    override func setUp() async throws {
        try skipUnlessIntegration()
    }

    // ── sp_GetEmployeeById ───────────────────────────────────────────────────

    func testGetEmployeeByIdFound() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let all = try await conn.query(
                    "SELECT TOP 1 id, name FROM Employees WHERE name = N'Alice Johnson'", [])
                XCTAssertEqual(all.count, 1)
                guard let uuid = all[0]["id"].asUUID() else {
                    XCTFail("No UUID for Alice"); return
                }

                let rows = try await conn.query(
                    "EXEC sp_GetEmployeeById @p1", [.uuid(uuid)])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["name"].asString(), "Alice Johnson")
                let salary = rows[0]["salary"].toDouble()
                XCTAssertNotNil(salary)
                XCTAssertEqual(salary!, 95000.0, accuracy: 0.01)
            }
        }
    }

    func testGetEmployeeByIdNotFound() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "EXEC sp_GetEmployeeById @p1", [.uuid(UUID())])
                XCTAssertEqual(rows.count, 0)
            }
        }
    }

    // ── sp_GetEmployeesByDepartment ──────────────────────────────────────────

    func testGetEmployeesByDepartment() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "EXEC sp_GetEmployeesByDepartment @p1", [.int(1)])
                XCTAssertEqual(rows.count, 2)
                XCTAssertEqual(rows[0]["name"].asString(), "Alice Johnson")
                XCTAssertEqual(rows[1]["name"].asString(), "Bob Smith")
            }
        }
    }

    func testGetEmployeesByDepartmentNoResults() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                // Dept 5 = Marketing — no employees seeded
                let rows = try await conn.query(
                    "EXEC sp_GetEmployeesByDepartment @p1", [.int(5)])
                XCTAssertEqual(rows.count, 0)
            }
        }
    }

    func testGetEmployeesByDepartmentNVarCharMaxNotes() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                // Alice has NVARCHAR(MAX) notes — verify PLP decode in stored proc result
                let rows = try await conn.query(
                    "EXEC sp_GetEmployeesByDepartment @p1", [.int(1)])
                let alice = rows.first { $0["name"].asString() == "Alice Johnson" }
                XCTAssertNotNil(alice)
                let notes = alice!["notes"].asString()
                XCTAssertNotNil(notes)
                XCTAssertGreaterThan(notes!.count, 10)
                XCTAssertTrue(notes!.hasPrefix("Senior engineer"))
            }
        }
    }

    // ── sp_InsertEmployee ────────────────────────────────────────────────────

    func testInsertEmployee() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "EXEC sp_InsertEmployee @p1, @p2, @p3, @p4, @p5",
                    [.string("Test User"),
                     .string("test@example.com"),
                     .int(3),
                     .double(50000.0),
                     .date(Date())])
                XCTAssertEqual(rows.count, 1)
                let uuid = rows[0].values.first?.asUUID()
                XCTAssertNotNil(uuid, "INSERT OUTPUT should return a UUID")

                if let uuid = uuid {
                    let verify = try await conn.query(
                        "SELECT name, salary FROM Employees WHERE id = @p1", [.uuid(uuid)])
                    XCTAssertEqual(verify.count, 1)
                    XCTAssertEqual(verify[0]["name"].asString(), "Test User")
                    XCTAssertEqual(verify[0]["salary"].toDouble() ?? 0, 50000.0, accuracy: 0.01)
                    _ = try await conn.execute(
                        "DELETE FROM Employees WHERE id = @p1", [.uuid(uuid)])
                }
            }
        }
    }

    // ── sp_GetDepartmentSummary ──────────────────────────────────────────────

    func testGetDepartmentSummary() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "EXEC sp_GetDepartmentSummary", [])
                XCTAssertEqual(rows.count, 5, "Should return one row per department")

                // Engineering: 2 employees, avg salary = (95000+85000)/2 = 90000
                let eng = rows.first { $0["name"].asString() == "Engineering" }
                XCTAssertNotNil(eng)
                XCTAssertEqual(eng!["employee_count"].toInt(), 2)
                let avg = eng!["avg_salary"].toDouble()
                XCTAssertNotNil(avg)
                XCTAssertEqual(avg!, 90000.0, accuracy: 1.0)

                // Marketing: 0 employees
                let mkt = rows.first { $0["name"].asString() == "Marketing" }
                XCTAssertNotNil(mkt)
                XCTAssertEqual(mkt!["employee_count"].toInt(), 0)
            }
        }
    }

    func testDepartmentBudgetDecimal() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("EXEC sp_GetDepartmentSummary", [])

                let eng = rows.first { $0["name"].asString() == "Engineering" }
                let budget = eng?["budget"].toDouble()
                XCTAssertNotNil(budget)
                XCTAssertEqual(budget!, 1_500_000.0, accuracy: 0.01)

                let sales = rows.first { $0["name"].asString() == "Sales" }
                let salesBudget = sales?["budget"].toDouble()
                XCTAssertNotNil(salesBudget)
                XCTAssertEqual(salesBudget!, 800_000.50, accuracy: 0.01)
            }
        }
    }

    // ── sp_GetEmployeesAsJSON (FOR JSON PATH / PLP) ──────────────────────────

    func testGetEmployeesAsJSON() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "EXEC sp_GetEmployeesAsJSON", [])
                let json = rows.compactMap { $0.values.first?.asString() }.joined()
                XCTAssertFalse(json.isEmpty)

                let data = json.data(using: .utf8)!
                let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                XCTAssertNotNil(arr)
                XCTAssertEqual(arr!.count, 5)

                let names = arr!.compactMap { $0["name"] as? String }
                XCTAssertTrue(names.contains("Alice Johnson"))
                XCTAssertTrue(names.contains("Eve Davis"))
            }
        }
    }
}
