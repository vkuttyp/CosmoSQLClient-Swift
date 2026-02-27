import XCTest
import SQLNioCore

final class SQLValueTests: XCTestCase {

    func testLiteralInit() {
        let n: SQLValue = nil
        XCTAssertTrue(n.isNull)

        let b: SQLValue = true
        XCTAssertEqual(b.asBool(), true)

        let i: SQLValue = 42
        XCTAssertEqual(i.asInt(), 42)

        let d: SQLValue = 3.14
        XCTAssertEqual(d.asDouble()!, 3.14, accuracy: 0.001)

        let s: SQLValue = "hello"
        XCTAssertEqual(s.asString(), "hello")
    }

    func testTypedAccessors() {
        XCTAssertNil(SQLValue.string("x").asInt())
        XCTAssertNil(SQLValue.null.asBool())
        XCTAssertNil(SQLValue.null.asString())
    }

    func testEquality() {
        XCTAssertEqual(SQLValue.int(1), SQLValue.int(1))
        XCTAssertNotEqual(SQLValue.int(1), SQLValue.int(2))
        XCTAssertEqual(SQLValue.null, SQLValue.null)
    }
}

final class SQLRowTests: XCTestCase {

    func testIndexAccess() {
        let cols = [SQLColumn(name: "id"), SQLColumn(name: "name")]
        let row  = SQLRow(columns: cols, values: [.int32(1), .string("Alice")])
        XCTAssertEqual(row[0], .int32(1))
        XCTAssertEqual(row[1], .string("Alice"))
    }

    func testNameAccess() {
        let cols = [SQLColumn(name: "ID"), SQLColumn(name: "Name")]
        let row  = SQLRow(columns: cols, values: [.int32(99), .string("Bob")])
        XCTAssertEqual(row["id"],   .int32(99))    // case-insensitive
        XCTAssertEqual(row["name"], .string("Bob"))
        XCTAssertEqual(row["missing"], .null)       // unknown column → .null
    }

    func testRequireThrowsOnMissingColumn() {
        let cols = [SQLColumn(name: "id")]
        let row  = SQLRow(columns: cols, values: [.int32(1)])
        XCTAssertThrowsError(try row["nonexistent"].require(column: "nonexistent"))
    }
}

final class SQLErrorTests: XCTestCase {

    func testDescriptions() {
        let e = SQLError.serverError(code: 1045, message: "Access denied")
        XCTAssertTrue(e.description.contains("1045"))
        XCTAssertTrue(e.description.contains("Access denied"))

        let e2 = SQLError.columnNotFound("email")
        XCTAssertTrue(e2.description.contains("email"))
    }
}
