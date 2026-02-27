import NIOCore
import NIOSSL
import NIOTLS

// ── TDS-TLS Framing ───────────────────────────────────────────────────────────
//
// SQL Server negotiates TLS *within* TDS Pre-Login packets (type 0x12) rather
// than using standard TLS-on-TCP.  After the TLS handshake completes, all
// subsequent communication (Login7, SQL Batch …) is sent as ordinary TLS
// records directly – no more TDS wrapping.
//
// TDSTLSFramer sits between the network and the NIOSSLClientHandler:
//
//   Network ↔ TDSTLSFramer ↔ NIOSSLClientHandler ↔ TDSFramingHandler ↔ Bridge
//
// • active == true  (handshake phase):
//     Inbound  – strips the 8-byte TDS Pre-Login header, passes raw TLS record
//     Outbound – prepends 8-byte TDS Pre-Login header to each TLS record
// • active == false (post-handshake):
//     Both directions pass through unchanged.

final class TDSTLSFramer: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn  = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = IOData
    typealias OutboundOut = ByteBuffer

    /// Set to true before adding NIOSSLClientHandler; set back to false when
    /// the TLS handshake completes.
    var active: Bool = false

    // MARK: - Inbound

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard active else {
            context.fireChannelRead(data)
            return
        }
        var buf = unwrapInboundIn(data)
        // The buffer may contain one or more TDS Pre-Login packets.
        // Each packet: [type 1B][status 1B][length 2B big-endian][spid 2B][pid 1B][win 1B] + payload
        while buf.readableBytes >= 8 {
            guard
                let lengthBE: UInt16 = buf.getInteger(at: buf.readerIndex + 2, endianness: .big),
                Int(lengthBE) <= buf.readableBytes,
                Int(lengthBE) >= 8
            else { break }
            let packetLen = Int(lengthBE)
            var packet = buf.readSlice(length: packetLen)!
            packet.moveReaderIndex(forwardBy: 8)      // skip TDS header
            context.fireChannelRead(wrapInboundOut(packet))
        }
    }

    // MARK: - Outbound

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard active else {
            context.write(data, promise: promise)
            return
        }
        var payload: ByteBuffer
        switch unwrapOutboundIn(data) {
        case .byteBuffer(let b): payload = b
        case .fileRegion:        fatalError("FileRegion not supported in TDSTLSFramer")
        }
        let totalLen = UInt16(payload.readableBytes + 8)
        var out = context.channel.allocator.buffer(capacity: Int(totalLen))
        out.writeInteger(UInt8(0x12))              // Pre-Login type
        out.writeInteger(UInt8(0x01))              // status = EOM
        out.writeInteger(totalLen, endianness: .big)
        out.writeInteger(UInt16(0), endianness: .big) // SPID
        out.writeInteger(UInt8(0))                 // packetID
        out.writeInteger(UInt8(0))                 // window
        out.writeBuffer(&payload)
        context.write(NIOAny(IOData.byteBuffer(out)), promise: promise)
    }

    func flush(context: ChannelHandlerContext) {
        context.flush()
    }
}

// ── TLS handshake tracker ────────────────────────────────────────────────────
//
// Sits just above NIOSSLClientHandler and watches for TLSUserEvent.
// When the TLS handshake completes it:
//   1. Switches TDSTLSFramer back to pass-through mode.
//   2. Fulfils the promise so upgradeTLS() can continue.

final class TLSHandshakeTracker: ChannelInboundHandler, RemovableChannelHandler,
                                   @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private weak var framer:  TDSTLSFramer?
    private var promise: EventLoopPromise<Void>?

    init(framer: TDSTLSFramer, promise: EventLoopPromise<Void>) {
        self.framer  = framer
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted = tlsEvent {
            framer?.active = false        // switch framer to pass-through
            promise?.succeed(())
            promise = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if let p = promise {
            p.fail(error)
            promise = nil
        }
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let p = promise {
            p.fail(ChannelError.ioOnClosedChannel)
            promise = nil
        }
        context.fireChannelInactive()
    }
}
