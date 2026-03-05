import XCTest
@testable import CosmoPostgres
import CosmoSQLCore

final class PostgresTieredAPITests: XCTestCase, @unchecked Sendable {
    override func setUp() async throws { try skipUnlessPG() }

    func testStandardQuery() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT 1 AS val", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["val"].asInt32(), 1)
            }
        }
    }

    func testAdvancedQueryStream() {
        pgRunAsync {
            try await PGTestDatabase.withConnection { conn in
                var count = 0
                for try await row in conn.advanced.queryStream("SELECT 1 AS val", []) {
                    count += 1
                    XCTAssertEqual(row["val"].asInt32(), 1)
                }
                XCTAssertEqual(count, 1)
            }
        }
    }
}
