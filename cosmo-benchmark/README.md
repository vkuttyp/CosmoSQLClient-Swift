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
