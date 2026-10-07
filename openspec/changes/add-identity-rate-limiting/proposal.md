## Why

DANS has no per-caller throttling: its only overload control is a per-instance concurrent-request cap, so a single runaway identity can saturate PostgreSQL authorization and push unbounded change volume into the shared PowerDNS upstream. A shared, Route 53-style token-bucket limit per identity bounds that load across all API instances without changing authorization semantics.

## What Changes

- Meter every authenticated request against per-identity token buckets, keyed by identity resource ID, shared across API instances through Redis:
  - an identity-level request bucket (default capacity 50, refill 10/s);
  - a per-operation request bucket (default 50/10; zone creation 40/2; zone deletion 40/5);
  - a change-throughput bucket (default 1,500, refill 100/s).
- Charge change throughput per RRset in a zone `PATCH`: `REPLACE` 2, `DELETE`, `EXTEND`, and `PRUNE` 1 each, summed across the batch; zone creation and deletion cost 2; all other operations cost 0. Defaults follow the AWS "Throttling for Amazon Route 53 API requests" page as verified on 2026-10-06.
- Admit a request only when every applicable bucket can pay its cost, consuming from all or none atomically, using Redis server time.
- Throttle after authentication and before compatibility, authorization, audit intent, and forwarding, so a refused request performs no authorization query, writes no audit intent, and sends nothing upstream.
- Return `429 Too Many Requests` in the existing DANS error format with `Retry-After` and an `X-DANS-RateLimit-Bucket` header naming every short bucket. Return `413` without `Retry-After` when a request's cost exceeds a bucket's capacity and can never succeed. Successful and relayed responses gain no rate-limit headers.
- Limit DANS operators like every other identity; extra headroom comes only from per-identity overrides.
- Let operators override capacities, refill rates, per-change-kind costs, and per-operation costs globally or per identity resource ID in static configuration, with precedence identity > global > built-in; validate positive values and capacity >= 1; warn at startup when a change capacity is below the largest possible request cost (200). Rate limiting can be disabled.
- Fail open when Redis is unavailable, errors, or exceeds a short timeout: admit the request unmetered, emit a rate-limited structured warning, and resume limiting automatically once Redis is reachable. Redis never affects `/readyz`, authorization, or audit.
- Report allowed, throttled, `exceeds_capacity`, fail-open, and limiter-latency signals through the existing structured JSON logs; no metrics endpoint is added.
- Add Redis to the development stack, deployment examples, integration gate (including outage and latency injection through test-environment controls), and operator documentation.

### Non-goals

- A deployment-wide change bucket protecting PowerDNS across all identities (possible follow-up).
- Throttling unauthenticated traffic, per-IP limits, or limits per group or API token.
- Remaining-capacity headers on successful responses, or the IETF `RateLimit` draft headers.
- Automatic client retry in the CLI or console.
- A production metrics endpoint or new metrics dependency.
- Runtime-editable limits through the management API.

## Capabilities

### New Capabilities

- `api-rate-limiting`: Per-identity request-rate and change-throughput token buckets, their costs, defaults, override precedence, throttle and over-capacity responses, fail-open behavior, and log-based observability.

### Modified Capabilities

- `multi-instance-runtime`: Allow Redis as an optional, ephemeral, non-authoritative dependency shared by instances; exclude it from readiness and from the fail-closed dependency rule while keeping PostgreSQL the only durable state engine.
- `cli-configuration-qa`: Add rate-limit and Redis settings (with the Redis connection URL handled as a secret), and require the integration gate and development stack to exercise shared limiting and Redis failure across two instances.

## Impact

- Code: new limiter package with a Redis backend (single Lua script) and an in-memory backend for unit tests; middleware inserted in `internal/httpserver/application.go` between authentication and compatibility; PATCH change-cost computation from the already-decoded request; configuration and validation in `internal/cli`.
- API: new DANS-originated `429` and `413` responses on every authenticated operation; documented in `docs/api.md` and the combined contract as applicable. CLI and console surface the message and `Retry-After`.
- Dependencies: one Redis Go client; must keep release executables within the 24 MiB and ready-idle RSS within the 64 MiB budgets.
- Operations: a new Redis service in Compose, Kubernetes examples, and the private network boundary; recovery and upgrade runbooks note that Redis state is disposable and needs no backup.
- Decisions: a new ADR records Redis as ephemeral throttle state and fail-open throttling as a deliberate contrast to fail-closed authorization.
