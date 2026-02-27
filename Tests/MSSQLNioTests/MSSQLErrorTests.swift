import XCTest
@testable import MSSQLNio
import SQLNioCore

// ── Error handling integration tests ─────────────────────────────────────────

final class MSSQLErrorTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws {
        try skipUnlessIntegration()
    }

    // ── SQL syntax / runtime errors ──────────────────────────────────────────

    func testInvalidSQLSyntax() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                do {
                    _ = try await conn.query("THIS IS NOT SQL", [])
                    XCTFail("Expected an error for invalid SQL")
                } catch {
                    XCTAssertNotNil(error)
                }
            }
        }
    }

    func testUnknownTable() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                do {
                    _ = try await conn.query("SELECT * FROM NonExistentTable99", [])
                    XCTFail("Expected an error for unknown table")
                } catch {
                    XCTAssertNotNil(error)
                }
            }
        }
    }

    func testDivisionByZero() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                do {
                    _ = try await conn.query("SELECT 1 / 0", [])
                    XCTFail("Expected division-by-zero error")
                } catch {
                    XCTAssertNotNil(error)
                }
            }
        }
    }

    func testColumnDoesNotExist() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                do {
                    _ = try await conn.query(
                        "SELECT nonexistent_column FROM Departments", [])
                    XCTFail("Expected column-not-found error")
                } catch {
                    XCTAssertNotNil(error)
                }
            }
        }
    }

    // ── Recovery: new connection after error ─────────────────────────────────

    func testNewConnectionAfterError() {
        runAsync {
            // First connection hits an error
            try await TestDatabase.withConnection { conn in
                do { _ = try await conn.query("SELECT * FROM GhostTable", []) }
                catch { /* expected */ }
            }

            // A fresh connection must still work correctly
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT 42 AS val", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["val"].toInt(), 42)
            }
        }
    }

    // ── Concurrent independent connections ───────────────────────────────────

    func testConcurrentConnections() {
        runAsync {
            async let r1: [SQLRow] = TestDatabase.withConnection { conn in
                try await conn.query("SELECT COUNT(*) AS cnt FROM Departments", [])
            }
            async let r2: [SQLRow] = TestDatabase.withConnection { conn in
                try await conn.query("SELECT COUNT(*) AS cnt FROM Employees", [])
            }
            async let r3: [SQLRow] = TestDatabase.withConnection { conn in
                try await conn.query("SELECT COUNT(*) AS cnt FROM LargeData", [])
            }
            let (rows1, rows2, rows3) = try await (r1, r2, r3)
            XCTAssertEqual(rows1[0]["cnt"].toInt(), 5)
            XCTAssertEqual(rows2[0]["cnt"].toInt(), 5)
            XCTAssertGreaterThanOrEqual(rows3[0]["cnt"].toInt() ?? 0, 3)
        }
    }

    // ── Connection reuse across query sequence ───────────────────────────────

    func testReuseConnectionAfterSuccessfulQuery() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let r1 = try await conn.query("SELECT 1 AS v", [])
                XCTAssertEqual(r1[0]["v"].toInt(), 1)

                let r2 = try await conn.query("SELECT 2 AS v", [])
                XCTAssertEqual(r2[0]["v"].toInt(), 2)

                let r3 = try await conn.query(
                    "SELECT name FROM Departments WHERE id = @p1", [.int(1)])
                XCTAssertEqual(r3[0]["name"].asString(), "Engineering")
            }
        }
    }
}
