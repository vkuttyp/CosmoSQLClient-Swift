import Foundation
import Logging
import NIOPosix
import CosmoMSSQL
import CosmoPostgres
import CosmoMySQL
import CosmoSQLCore
import SQLClientSwift
import PostgresNIO
import MySQLNIO

// ─────────────────────────────────────────────
// MARK: - Configuration
// ─────────────────────────────────────────────

let env = ProcessInfo.processInfo.environment

// MSSQL
let mssqlHost  = env["BENCH_HOST"]      ?? ""
let mssqlPort  = UInt16(env["BENCH_PORT"] ?? "1433") ?? 1433
let mssqlDb    = env["BENCH_DB"]        ?? "MurshiDb"
let mssqlUser  = env["BENCH_USER"]      ?? "sa"
let mssqlPass  = env["BENCH_PASS"]      ?? ""
let mssqlQuery = env["BENCH_QUERY"]     ?? "SELECT * FROM Accounts"

// Postgres
let pgHost  = env["PG_HOST"]   ?? env["BENCH_HOST"] ?? ""
let pgPort  = Int(env["PG_PORT"]  ?? "5432") ?? 5432
let pgDb    = env["PG_DB"]    ?? "MurshiDb"
let pgUser  = env["PG_USER"]  ?? "pguser"
let pgPass  = env["PG_PASS"]  ?? ""
let pgQuery = env["PG_QUERY"] ?? "SELECT * FROM accounts"

// MySQL
let myHost  = env["MYSQL_HOST"]  ?? env["BENCH_HOST"] ?? ""
let myPort  = Int(env["MYSQL_PORT"]  ?? "3306") ?? 3306
let myDb    = env["MYSQL_DB"]   ?? "MurshiDb"
let myUser  = env["MYSQL_USER"] ?? "mysqluser"
let myPass  = env["MYSQL_PASS"] ?? ""
let myQuery = env["MYSQL_QUERY"] ?? "SELECT * FROM accounts"

let iterations = Int(env["BENCH_ITER"] ?? "20") ?? 20

// Shared logger and event loop group for Vapor drivers
var logger = Logger(label: "cosmo-benchmark")
logger.logLevel = .critical   // suppress Vapor NIO noise during benchmarks
let elg = MultiThreadedEventLoopGroup.singleton

// ─────────────────────────────────────────────
// MARK: - Timing helpers
// ─────────────────────────────────────────────

struct BenchResult {
    let label: String
    let iterations: Int
    let totalMs: Double
    var avgMs: Double { totalMs / Double(iterations) }
    var minMs: Double
    var maxMs: Double
}

func measure(label: String, iterations: Int, block: () async throws -> Void) async -> BenchResult {
    var times: [Double] = []
    for _ in 0..<iterations {
        let t = Date()
        do { try await block() } catch { /* silent — connection errors are printed at setup */ }
        times.append(Date().timeIntervalSince(t) * 1000)
    }
    let total = times.reduce(0, +)
    return BenchResult(label: label, iterations: iterations, totalMs: total,
                       minMs: times.min() ?? 0, maxMs: times.max() ?? 0)
}

func printResult(_ r: BenchResult) {
    print(String(format: "  %-50s  avg %6.2f ms  min %6.2f ms  max %6.2f ms  (%d runs)",
        (r.label as NSString).utf8String!, r.avgMs, r.minMs, r.maxMs, r.iterations))
}

func printHeader(_ title: String) {
    print("\n" + String(repeating: "─", count: 92))
    print("  \(title)")
    print(String(repeating: "─", count: 92))
}

func printSeparator(_ title: String) {
    print("\n" + String(repeating: "═", count: 92))
    print("  \(title)")
    print(String(repeating: "═", count: 92))
}

// ─────────────────────────────────────────────
// MARK: - MSSQL — CosmoSQL vs FreeTDS
// ─────────────────────────────────────────────

func benchMSSQLCosmo() async -> [BenchResult] {
    printHeader("🔵  CosmoSQLClient MSSQL (NIO-based, pure Swift)")
    guard !mssqlHost.isEmpty && !mssqlPass.isEmpty else {
        print("  ⚠️  Skipped — set BENCH_HOST and BENCH_PASS")
        return []
    }
    let connStr = "Server=\(mssqlHost),\(mssqlPort);Database=\(mssqlDb);User Id=\(mssqlUser);Password=\(mssqlPass);Encrypt=true;TrustServerCertificate=true"
    var results: [BenchResult] = []

    results.append(await measure(label: "Cold  connect + query + close", iterations: iterations) {
        let c = try await MSSQLConnection.connect(configuration: .init(connectionString: connStr))
        defer { Task { try? await c.close() } }
        _ = try await c.query(mssqlQuery, [])
    })
    printResult(results.last!)

    if let conn = try? await MSSQLConnection.connect(configuration: .init(connectionString: connStr)) {
        results.append(await measure(label: "Warm  query (full table)", iterations: iterations) {
            _ = try await conn.query(mssqlQuery, [])
        })
        printResult(results.last!)

        results.append(await measure(label: "Warm  single-row query", iterations: iterations) {
            _ = try await conn.query("SELECT TOP 1 * FROM Accounts", [])
        })
        printResult(results.last!)

        results.append(await measure(label: "Warm  query + decode<Account>()", iterations: iterations) {
            let rows = try await conn.query(mssqlQuery, [])
            _ = try rows.asDataTable().decode(as: Account.self)
        })
        printResult(results.last!)

        results.append(await measure(label: "Warm  query + toJson()", iterations: iterations) {
            let rows = try await conn.query(mssqlQuery, [])
            _ = rows.asDataTable().toJson()
        })
        printResult(results.last!)
        try? await conn.close()
    } else { print("  ⚠️  Could not open persistent connection") }

    return results
}

func benchFreeTDS() async -> [BenchResult] {
    printHeader("🟠  SQLClient-Swift (FreeTDS-based)")
    guard !mssqlHost.isEmpty && !mssqlPass.isEmpty else {
        print("  ⚠️  Skipped — set BENCH_HOST and BENCH_PASS")
        return []
    }
    var options = SQLClientConnectionOptions(server: mssqlHost, username: mssqlUser,
                                             password: mssqlPass, database: mssqlDb)
    options.port = mssqlPort
    var results: [BenchResult] = []

    results.append(await measure(label: "Cold  connect + query + disconnect", iterations: iterations) {
        let c = SQLClient()
        try await c.connect(options: options)
        _ = try await c.execute(mssqlQuery)
        await c.disconnect()
    })
    printResult(results.last!)

    let client = SQLClient()
    if (try? await client.connect(options: options)) != nil {
        results.append(await measure(label: "Warm  query (full table)", iterations: iterations) {
            _ = try await client.execute(mssqlQuery)
        })
        printResult(results.last!)

        results.append(await measure(label: "Warm  single-row query", iterations: iterations) {
            _ = try await client.execute("SELECT TOP 1 * FROM Accounts")
        })
        printResult(results.last!)
        await client.disconnect()
    } else {
        print("  ⚠️  FreeTDS unavailable — brew install freetds")
    }
    return results
}

// ─────────────────────────────────────────────
// MARK: - Postgres — CosmoSQL vs postgres-nio
// ─────────────────────────────────────────────

func benchPostgresCosmo() async -> [BenchResult] {
    printHeader("🔵  CosmoSQLClient Postgres (NIO-based, pure Swift)")
    guard !pgHost.isEmpty && !pgPass.isEmpty else {
        print("  ⚠️  Skipped — set PG_HOST and PG_PASS")
        return []
    }
    let config = PostgresConnection.Configuration(
        host: pgHost, port: pgPort, database: pgDb, username: pgUser, password: pgPass, tls: .prefer)
    var results: [BenchResult] = []

    results.append(await measure(label: "Cold  connect + query + close", iterations: iterations) {
        let c = try await PostgresConnection.connect(configuration: config)
        defer { Task { try? await c.close() } }
        _ = try await c.query(pgQuery, [])
    })
    printResult(results.last!)

    if let conn = try? await PostgresConnection.connect(configuration: config) {
        results.append(await measure(label: "Warm  query (full table)", iterations: iterations) {
            _ = try await conn.query(pgQuery, [])
        })
        printResult(results.last!)

        results.append(await measure(label: "Warm  single-row query", iterations: iterations) {
            _ = try await conn.query("SELECT * FROM accounts LIMIT 1", [])
        })
        printResult(results.last!)

        results.append(await measure(label: "Warm  query + decode<PgRow>()", iterations: iterations) {
            let rows = try await conn.query(pgQuery, [])
            _ = try rows.asDataTable().decode(as: PgRow.self)
        })
        printResult(results.last!)

        results.append(await measure(label: "Warm  query + toJson()", iterations: iterations) {
            let rows = try await conn.query(pgQuery, [])
            _ = rows.asDataTable().toJson()
        })
        printResult(results.last!)
        try? await conn.close()
    } else { print("  ⚠️  Could not open persistent connection") }

    return results
}

func benchPostgresNIO() async -> [BenchResult] {
    printHeader("🟣  postgres-nio (Vapor)")
    guard !pgHost.isEmpty && !pgPass.isEmpty else {
        print("  ⚠️  Skipped — set PG_HOST and PG_PASS")
        return []
    }
    let config = PostgresNIO.PostgresConnection.Configuration(
        host: pgHost, port: pgPort,
        username: pgUser, password: pgPass,
        database: pgDb, tls: .disable)
    var results: [BenchResult] = []

    results.append(await measure(label: "Cold  connect + query + close", iterations: iterations) {
        let c = try await PostgresNIO.PostgresConnection.connect(
            configuration: config, id: 0, logger: logger)
        defer { Task { try? await c.close() } }
        let rows = try await c.query(PostgresNIO.PostgresQuery(unsafeSQL: pgQuery), logger: logger)
        for try await _ in rows { }
    })
    printResult(results.last!)

    if let conn = try? await PostgresNIO.PostgresConnection.connect(
        configuration: config, id: 1, logger: logger) {
        results.append(await measure(label: "Warm  query (full table)", iterations: iterations) {
            let rows = try await conn.query(PostgresNIO.PostgresQuery(unsafeSQL: pgQuery), logger: logger)
            for try await _ in rows { }
        })
        printResult(results.last!)

        results.append(await measure(label: "Warm  single-row query", iterations: iterations) {
            let rows = try await conn.query(
                PostgresNIO.PostgresQuery(unsafeSQL: "SELECT * FROM accounts LIMIT 1"), logger: logger)
            for try await _ in rows { }
        })
        printResult(results.last!)
        try? await conn.close()
    } else { print("  ⚠️  Could not open persistent connection") }

    return results
}

// ─────────────────────────────────────────────
// MARK: - MySQL — CosmoSQL vs mysql-nio
// ─────────────────────────────────────────────

func benchMySQLCosmo() async -> [BenchResult] {
    printHeader("🔵  CosmoSQLClient MySQL (NIO-based, pure Swift)")
    guard !myHost.isEmpty && !myPass.isEmpty else {
        print("  ⚠️  Skipped — set MYSQL_HOST and MYSQL_PASS")
        return []
    }
    let config = MySQLConnection.Configuration(
        host: myHost, port: myPort, database: myDb, username: myUser, password: myPass, tls: .prefer)
    var results: [BenchResult] = []

    results.append(await measure(label: "Cold  connect + query + close", iterations: iterations) {
        let c = try await MySQLConnection.connect(configuration: config)
        defer { Task { try? await c.close() } }
        _ = try await c.query(myQuery, [])
    })
    printResult(results.last!)

    if let conn = try? await MySQLConnection.connect(configuration: config) {
        results.append(await measure(label: "Warm  query (full table)", iterations: iterations) {
            _ = try await conn.query(myQuery, [])
        })
        printResult(results.last!)

        results.append(await measure(label: "Warm  single-row query", iterations: iterations) {
            _ = try await conn.query("SELECT * FROM accounts LIMIT 1", [])
        })
        printResult(results.last!)

        results.append(await measure(label: "Warm  query + decode<MyRow>()", iterations: iterations) {
            let rows = try await conn.query(myQuery, [])
            _ = try rows.asDataTable().decode(as: MyRow.self)
        })
        printResult(results.last!)

        results.append(await measure(label: "Warm  query + toJson()", iterations: iterations) {
            let rows = try await conn.query(myQuery, [])
            _ = rows.asDataTable().toJson()
        })
        printResult(results.last!)
        try? await conn.close()
    } else { print("  ⚠️  Could not open persistent connection") }

    return results
}

func benchMySQLNIO() async -> [BenchResult] {
    printHeader("🟢  mysql-nio (Vapor)")
    guard !myHost.isEmpty && !myPass.isEmpty else {
        print("  ⚠️  Skipped — set MYSQL_HOST and MYSQL_PASS")
        return []
    }
    var results: [BenchResult] = []

    results.append(await measure(label: "Cold  connect + query + close", iterations: iterations) {
        let addr = try SocketAddress.makeAddressResolvingHost(myHost, port: myPort)
        let c = try await MySQLNIO.MySQLConnection.connect(
            to: addr, username: myUser, database: myDb,
            password: myPass, tlsConfiguration: nil,
            logger: logger, on: elg.next()).get()
        defer { Task { try? await c.close().get() } }
        let rows = try await c.query(myQuery).get()
        _ = rows.count
    })
    printResult(results.last!)

    let addr = try? SocketAddress.makeAddressResolvingHost(myHost, port: myPort)
    if let addr,
       let conn = try? await MySQLNIO.MySQLConnection.connect(
            to: addr, username: myUser, database: myDb,
            password: myPass, tlsConfiguration: nil,
            logger: logger, on: elg.next()).get() {

        results.append(await measure(label: "Warm  query (full table)", iterations: iterations) {
            let rows = try await conn.query(myQuery).get()
            _ = rows.count
        })
        printResult(results.last!)

        results.append(await measure(label: "Warm  single-row query", iterations: iterations) {
            let rows = try await conn.query("SELECT * FROM accounts LIMIT 1").get()
            _ = rows.count
        })
        printResult(results.last!)
        try? await conn.close().get()
    } else { print("  ⚠️  Could not open persistent connection") }

    return results
}

// ─────────────────────────────────────────────
// MARK: - Summary
// ─────────────────────────────────────────────

func printComparison(title: String, cosmo: [BenchResult], vapor: [BenchResult], vaporLabel: String) {
    guard !cosmo.isEmpty, !vapor.isEmpty else { return }
    printSeparator("📊  \(title)  (lower is better)")
    print(String(format: "  %-42@  %13@  %13@  %@",
        "Scenario" as NSString, "CosmoSQL" as NSString, vaporLabel as NSString, "Winner" as NSString))
    print("  " + String(repeating: "─", count: 85))
    for (c, v) in zip(cosmo, vapor) {
        let cosmoWins = c.avgMs <= v.avgMs
        let winner = cosmoWins ? "🔵 CosmoSQL" : "🟤 \(vaporLabel)"
        let faster = min(c.avgMs, v.avgMs)
        let slower = max(c.avgMs, v.avgMs)
        let pct = slower > 0 ? (slower - faster) / slower * 100 : 0
        print(String(format: "  %-42@  %10.2f ms  %10.2f ms  %@  (%.0f%% faster)",
            c.label.truncated(to: 42) as NSString, c.avgMs, v.avgMs, winner as NSString, pct))
    }
}

extension String {
    func truncated(to length: Int) -> String {
        count > length ? String(prefix(length - 1)) + "…" : self
    }
}

// ─────────────────────────────────────────────
// MARK: - Decodable models
// ─────────────────────────────────────────────

struct Account: Decodable { let AccountNo: String?; let AccountName: String? }
struct PgRow:   Decodable { let id: Int? }
struct MyRow:   Decodable { let id: Int? }

// ─────────────────────────────────────────────
// MARK: - Entry point
// ─────────────────────────────────────────────

print("""
╔══════════════════════════════════════════════════════════════════════════════════════════╗
║       CosmoSQLClient Benchmark                                                           ║
║       MSSQL: CosmoSQL vs FreeTDS  |  Postgres: CosmoSQL vs postgres-nio                 ║
║       MySQL: CosmoSQL vs mysql-nio                                                       ║
╠══════════════════════════════════════════════════════════════════════════════════════════╣
║  Iterations: \(iterations) per scenario
║  MSSQL  → \(mssqlHost):\(mssqlPort)  db=\(mssqlDb)
║  Postgres → \(pgHost):\(pgPort)  db=\(pgDb)
║  MySQL   → \(myHost):\(myPort)  db=\(myDb)
╚══════════════════════════════════════════════════════════════════════════════════════════╝
""")

// ── MSSQL ──
printSeparator("SQL Server")
let mssqlCosmo   = await benchMSSQLCosmo()
let mssqlFreeTDS = await benchFreeTDS()
printComparison(title: "MSSQL  CosmoSQL vs FreeTDS",
                cosmo: mssqlCosmo, vapor: mssqlFreeTDS, vaporLabel: "FreeTDS")

// ── Postgres ──
printSeparator("PostgreSQL")
let pgCosmo = await benchPostgresCosmo()
let pgVapor = await benchPostgresNIO()
printComparison(title: "Postgres  CosmoSQL vs postgres-nio",
                cosmo: pgCosmo, vapor: pgVapor, vaporLabel: "postgres-nio")

// ── MySQL ──
printSeparator("MySQL")
let myCosmo = await benchMySQLCosmo()
let myVapor = await benchMySQLNIO()
printComparison(title: "MySQL  CosmoSQL vs mysql-nio",
                cosmo: myCosmo, vapor: myVapor, vaporLabel: "mysql-nio")

print("\n" + String(repeating: "═", count: 92))
print("  Benchmark complete.")
print(String(repeating: "═", count: 92) + "\n")

