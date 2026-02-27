import XCTest
import NIOCore
import NIOEmbedded
@testable import MSSQLNio

final class TDSPacketTests: XCTestCase {

    func testHeaderRoundtrip() throws {
        var allocator = ByteBufferAllocator()
        var buf = allocator.buffer(capacity: 8)

        let original = TDSPacketHeader(type: .sqlBatch, status: .eom,
                                       length: 4096, spid: 0, packetID: 1)
        original.encode(into: &buf)
        XCTAssertEqual(buf.readableBytes, 8)

        let decoded = try TDSPacketHeader.decode(from: &buf)
        XCTAssertEqual(decoded.type,     .sqlBatch)
        XCTAssertEqual(decoded.status,   .eom)
        XCTAssertEqual(decoded.length,   4096)
        XCTAssertEqual(decoded.packetID, 1)
    }

    func testPreLoginEncoding() {
        let allocator = ByteBufferAllocator()
        let req = TDSPreLoginRequest(encryption: .on)
        let buf = req.encode(allocator: allocator)
        // Must start with option 0x00 (VERSION)
        let bytes = buf.getBytes(at: buf.readerIndex, length: 1)!
        XCTAssertEqual(bytes[0], 0x00)
    }

    func testTDSPacketEncoder() throws {
        // Test that a payload larger than maxPacketSize is split
        let allocator = ByteBufferAllocator()
        let encoder = TDSPacketEncoder(maxPacketSize: 16)   // tiny for testing
        var payload = allocator.buffer(capacity: 20)
        payload.writeBytes([UInt8](repeating: 0xAA, count: 20))

        var out = allocator.buffer(capacity: 64)
        try encoder.encode(data: (.sqlBatch, payload), out: &out)

        // 20-byte payload, max body = 16 - 8 = 8 bytes → 3 packets: 16+16+12 = 44
        XCTAssertEqual(out.readableBytes, 44)
    }
}

final class TDSDecoderTests: XCTestCase {

    func testDecodeColMetadata() throws {
        // Build a minimal COLMETADATA token
        var buf = ByteBufferAllocator().buffer(capacity: 64)
        buf.writeInteger(UInt8(0x81))        // COLMETADATA token
        buf.writeInteger(UInt16(1), endianness: .little)  // 1 column
        buf.writeInteger(UInt32(0), endianness: .little)  // userType
        buf.writeInteger(UInt16(0), endianness: .little)  // flags
        buf.writeInteger(UInt8(0x26))        // intN type
        buf.writeInteger(UInt8(4))           // maxLen = 4 (int32)
        // B_VARCHAR name: "id" (1 char count + UTF-16LE)
        buf.writeInteger(UInt8(2))           // 2 chars
        buf.writeInteger(UInt8(ascii: "i")); buf.writeInteger(UInt8(0))
        buf.writeInteger(UInt8(ascii: "d")); buf.writeInteger(UInt8(0))
        // DONE token
        buf.writeInteger(UInt8(0xFD))        // DONE
        buf.writeInteger(UInt16(0x10), endianness: .little)  // status = count
        buf.writeInteger(UInt16(0), endianness: .little)     // curCmd
        buf.writeInteger(UInt64(0), endianness: .little)     // rowCount

        var dec = TDSTokenDecoder()
        try dec.decode(buffer: &buf)
        XCTAssertEqual(dec.columns.count, 1)
        XCTAssertEqual(dec.columns[0].name, "id")
    }
}
