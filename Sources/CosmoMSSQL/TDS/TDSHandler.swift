import NIOCore
import CosmoSQLCore

// ── TDS NIO Channel Handler ───────────────────────────────────────────────────
//
// Emits one TDSFrame per TDS packet so consumers can process rows incrementally
// without waiting for the entire EOM-terminated message to arrive.

/// A single TDS packet payload emitted by TDSFramingHandler.
struct TDSFrame: @unchecked Sendable {
    var payload: ByteBuffer
    var isEOM:   Bool   // true if this is the last packet of the TDS message
}

final class TDSFramingHandler: ByteToMessageDecoder {
    typealias InboundOut = TDSFrame

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes >= TDSPacketHeader.size else { return .needMoreData }
        var peek = buffer
        let header = try TDSPacketHeader.decode(from: &peek)
        let packetLen = Int(header.length)
        guard buffer.readableBytes >= packetLen else { return .needMoreData }
        var packet = buffer.readSlice(length: packetLen)!
        packet.moveReaderIndex(forwardBy: TDSPacketHeader.size)   // strip 8-byte header
        context.fireChannelRead(wrapInboundOut(TDSFrame(payload: packet, isEOM: header.status == .eom)))
        return .continue
    }

    func decodeLast(context: ChannelHandlerContext,
                    buffer: inout ByteBuffer,
                    seenEOF: Bool) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}

// ── TDSFrameBridge ────────────────────────────────────────────────────────────
//
// Bridges per-packet TDSFrame values from the NIO pipeline into an
// AsyncThrowingStream for consumption by async Swift callers.

final class TDSFrameBridge: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = TDSFrame

    private let cont: AsyncThrowingStream<TDSFrame, any Error>.Continuation
    let stream: AsyncThrowingStream<TDSFrame, any Error>

    init() {
        var captured: AsyncThrowingStream<TDSFrame, any Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { captured = $0 }
        cont = captured
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        cont.yield(unwrapInboundIn(data))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        cont.finish(throwing: error)
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        cont.finish()
        context.fireChannelInactive()
    }
}

// ── TDSFrameReader ────────────────────────────────────────────────────────────
//
// Wraps AsyncThrowingStream.AsyncIterator (a struct) in a class so it can be
// stored and advanced from async contexts.

final class TDSFrameReader: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<TDSFrame, any Error>.AsyncIterator

    init(_ bridge: TDSFrameBridge) {
        iterator = bridge.stream.makeAsyncIterator()
    }

    func next() async throws -> TDSFrame? {
        try await iterator.next()
    }

    /// Accumulate frames until EOM — used by non-streaming callers.
    func receiveMessage() async throws -> ByteBuffer {
        var accumulated: ByteBuffer? = nil
        while true {
            guard let frame = try await next() else { throw SQLError.connectionClosed }
            if accumulated == nil {
                accumulated = frame.payload
            } else {
                accumulated!.writeImmutableBuffer(frame.payload)
            }
            if frame.isEOM { return accumulated! }
        }
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
