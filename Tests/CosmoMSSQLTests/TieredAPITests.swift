import XCTest
@testable import CosmoMSSQL
import CosmoSQLCore

final class MSSQLTieredAPITests: XCTestCase, @unchecked Sendable {
    override func setUp() async throws { try skipUnlessIntegration() }

    func testStandardQuery() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT 1 AS val", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["val"].asInt32(), 1)
            }
        }
    }

    func testAdvancedQueryStream() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                var count = 0
                for try await row in conn.advanced.queryStream("SELECT 1 AS val", []) {
                    count += 1
                    XCTAssertEqual(row["val"].asInt32(), 1)
                }
                XCTAssertEqual(count, 1)
            }
        }
    }

    func testAdvancedJsonStream() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                var count = 0
                for try await data in conn.advanced.queryJsonStream("SELECT 1 AS val FOR JSON PATH", []) {
                    count += 1
                    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    XCTAssertNotNil(obj)
                }
                XCTAssertEqual(count, 1)
            }
        }
    }
}
