import Foundation
import CosmoMSSQL
import CosmoSQLCore
import SQLClientSwift

// ─────────────────────────────────────────────
// MARK: - Configuration
// ─────────────────────────────────────────────

let host     = ProcessInfo.processInfo.environment["BENCH_HOST"]     ?? ""
let port     = UInt16(ProcessInfo.processInfo.environment["BENCH_PORT"] ?? "1433") ?? 1433
let database = ProcessInfo.processInfo.environment["BENCH_DB"]       ?? "MurshiDb"
let user     = ProcessInfo.processInfo.environment["BENCH_USER"]     ?? "sa"
let password = ProcessInfo.processInfo.environment["BENCH_PASS"]     ?? ""
let query    = ProcessInfo.processInfo.environment["BENCH_QUERY"]    ?? "SELECT * FROM Accounts"
let iterations = Int(ProcessInfo.processInfo.environment["BENCH_ITER"] ?? "20") ?? 20

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
        do { try await block() } catch { print("  ⚠️  \(label) error: \(error)") }
        times.append(Date().timeIntervalSince(t) * 1000)
    }
    let total = times.reduce(0, +)
    return BenchResult(
        label: label,
        iterations: iterations,
        totalMs: total,
        minMs: times.min() ?? 0,
        maxMs: times.max() ?? 0
    )
}

func printResult(_ r: BenchResult) {
    print(String(format: "  %-48s  avg %7.2f ms  min %7.2f ms  max %7.2f ms  (%d runs)",
        (r.label as NSString).utf8String!, r.avgMs, r.minMs, r.maxMs, r.iterations))
}

func printHeader(_ title: String) {
    print("\n" + String(repeating: "─", count: 90))
    print("  \(title)")
    print(String(repeating: "─", count: 90))
}

// ─────────────────────────────────────────────
// MARK: - CosmoSQLClient (NIO) benchmarks
// ─────────────────────────────────────────────

func benchCosmo() async {
    printHeader("🔵  CosmoSQLClient (NIO-based, pure Swift)")

    let connStr = "Server=\(host),\(port);Database=\(database);User Id=\(user);Password=\(password);Encrypt=true;TrustServerCertificate=true"

    // 1. Cold: connect + query + close (per iteration)
    let cold = await measure(label: "Cold  connect + query + close", iterations: iterations) {
        let conn = try await MSSQLConnection.connect(
            configuration: .init(connectionString: connStr))
        defer { Task { try? await conn.close() } }
        _ = try await conn.query(query, [])
    }
    printResult(cold)

    // 2. Warm: persistent connection, query only
    let conn = try? await MSSQLConnection.connect(
        configuration: .init(connectionString: connStr))
    if let conn {
        let warm = await measure(label: "Warm  query only (persistent conn)", iterations: iterations) {
            _ = try await conn.query(query, [])
        }
        printResult(warm)

        // 3. Warm: single row
        let warmSingle = await measure(label: "Warm  single-row query", iterations: iterations) {
            _ = try await conn.query("SELECT TOP 1 * FROM Accounts", [])
        }
        printResult(warmSingle)

        // 4. Warm: decode into typed list
        let warmDecode = await measure(label: "Warm  query + decode<Account>()", iterations: iterations) {
            let rows = try await conn.query(query, [])
            _ = try rows.asDataTable().decode(as: Account.self)
        }
        printResult(warmDecode)

        // 5. Warm: toJson
        let warmJson = await measure(label: "Warm  query + toJson()", iterations: iterations) {
            let rows = try await conn.query(query, [])
            _ = rows.asDataTable().toJson()
        }
        printResult(warmJson)

        try? await conn.close()
    } else {
        print("  ⚠️  Could not connect — skipping warm benchmarks")
    }
}

// ─────────────────────────────────────────────
// MARK: - SQLClient-Swift (FreeTDS) benchmarks
// ─────────────────────────────────────────────

func benchFreeTDS() async {
    printHeader("🟠  SQLClient-Swift (FreeTDS-based)")

    var options = SQLClientConnectionOptions(
        server:   host,
        username: user,
        password: password,
        database: database
    )
    options.port = port

    // 1. Cold: connect + query + disconnect
    let cold = await measure(label: "Cold  connect + query + disconnect", iterations: iterations) {
        let client = SQLClient()
        try await client.connect(options: options)
        _ = try await client.execute(query)
        await client.disconnect()
    }
    printResult(cold)

    // 2. Warm: persistent connection
    let client = SQLClient()
    let connected = (try? await client.connect(options: options)) != nil
    if connected {
        let warm = await measure(label: "Warm  query only (persistent conn)", iterations: iterations) {
            _ = try await client.execute(query)
        }
        printResult(warm)

        let warmSingle = await measure(label: "Warm  single-row query", iterations: iterations) {
            _ = try await client.execute("SELECT TOP 1 * FROM Accounts")
        }
        printResult(warmSingle)

        await client.disconnect()
    } else {
        print("  ⚠️  FreeTDS not available or could not connect — is freetds installed?")
        print("       brew install freetds   (macOS)")
        print("       apt install freetds-dev (Linux)")
    }
}

// ─────────────────────────────────────────────
// MARK: - Decodable model
// ─────────────────────────────────────────────

struct Account: Decodable {
    let AccountNo:   String?
    let AccountName: String?
}

// ─────────────────────────────────────────────
// MARK: - Summary table
// ─────────────────────────────────────────────

func printSummary(_ cosmo: [BenchResult], _ freetds: [BenchResult]) {
    printHeader("📊  Summary — avg ms per operation  (lower is better)")
    print(String(format: "  %-40s  %12s  %12s  %10s",
        "Scenario", "CosmoSQL(NIO)", "FreeTDS", "Winner"))
    print("  " + String(repeating: "-", count: 80))

    let pairs = zip(cosmo, freetds)
    for (c, f) in pairs {
        let winner = c.avgMs < f.avgMs ? "🔵 NIO" : "🟠 FreeTDS"
        let diff = abs(c.avgMs - f.avgMs)
        let pct  = (diff / max(c.avgMs, f.avgMs)) * 100
        print(String(format: "  %-40s  %10.2f ms  %10.2f ms  %@ (%.0f%% faster)",
            c.label.truncated(to: 40), c.avgMs, f.avgMs, winner, pct))
    }
}

extension String {
    func truncated(to length: Int) -> String {
        count > length ? String(prefix(length - 1)) + "…" : self
    }
}

// ─────────────────────────────────────────────
// MARK: - Entry point
// ─────────────────────────────────────────────

print("""
╔══════════════════════════════════════════════════════════════════════════════╗
║       CosmoSQLClient Benchmark — Swift NIO  vs  FreeTDS                     ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  Host: \(host):\(port)  DB: \(database)
║  Query: \(query)
║  Iterations: \(iterations) per scenario
╚══════════════════════════════════════════════════════════════════════════════╝
""")

await benchCosmo()
await benchFreeTDS()

print("\n" + String(repeating: "═", count: 90))
print("  Benchmark complete.")
print(String(repeating: "═", count: 90) + "\n")
