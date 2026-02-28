import NIOCore
import CosmoSQLCore

// ── TDS NIO Channel Handler ───────────────────────────────────────────────────
//
// Reassembles TDS packets (which may be split across TCP segments or
// span multiple NIO ByteBuffers) and emits complete TDS messages.

final class TDSFramingHandler: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    private var pendingPayload: ByteBuffer?
    private var expectedTotal: Int = 0
    private var isComplete: Bool = false

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // We need at least an 8-byte header
        guard buffer.readableBytes >= TDSPacketHeader.size else { return .needMoreData }

        // Peek at header without consuming
        var peek = buffer
        let header = try TDSPacketHeader.decode(from: &peek)

        let packetLen = Int(header.length)
        guard buffer.readableBytes >= packetLen else { return .needMoreData }

        // Consume the full packet
        var packet = buffer.readSlice(length: packetLen)!
        packet.moveReaderIndex(forwardBy: TDSPacketHeader.size)   // skip header

        if pendingPayload == nil {
            pendingPayload = context.channel.allocator.buffer(capacity: packetLen)
        }
        pendingPayload!.writeBuffer(&packet)

        if header.status == .eom {
            let msg = pendingPayload!
            pendingPayload = nil
            context.fireChannelRead(wrapInboundOut(msg))
        }

        return .continue
    }

    func decodeLast(context: ChannelHandlerContext,
                    buffer: inout ByteBuffer,
                    seenEOF: Bool) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}

// MARK: - TDS Packet Encoder

final class TDSPacketEncoder: MessageToByteEncoder {
    typealias OutboundIn = (TDSPacketType, ByteBuffer)

    private var packetID: UInt8 = 1
    private let maxPacketSize: Int

    init(maxPacketSize: Int = 4096) {
        self.maxPacketSize = maxPacketSize
    }

    func encode(data: (TDSPacketType, ByteBuffer), out: inout ByteBuffer) throws {
        var payload = data.1
        let type    = data.0
        let payloadSize = payload.readableBytes
        let maxBody = maxPacketSize - TDSPacketHeader.size

        var offset = 0
        while offset < payloadSize {
            let chunkLen = min(maxBody, payloadSize - offset)
            let isLast   = (offset + chunkLen) >= payloadSize
            let totalLen = UInt16(chunkLen + TDSPacketHeader.size)

            let header = TDSPacketHeader(
                type: type,
                status: isLast ? .eom : .normal,
                length: totalLen,
                packetID: packetID
            )
            header.encode(into: &out)
            out.writeBytes(payload.readBytes(length: chunkLen)!)
            packetID = packetID == 255 ? 1 : packetID + 1
            offset += chunkLen
        }
    }
}
