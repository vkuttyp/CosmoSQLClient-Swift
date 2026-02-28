# CosmoSQLClient Benchmarks

Compares **CosmoSQLClient (Swift NIO)** vs **SQLClient-Swift (FreeTDS)** for MSSQL Server.

## Prerequisites

FreeTDS must be installed for the FreeTDS driver to be active:

```bash
# macOS
brew install freetds

# Ubuntu/Debian
sudo apt install freetds-dev
```

## Run

```bash
cd cosmo-benchmark

# defaults: hanan.iserveus.com:1433  MurshiDb  sa  aBCD111
swift run -c release

# custom server
BENCH_HOST=myserver BENCH_PORT=1433 BENCH_DB=MyDB \
BENCH_USER=sa BENCH_PASS=mypass BENCH_ITER=50 \
swift run -c release
```

## Latest Results

> Environment: macOS, Apple Silicon, frpc tunnel → MSSQL Server 2019  
> Table: `Accounts` (46 rows × 20 columns) · 20 iterations per scenario

```
🔵  CosmoSQLClient (NIO-based, pure Swift)
  Cold  connect + query + close      avg  14.30 ms  min  10.84 ms  max  44.55 ms
  Warm  query only (persistent conn) avg   0.95 ms  min   0.74 ms  max   1.23 ms
  Warm  single-row query             avg   0.64 ms  min   0.47 ms  max   1.80 ms
  Warm  query + decode<Account>()    avg   1.53 ms  min   1.25 ms  max   2.36 ms
  Warm  query + toJson()             avg   1.56 ms  min   1.33 ms  max   2.83 ms

🟠  SQLClient-Swift (FreeTDS-based)
  Cold  connect + query + disconnect avg  13.92 ms  min  11.06 ms  max  20.54 ms
  Warm  query only (persistent conn) avg   1.58 ms  min   1.17 ms  max   4.03 ms
  Warm  single-row query             avg   1.10 ms  min   0.91 ms  max   2.41 ms
```

### Head-to-head (warm queries)

| Scenario | CosmoSQL (NIO) | FreeTDS | Winner |
|---|---|---|---|
| Warm full-table query | **0.95 ms** | 1.58 ms | 🔵 **1.7× faster** |
| Warm single-row query | **0.64 ms** | 1.10 ms | 🔵 **1.7× faster** |
| `decode<T>()` (Codable) | 1.53 ms | N/A | 🔵 only |
| `toJson()` | 1.56 ms | N/A | 🔵 only |

## Scenarios

| Scenario | CosmoSQL (NIO) | FreeTDS |
|---|---|---|
| Cold connect + query + close | ✅ | ✅ |
| Warm query only (persistent conn) | ✅ | ✅ |
| Warm single-row query | ✅ | ✅ |
| Warm query + `decode<T>()` / Codable | ✅ | ❌ |
| Warm query + `toJson()` | ✅ | ❌ |

## Notes

- FreeTDS benchmarks are skipped if FreeTDS is not installed (graceful degradation)
- Results include avg / min / max ms per iteration and a winner comparison table
- Use `BENCH_ITER=50` or higher for more stable results
