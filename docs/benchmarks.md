# Benchmarks

The suite measures shared request paths before optimization. Benchmark names
identify isolated Go work, stubbed application dependencies, real PostgreSQL,
and loopback HTTP. These are synthetic workloads, not production capacity tests.

## Correctness smokes

```sh
GOTOOLCHAIN=go1.26.5 make benchmark-check
GOTOOLCHAIN=go1.26.5 make benchmark-postgres-check
```

The second command requires the repository's test-database environment variable
to reference a disposable supported PostgreSQL instance. Configure it privately;
do not put connection strings in evidence. Each leaf sample creates and removes
its own schema. Integration benchmark files use the `integration` build tag.
The smoke entry point fails if the database is not configured.

Both targets run one iteration with assertions and allocation reporting. CI
does not enforce timing or allocation limits. A one-iteration mixed-traffic
smoke can contain only reads; the separate write case always exercises writes.

## Repeated measurements

Use one otherwise idle machine, the same toolchain, dependency versions, CPU
setting, and benchmark selectors for both revisions. Run groups sequentially.
The examples fix `GOMAXPROCS` at four via `-cpu=4`; record a different value if
you choose one. Keep raw output in private storage, outside the repository.

Run from the repository root and allocate private output storage first:

```sh
BENCHMARK_OUTPUT_DIR="$(mktemp -d)"
```

Portable duration-based cases repeat the whole suite so TCP close states can
expire between connection-churn samples:

```sh
for sample in 1 2 3 4 5 6 7 8 9 10; do
  GOTOOLCHAIN=go1.26.5 go test -p=1 ./internal/identifier ./internal/dnsname ./internal/httpapi ./internal/httpserver ./internal/upstream \
    -run '^$' -bench '^Benchmark' -benchmem -benchtime=3s -count=1 -cpu=4 || exit
done > "$BENCHMARK_OUTPUT_DIR/portable-before.txt"
```

The delayed deletion retry closes an unread body and normally opens one TCP
connection per operation. Consecutive samples can exhaust local ephemeral
ports. For an isolated comparison, run one three-second sample at a time with
enough untimed cooldown for the platform's TCP close states to expire. Record
and reuse that cooldown; the initial evidence uses 35 seconds. Discard samples
with transport errors and retain the expected deletion-outcome assertion.

Database and complete-request read-only cases:

```sh
GOTOOLCHAIN=go1.26.5 go test -p=1 -tags=integration ./internal/database ./internal/httpserver \
  -run '^$' -bench '^Benchmark(AuthorizeRRsetBatch|AuthenticatePostgres|RuntimeCompatibilityPostgres|AuthorizationGrants|ApplicationPostgresRead|ApplicationPostgresParallelRead)$' \
  -benchmem -benchtime=3s -count=10 -cpu=4 > "$BENCHMARK_OUTPUT_DIR/postgres-read-before.txt"
```

Durable writes use fixed work, including authorization denial and mixed traffic.
First pilot the command below with `-count=1`. Choose enough iterations for a
stable sample, record the pilot durations, then keep that count identical across
the ten samples and both revisions. `2000x` is a starting point, not a workload
size derived from the benchmark runner. Every sample begins with the same empty
audit ledger; real commits are timed and cleanup is excluded.

```sh
GOTOOLCHAIN=go1.26.5 go test -p=1 -tags=integration ./internal/database ./internal/httpserver \
  -run '^$' -bench '^Benchmark(AuthorizationDeniedWrite|DNSAuditWrite|ApplicationPostgresWrite|ApplicationPostgresParallelWrite)$' \
  -benchmem -benchtime=2000x -count=10 -cpu=4 > "$BENCHMARK_OUTPUT_DIR/postgres-write-before.txt"
```

Report `initial-rows`, `final-rows`, and the chosen iteration count. A successful
mutation adds two linked audit events; a denial adds one. Pure reads add none.
For mixed traffic, each worker repeats nine reads then one write. Incomplete
worker sequences can change the observed ratio slightly. Check reported `reads`
and `writes`: use a larger fixed count if write shares differ by more than
0.5 percentage points between samples or revisions, or fall outside 9.5–10.5%.
This comparability rule applies to evidence, not tiny correctness smokes.

Repeat each command into a corresponding `*-after.txt` on the comparison
revision. Use a fixed benchstat version:

```sh
go run golang.org/x/perf/cmd/benchstat@v0.0.0-20260615155930-9e4b9ddef5b6 "$BENCHMARK_OUTPUT_DIR/portable-before.txt" "$BENCHMARK_OUTPUT_DIR/portable-after.txt"
go run golang.org/x/perf/cmd/benchstat@v0.0.0-20260615155930-9e4b9ddef5b6 "$BENCHMARK_OUTPUT_DIR/postgres-read-before.txt" "$BENCHMARK_OUTPUT_DIR/postgres-read-after.txt"
go run golang.org/x/perf/cmd/benchstat@v0.0.0-20260615155930-9e4b9ddef5b6 "$BENCHMARK_OUTPUT_DIR/postgres-write-before.txt" "$BENCHMARK_OUTPUT_DIR/postgres-write-after.txt"
```

Inspect the medians, confidence intervals, and variation. A single run is not
evidence of improvement. Without a code optimization, capture a baseline and
its variation rather than inventing an A/B speedup. Historical measurements
under different conditions are not interchangeable with a fresh baseline.
Inspect failure diagnostics as well as exit status: every selected leaf must
have ten successful measurement rows before its evidence is accepted.

## Workloads and interpretation

| Group | Inputs and boundary |
| --- | --- |
| Token and DNS | Existing token cases and 1/100-owner batches; Unicode, escaped, and legal long-name variants |
| Strict JSON | 1/100 RRsets, 32 records per RRset, late duplicate/unknown fields |
| Contract | GET; 1/10/100 RRsets; roughly 960 KiB body; invalid suffix fields; terminal-handler count verified |
| Stubbed application | Production middleware/router with stub database dependencies; GET, 1/10/100-RRset PATCH, and partial denial |
| Stubbed rate-limited application | The stubbed application with the rate-limit middleware enabled; GET and 1/100-RRset PATCH. The limiter uses the in-memory backend (a stubbed dependency) with unreachable limits, so results show middleware and cost-calculation overhead only, never a Redis round trip or deployed throttling capacity |
| PostgreSQL checks | Valid/unknown/revoked/expired credentials and healthy runtime compatibility |
| Authorization | 1/100 tuples; 1/100/1000 grants with nonmatching candidates; group, exact, and 100 overlapping grants; partial/full denial |
| Audit | Real intent/outcome commits with 1/100 RRsets and success/failure outcomes; event links and counts verified |
| Relay/loopback | 1 KiB/64 KiB/1 MiB bodies; success/error and filtered-header cases; warm connections and full response bytes verified |
| PostgreSQL application | Real authentication, compatibility, authorization, and persistence; controlled loopback upstream |
| Concurrent application | Read, write, and synthetic 9:1 traffic; worker-local state, 16 total pool connections (4 authentication, 1 readiness, 11 requests), request limit 32, five-second request/statement bounds |

Serial cases use `b.Loop`; parallel cases use `RunParallel` with setup excluded
by timer reset. The parallel runner defaults to one worker per `GOMAXPROCS`.
Its `ns/op` measures aggregate throughput, not a request latency percentile.

Complete requests include request cloning/body reset, random request IDs, and
log encoding to `io.Discard`, excluding deployment-specific logging I/O. The
portable mutation stub retains only its last intent/outcome. Response buffers
retain at most one fixture response. Timed response assertions include byte
comparison costs; the isolated relay reader deliberately hides `WriteTo` so a
memory-reader shortcut cannot replace the streaming path.

Loopback client and server work shares the measured Go process, so both appear
in CPU/allocation results. PostgreSQL server CPU and memory are separate. Pure
database cases use one connection; complete requests use the production pool
configuration. Shared fixture helpers are integration-tagged and imported only
by test files. Pool connections are checked for release, and test cleanup closes
pools and loopback servers (including their peer connections).
The upstream transport permits 20 connections per host and 20 idle connections.
New loopback/application fixtures use a five-second client timeout; the retained
deletion fixture uses one second.

Complete PostgreSQL requests warm both authentication/request stores and one
upstream read before timing. Parallel samples include any additional lazy pool
and upstream connection creation required by their workers; keep that warmup
policy identical when comparing revisions.

## Profiling and race checks

Profile one selected case in a separate run, outside comparison evidence:

```sh
GOTOOLCHAIN=go1.26.5 go test ./internal/httpserver -run '^$' \
  -bench '^BenchmarkApplicationStubbed$/^Patch100$' -benchtime=5s -cpu=4 \
  -cpuprofile "$BENCHMARK_OUTPUT_DIR/cpu.out" -memprofile "$BENCHMARK_OUTPUT_DIR/alloc.out" -o "$BENCHMARK_OUTPUT_DIR/httpserver-profile.test"
go tool pprof -top "$BENCHMARK_OUTPUT_DIR/cpu.out"
go tool pprof -top -alloc_space "$BENCHMARK_OUTPUT_DIR/alloc.out"
```

Keep generated profiles and test binaries in private storage. Database-heavy
results also need database-side query analysis to attribute server execution
cost; Go CPU profiles alone cannot explain it.

Run correctness and races independently of performance measurements:

```sh
GOTOOLCHAIN=go1.26.5 go test -tags=integration ./internal/database ./internal/httpserver ./internal/upstream ./internal/httpapi ./internal/dnsname ./internal/identifier
GOTOOLCHAIN=go1.26.5 go test -race -tags=integration ./internal/httpserver \
  -run '^TestBenchmark' -bench '^BenchmarkApplicationPostgresParallel' -benchtime=100x -cpu=4
```

Preserve the original raw output privately. Before adding evidence to a
repository or sharing it, remove private identifiers, connection details,
module-identifying headers, and diagnostic machine paths. Label redactions and
hash the actual shared bytes. Record source identity, actual Go and benchstat
versions, platform, database version, commands, sample counts, fixture sizes,
and concurrency limits with sanitized descriptions.
