// SQLClientCompatTests.swift
//
// Tests ported from SQLClient-Swift to exercise the same scenarios
// against the pure-Swift MSSQLNio driver.
//
// Environment variables (same as the rest of the test suite):
//   MSSQL_TEST_HOST=127.0.0.1
//   MSSQL_TEST_PASS=aBCD111
//   swift test --filter SQLClientCompat

import XCTest
@testable import MSSQLNio
import SQLNioCore

// MARK: - Basic Query Tests

final class SQLClientCompatBasicTests: XCTestCase {

    override func setUp() async throws { try skipUnlessIntegration() }

    // MARK: - Connect / disconnect

    func testConnect() {
        runAsync {
            let conn = try await TestDatabase.connect()
            XCTAssertTrue(conn.isOpen)
            try? await conn.close()
            XCTAssertFalse(conn.isOpen)
        }
    }

    // MARK: - Simple scalar selects

    func testSelectScalar() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT 42 AS Answer", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["Answer"].asInt32(), 42)
            }
        }
    }

    func testSelectNull() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT NULL AS Val", [])
                XCTAssertEqual(rows[0]["Val"], .null)
            }
        }
    }

    func testSelectString() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT 'Hello' AS Msg", [])
                XCTAssertEqual(rows[0]["Msg"].asString(), "Hello")
            }
        }
    }

    func testSelectFloat() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT CAST(3.14 AS FLOAT) AS Pi", [])
                let pi = rows[0]["Pi"].asDouble() ?? 0
                XCTAssertEqual(pi, 3.14, accuracy: 0.001)
            }
        }
    }

    func testSelectBit() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT CAST(1 AS BIT) AS Flag", [])
                XCTAssertEqual(rows[0]["Flag"].asBool(), true)
            }
        }
    }

    func testSelectDateTime() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT GETDATE() AS Now", [])
                XCTAssertNotNil(rows[0]["Now"].asDate())
            }
        }
    }

    func testMultipleRows() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3", [])
                XCTAssertEqual(rows.count, 3)
                let nums = rows.compactMap { $0["n"].asInt32() }
                XCTAssertEqual(nums, [1, 2, 3])
            }
        }
    }

    // MARK: - Multiple result sets

    func testMultipleResultSets() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let sets = try await conn.queryMulti("SELECT 1 AS A; SELECT 2 AS B;")
                XCTAssertEqual(sets.count, 2)
                XCTAssertEqual(sets[0][0]["A"].asInt32(), 1)
                XCTAssertEqual(sets[1][0]["B"].asInt32(), 2)
            }
        }
    }

    // MARK: - Rows affected

    func testRowsAffected() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                _ = try await conn.execute("""
                    IF OBJECT_ID('tempdb..#CompatT') IS NOT NULL DROP TABLE #CompatT;
                    CREATE TABLE #CompatT (id INT);
                    INSERT INTO #CompatT VALUES (1),(2),(3);
                """, [])
                let affected = try await conn.execute("UPDATE #CompatT SET id = id + 10", [])
                XCTAssertEqual(affected, 3)
                _ = try await conn.execute("DROP TABLE #CompatT", [])
            }
        }
    }

    // MARK: - Parameterized queries

    func testParameterizedQueryQuestionMark() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                // Using ? placeholder (auto-converted to @p1)
                let rows = try await conn.query("SELECT ? AS Name", [.string("O'Brien")])
                XCTAssertEqual(rows[0]["Name"].asString(), "O'Brien")
            }
        }
    }

    func testParameterizedQueryAtStyle() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                // Using @p1 placeholder directly
                let rows = try await conn.query("SELECT @p1 AS Name", [.string("O'Brien")])
                XCTAssertEqual(rows[0]["Name"].asString(), "O'Brien")
            }
        }
    }

    func testNullParameter() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query("SELECT @p1 AS Val", [.null])
                XCTAssertEqual(rows[0]["Val"], .null)
            }
        }
    }

    func testMultipleParameters() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                let rows = try await conn.query(
                    "SELECT @p1 + @p2 AS Total",
                    [.int32(10), .int32(20)]
                )
                XCTAssertEqual(rows[0]["Total"].asInt32(), 30)
            }
        }
    }

    // MARK: - Error handling

    func testBadSQLThrows() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                do {
                    _ = try await conn.query("THIS IS NOT VALID SQL", [])
                    XCTFail("Expected server error")
                } catch SQLError.serverError {
                    // expected
                }
            }
        }
    }

    func testConnectionClosedThrows() {
        runAsync {
            let conn = try await TestDatabase.connect()
            try? await conn.close()
            XCTAssertFalse(conn.isOpen)
            do {
                _ = try await conn.query("SELECT 1", [])
                XCTFail("Expected connectionClosed error")
            } catch SQLError.connectionClosed {
                // expected
            }
        }
    }

    // MARK: - Decodable struct

    func testDecodableStruct() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                struct Point: Decodable {
                    let x: Int32
                    let y: Int32
                }
                let rows = try await conn.query("SELECT 10 AS x, 20 AS y", [])
                let points = try rows.map { try SQLRowDecoder().decode(Point.self, from: $0) }
                XCTAssertEqual(points[0].x, 10)
                XCTAssertEqual(points[0].y, 20)
            }
        }
    }

    func testDecodableSnakeCase() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                struct Item: Decodable {
                    let itemId: Int32
                    let itemName: String
                }
                let rows = try await conn.query("SELECT 7 AS item_id, 'Widget' AS item_name", [])
                var decoder = SQLRowDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let items = try rows.map { try decoder.decode(Item.self, from: $0) }
                XCTAssertEqual(items[0].itemId, 7)
                XCTAssertEqual(items[0].itemName, "Widget")
            }
        }
    }
}

// MARK: - Transaction Tests

final class SQLClientCompatTransactionTests: XCTestCase {

    override func setUp() async throws { try skipUnlessIntegration() }

    func testCommitTransaction() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                _ = try await conn.execute("""
                    IF OBJECT_ID('tempdb..#TranCompat') IS NOT NULL DROP TABLE #TranCompat;
                    CREATE TABLE #TranCompat (Id INT, Name NVARCHAR(50));
                """, [])
                try await conn.beginTransaction()
                _ = try await conn.execute("INSERT INTO #TranCompat VALUES (1, 'Committed')", [])
                try await conn.commitTransaction()

                let rows = try await conn.query("SELECT Name FROM #TranCompat WHERE Id = 1", [])
                XCTAssertEqual(rows.count, 1)
                XCTAssertEqual(rows[0]["Name"].asString(), "Committed")
                _ = try await conn.execute("DROP TABLE #TranCompat", [])
            }
        }
    }

    func testRollbackTransaction() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                _ = try await conn.execute("""
                    IF OBJECT_ID('tempdb..#TranCompatRB') IS NOT NULL DROP TABLE #TranCompatRB;
                    CREATE TABLE #TranCompatRB (Id INT, Name NVARCHAR(50));
                """, [])
                try await conn.beginTransaction()
                _ = try await conn.execute("INSERT INTO #TranCompatRB VALUES (2, 'RolledBack')", [])
                try await conn.rollbackTransaction()

                let rows = try await conn.query("SELECT Name FROM #TranCompatRB WHERE Id = 2", [])
                XCTAssertEqual(rows.count, 0)
                _ = try await conn.execute("DROP TABLE #TranCompatRB", [])
            }
        }
    }

    func testWithTransactionHelper() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                _ = try await conn.execute("""
                    IF OBJECT_ID('tempdb..#TranHelper') IS NOT NULL DROP TABLE #TranHelper;
                    CREATE TABLE #TranHelper (Val INT);
                """, [])
                try await conn.withTransaction { _ in
                    _ = try await conn.execute("INSERT INTO #TranHelper VALUES (99)", [])
                }
                let rows = try await conn.query("SELECT Val FROM #TranHelper", [])
                XCTAssertEqual(rows[0]["Val"].asInt32(), 99)
                _ = try await conn.execute("DROP TABLE #TranHelper", [])
            }
        }
    }
}

// MARK: - Stored Procedure / RPC Tests

final class SQLClientCompatProcTests: XCTestCase {

    override func setUp() async throws { try skipUnlessIntegration() }

    func testRPCWithOutputParameters() {
        runAsync {
            let procName = "CompatRPC_IntProc"
            try await TestDatabase.withConnection { conn in
                _ = try? await conn.execute("DROP PROCEDURE \(procName)", [])
                _ = try await conn.execute("""
                    CREATE PROCEDURE \(procName) @InVal INT, @OutVal INT OUTPUT AS
                    BEGIN
                        SET @OutVal = @InVal * 2;
                        RETURN 77;
                    END;
                """, [])
                defer { Task { try? await conn.execute("DROP PROCEDURE \(procName)", []) } }

                let params: [SQLParameter] = [
                    SQLParameter(.int32(21),      name: "@InVal",  isOutput: false),
                    SQLParameter(.int32(0),       name: "@OutVal", isOutput: true),
                ]
                let result = try await conn.callProcedure(procName, parameters: params)

                XCTAssertEqual(result.outputParameters["@OutVal"]?.asInt32(), 42)
                XCTAssertEqual(result.returnStatus, 77)
            }
        }
    }

    func testRPCWithStringOutput() {
        runAsync {
            let procName = "CompatRPC_StrProc"
            try await TestDatabase.withConnection { conn in
                _ = try? await conn.execute("DROP PROCEDURE \(procName)", [])
                _ = try await conn.execute("""
                    CREATE PROCEDURE \(procName) @InStr NVARCHAR(50), @OutStr NVARCHAR(50) OUTPUT AS
                    BEGIN
                        SET @OutStr = N'Hello ' + @InStr;
                    END;
                """, [])
                defer { Task { try? await conn.execute("DROP PROCEDURE \(procName)", []) } }

                let params: [SQLParameter] = [
                    SQLParameter(.string("World"), name: "@InStr",  isOutput: false),
                    SQLParameter(.string(""),      name: "@OutStr", isOutput: true),
                ]
                let result = try await conn.callProcedure(procName, parameters: params)
                XCTAssertEqual(result.outputParameters["@OutStr"]?.asString(), "Hello World")
            }
        }
    }

    func testRPCWithResultSet() {
        runAsync {
            let procName = "CompatRPC_SelectProc"
            try await TestDatabase.withConnection { conn in
                _ = try? await conn.execute("DROP PROCEDURE \(procName)", [])
                _ = try await conn.execute("""
                    CREATE PROCEDURE \(procName) @N INT AS
                    BEGIN
                        SELECT @N AS Val, @N * 2 AS [Double];
                    END;
                """, [])
                defer { Task { try? await conn.execute("DROP PROCEDURE \(procName)", []) } }

                let params: [SQLParameter] = [
                    SQLParameter(.int32(7), name: "@N", isOutput: false),
                ]
                let result = try await conn.callProcedure(procName, parameters: params)
                XCTAssertEqual(result.rows.count, 1)
                XCTAssertEqual(result.rows[0]["Val"].asInt32(), 7)
                XCTAssertEqual(result.rows[0]["Double"].asInt32(), 14)  // [Double] is bracket-quoted
            }
        }
    }

    func testOutputParamsViaExecBatch() {
        // Mirrors SQLOutputParamTests — uses EXEC in a batch, reads result as SELECT
        runAsync {
            try await TestDatabase.withConnection { conn in
                _ = try? await conn.execute("IF OBJECT_ID('tempdb..#CompatOutProc') IS NOT NULL DROP PROCEDURE #CompatOutProc", [])
                _ = try await conn.execute("""
                    CREATE PROCEDURE #CompatOutProc @InVal INT, @OutVal INT OUTPUT AS
                    BEGIN
                        SET @OutVal = @InVal * 2;
                        RETURN 99;
                    END;
                """, [])
                let rows = try await conn.query("""
                    DECLARE @Out INT;
                    EXEC #CompatOutProc @InVal = 21, @OutVal = @Out OUTPUT;
                    SELECT @Out AS OutVal;
                """, [])
                XCTAssertEqual(rows[0]["OutVal"].asInt32(), 42)
            }
        }
    }

    func testMultipleOutputParameters() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                _ = try? await conn.execute("IF OBJECT_ID('tempdb..#CompatMultiOut') IS NOT NULL DROP PROCEDURE #CompatMultiOut", [])
                _ = try await conn.execute("""
                    CREATE PROCEDURE #CompatMultiOut @A INT OUTPUT, @B NVARCHAR(50) OUTPUT AS
                    BEGIN
                        SET @A = 123;
                        SET @B = N'Hello Output';
                    END;
                """, [])
                let rows = try await conn.query("""
                    DECLARE @O1 INT, @O2 NVARCHAR(50);
                    EXEC #CompatMultiOut @A = @O1 OUTPUT, @B = @O2 OUTPUT;
                    SELECT @O1 AS A, @O2 AS B;
                """, [])
                XCTAssertEqual(rows[0]["A"].asInt32(), 123)
                XCTAssertEqual(rows[0]["B"].asString(), "Hello Output")
            }
        }
    }

    func testNamedInputParameters() {
        // Mirrors SQLParameterizedTests.testExecuteParameterized
        runAsync {
            let procName = "CompatRPC_NamedParams"
            try await TestDatabase.withConnection { conn in
                _ = try? await conn.execute("DROP PROCEDURE \(procName)", [])
                _ = try await conn.execute("""
                    CREATE PROCEDURE \(procName) @Val INT, @Str NVARCHAR(50) AS
                    BEGIN
                        SELECT @Val + 1 AS Result, @Str AS Msg;
                    END;
                """, [])
                defer { Task { try? await conn.execute("DROP PROCEDURE \(procName)", []) } }

                let params: [SQLParameter] = [
                    SQLParameter(.int32(10),       name: "@Val", isOutput: false),
                    SQLParameter(.string("Hello"), name: "@Str", isOutput: false),
                ]
                let result = try await conn.callProcedure(procName, parameters: params)
                XCTAssertEqual(result.rows[0]["Result"].asInt32(), 11)
                XCTAssertEqual(result.rows[0]["Msg"].asString(), "Hello")
            }
        }
    }
}

// MARK: - Bulk Insert Tests

final class SQLClientCompatBulkTests: XCTestCase {

    override func setUp() async throws { try skipUnlessIntegration() }

    func testBulkInsert100Rows() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                _ = try await conn.execute("""
                    IF OBJECT_ID('tempdb..#BCPCompat') IS NOT NULL DROP TABLE #BCPCompat;
                    CREATE TABLE #BCPCompat (Id INT, Name NVARCHAR(50), Value FLOAT);
                """, [])
                defer { Task { try? await conn.execute("DROP TABLE #BCPCompat", []) } }

                let columns = ["Id", "Name", "Value"]
                let rows: [[SQLValue]] = (1...100).map { i in
                    [.int32(Int32(i)), .string("Row \(i)"), .double(Double(i) * 1.1)]
                }

                let inserted = try await conn.bulkInsert(table: "#BCPCompat", columns: columns, rows: rows)
                XCTAssertEqual(inserted, 100)

                let countRows = try await conn.query("SELECT COUNT(*) AS cnt FROM #BCPCompat", [])
                XCTAssertEqual(countRows[0]["cnt"].asInt32(), 100)

                let row42 = try await conn.query("SELECT Name FROM #BCPCompat WHERE Id = 42", [])
                XCTAssertEqual(row42[0]["Name"].asString(), "Row 42")
            }
        }
    }

    func testBulkInsertDictRows() {
        runAsync {
            try await TestDatabase.withConnection { conn in
                _ = try await conn.execute("""
                    IF OBJECT_ID('tempdb..#BCPDict') IS NOT NULL DROP TABLE #BCPDict;
                    CREATE TABLE #BCPDict (Code NVARCHAR(10), Amount INT);
                """, [])
                defer { Task { try? await conn.execute("DROP TABLE #BCPDict", []) } }

                let rows: [[String: SQLValue]] = [
                    ["Code": .string("A"), "Amount": .int32(10)],
                    ["Code": .string("B"), "Amount": .int32(20)],
                    ["Code": .string("C"), "Amount": .int32(30)],
                ]
                let inserted = try await conn.bulkInsert(table: "#BCPDict", rows: rows)
                XCTAssertEqual(inserted, 3)

                let total = try await conn.query("SELECT SUM(Amount) AS T FROM #BCPDict", [])
                XCTAssertEqual(total[0]["T"].asInt32(), 60)
            }
        }
    }
}

// MARK: - Connection Pool Tests

final class SQLClientCompatPoolTests: XCTestCase {

    override func setUp() async throws { try skipUnlessIntegration() }

    func testPoolAcquireRelease() {
        runAsync {
            let pool = MSSQLConnectionPool(configuration: TestDatabase.configuration, maxConnections: 2)
            let conn1 = try await pool.acquire()
            XCTAssertTrue(conn1.isOpen)
            let active1 = await pool.activeCount
            XCTAssertEqual(active1, 1)

            let conn2 = try await pool.acquire()
            XCTAssertTrue(conn2.isOpen)
            let active2 = await pool.activeCount
            XCTAssertEqual(active2, 2)

            await pool.release(conn1)
            let active3 = await pool.activeCount
            XCTAssertEqual(active3, 1)

            // Re-acquire should reuse conn1
            let conn3 = try await pool.acquire()
            XCTAssertTrue(conn3 === conn1, "Expected connection reuse from idle pool")
            let active4 = await pool.activeCount
            XCTAssertEqual(active4, 2)

            await pool.release(conn2)
            await pool.release(conn3)
            await pool.closeAll()
        }
    }

    func testPoolWithConnection() {
        runAsync {
            let pool = MSSQLConnectionPool(configuration: TestDatabase.configuration, maxConnections: 2)
            let result = try await pool.withConnection { conn in
                let rows = try await conn.query("SELECT 42 AS Answer", [])
                return rows[0]["Answer"].asInt32()
            }
            XCTAssertEqual(result, 42)
            let active = await pool.activeCount
            XCTAssertEqual(active, 0)
            await pool.closeAll()
        }
    }

    func testPoolConcurrentQueries() {
        runAsync {
            let pool = MSSQLConnectionPool(configuration: TestDatabase.configuration, maxConnections: 3)
            try await withThrowingTaskGroup(of: Int32.self) { group in
                for i in 1...9 {
                    let val = Int32(i)
                    group.addTask {
                        try await pool.withConnection { (conn: MSSQLConnection) -> Int32 in
                            let rows = try await conn.query("SELECT \(val) AS val", [])
                            return rows[0]["val"].asInt32() ?? -1
                        }
                    }
                }
                var results: [Int32] = []
                for try await r in group { results.append(r) }
                XCTAssertEqual(results.sorted(), Array(1...9).map { Int32($0) })
            }
            await pool.closeAll()
        }
    }
}
