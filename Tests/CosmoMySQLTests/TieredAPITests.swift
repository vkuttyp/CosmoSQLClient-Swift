import XCTest
@testable import CosmoMySQL
import CosmoSQLCore

final class MySQLTieredAPITests: XCTestCase, @unchecked Sendable {
    override func setUp() async throws { try skipUnlessMySQL() }

    func testStandardQuery() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT 1 AS val", [])
                XCTAssertEqual(rows.count, 1)
                let val = rows[0]["val"]
                let intVal = val.asInt32() ?? val.asInt64().map { v in Int32(v) }
                XCTAssertEqual(intVal, 1)
            }
        }
    }

    func testAdvancedQueryStream() {
        mysqlRunAsync {
            try await MySQLTestDatabase.withConnection { conn in
                var count = 0
                for try await row in conn.advanced.queryStream("SELECT 1 AS val", []) {
                    count += 1
                    let val = row["val"]
                    let intVal = val.asInt32() ?? val.asInt64().map { v in Int32(v) }
                    XCTAssertEqual(intVal, 1)
                }
                XCTAssertEqual(count, 1)
            }
        }
    }
}
