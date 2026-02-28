/// Minimal @unchecked Sendable bridge for NIO channel handlers that are event-loop-bound.
///
/// NIO marks certain handlers (e.g. `NIOSSLHandler`, `ByteToMessageHandler`) as
/// `@available(*, unavailable) Sendable` because they must remain on their event loop.
/// When Swift 6 strict concurrency requires crossing a concurrency boundary to call
/// `syncOperations` (which itself enforces event-loop execution), this wrapper provides
/// the necessary type-level escape hatch. It is safe as long as the wrapped value is
/// immediately handed to the event loop and never accessed from another isolation domain.
public final class _UnsafeSendable<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}
