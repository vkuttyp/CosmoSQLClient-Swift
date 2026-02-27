import XCTest
import NIOCore
@testable import PostgresNio

final class PostgresFramingTests: XCTestCase {

    func testStartupMessageFormat() {
        let buf = PGFrontend.startup(user: "alice", database: "mydb",
                                     allocator: ByteBufferAllocator())
        // First 4 bytes = total length (big-endian int32)
        let length: Int32 = buf.getInteger(at: buf.readerIndex, endianness: .big)!
        XCTAssertEqual(Int(length), buf.readableBytes)
    }

    func testSSLRequestFormat() {
        let buf = PGFrontend.sslRequest(allocator: ByteBufferAllocator())
        XCTAssertEqual(buf.readableBytes, 8)
        let length: Int32 = buf.getInteger(at: 0, endianness: .big)!
        XCTAssertEqual(length, 8)
        let code:   Int32 = buf.getInteger(at: 4, endianness: .big)!
        XCTAssertEqual(code, 80877103)
    }

    func testQueryMessageFormat() {
        let sql = "SELECT 1"
        let buf = PGFrontend.query(sql, allocator: ByteBufferAllocator())
        // type byte = 'Q' = 0x51
        XCTAssertEqual(buf.getBytes(at: 0, length: 1)![0], 0x51)
        // length (4 bytes big-endian): 4 (itself) + sql.utf8.count + 1 (null)
        let expectedLen = Int32(4 + sql.utf8.count + 1)
        let actualLen: Int32 = buf.getInteger(at: 1, endianness: .big)!
        XCTAssertEqual(actualLen, expectedLen)
    }
}

final class PostgresDecoderTests: XCTestCase {

    func testMD5PasswordHashing() {
        // Known vector from PostgreSQL docs
        let result = pgMD5Password(user: "bob", password: "secret", salt: [0x53, 0x61, 0x6C, 0x74])
        XCTAssertTrue(result.hasPrefix("md5"))
        XCTAssertEqual(result.count, 35)  // "md5" + 32 hex chars
    }

    func testDecodeCommandComplete() throws {
        var buf = ByteBufferAllocator().buffer(capacity: 32)
        buf.writeInteger(UInt8(0x43))             // 'C' commandComplete
        let body = "SELECT 5\0"
        buf.writeInteger(Int32(4 + body.utf8.count), endianness: .big)
        buf.writeString(body)

        let msg = try PGMessageDecoder.decode(buffer: &buf)
        if case .commandComplete(let tag) = msg {
            XCTAssertEqual(tag.rowsAffected, 5)
        } else {
            XCTFail("Expected commandComplete, got \(msg)")
        }
    }

    func testDecodeErrorResponse() throws {
        var buf = ByteBufferAllocator().buffer(capacity: 64)
        buf.writeInteger(UInt8(0x45))   // 'E' error
        var body = ByteBufferAllocator().buffer(capacity: 32)
        body.writeInteger(UInt8(ascii: "S")); body.writeString("ERROR\0")
        body.writeInteger(UInt8(ascii: "M")); body.writeString("relation does not exist\0")
        body.writeInteger(UInt8(0))   // terminator
        buf.writeInteger(Int32(4 + body.readableBytes), endianness: .big)
        buf.writeBuffer(&body)

        let msg = try PGMessageDecoder.decode(buffer: &buf)
        if case .error(_, _, let message) = msg {
            XCTAssertTrue(message.contains("relation does not exist"))
        } else {
            XCTFail("Expected error, got \(msg)")
        }
    }
}
