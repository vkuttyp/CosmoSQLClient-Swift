// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cosmo-swift",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "cosmo-swift",
            dependencies: [
                .product(name: "CosmoMSSQL", package: "sql-nio"),
            ]
        ),
    ]
)
