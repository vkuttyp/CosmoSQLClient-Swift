import XCTest
import NIOCore
@testable import MySQLNio

final class MySQLFramingTests: XCTestCase, @unchecked Sendable {

    func testPacketBuildAndRead() {
        let allocator = ByteBufferAllocator()
        var body = allocator.buffer(capacity: 4)
        body.writeBytes([0x01, 0x02, 0x03, 0x04])

        var packet = ByteBuffer.mysqlPacket(sequenceID: 1, body: body, allocator: allocator)
        XCTAssertEqual(packet.readableBytes, 8)   // 4-byte header + 4-byte payload

        // Verify 3-byte little-endian length = 4
        let b0: UInt8 = packet.readInteger()!
        let b1: UInt8 = packet.readInteger()!
        let b2: UInt8 = packet.readInteger()!
        let len = Int(b0) | (Int(b1) << 8) | (Int(b2) << 16)
        XCTAssertEqual(len, 4)

        let seqID: UInt8 = packet.readInteger()!
        XCTAssertEqual(seqID, 1)
    }

    func testLengthEncodedInt() {
        var buf = ByteBufferAllocator().buffer(capacity: 16)

        buf.writeLengthEncodedInt(200)      // 1-byte
        buf.writeLengthEncodedInt(1000)     // 3-byte (0xFC prefix)
        buf.writeLengthEncodedInt(100_000)  // 4-byte (0xFD prefix)

        XCTAssertEqual(buf.readLengthEncodedInt(), 200)
        XCTAssertEqual(buf.readLengthEncodedInt(), 1000)
        XCTAssertEqual(buf.readLengthEncodedInt(), 100_000)
    }
}

final class MySQLDecoderTests: XCTestCase, @unchecked Sendable {

    func testNativePasswordHash() {
        // The hash should be 20 bytes
        let result = mysqlNativePassword(password: "secret",
                                         challenge: Array("12345678901234567890".utf8))
        XCTAssertEqual(result.count, 20)
    }

    func testMySQLDecode() {
        // TINYINT(1) often used as BOOL
        XCTAssertEqual(mysqlDecode(columnType: 0x01, isUnsigned: false, text: "1"),  .int(1))
        XCTAssertEqual(mysqlDecode(columnType: 0x03, isUnsigned: false, text: "42"), .int32(42))
        XCTAssertEqual(mysqlDecode(columnType: 0x08, isUnsigned: false, text: "999999999"), .int64(999999999))
        XCTAssertEqual(mysqlDecode(columnType: 0x01, isUnsigned: false, text: nil),  .null)
    }
}
