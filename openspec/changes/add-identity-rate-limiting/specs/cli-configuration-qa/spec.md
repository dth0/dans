## ADDED Requirements

### Requirement: Rate-limit settings are serve-scoped
`serve` SHALL accept `rate_limit_enabled` (default `false`), `rate_limit_redis_timeout` (default `25ms`, from `1ms` to `1s`), and an optional `rate_limit_policy_file`, each with a documented flag and `DANS_*` variable. The Redis connection URL SHALL be a secret from `DANS_REDIS_URL` or `redis_url_file`, required only when rate limiting is enabled.

#### Scenario: Enabled without a backend URL
- **WHEN** `serve` runs with rate limiting enabled and no Redis URL secret
- **THEN** it performs no requested operation and exits with code 2

#### Scenario: Disabled with backend settings present
- **WHEN** `serve` runs with rate limiting disabled and a Redis URL or policy file configured
- **THEN** startup does not read the policy file or connect to Redis

#### Scenario: URL supplied as a literal value
- **WHEN** a Redis URL appears as a JSON configuration value or command flag
- **THEN** the command rejects it as an unapproved secret source and exits with code 2

#### Scenario: Timeout out of range
- **WHEN** `rate_limit_redis_timeout` is below `1ms` or above `1s`
- **THEN** `serve` exits with code 2

### Requirement: Rate-limit policy documents are strict
A rate-limit policy file SHALL be one strict JSON document read once at startup, with global `defaults` and an `identities` map keyed by lowercase UUIDv4 identity resource IDs. DANS MUST reject unknown properties, unknown operation IDs or change kinds, capacities that are not integers of at least 1, refill rates that are not positive, and costs that are not non-negative integers, exiting with code 2.

#### Scenario: Valid policy
- **WHEN** the policy file sets global change capacity and one identity's `createZone` bucket using known fields and positive values
- **THEN** `serve` starts and applies those values by the rate-limit precedence rules

#### Scenario: Invalid policy value
- **WHEN** the policy file sets a capacity of 0, a negative refill rate, an unknown operation ID, or an identity key that is not a lowercase UUIDv4
- **THEN** `serve` performs no requested operation and exits with code 2

#### Scenario: Zone patch uses change-kind costs
- **WHEN** the policy file assigns a flat operation change cost to `patchZone`
- **THEN** `serve` rejects the policy because zone patch cost is defined only by change-kind costs

#### Scenario: Capacity smaller than a possible request
- **WHEN** a resolved change capacity is lower than the largest possible single-request change cost
- **THEN** `serve` starts and logs one warning naming the affected defaults or identity resource ID

### Requirement: The CLI reports throttling without retrying
When the API returns a rate-limit `429` or `413`, the CLI SHALL exit with code 1 and write a stderr diagnostic that names the short buckets and, for `429`, the `Retry-After` seconds. The CLI MUST NOT automatically retry the request.

#### Scenario: Throttled command
- **WHEN** a CLI command receives a `429` with `Retry-After: 3` and bucket `changes`
- **THEN** the CLI writes a diagnostic naming `changes` and 3 seconds to stderr, sends no retry, and exits with code 1

### Requirement: Integration QA verifies shared throttling and fail-open behavior
The required integration gate SHALL run two same-version DANS instances with rate limiting enabled against one Redis backend reached through test-environment fault controls. It MUST verify no overspend under concurrency, untouched buckets on throttle, `429` and `413` formats, idle state expiry, admission and logged warnings while Redis is down or slower than the timeout, and resumed metering after recovery.

#### Scenario: Cross-instance concurrency
- **WHEN** concurrent requests from one identity are spread across both instances
- **THEN** the gate observes admitted costs within each bucket's capacity plus elapsed refill

#### Scenario: Redis outage and recovery
- **WHEN** the gate makes Redis unreachable, then slower than the limiter timeout, then healthy
- **THEN** requests are admitted with fail-open warnings during the faults, `/readyz` stays 200, and throttling resumes after recovery without restarting either instance

#### Scenario: Gate runs without manual setup
- **WHEN** CI runs the integration gate on a fresh runner
- **THEN** Redis is started and torn down by the gate itself with no operator-provided state

### Requirement: The development stack includes the throttle backend
The development stack SHALL start a pinned Redis service on its private network with local connection defaults and rate limiting enabled, without publishing Redis to the host. Development documentation MUST describe starting it, every rate-limit setting and default, the policy file format, and how to run unit and integration tests.

#### Scenario: Developer starts the stack
- **WHEN** a developer runs the documented development start command
- **THEN** DANS starts with rate limiting enabled against the stack's Redis and Redis has no host-published port
