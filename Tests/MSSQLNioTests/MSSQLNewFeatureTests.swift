import XCTest
import SQLNioCore
@testable import MSSQLNio

// ── Integration tests for new features: ──────────────────────────────────────
//   • Multi-result sets
//   • Named stored procedure RPC (callProcedure)
//   • OUTPUT parameters
//   • Decimal precision (MONEY / DECIMAL / NUMERIC)
//   • INFO/PRINT message surfacing

final class MSSQLNewFeatureTests: XCTestCase, @unchecked Sendable {

    // ── Decimal / MONEY precision ─────────────────────────────────────────────

    func testDecimalColumnReturnsDecimalValue() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT TOP 1 col_decimal FROM TypesTable")
                XCTAssertFalse(rows.isEmpty)
                let v = rows[0]["col_decimal"]
                if case .decimal(_) = v {
                    // Correct
                } else {
                    XCTFail("Expected .decimal, got \(v)")
                }
            }
        }
    }

    func testMoneyColumnReturnsDecimalValue() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT TOP 1 col_money FROM TypesTable")
                XCTAssertFalse(rows.isEmpty)
                let v = rows[0]["col_money"]
                if case .decimal(_) = v {
                    // Correct
                } else {
                    XCTFail("Expected .decimal for MONEY, got \(v)")
                }
            }
        }
    }

    func testSmallMoneyColumnReturnsDecimalValue() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT TOP 1 col_smallmoney FROM TypesTable")
                XCTAssertFalse(rows.isEmpty)
                let v = rows[0]["col_smallmoney"]
                if case .decimal(_) = v {
                    // Correct
                } else {
                    XCTFail("Expected .decimal for SMALLMONEY, got \(v)")
                }
            }
        }
    }

    func testDecimalPrecisionPreserved() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                // salary column in Employees is DECIMAL(10,2)
                let rows = try await conn.query("SELECT salary FROM Employees WHERE name = N'Alice Johnson'")
                XCTAssertFalse(rows.isEmpty)
                let v = rows[0]["salary"]
                guard case .decimal(let d) = v else {
                    XCTFail("Expected .decimal, got \(v)"); return
                }
                // Alice has salary 95000.00
                XCTAssertEqual(d, Decimal(string: "95000.00")!)
            }
        }
    }

    func testDecimalCodableDecoding() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                struct Row: Decodable { var salary: Decimal }
                let rows = try await conn.query(
                    "SELECT salary FROM Employees WHERE name = N'Alice Johnson'",
                    as: Row.self)
                XCTAssertFalse(rows.isEmpty)
                XCTAssertEqual(rows[0].salary, Decimal(string: "95000.00")!)
            }
        }
    }

    // ── Multi-result sets ─────────────────────────────────────────────────────

    func testQueryMultiReturnsTwoResultSets() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let sets = try await conn.queryMulti("""
                    SELECT id, name FROM Departments ORDER BY id;
                    SELECT id, name FROM Employees ORDER BY id;
                    """)
                XCTAssertEqual(sets.count, 2, "Expected 2 result sets")
                XCTAssertFalse(sets[0].isEmpty, "Departments should not be empty")
                XCTAssertFalse(sets[1].isEmpty, "Employees should not be empty")
                // First result set has department columns
                XCTAssertNotNil(sets[0][0]["name"].asString())
                // Second result set has employee columns
                XCTAssertNotNil(sets[1][0]["name"].asString())
            }
        }
    }

    func testQueryMultiSingleResult() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let sets = try await conn.queryMulti("SELECT 1 AS n")
                XCTAssertEqual(sets.count, 1)
                XCTAssertEqual(sets[0][0]["n"].asInt32(), 1)
            }
        }
    }

    // ── Stored procedure: callProcedure ───────────────────────────────────────

    func testCallProcedureMultiResultSets() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let result = try await conn.callProcedure("sp_GetMultipleResultSets")
                XCTAssertEqual(result.resultSets.count, 2,
                               "sp_GetMultipleResultSets should return 2 result sets")
                // First set: Departments
                XCTAssertFalse(result.resultSets[0].isEmpty)
                XCTAssertNotNil(result.resultSets[0][0]["name"].asString())
                // Second set: Employees
                XCTAssertFalse(result.resultSets[1].isEmpty)
                XCTAssertNotNil(result.resultSets[1][0]["name"].asString())
            }
        }
    }

    func testCallProcedureWithInputParams() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let empRows = try await conn.query("SELECT TOP 1 id FROM Employees ORDER BY id")
                guard let empId = empRows.first?["id"].asUUID() else {
                    XCTFail("No employees found"); return
                }
                let result = try await conn.callProcedure("sp_GetEmployeeById", parameters: [
                    SQLParameter(.uuid(empId), name: "@id")
                ])
                XCTAssertFalse(result.rows.isEmpty)
            }
        }
    }

    func testCallProcedureOutputParameters() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let empRows = try await conn.query("SELECT TOP 1 id FROM Employees ORDER BY id")
                guard let empId = empRows.first?["id"].asUUID() else {
                    XCTFail("No employees found"); return
                }
                let result = try await conn.callProcedure("sp_GetEmployeeWithOutput", parameters: [
                    SQLParameter(.uuid(empId),   name: "@EmployeeId"),
                    SQLParameter.output("@FullName",       type: .string("")),
                    SQLParameter.output("@DepartmentName", type: .string("")),
                ])
                XCTAssertEqual(result.returnStatus, 0, "Return status should be 0")
                let fullName = result.outputParameters["@FullName"]?.asString()
                let deptName = result.outputParameters["@DepartmentName"]?.asString()
                XCTAssertNotNil(fullName, "Expected @FullName output parameter")
                XCTAssertNotNil(deptName, "Expected @DepartmentName output parameter")
                XCTAssertFalse(fullName?.isEmpty ?? true)
            }
        }
    }

    func testCallProcedureReturnStatus() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let empRows = try await conn.query("SELECT TOP 1 id FROM Employees ORDER BY id")
                guard let empId = empRows.first?["id"].asUUID() else {
                    XCTFail("No employees found"); return
                }
                let result = try await conn.callProcedure("sp_GetEmployeeWithOutput", parameters: [
                    SQLParameter(.uuid(empId),   name: "@EmployeeId"),
                    SQLParameter.output("@FullName",       type: .string("")),
                    SQLParameter.output("@DepartmentName", type: .string("")),
                ])
                XCTAssertNotNil(result.returnStatus)
                XCTAssertEqual(result.returnStatus, 0)
            }
        }
    }

    // ── INFO / PRINT message surfacing ────────────────────────────────────────

    func testInfoMessagesFromPrint() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                var messages: [(Int, String)] = []
                conn.onInfoMessage = { code, msg in messages.append((code, msg)) }

                _ = try await conn.execute("PRINT N'Hello from PRINT'")

                XCTAssertFalse(messages.isEmpty, "Should have received at least one INFO message")
                let found = messages.contains { $0.1.contains("Hello from PRINT") }
                XCTAssertTrue(found, "Expected PRINT message, got: \(messages)")
            }
        }
    }

    func testInfoMessagesFromStoredProc() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                var messages: [(Int, String)] = []
                conn.onInfoMessage = { code, msg in messages.append((code, msg)) }

                let _ = try await conn.callProcedure("sp_PrintMessage", parameters: [
                    SQLParameter(.string("test message"), name: "@Msg"),
                ])

                XCTAssertFalse(messages.isEmpty, "Should have received PRINT message from proc")
                let found = messages.contains { $0.1.contains("test message") }
                XCTAssertTrue(found, "Expected proc PRINT message, got: \(messages)")
            }
        }
    }
}
