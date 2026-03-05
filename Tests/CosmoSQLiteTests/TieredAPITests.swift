import XCTest
@testable import CosmoSQLite
import CosmoSQLCore

final class SQLiteTieredAPITests: XCTestCase, @unchecked Sendable {
    func testStandardQuery() {
        let exp = expectation(description: "sqlite")
        Task {
            do {
                let conn = try SQLiteConnection.open(configuration: .init(storage: .memory))
                let rows = try await conn.query("SELECT 1 AS val", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["val"].asInt64(), 1)
                try await conn.close()
            } catch { XCTFail("\(error)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testAdvancedQueryStream() {
        let exp = expectation(description: "sqlite-stream")
        Task {
            do {
                let conn = try SQLiteConnection.open(configuration: .init(storage: .memory))
                var count = 0
                for try await row in conn.advanced.queryStream("SELECT 1 AS val", []) {
                    count += 1
                    XCTAssertEqual(row["val"].asInt64(), 1)
                }
                XCTAssertEqual(count, 1)
                try await conn.close()
            } catch { XCTFail("\(error)") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }
}
