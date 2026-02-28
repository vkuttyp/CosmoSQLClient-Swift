/// Errors thrown by sql-nio drivers.
public enum SQLError: Error, Sendable, CustomStringConvertible {
    /// The server returned an application-level error.
    case serverError(code: Int, message: String, state: UInt8 = 0)

    /// A network or I/O level failure.
    case connectionError(String)

    /// TLS / SSL handshake failed.
    case tlsError(String)

    /// Authentication was rejected by the server.
    case authenticationFailed(String)

    /// The server returned data that could not be decoded.
    case protocolError(String)

    /// A value could not be decoded into the requested Swift type.
    case typeMismatch(expected: String, got: String)

    /// A named column was not found in the result row.
    case columnNotFound(String)

    /// The connection was already closed.
    case connectionClosed

    /// An unsupported feature was requested.
    case unsupported(String)

    /// A query or connection operation exceeded its timeout.
    case timeout

    public var description: String {
        switch self {
        case .serverError(let code, let msg, _):
            return "Server error \(code): \(msg)"
        case .connectionError(let msg):
            return "Connection error: \(msg)"
        case .tlsError(let msg):
            return "TLS error: \(msg)"
        case .authenticationFailed(let msg):
            return "Authentication failed: \(msg)"
        case .protocolError(let msg):
            return "Protocol error: \(msg)"
        case .typeMismatch(let expected, let got):
            return "Type mismatch: expected \(expected), got \(got)"
        case .columnNotFound(let name):
            return "Column not found: '\(name)'"
        case .connectionClosed:
            return "Connection is closed"
        case .unsupported(let feature):
            return "Unsupported: \(feature)"
        case .timeout:
            return "Operation timed out"
        }
    }
}
