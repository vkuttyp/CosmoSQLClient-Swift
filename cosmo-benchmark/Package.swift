// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cosmo-benchmark",
    platforms: [.macOS(.v13)],
    dependencies: [
        // CosmoSQLClient (NIO-based — this repo)
        .package(path: ".."),
        // SQLClient-Swift (FreeTDS-based, for MSSQL comparison)
        .package(url: "https://github.com/vkuttyp/SQLClient-Swift.git", branch: "main"),
        // Vapor drivers (for Postgres and MySQL comparison)
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git",    from: "1.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "cosmo-benchmark",
            dependencies: [
                .product(name: "CosmoMSSQL",     package: "sql-nio"),
                .product(name: "CosmoPostgres",  package: "sql-nio"),
                .product(name: "CosmoMySQL",     package: "sql-nio"),
                .product(name: "CosmoSQLCore",   package: "sql-nio"),
                .product(name: "SQLClientSwift", package: "SQLClient-Swift"),
                .product(name: "PostgresNIO",    package: "postgres-nio"),
                .product(name: "MySQLNIO",       package: "mysql-nio"),
            ]
        ),
    ]
)
