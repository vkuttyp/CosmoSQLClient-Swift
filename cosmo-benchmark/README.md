# CosmoSQLClient Benchmarks

Compares **CosmoSQLClient (Swift NIO)** against:
- **SQLClient-Swift (FreeTDS)** — for MSSQL Server
- **postgres-nio (Vapor)** — for PostgreSQL
- **mysql-nio (Vapor)** — for MySQL

## Prerequisites

FreeTDS must be installed for the FreeTDS driver:

```bash
# macOS
brew install freetds

# Ubuntu/Debian
sudo apt install freetds-dev
```

## Run

```bash
cd cosmo-benchmark

# MSSQL only (FreeTDS comparison)
BENCH_HOST=localhost BENCH_PASS=secret BENCH_DB=MyDB \
BENCH_USER=sa BENCH_ITER=20 \
PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig \
swift run -c release

# All three databases
BENCH_HOST=localhost BENCH_PASS=secret \
PG_HOST=localhost PG_USER=pguser PG_PASS=secret PG_DB=MyPgDb PG_QUERY="SELECT * FROM employees" \
MYSQL_HOST=localhost MYSQL_USER=mysqluser MYSQL_PASS=secret MYSQL_DB=MyMySQLDb MYSQL_QUERY="SELECT * FROM employees" \
PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig \
swift run -c release
```

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `BENCH_HOST` | `localhost` | MSSQL host |
| `BENCH_PORT` | `1433` | MSSQL port |
| `BENCH_DB` | `MurshiDb` | MSSQL database |
| `BENCH_USER` | `sa` | MSSQL user |
| `BENCH_PASS` | *(required)* | MSSQL password |
| `BENCH_QUERY` | `SELECT * FROM Accounts` | MSSQL query |
| `PG_HOST` | `BENCH_HOST` | Postgres host |
| `PG_PORT` | `5432` | Postgres port |
| `PG_DB` | `MurshiDb` | Postgres database |
| `PG_USER` | `pguser` | Postgres user |
| `PG_PASS` | *(required)* | Postgres password |
| `PG_QUERY` | `SELECT * FROM accounts` | Postgres query |
| `MYSQL_HOST` | `BENCH_HOST` | MySQL host |
| `MYSQL_PORT` | `3306` | MySQL port |
| `MYSQL_DB` | `MurshiDb` | MySQL database |
| `MYSQL_USER` | `mysqluser` | MySQL user |
| `MYSQL_PASS` | *(required)* | MySQL password |
| `MYSQL_QUERY` | `SELECT * FROM accounts` | MySQL query |
| `BENCH_ITER` | `20` | Iterations per scenario |

## Latest Results

> Environment: macOS, Apple Silicon M-series, frpc tunnel to remote servers  
> 20 iterations per scenario

### MSSQL — CosmoSQL (NIO) vs SQLClient-Swift (FreeTDS)

> Table: `Accounts` (46 rows × 20 columns)

| Scenario | CosmoSQL | FreeTDS | Winner |
|---|---|---|---|
| Cold connect + query + close | 14.61 ms | 13.65 ms | ~tie |
| Warm full-table query | **0.91 ms** | 1.56 ms | 🔵 **42% faster** |
| Warm single-row query | **0.56 ms** | 1.11 ms | 🔵 **49% faster** |
| Warm `decode<T>()` | 1.64 ms | N/A | 🔵 only |
| Warm `toJson()` | 1.55 ms | N/A | 🔵 only |

### PostgreSQL — CosmoSQL (NIO) vs postgres-nio (Vapor)

> Table: `employees` (20 rows × 6 columns)

| Scenario | CosmoSQL | postgres-nio | Winner |
|---|---|---|---|
| Cold connect + query + close | 23.96 ms | **4.98 ms** | 🟣 79% faster |
| Warm full-table query | 0.39 ms | **0.35 ms** | ~tie |
| Warm single-row query | 0.39 ms | **0.30 ms** | ~tie |
| Warm `decode<T>()` | 0.31 ms | N/A | 🔵 only |
| Warm `toJson()` | 0.38 ms | N/A | 🔵 only |

> **Note:** CosmoSQL cold connect is slower due to TLS negotiation overhead — a connection pool eliminates this gap for real workloads.

### MySQL — CosmoSQL (NIO) vs mysql-nio (Vapor)

> Table: `employees` (20 rows × 6 columns)

| Scenario | CosmoSQL | mysql-nio | Winner |
|---|---|---|---|
| Cold connect + query + close | 8.60 ms | **4.90 ms** | 🟢 43% faster |
| Warm full-table query | **0.37 ms** | 0.48 ms | 🔵 **22% faster** |
| Warm single-row query | 0.73 ms | **0.27 ms** | ~varies |
| Warm `decode<T>()` | 0.36 ms | N/A | 🔵 only |
| Warm `toJson()` | 0.44 ms | N/A | 🔵 only |

## Notes

- Cold connect differences are dominated by TLS handshake time — use connection pooling (`CosmoMSSQL`, `CosmoPostgres`, `CosmoMySQL` all include built-in pools)
- Warm query benchmarks reflect steady-state throughput on a persistent connection
- FreeTDS benchmarks are skipped if FreeTDS is not installed (graceful degradation)
- postgres-nio and mysql-nio warm comparisons exclude `decode<T>()` / `toJson()` as those are CosmoSQL-only features
- Use `BENCH_ITER=50` or higher for more stable averages
