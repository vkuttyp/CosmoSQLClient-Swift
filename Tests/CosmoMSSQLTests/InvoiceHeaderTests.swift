import XCTest
@testable import CosmoMSSQL
import CosmoSQLCore

final class InvoiceHeaderTests: XCTestCase, @unchecked Sendable {

    override func setUp() async throws {
        try skipUnlessIntegration()
    }

    private func ensureProcedureExists(conn: MSSQLConnection) async throws {
        _ = try await conn.execute("IF OBJECT_ID('InvoiceHeader', 'P') IS NOT NULL DROP PROCEDURE InvoiceHeader;")
        
        _ = try await conn.execute("CREATE PROCEDURE InvoiceHeader @TransactionID NVARCHAR(50), @FinancialYear INT, @AdminUser INT, @Language NVARCHAR(50) AS BEGIN SELECT @TransactionID as TransactionID, @FinancialYear as FinancialYear, @AdminUser as AdminUser, @Language as Language, 'Test' as DummyData; END")
    }

    func testInvoiceHeaderProcedure_ShouldSucceed() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                try await self.ensureProcedureExists(conn: conn)

                let parameters: [SQLParameter] = [
                    .init("1-C-96/25", name: "TransactionID"),
                    .init(2025, name: "FinancialYear"),
                    .init(1, name: "AdminUser"),
                    .init("English", name: "Language")
                ]

                let result = try await conn.callProcedure("InvoiceHeader", parameters: parameters)

                XCTAssertEqual(result.rows.count, 1)
                XCTAssertEqual(result.rows[0]["TransactionID"].asString(), "1-C-96/25")
                XCTAssertEqual(result.resultSets.first?.columns.count, 5)
            }
        }
    }

    func testQueryTable_WithEmptyResult_ShouldHaveSchema() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let table = try await conn.queryTable("SELECT 'A' as Col1, 1 as Col2 WHERE 1=0")
                
                XCTAssertEqual(table.rowCount, 0)
                XCTAssertEqual(table.columnCount, 2)
                XCTAssertEqual(table.columns[0].name, "Col1")
                XCTAssertEqual(table.columns[1].name, "Col2")
            }
        }
    }

    func testQueryTable_WithInvoiceHeader_ShouldHaveData() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                try await self.ensureProcedureExists(conn: conn)

                let table = try await conn.queryTable("exec InvoiceHeader @TransactionID='1-C-96/25', @FinancialYear=2025, @AdminUser=1, @Language='English'")

                XCTAssertTrue(table.columnCount > 0)
                XCTAssertTrue(table.rowCount > 0)
                XCTAssertEqual(table[0, "TransactionID"].displayString, "1-C-96/25")
            }
        }
    }
}
