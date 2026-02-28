// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cosmo-benchmark",
    platforms: [.macOS(.v13)],
    dependencies: [
        // CosmoSQLClient (NIO-based — this repo)
        .package(path: ".."),
        // SQLClient-Swift (FreeTDS-based)
        .package(url: "https://github.com/vkuttyp/SQLClient-Swift.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "cosmo-benchmark",
            dependencies: [
                .product(name: "CosmoMSSQL",     package: "sql-nio"),
                .product(name: "CosmoSQLCore",   package: "sql-nio"),
                .product(name: "SQLClientSwift",  package: "SQLClient-Swift"),
            ]
        ),
    ]
)
