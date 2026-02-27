// swift-tools-version: 5.9
import PackageDescription

// SQLite is provided by the Apple SDK on Darwin; on Linux we need a system library.
#if canImport(Darwin)
let sqliteSystemLibTargets: [Target] = []
let sqliteNioExtraDeps:       [Target.Dependency] = []
let sqliteNioLinkerSettings:  [LinkerSetting] = [.linkedLibrary("sqlite3")]
#else
let sqliteSystemLibTargets: [Target] = [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3",
                   providers: [.apt(["libsqlite3-dev"])]),
]
let sqliteNioExtraDeps:       [Target.Dependency] = [.target(name: "CSQLite")]
let sqliteNioLinkerSettings:  [LinkerSetting] = []
#endif

let package = Package(
    name: "sql-nio",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SQLNioCore",    targets: ["SQLNioCore"]),
        .library(name: "MSSQLNio",      targets: ["MSSQLNio"]),
        .library(name: "PostgresNio",   targets: ["PostgresNio"]),
        .library(name: "MySQLNio",      targets: ["MySQLNio"]),
        .library(name: "SQLiteNio",     targets: ["SQLiteNio"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git",          from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git",      from: "2.25.0"),
        .package(url: "https://github.com/apple/swift-log.git",          from: "1.5.3"),
        .package(url: "https://github.com/apple/swift-crypto.git",       from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin.git",  from: "1.3.0"),
    ],
    targets: [
        // ── Core ─────────────────────────────────────────────────────────────
        .target(
            name: "SQLNioCore",
            dependencies: [
                .product(name: "NIOCore",   package: "swift-nio"),
                .product(name: "Logging",   package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),

        // ── MSSQL (TDS 7.4) ──────────────────────────────────────────────────
        .target(
            name: "MSSQLNio",
            dependencies: [
                .target(name: "SQLNioCore"),
                .product(name: "NIOCore",       package: "swift-nio"),
                .product(name: "NIOTLS",        package: "swift-nio"),
                .product(name: "NIOPosix",      package: "swift-nio"),
                .product(name: "NIOSSL",        package: "swift-nio-ssl"),
                .product(name: "Logging",       package: "swift-log"),
                .product(name: "Crypto",        package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),

        // ── PostgreSQL (wire protocol v3) ────────────────────────────────────
        .target(
            name: "PostgresNio",
            dependencies: [
                .target(name: "SQLNioCore"),
                .product(name: "NIOCore",       package: "swift-nio"),
                .product(name: "NIOPosix",      package: "swift-nio"),
                .product(name: "NIOSSL",        package: "swift-nio-ssl"),
                .product(name: "Logging",       package: "swift-log"),
                .product(name: "Crypto",        package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),

        // ── MySQL (wire protocol v10) ─────────────────────────────────────────
        .target(
            name: "MySQLNio",
            dependencies: [
                .target(name: "SQLNioCore"),
                .product(name: "NIOCore",       package: "swift-nio"),
                .product(name: "NIOPosix",      package: "swift-nio"),
                .product(name: "NIOSSL",        package: "swift-nio-ssl"),
                .product(name: "Logging",       package: "swift-log"),
                .product(name: "Crypto",        package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),

        // ── SQLite (embedded) ─────────────────────────────────────────────────
        .target(
            name: "SQLiteNio",
            dependencies: [
                .target(name: "SQLNioCore"),
                .product(name: "NIOCore",   package: "swift-nio"),
                .product(name: "NIOPosix",  package: "swift-nio"),
                .product(name: "Logging",   package: "swift-log"),
            ] + sqliteNioExtraDeps,
            swiftSettings: swiftSettings,
            linkerSettings: sqliteNioLinkerSettings
        ),

        // ── Tests ─────────────────────────────────────────────────────────────
        .testTarget(
            name: "SQLNioCoreTests",
            dependencies: [
                .target(name: "SQLNioCore"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MSSQLNioTests",
            dependencies: [
                .target(name: "MSSQLNio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PostgresNioTests",
            dependencies: [
                .target(name: "PostgresNio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MySQLNioTests",
            dependencies: [
                .target(name: "MySQLNio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SQLiteNioTests",
            dependencies: [
                .target(name: "SQLiteNio"),
            ],
            swiftSettings: swiftSettings
        ),
    ] + sqliteSystemLibTargets
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("StrictConcurrency"),
] }
