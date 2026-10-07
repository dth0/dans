## Context

See `proposal.md` for motivation and `specs/` for the required behavior. The current state that shapes the approach:

- `NewApplicationHandler` (`internal/httpserver/application.go`) chains `boundary` → `AccessLog` → contract `validation` → `Authentication` → `Compatibility` → `Authorization` → generated router. The concurrency cap in `boundary` (`DANS_MAX_CONCURRENT_REQUESTS`, default 64) is the only overload control.
- Contract validation already reads a JSON body and replaces it with an in-memory reader, and it stores a `RouteInfo` (template, `OperationID`, access class) in the request context. `Authentication` stores an actor with `IdentityID` and `Operator`.
- `PatchZone` (`internal/httpserver/proxy.go`) re-reads the buffered body, decodes `api.ZonePatch`, and enforces the 1..100 batch size (`database.MaxRRsetBatch`) before delegation authorization and audit intent.
- Configuration (`internal/cli/config.go`) is a flat, strict set of string settings, each bound to a JSON key, a `DANS_*` variable, and a flag. Secrets go through `internal/cli/secret.go`: a dedicated environment variable or a `*_file` setting.
- Errors go through `httpapi.WriteError` with fixed `ErrorKind`s and optional detail strings (the `errors` array). Logs use `log/slog` JSON. Access-log fields live in `AccessMetadata`.
- Integration QA (`scripts/integration.sh`, `integration/compose.yaml`) already runs two DANS instances and uses toxiproxy for upstream fault injection. Go integration tests use the `integration` build tag and skip when their `DANS_TEST_*` URL is unset.
- `go.mod` contains no Redis client and no metrics library. The performance baseline caps release executables at 24 MiB and ready-idle RSS at 64 MiB.

## Goals / Non-Goals

**Goals:**
- Keep the metering path to one Redis round trip per request, bounded by a short timeout.
- Make the token-bucket arithmetic a single, testable definition shared by the Redis and in-memory backends.
- Keep every existing configuration, error, logging, and fault-injection convention.

**Non-Goals:**
- Redis Sentinel or Cluster topology management. Keys are cluster-safe, but deployments supply one endpoint.
- Local or in-process fallback limiting during Redis outages. Fail-open means unmetered.
- Runtime policy reload. Policy changes take effect on restart, like every other setting.

## Decisions

### D1. The limiter middleware runs between Authentication and Compatibility

```
boundary -> AccessLog -> validation -> Authentication -> RateLimit -> Compatibility -> Authorization -> router
```

At this point the identity and the operation ID are both known, and the body has already been buffered. A throttled request has not yet run compatibility checks, written an authorization-denial audit, done delegation lookups, or written an audit intent. When no actor is present (anonymous routes), the middleware passes the request through. When rate limiting is disabled, the middleware is not installed at all, so the request path is unchanged.

*Alternatives:* Putting the limiter after Authorization would protect less, because denial audits and authorization queries would still run for throttled callers. Putting it inside each handler would scatter the logic across handlers and miss operator-only routes.

### D2. Change cost comes from a minimal decode of the buffered PATCH body

For `patchZone`, the middleware decodes only `rrsets[].changetype` from the buffered body and resets the reader for the handler. If the batch is outside 1..100, the change cost is 0, and the handler returns its existing 422. That way an invalid batch never gets a 413. `createZone` and `deleteZone` take their costs from the resolved policy. Every other operation has change cost 0.

*Alternative:* Have the validation middleware publish the decoded patch. Rejected because it would couple contract validation to rate limiting, and the extra partial decode is cheap: the body is at most 100 RRsets and already in memory.

### D3. One Lua script performs the multi-bucket check and consume

Each bucket is a Redis hash `{t: tokens (float), u: last-update µs}`. The keys share a hash tag, so the script is valid on Redis Cluster:

```
dans:rl:{<identity-id>}:req
dans:rl:{<identity-id>}:op:<operationId>
dans:rl:{<identity-id>}:chg          (only when change cost > 0)
```

The script receives `(capacity, refill/s, cost)` for each key. It then:

1. Reads `TIME`.
2. For each bucket: tokens = `min(capacity, stored + max(0, now - u) * refill)`. A missing key counts as full, and a stored value above capacity is clamped, which covers lowered capacities after a restart.
3. If any bucket has fewer tokens than its cost, returns `{throttled, short-bucket indexes, max wait ms}` and writes nothing.
4. Otherwise subtracts the costs, writes `t` and `u` for each bucket, sets `PEXPIRE` to `ceil(capacity / refill)` seconds plus 1 s, and returns `admitted`.

Elapsed time is clamped at 0, so a backwards clock step after a failover never adds tokens. The script runs via `EVALSHA` with an automatic `NOSCRIPT` fallback. It needs a Redis 6.2+ compatible server, because it relies on effects replication of a script that calls `TIME`.

*Alternatives:* `MULTI` with `WATCH` takes several round trips and retries under contention. A key per bucket with integer tokens loses the fractional refill that 0.5/s rates need.

### D4. The capacity check runs in Go, before Redis

Whether any bucket's cost exceeds its capacity is a pure function of the resolved policy. So the middleware returns 413 before contacting Redis, and that answer holds during outages. The Lua script still rejects such a request defensively.

### D5. The limiter sits behind an interface with two backends and one conformance suite

`internal/ratelimit` defines the policy model, cost calculation, and a `Limiter` interface: `Admit(ctx, identity, operation, costs) (Decision, error)`.

- **Memory backend:** takes an injectable clock and implements the same arithmetic. It serves the unit tests and acts as the reference implementation.
- **Redis backend:** wraps the script.
- **`failOpen` decorator:** converts any backend error or a context deadline into `Decision{Outcome: unmetered}` and notifies a degradation reporter.

A shared conformance table covers refill, burst, weighted cost, all-or-nothing, capacity clamp and retry-after. It runs against the memory backend in `go test ./...` and against real Redis under the `integration` tag via `DANS_TEST_REDIS_URL`.

### D6. The Redis client is `github.com/gomodule/redigo`, tuned for fail-fast

- Every request takes a pooled connection with the request's limiter deadline (`rate_limit_redis_timeout`), and the connect, read and write timeouts are set to the same value. Waiting for a free connection is bounded by that deadline too.
- Nothing is retried. A failed connection is discarded, and the pool dials a fresh one on the next request, so metering resumes once Redis is reachable. No background loop is needed, and no ping is done at startup, because readiness must not depend on Redis.
- `redis://` and `rediss://` URLs carry the username, password and database, so ACL users and TLS stay inside the URL secret.

The client counts against the footprint budget. Measured on the release recipe, it adds about 0.2 MB to the Linux executables.

*Alternatives:* `go-redis/v9` was the first choice, but it added about 8 MB to each release executable (amd64 grew from 23.3 MB to 31.5 MB), breaking both the 24 MiB executable and 26 MiB image budgets. The linker keeps its hundreds of command methods even when they're unused, so it can't be trimmed. `rueidis` has the same kind of large command surface. A hand-written RESP client would avoid any dependency, but it would mean owning protocol, pooling and TLS code. redigo's small `Do`-style API keeps the footprint low without that cost.

### D7. Configuration is flat settings plus a separate strict policy document

The flat settings follow the existing pattern: key, `DANS_*` variable, flag, default, and validation in `cli/server.go`.

- `rate_limit_enabled` (default `false`)
- `rate_limit_redis_timeout` (default `25ms`)
- `rate_limit_policy_file`
- The Redis URL secret: `DANS_REDIS_URL` or `redis_url_file`, routed through `secret.go`. `redis://` and `rediss://` are both accepted, so password and TLS stay inside the secret.

The policy file is a strict JSON document. It is decoded with `httpapi.StrictJSON`, validated against the embedded contract's operation IDs, and resolved once at startup into an immutable per-identity lookup table:

```json
{
  "defaults": {
    "requests":   {"capacity": 50, "refill_per_second": 10},
    "operations": {"*": {"capacity": 50, "refill_per_second": 10},
                   "createZone": {"capacity": 40, "refill_per_second": 2}},
    "changes":    {"capacity": 1500, "refill_per_second": 100},
    "change_costs":    {"REPLACE": 2, "DELETE": 1, "EXTEND": 1, "PRUNE": 1},
    "operation_costs": {"createZone": 2, "deleteZone": 2}
  },
  "identities": {
    "<lowercase-uuidv4>": {"changes": {"capacity": 3000}}
  }
}
```

Every field is optional and merges per field: identity, then defaults, then built-in. `"*"` names the default operation bucket.

*Alternative:* A nested object inside the main config file. Rejected because nested maps can't follow the existing per-setting env and flag precedence rule. A separately named file matches the `powerdns_config_file` pattern and mounts cleanly as a Kubernetes ConfigMap.

Disabled is the default so that upgrading an existing deployment adds no required dependency.

### D8. Responses use two new error kinds

- `KindRateLimited` maps to 429 with public message `Rate exceeded`.
- `KindRateLimitCapacity` maps to 413 with its own public message, separate from `body_too_large`.

The middleware sets `X-DANS-RateLimit-Bucket` (a comma-separated list in `requests`, `operation`, `changes` order) and, for 429, `Retry-After` = `max(1, ceil(wait_ms / 1000))`. It does this before calling `httpapi.WriteError` with detail strings such as `bucket: changes`, `cost: 60` and `capacity: 50`. `Cache-Control: no-store` comes from the existing authenticated-response path. The responses are documented in `docs/api.md`. The OpenAPI overlay doesn't declare per-operation DANS gateway errors today, and this change keeps it that way.

### D9. Observability goes into access-log fields and a degradation reporter

`AccessMetadata` gains these fields: `rate_limit` (outcome), `rate_limit_request_cost`, `rate_limit_change_cost`, `rate_limit_buckets`, and `rate_limit_ms`. The degradation reporter works like this:

- On the first fail-open after healthy operation, it logs one `rate_limit.fail_open` warning with a reason class (`timeout`, `connection` or `script`) and no URL.
- During the outage, it logs at most one warning every 10 s, carrying a `suppressed` count.
- On the first metered success afterwards, it logs `rate_limit.recovered` with the total number of unmetered admissions.

Log pipelines can turn these events into dashboards and alerts.

### D10. Deployment and test environments

All Redis services run with persistence off (`--save "" --appendonly no`), because the state is disposable.

- **Development Compose:** a pinned Redis service on the `control` network, no published port, rate limiting enabled with built-in defaults.
- **Integration Compose:** Redis behind a new toxiproxy proxy, so the gate can add latency, disable or re-enable it. Both instances point at the proxy.
- **Docker and Kubernetes deployment examples:** Redis on the private network with `requirepass`. DANS reads `redis_url_file` from a mounted secret.

Every environment pins one exact official Redis 8 image tag (`redis:8.<minor>.<patch>`), following the repository's convention of exact tags such as `postgres:16.14`. Redis 8 is distributed under a choice of licences that includes AGPLv3, the same licence as DANS. It also meets the script's 6.2+ requirement.

*Alternatives:* Redis 7.2 is BSD-licensed but an older line. Valkey 8 is BSD-licensed and protocol-compatible. Both would work with the same script and client, but Redis 8 was chosen.

ADR-0013 records Redis as ephemeral, fail-open throttle state. It doesn't change ADR-0005's statement that PostgreSQL is the only durable state engine.

## Risks / Trade-offs

- **A Redis outage means no throttling.** → This is deliberate. The concurrency cap stays in place as a backstop, and fail-open warnings plus recovery events make the outage visible for alerting. Redis is private, so only someone already inside the boundary could degrade it to trigger the bypass.
- **Added latency on every metered request.** → It's one in-network round trip, capped at 25 ms by default. Complete-request benchmarks gain a limiter-enabled variant using the memory backend, labelled as a stubbed dependency so it isn't read as deployed capacity.
- **Footprint budget.** → The Redis client adds binary size and pooled connections. redigo was chosen over go-redis for this reason (see D6). Tasks run the existing footprint and ready-idle checks.
- **Dev-stack scripts may burst past 50 requests.** → Run the lifecycle and smoke suites with rate limiting enabled. If they throttle, give the dev operator identity a dev policy override rather than disabling limiting.
- **Timing flakiness in integration tests.** → Use small capacities with high refill rates for refill checks, poll with deadlines instead of fixed sleeps, and assert overspend bounds that include elapsed refill.
- **`Retry-After` is advisory.** → Concurrent requests from the same identity can still consume the tokens first. The docs say so.
- **Policy keyed by resource ID goes stale when an identity is recreated.** → That matches the resource-ID convention. Entries for unknown IDs are harmless and simply never match.

## Migration Plan

1. Release with rate limiting disabled by default. Existing deployments see no behavior change and need no Redis.
2. To enable: deploy Redis on the private network, supply `redis_url_file`, optionally add a policy file, set `rate_limit_enabled=true`, then do a coordinated restart following the existing procedure.
3. Rollback: set `rate_limit_enabled=false` and restart. Redis can be removed or flushed at any time without data loss. No schema migration is involved.

