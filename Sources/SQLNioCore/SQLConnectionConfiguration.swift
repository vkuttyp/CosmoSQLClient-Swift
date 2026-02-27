/// Common configuration shared by all drivers.
public struct SQLConnectionConfiguration: Sendable {
    /// Server hostname or IP address.
    public var host: String
    /// TCP port. Default depends on driver (1433, 5432, 3306).
    public var port: Int
    /// Database / catalog name.
    public var database: String
    /// Login username.
    public var username: String
    /// Login password.
    public var password: String
    /// Enable TLS. Defaults to `true`.
    public var tls: SQLTLSConfiguration

    public init(
        host: String,
        port: Int,
        database: String,
        username: String,
        password: String,
        tls: SQLTLSConfiguration = .prefer
    ) {
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.password = password
        self.tls = tls
    }
}

/// TLS behaviour for a connection.
public enum SQLTLSConfiguration: Sendable {
    /// Always require TLS; abort if the server doesn't support it.
    case require
    /// Use TLS when the server offers it; fall back to plain-text.
    case prefer
    /// Never use TLS (not recommended for production).
    case disable
}
