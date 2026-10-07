## 1. Decision record and dependency

- [x] 1.1 Add `docs/adr/0013-use-redis-for-ephemeral-identity-throttling.md`, recording Redis as disposable, non-authoritative, fail-open throttle state alongside ADR-0005's PostgreSQL-only durable state, and add the throttle terms (rate-limit bucket, change cost) to `CONTEXT.md`; verify both documents render and are linked from `docs/adr` conventions.
- [x] 1.2 Add `github.com/gomodule/redigo` as the only new module (design D6) and choose the exact current `redis:8.<minor>.<patch>` image tag for every Compose and Kubernetes file (design D10); verify `go mod tidy` leaves no other new direct dependency and `go build ./...` succeeds.

## 2. Policy model and token-bucket core (`internal/ratelimit`)

- [x] 2.1 Implement the policy model with built-in Route 53 defaults, citing the AWS "Throttling for Amazon Route 53 API requests" page (verified 2026-10-06) in a code comment, plus per-field identity > defaults > built-in resolution into an immutable lookup table; verify with unit tests for precedence, partial overrides, and the `"*"` default operation bucket.
- [x] 2.2 Implement strict policy-document decoding and validation: unknown properties, unknown operation IDs from the embedded contract, unknown change kinds, `patchZone` in `operation_costs`, non-UUIDv4 identity keys, capacity < 1, non-positive refill, and negative or fractional costs are all rejected, and capacities below the largest possible request cost produce warnings; verify with table-driven unit tests.
- [x] 2.3 Implement request cost calculation: one token for each request bucket, PATCH change cost from `rrsets[].changetype` (REPLACE 2, DELETE/EXTEND/PRUNE 1), 0 for out-of-range batches, and policy costs for `createZone` and `deleteZone`; verify with unit tests for mixed batches, empty and 101-RRset batches, and zero-cost reads.
- [x] 2.4 Implement the `Limiter` interface, the capacity pre-check, and the memory backend with an injectable clock; verify with a shared conformance table (refill math, burst exhaustion, weighted cost, batch summation, cost > capacity, all-or-nothing, capacity clamp after reduction, retry-after, expiry-equals-full) that runs without sleeps.
- [x] 2.5 Implement the fail-open decorator and degradation reporter (immediate first warning, at most one warning per 10 s with a suppressed count, a recovery event, reason classes without URLs); verify with unit tests driven by a fake clock and a failing backend.

## 3. Redis backend

- [x] 3.1 Implement the Lua check-and-consume script and Redis backend (hash-tagged keys, `TIME`, clamped elapsed time, `PEXPIRE` = full-refill time + 1 s, `EVALSHA` with `NOSCRIPT` fallback) and the fail-fast redigo pool (per-request deadline bounding the pool wait, connect/read/write timeouts, no retries, broken connections discarded, no startup ping); verify that the unit tests compile and pass without Redis.
- [x] 3.2 Run the conformance table against real Redis under the `integration` build tag via `DANS_TEST_REDIS_URL`, adding concurrent cross-client no-overspend, untouched buckets on throttle, TTL expiry, and timeout/unreachable classification; verify with `go test -tags integration ./internal/ratelimit/...` against a local Redis, with tests skipping when the variable is unset.

## 4. Configuration and startup wiring (`internal/cli`)

- [x] 4.1 Add the `rate_limit_enabled`, `rate_limit_redis_timeout` (1ms..1s) and `rate_limit_policy_file` settings with JSON keys, `DANS_*` variables and flags, plus the `DANS_REDIS_URL` / `redis_url_file` secret through `secret.go`; verify with config tests for defaults, precedence, the range check, enabled-without-URL failing with exit 2, a literal URL rejected, and disabled mode ignoring the Redis and policy settings.
- [x] 4.2 Wire the policy loader, Redis client and limiter into `runtime_server.go` only when enabled, log capacity warnings once at startup, and keep `/readyz` independent of Redis; verify with runtime-server tests showing that an unreachable Redis still reaches readiness and that disabled mode creates no client.
- [x] 4.3 Document every new setting, its default, the policy file format with an example, and the secret sources in `docs/cli.md`; verify that the documented example policy passes the validator in a unit test.

## 5. HTTP middleware and responses (`internal/httpserver`, `internal/httpapi`)

- [x] 5.1 Add the `KindRateLimited` (429, `Rate exceeded`) and `KindRateLimitCapacity` (413, distinct message) error kinds; verify with `httpapi` error tests for status, public message, and detail strings.
- [x] 5.2 Implement the rate-limit middleware between Authentication and Compatibility. It skips anonymous requests, reads and resets the buffered PATCH body, sets `X-DANS-RateLimit-Bucket` and `Retry-After` on 429, sets only the bucket header on 413, and adds nothing on admit or fail-open. Verify with handler tests using the memory backend, covering every response scenario in the `api-rate-limiting` spec.
- [x] 5.3 Add the rate-limit access-log fields (outcome, costs, buckets, latency) to `AccessMetadata`; verify with log tests that throttled, `exceeds_capacity`, admitted and unmetered requests are logged with no URL, credential or body.
- [x] 5.4 Verify that refused requests have no side effects. Application tests must show a throttled PATCH writes no audit intent and sends nothing upstream, and that a throttled non-operator on an operator-only route gets 429 with no denial record. A disabled limiter must leave existing application tests unchanged.
- [x] 5.5 Add a limiter-enabled complete-request benchmark variant using the memory backend, labelled as a stubbed dependency; verify that `make benchmark-check` passes and that `docs/benchmarks.md` documents the variant.
- [x] 5.6 Document the 429 and 413 responses, headers, advisory `Retry-After`, per-identity metering, cost table, and fail-open behaviour in `docs/api.md`; verify that the documented header and body examples match the handler test fixtures.

## 6. Clients

- [x] 6.1 Make the CLI report a rate-limit 429 or 413 as a stderr diagnostic naming the buckets and the `Retry-After` seconds, exit with code 1, and never retry; verify with CLI tests against a stub server, and document it in `docs/cli.md` under output and exit status.
- [x] 6.2 Make the web console show a clear throttle message with the retry wait for 429, and the bucket and capacity for 413, without retrying automatically; verify with frontend tests via `make frontend-test`.

## 7. Development stack

- [x] 7.1 Add the pinned Redis service, with persistence off and no published port, to the root `compose.yaml` on the `control` network, and enable rate limiting for `dans` with local connection defaults; verify that `make up`, `make smoke` and `make smoke-host` pass.
- [x] 7.2 Run the dev-stack, lifecycle and host-smoke suites with rate limiting enabled. Fix any throttling with a dev policy override for the dev operator rather than disabling limiting. Verify the `scripts/*_test.sh` suites and `make dev-contract` pass.
- [x] 7.3 Update the README and developer docs with starting Redis locally, the rate-limit settings and how to run the unit and Redis integration tests; verify the development documentation contract passes.

## 8. Integration gate and deployment examples

- [x] 8.1 Add Redis behind a new toxiproxy proxy in `integration/compose.yaml`, enable rate limiting on `dans-a` and `dans-b` through it, and run the Go Redis integration tests in the CI unit job against a Redis service container via `DANS_TEST_REDIS_URL` (`scripts/integration.sh` drives the stack through the CLI and runs no Go tests); verify that `make integration` starts and tears down Redis without manual setup.
- [x] 8.2 Extend `scripts/integration.sh` to check cross-instance no-overspend, untouched buckets on throttle, the 429 and 413 formats, idle-state expiry, fail-open with warnings and `/readyz` 200 while Redis is disabled and while it is slower than the timeout, and resumed throttling after recovery without restarts; verify the gate passes on both PostgreSQL matrix legs and that summaries stay allowlisted.
- [x] 8.3 Add Redis with `requirepass` and a file-supplied `redis_url_file` to the Docker and Kubernetes deployment examples on the private network only, enabling rate limiting; verify with `scripts/deploy-runtime_test.sh` (including one observed 429 and no client-reachable Redis) and the existing Kubernetes configuration validation.
- [x] 8.4 Note in `docs/operations/runbooks.md` and `docs/operations/coordinated-upgrades.md` that Redis state is disposable (no backup or restore) and add a Redis-outage runbook entry built on the fail-open warning and recovery events; verify that the docs reference the exact log event names.

## 9. Final verification

- [x] 9.1 Run `go test ./...`, `go test -race ./...`, `make generate-check`, the footprint and ready-idle checks (24 MiB executable, 26 MiB image, 64 MiB RSS), `make integration` and `openspec validate add-identity-rate-limiting --strict`; verify everything passes, and record any footprint change in the benchmark evidence.
