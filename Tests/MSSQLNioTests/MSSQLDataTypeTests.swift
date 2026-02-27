import XCTest
@testable import MSSQLNio
import SQLNioCore

// ── Data-type round-trip integration tests ────────────────────────────────────
//
// Each test verifies that a specific TDS type is correctly encoded in COLMETADATA
// and decoded in row data. Tests run against the `TypesTable` seeded in
// MSSQLNioTestDb.
//
// Skip all tests if MSSQL_TEST_HOST is not set.
//
// TDS type → SQLValue mapping (from TDSDecoder.readValue):
//   TINYINT  (0x30) → .int      SMALLINT (0x34) → .int
//   INT      (0x38) → .int32    BIGINT   (0x7F) → .int64
//   BIT      (0x32) → .bool     INTN     (0x26) → .int / .int32 / .int64
//   DECIMAL  (0x6A) → .decimal  FLOAT    (0x3E) → .double
//   REAL     (0x3B) → .float    MONEY    (0x3C) → .decimal
//   MONEYN   (0x6E) → .decimal  SMALLMONEY (0x7A) → .decimal
//   DATETIME (0x3D) → .date     SMALLDATETIME (0x3A) → .date
//   DATE     (0x28) → .date     TIME     (0x29) → .date
//   DATETIME2 (0x2A) → .date    DATETIMEOFFSET (0x2B) → .date
//   NVARCHAR (0xE7) → .string   VARCHAR  (0xA7) → .string
//   UUID     (0x24) → .uuid

final class MSSQLDataTypeTests: XCTestCase {

    // ── Helpers ──────────────────────────────────────────────────────────────

    override func setUp() async throws {
        try skipUnlessIntegration()
    }

    private func firstRow() async throws -> SQLRow {
        try await TestDatabase.withConnection { conn in
            let rows = try await conn.query(
                "SELECT * FROM TypesTable ORDER BY id", [])
            XCTAssertGreaterThanOrEqual(rows.count, 2, "TypesTable must have at least 2 rows")
            return rows[0]
        }
    }

    private func secondRow() async throws -> SQLRow {
        try await TestDatabase.withConnection { conn in
            let rows = try await conn.query(
                "SELECT * FROM TypesTable ORDER BY id", [])
            return rows[1]
        }
    }

    // ── INT ──────────────────────────────────────────────────────────────────

    func testInt() {
        runAsync {
            let row = try await self.firstRow()
            XCTAssertEqual(row["col_int"].toInt(), 42)
        }
    }

    func testIntNull() {
        runAsync {
            let row = try await self.firstRow()
            XCTAssertEqual(row["col_int_null"], .null)
        }
    }

    func testIntNotNull() {
        runAsync {
            let row = try await self.secondRow()
            XCTAssertEqual(row["col_int_null"].toInt(), 100)
        }
    }

    // ── BIGINT ───────────────────────────────────────────────────────────────

    func testBigInt() {
        runAsync {
            let row = try await self.firstRow()
            XCTAssertEqual(row["col_bigint"].asInt64(), Int64.max)
        }
    }

    func testBigIntMin() {
        runAsync {
            let row = try await self.secondRow()
            XCTAssertEqual(row["col_bigint"].asInt64(), Int64.min)
        }
    }

    // ── SMALLINT ─────────────────────────────────────────────────────────────

    func testSmallInt() {
        runAsync {
            let row = try await self.firstRow()
            XCTAssertEqual(row["col_smallint"].asInt(), 32767)
        }
    }

    func testSmallIntMin() {
        runAsync {
            let row = try await self.secondRow()
            XCTAssertEqual(row["col_smallint"].asInt(), -32768)
        }
    }

    // ── TINYINT ──────────────────────────────────────────────────────────────

    func testTinyInt() {
        runAsync {
            let row = try await self.firstRow()
            XCTAssertEqual(row["col_tinyint"].asInt(), 255)
        }
    }

    func testTinyIntZero() {
        runAsync {
            let row = try await self.secondRow()
            XCTAssertEqual(row["col_tinyint"].asInt(), 0)
        }
    }

    // ── BIT ──────────────────────────────────────────────────────────────────

    func testBitTrue() {
        runAsync {
            let row = try await self.firstRow()
            XCTAssertEqual(row["col_bit"].asBool(), true)
        }
    }

    func testBitFalse() {
        runAsync {
            let row = try await self.secondRow()
            XCTAssertEqual(row["col_bit"].asBool(), false)
        }
    }

    func testBitNull() {
        runAsync {
            let row = try await self.firstRow()
            XCTAssertEqual(row["col_bit_null"], .null)
        }
    }

    func testBitNullValue() {
        runAsync {
            let row = try await self.secondRow()
            XCTAssertEqual(row["col_bit_null"].asBool(), true)
        }
    }

    // ── DECIMAL ──────────────────────────────────────────────────────────────

    func testDecimal() {
        runAsync {
            let row = try await self.firstRow()
            let v = row["col_decimal"].toDouble()
            XCTAssertNotNil(v)
            XCTAssertEqual(v!, 12345.6789, accuracy: 0.0001)
        }
    }

    func testDecimalNull() {
        runAsync {
            let row = try await self.firstRow()
            XCTAssertEqual(row["col_decimal_null"], .null)
        }
    }

    func testDecimalSmall() {
        runAsync {
            let row = try await self.secondRow()
            let v = row["col_decimal"].toDouble()
            XCTAssertNotNil(v)
            XCTAssertEqual(v!, 0.0001, accuracy: 0.00001)
        }
    }

    func testDecimalNotNull() {
        runAsync {
            let row = try await self.secondRow()
            let v = row["col_decimal_null"].toDouble()
            XCTAssertNotNil(v)
            XCTAssertEqual(v!, 99.99, accuracy: 0.001)
        }
    }

    // ── FLOAT / REAL ─────────────────────────────────────────────────────────

    func testFloat() {
        runAsync {
            let row = try await self.firstRow()
            let v = row["col_float"].toDouble()
            XCTAssertNotNil(v)
            XCTAssertEqual(v!, 3.14159265358979, accuracy: 1e-10)
        }
    }

    func testReal() {
        runAsync {
            let row = try await self.firstRow()
            let v = row["col_real"].toDouble()
            XCTAssertNotNil(v)
            XCTAssertEqual(v!, 2.718, accuracy: 0.001)
        }
    }

    // ── MONEY ────────────────────────────────────────────────────────────────

    func testMoney() {
        runAsync {
            let row = try await self.firstRow()
            let v = row["col_money"].toDouble()
            XCTAssertNotNil(v)
            XCTAssertEqual(v!, 1234.5678, accuracy: 0.0001)
        }
    }

    func testSmallMoney() {
        runAsync {
            let row = try await self.firstRow()
            let v = row["col_smallmoney"].toDouble()
            XCTAssertNotNil(v)
            XCTAssertEqual(v!, 99.99, accuracy: 0.001)
        }
    }

    // ── DATETIME ─────────────────────────────────────────────────────────────

    func testDatetime() {
        runAsync {
            let row = try await self.firstRow()
            let d = row["col_datetime"].asDate()
            XCTAssertNotNil(d)
            // Seeded: '2024-01-15 10:30:00'
            let comps = Calendar(identifier: .gregorian)
                .dateComponents(in: TimeZone(identifier: "UTC")!, from: d!)
            XCTAssertEqual(comps.year,  2024)
            XCTAssertEqual(comps.month, 1)
            XCTAssertEqual(comps.day,   15)
            XCTAssertEqual(comps.hour,  10)
            XCTAssertEqual(comps.minute, 30)
        }
    }

    func testDatetimeNull() {
        runAsync {
            let row = try await self.firstRow()
            XCTAssertEqual(row["col_datetime_null"], .null)
        }
    }

    func testDatetimeNotNull() {
        runAsync {
            let row = try await self.secondRow()
            let d = row["col_datetime_null"].asDate()
            XCTAssertNotNil(d)
            let comps = Calendar(identifier: .gregorian)
                .dateComponents(in: TimeZone(identifier: "UTC")!, from: d!)
            XCTAssertEqual(comps.year,  2099)
            XCTAssertEqual(comps.month, 12)
            XCTAssertEqual(comps.day,   31)
        }
    }

    func testSqlServerEpoch() {
        runAsync {
            // Second row stores '1900-01-01 00:00:00' — the SQL Server DATETIME epoch
            let row = try await self.secondRow()
            let d = row["col_datetime"].asDate()
            XCTAssertNotNil(d)
            XCTAssertEqual(d!.timeIntervalSince1970, -2208988800.0, accuracy: 1.0)
        }
    }

    func testSmallDatetime() {
        runAsync {
            let row = try await self.firstRow()
            let d = row["col_smalldatetime"].asDate()
            XCTAssertNotNil(d)
            let comps = Calendar(identifier: .gregorian)
                .dateComponents(in: TimeZone(identifier: "UTC")!, from: d!)
            XCTAssertEqual(comps.year,  2024)
            XCTAssertEqual(comps.month, 1)
            XCTAssertEqual(comps.day,   15)
        }
    }

    // ── NVARCHAR(n) ──────────────────────────────────────────────────────────

    func testNVarChar() {
        runAsync {
            let row = try await self.firstRow()
            XCTAssertEqual(row["col_nvarchar"].asString(), "Hello, World!")
        }
    }

    func testNVarCharNull() {
        runAsync {
            let row = try await self.firstRow()
            XCTAssertEqual(row["col_nvarchar_null"], .null)
        }
    }

    func testNVarCharUnicode() {
        runAsync {
            // Second row stores "Ünïcödé テスト 中文"
            let row = try await self.secondRow()
            let s = row["col_nvarchar"].asString()
            XCTAssertNotNil(s)
            XCTAssertTrue(s!.contains("テスト"), "Expected Japanese characters")
            XCTAssertTrue(s!.contains("中文"),   "Expected Chinese characters")
        }
    }

    // ── NVARCHAR(MAX) / PLP ──────────────────────────────────────────────────

    func testNVarCharMax() {
        runAsync {
            let row = try await self.firstRow()
            let s = row["col_nvarchar_max"].asString()
            XCTAssertNotNil(s)
            XCTAssertTrue(s!.contains("NVARCHAR(MAX)"))
        }
    }

    func testNVarCharMaxLarge() {
        runAsync {
            // Second row stores 5000 'X' chars — crosses 4088-byte TDS packet boundary
            let row = try await self.secondRow()
            let s = row["col_nvarchar_max"].asString()
            XCTAssertNotNil(s)
            XCTAssertEqual(s!.count, 5000)
            XCTAssertTrue(s!.allSatisfy { $0 == "X" })
        }
    }

    // ── VARCHAR ──────────────────────────────────────────────────────────────

    func testVarChar() {
        runAsync {
            let row = try await self.firstRow()
            XCTAssertEqual(row["col_varchar"].asString(), "varchar_value")
        }
    }

    // ── UNIQUEIDENTIFIER ─────────────────────────────────────────────────────

    func testUniqueidentifier() {
        runAsync {
            let row = try await self.firstRow()
            let uuid = row["col_uniqueidentifier"].asUUID()
            XCTAssertNotNil(uuid)
            XCTAssertEqual(uuid, UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        }
    }

    func testUniqueidentifierNull() {
        runAsync {
            let row = try await self.firstRow()
            XCTAssertEqual(row["col_uniqueid_null"], .null)
        }
    }

    func testUniqueidentifierNotNull() {
        runAsync {
            let row = try await self.secondRow()
            let uuid = row["col_uniqueid_null"].asUUID()
            XCTAssertNotNil(uuid)
            XCTAssertEqual(uuid, UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"))
        }
    }

    // ── DATE (0x28) ──────────────────────────────────────────────────────────

    func testDate() {
        runAsync {
            let row = try await self.firstRow()
            let date = row["col_date"].asDate()
            XCTAssertNotNil(date, "col_date should decode to a Date")
            // 2025-03-15 → verify year/month/day in UTC
            let cal = Calendar(identifier: .gregorian)
            let comps = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date!)
            XCTAssertEqual(comps.year,  2025)
            XCTAssertEqual(comps.month,  3)
            XCTAssertEqual(comps.day,   15)
        }
    }

    func testDateNull() {
        runAsync {
            let row = try await self.secondRow()
            XCTAssertEqual(row["col_date_null"], .null)
        }
    }

    func testDateNotNull() {
        runAsync {
            let row = try await self.firstRow()
            let date = row["col_date_null"].asDate()
            XCTAssertNotNil(date)
            let cal = Calendar(identifier: .gregorian)
            let comps = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date!)
            XCTAssertEqual(comps.year,  2024)
            XCTAssertEqual(comps.month, 12)
            XCTAssertEqual(comps.day,   31)
        }
    }

    // ── TIME (0x29) ──────────────────────────────────────────────────────────

    func testTime() {
        runAsync {
            let row = try await self.firstRow()
            let date = row["col_time"].asDate()
            XCTAssertNotNil(date, "col_time should decode to a Date")
            // 13:45:30.1234567 → verify hour/minute/second
            let cal = Calendar(identifier: .gregorian)
            let comps = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date!)
            XCTAssertEqual(comps.hour,   13)
            XCTAssertEqual(comps.minute, 45)
            XCTAssertEqual(comps.second, 30)
        }
    }

    func testTimeNull() {
        runAsync {
            let row = try await self.secondRow()
            XCTAssertEqual(row["col_time_null"], .null)
        }
    }

    // ── DATETIME2 (0x2A) ─────────────────────────────────────────────────────

    func testDatetime2() {
        runAsync {
            let row = try await self.firstRow()
            let date = row["col_datetime2"].asDate()
            XCTAssertNotNil(date, "col_datetime2 should decode to a Date")
            let cal = Calendar(identifier: .gregorian)
            let comps = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date!)
            XCTAssertEqual(comps.year,   2025)
            XCTAssertEqual(comps.month,     3)
            XCTAssertEqual(comps.day,      15)
            XCTAssertEqual(comps.hour,     13)
            XCTAssertEqual(comps.minute,   45)
            XCTAssertEqual(comps.second,   30)
        }
    }

    func testDatetime2Null() {
        runAsync {
            let row = try await self.secondRow()
            XCTAssertEqual(row["col_datetime2_null"], .null)
        }
    }

    func testDatetime2NotNull() {
        runAsync {
            let row = try await self.firstRow()
            let date = row["col_datetime2_null"].asDate()
            XCTAssertNotNil(date)
            let cal = Calendar(identifier: .gregorian)
            let comps = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date!)
            XCTAssertEqual(comps.year,  2025)
            XCTAssertEqual(comps.month,    1)
            XCTAssertEqual(comps.day,      1)
            XCTAssertEqual(comps.hour,     0)
        }
    }

    // ── DATETIMEOFFSET (0x2B) ────────────────────────────────────────────────

    func testDatetimeoffset() {
        runAsync {
            let row = try await self.firstRow()
            let date = row["col_dtoffset"].asDate()
            XCTAssertNotNil(date, "col_dtoffset should decode to a Date")
            // '2025-03-15 13:45:30 +05:30' → UTC = 08:15:30
            let cal = Calendar(identifier: .gregorian)
            let comps = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date!)
            XCTAssertEqual(comps.year,   2025)
            XCTAssertEqual(comps.month,     3)
            XCTAssertEqual(comps.day,      15)
            XCTAssertEqual(comps.hour,      8)
            XCTAssertEqual(comps.minute,   15)
            XCTAssertEqual(comps.second,   30)
        }
    }

    func testDatetimeoffsetNull() {
        runAsync {
            let row = try await self.secondRow()
            XCTAssertEqual(row["col_dtoffset_null"], .null)
        }
    }

    // ── MONEYN (0x6E) ────────────────────────────────────────────────────────

    func testMoneyNull() {
        runAsync {
            let row = try await self.secondRow()
            XCTAssertEqual(row["col_money_null"], .null)
        }
    }

    func testMoneyNullNotNull() {
        runAsync {
            let row = try await self.firstRow()
            let d = row["col_money_null"].asDecimal()
            XCTAssertNotNil(d)
            XCTAssertEqual(d, Decimal(string: "9.99"))
        }
    }

    func testSmallmoneyNull() {
        runAsync {
            let row = try await self.secondRow()
            XCTAssertEqual(row["col_smallmoney_null"], .null)
        }
    }

    func testSmallmoneyNullNotNull() {
        runAsync {
            let row = try await self.firstRow()
            let d = row["col_smallmoney_null"].asDecimal()
            XCTAssertNotNil(d)
            XCTAssertEqual(d, Decimal(string: "1.23"))
        }
    }
}
