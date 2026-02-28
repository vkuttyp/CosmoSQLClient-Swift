import NIOCore

/// A NIO `ChannelInboundHandler` that bridges the event-loop-driven world of NIO
/// into Swift Concurrency via `async/await`.
///
/// Add this handler **after** any framing handler in the pipeline. Incoming
/// (fully-assembled) `ByteBuffer`s are queued until a caller awaits
/// `waitForMessage(on:)`.
///
/// Only one outstanding `waitForMessage` call is allowed at a time.
public final class AsyncChannelBridge: ChannelInboundHandler, RemovableChannelHandler,
                                        @unchecked Sendable {
    public typealias InboundIn = ByteBuffer

    // Accessed only on the channel's EventLoop
    private var queue:  [ByteBuffer] = []
    private var waiter: (CheckedContinuation<ByteBuffer, any Error>)?

    public init() {}

    // MARK: - ChannelInboundHandler

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        if let w = waiter {
            waiter = nil
            w.resume(returning: buf)
        } else {
            queue.append(buf)
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if let w = waiter {
            waiter = nil
            w.resume(throwing: error)
        }
        context.fireErrorCaught(error)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        if let w = waiter {
            waiter = nil
            w.resume(throwing: ChannelError.ioOnClosedChannel)
        }
        context.fireChannelInactive()
    }

    // MARK: - Async API

    /// Wait for the next fully-assembled message from the pipeline.
    ///
    /// - Parameter eventLoop: The channel's event loop; used to serialize queue access.
    public func waitForMessage(on eventLoop: any EventLoop) async throws -> ByteBuffer {
        // Fast path: if we're already on the event loop (e.g., called from channelRead
        // context) and there's buffered data, return synchronously without a thread hop.
        if eventLoop.inEventLoop {
            if !queue.isEmpty {
                return queue.removeFirst()
            }
            // Still on event loop but no data yet — suspend and wait.
            return try await withCheckedThrowingContinuation { cont in
                precondition(self.waiter == nil,
                             "AsyncChannelBridge: only one concurrent waitForMessage is allowed")
                self.waiter = cont
            }
        }
        // Slow path: hop to the event loop to safely read from the queue.
        return try await withCheckedThrowingContinuation { cont in
            eventLoop.execute {
                if !self.queue.isEmpty {
                    cont.resume(returning: self.queue.removeFirst())
                } else {
                    precondition(self.waiter == nil,
                                 "AsyncChannelBridge: only one concurrent waitForMessage is allowed")
                    self.waiter = cont
                }
            }
        }
    }
}
