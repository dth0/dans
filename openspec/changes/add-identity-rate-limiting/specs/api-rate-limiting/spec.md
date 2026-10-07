## Purpose

Bounds the request rate and DNS change throughput each DANS identity can drive through the API, using token buckets shared by every API instance, without changing authorization, audit, or upstream response semantics.

## ADDED Requirements

### Requirement: Authenticated requests are metered per identity
When rate limiting is enabled, DANS SHALL meter every request that establishes an enabled identity against buckets owned by that identity's resource ID. All API tokens and browser sessions of one identity MUST share its buckets, and different identities MUST NOT share buckets. Anonymous routes and requests rejected by contract validation or authentication MUST NOT be metered.

#### Scenario: Two credentials of one identity
- **WHEN** one identity sends requests with two different API tokens
- **THEN** both requests consume from the same identity buckets

#### Scenario: Separate identities
- **WHEN** one identity has exhausted its buckets and a different identity sends a request
- **THEN** the second identity's request is metered only against its own buckets

#### Scenario: Unmetered requests
- **WHEN** a caller requests `/livez` or `/readyz`, sends a contract-invalid request, or presents an invalid credential
- **THEN** DANS returns the existing response for that case and consumes no rate-limit tokens

### Requirement: Operators are metered like other identities
DANS SHALL meter identities with the DANS operator role under the same buckets, defaults, and override rules as every other identity. No role MUST bypass metering; additional headroom SHALL come only from a per-identity override.

#### Scenario: Operator exhausts a bucket
- **WHEN** a DANS operator without an override exceeds the identity-level request bucket
- **THEN** DANS throttles the operator's request exactly as it would for a non-operator

### Requirement: Each request consumes from an identity bucket and an operation bucket
Every metered request SHALL cost one token from the identity-level request bucket and one token from the bucket for its contract operation ID. Built-in defaults (capacity / refill per second) MUST be: identity level 50 / 10; any operation without its own default 50 / 10; `createZone` 40 / 2; `deleteZone` 40 / 5.

#### Scenario: Identity-level burst is exhausted
- **WHEN** an identity with built-in defaults sends 51 metered requests of mixed operations within a period too short for any refill
- **THEN** the first 50 are admitted and the 51st is throttled on the identity-level bucket

#### Scenario: Operation bucket throttles first
- **WHEN** an operator with built-in defaults creates zones faster than 2 per second after a burst of 40
- **THEN** further `createZone` requests are throttled on the operation bucket while the identity can still use other operations that have tokens

### Requirement: DNS changes consume a change-throughput bucket
Each identity SHALL have one change-throughput bucket with a built-in capacity of 1,500 and refill of 100 per second. A zone `PATCH` MUST cost the sum, over its RRsets, of 2 per `REPLACE` and 1 per `DELETE`, `EXTEND`, or `PRUNE`; `createZone` and `deleteZone` MUST cost 2; every other operation MUST cost 0 change tokens.

#### Scenario: Mixed batch cost
- **WHEN** an identity submits a zone `PATCH` with three `REPLACE`, one `DELETE`, and one `EXTEND` RRset
- **THEN** the request costs 8 change tokens in addition to its request-rate tokens

#### Scenario: Read operation
- **WHEN** an identity lists, gets, exports, or searches zones
- **THEN** the request consumes no change tokens

#### Scenario: Unsupported batch size
- **WHEN** a zone `PATCH` contains zero RRsets or more than the supported maximum of 100
- **THEN** the request is charged no change tokens and DANS returns its existing `422 Unprocessable Entity` response for the batch

### Requirement: Admission is all-or-nothing across buckets and instances
DANS SHALL admit a metered request only when every applicable bucket holds at least that bucket's cost, and MUST then consume from all of them; otherwise it MUST consume from none. The check and consumption MUST be atomic across all API instances and MUST use one shared clock, not instance clocks.

#### Scenario: One bucket is short
- **WHEN** a zone `PATCH` has enough request tokens but not enough change tokens
- **THEN** DANS throttles the request and both request buckets keep their previous token counts

#### Scenario: Concurrent requests across instances
- **WHEN** many requests from one identity arrive concurrently at two API instances
- **THEN** the total admitted cost never exceeds each bucket's capacity plus the tokens refilled during the interval

#### Scenario: Instance clocks disagree
- **WHEN** two API instances have different local wall-clock times
- **THEN** refill for a shared bucket is computed identically regardless of which instance handles the request

### Requirement: Buckets refill continuously and idle state is disposable
A bucket SHALL refill continuously at its refill rate, never above its capacity, computed from elapsed time when it is next used. DANS MUST let a bucket's stored state expire no earlier than the time a full refill would take, so an expired bucket behaves exactly like a full one.

#### Scenario: Partial refill
- **WHEN** an identity empties its identity-level bucket and waits one second with built-in defaults
- **THEN** about 10 further requests are admitted before the next throttle

#### Scenario: Idle identity returns
- **WHEN** an identity's bucket state has expired after inactivity
- **THEN** its next request is evaluated against a full bucket

### Requirement: Throttled requests receive 429 with retry guidance
A request refused for insufficient tokens SHALL receive `429 Too Many Requests` in the DANS error format with message `Rate exceeded`, an `X-DANS-RateLimit-Bucket` header listing every short bucket from `requests`, `operation`, and `changes`, and matching `errors` entries. `Retry-After` MUST give whole seconds, at least 1, until every short bucket could pay its cost.

#### Scenario: Change bucket throttles
- **WHEN** a zone `PATCH` is refused only because the change bucket is short
- **THEN** the response is `429` with `X-DANS-RateLimit-Bucket: changes`, an `errors` entry naming `changes`, and `Retry-After` of at least 1

#### Scenario: Several buckets are short
- **WHEN** both the identity-level and operation buckets lack a token
- **THEN** `X-DANS-RateLimit-Bucket` lists both `requests` and `operation`, and `Retry-After` reflects the longer wait

### Requirement: Requests that can never fit are rejected with 413
When a request's cost exceeds the capacity of an applicable bucket, DANS SHALL return `413 Content Too Large` in the DANS error format with an `X-DANS-RateLimit-Bucket` header and `errors` entries naming the bucket, the cost, and the capacity. The response MUST NOT include `Retry-After`, MUST consume no tokens, and MUST NOT depend on throttle backend health.

#### Scenario: Batch exceeds a reduced capacity
- **WHEN** an identity whose change capacity is overridden to 50 submits a zone `PATCH` costing 60
- **THEN** DANS returns `413` naming `changes`, cost 60, and capacity 50, without `Retry-After`, and no bucket changes

#### Scenario: Oversized request while the backend is down
- **WHEN** the throttle backend is unreachable and a request's cost exceeds an applicable bucket's capacity
- **THEN** DANS still returns `413` because the request could never be admitted

### Requirement: Refused requests have no downstream effects
Metering SHALL run after authentication and before compatibility checks, route authorization, delegation authorization, audit intent, and forwarding. A `429` or `413` rate-limit response MUST NOT evaluate delegations, write an audit intent or authorization-denial record, or contact PowerDNS.

#### Scenario: Throttled mutation
- **WHEN** a zone `PATCH` is throttled
- **THEN** DANS writes no audit intent and sends no request to PowerDNS

#### Scenario: Throttled operator-only request by a non-operator
- **WHEN** a non-operator whose buckets are empty requests an operator-only operation
- **THEN** DANS returns `429` and records no authorization denial

### Requirement: Admitted responses keep upstream fidelity
DANS SHALL NOT add rate-limit headers to admitted requests, including relayed PowerDNS responses, so their status, body, and headers follow the existing response-fidelity contract.

#### Scenario: Admitted relayed request
- **WHEN** a metered request is admitted and forwarded to PowerDNS
- **THEN** the relayed response contains no `Retry-After` or `X-DANS-RateLimit-Bucket` header added by DANS

### Requirement: Limits follow identity, global, then built-in precedence
For each bucket capacity, refill rate, change-kind cost, and operation change cost, DANS SHALL use the value from the identity's policy entry, else the policy's global defaults, else the built-in default. Overrides MUST apply per field, so an entry that sets one value inherits the rest.

#### Scenario: Identity overrides one field
- **WHEN** the global defaults set change capacity to 3,000 and an identity entry sets only change refill to 200
- **THEN** that identity's change bucket has capacity 3,000 and refill 200 per second

#### Scenario: Identity without an entry
- **WHEN** an identity has no policy entry
- **THEN** its buckets use the global defaults, falling back to built-in values for fields the defaults omit

#### Scenario: Capacity is reduced while tokens are stored
- **WHEN** a restart applies a lower capacity to an identity whose stored bucket holds more tokens than the new capacity
- **THEN** the bucket is treated as holding at most the new capacity

### Requirement: Rate limiting can be disabled
When rate limiting is disabled, DANS SHALL meter no request, MUST NOT connect to the throttle backend, and MUST NOT return rate-limit responses or headers. Rate limiting SHALL be disabled unless explicitly enabled.

#### Scenario: Default configuration
- **WHEN** an instance starts without enabling rate limiting
- **THEN** request handling is unchanged from a release without rate limiting and no throttle backend connection is attempted

### Requirement: Throttle backend failure fails open
When the shared throttle backend is unreachable, returns an error, or does not answer within the configured timeout, DANS SHALL admit every request that fits its buckets' capacities unmetered, for every operation including mutations, and MUST NOT add rate-limit headers. Metering MUST resume automatically, without restart, once the backend answers again.

#### Scenario: Backend is down
- **WHEN** the throttle backend is unreachable and an authorized zone `PATCH` arrives
- **THEN** DANS processes the request through authorization, audit, and forwarding as if rate limiting were disabled

#### Scenario: Backend is slow
- **WHEN** the throttle backend answers later than the configured timeout
- **THEN** the request is admitted unmetered and its latency includes at most the timeout for the limiter

#### Scenario: Backend recovers
- **WHEN** the throttle backend becomes reachable again after an outage
- **THEN** subsequent requests are metered without restarting any instance

#### Scenario: Backend is down at startup
- **WHEN** an instance with rate limiting enabled starts while the throttle backend is unreachable
- **THEN** the instance can still become ready and serves requests unmetered until the backend is reachable

### Requirement: Rate-limit activity is observable through structured logs
Each metered request's access log entry SHALL record the rate-limit outcome (`admitted`, `throttled`, `exceeds_capacity`, or `unmetered`), its request and change costs, any short buckets, and limiter latency. Fail-open episodes MUST produce warning events at a bounded rate with a suppressed-event count, and a recovery event when metering resumes. Logs MUST NOT contain the backend URL or credentials.

#### Scenario: Throttle is logged
- **WHEN** DANS returns a `429` rate-limit response
- **THEN** the access log entry records outcome `throttled`, the costs, the short buckets, and limiter latency

#### Scenario: Sustained outage
- **WHEN** the throttle backend stays unavailable while many requests arrive
- **THEN** DANS emits a bounded number of warning events that report how many fail-open admissions were suppressed, rather than one warning per request

#### Scenario: Outage ends
- **WHEN** metering succeeds again after fail-open admissions
- **THEN** DANS emits one recovery event
