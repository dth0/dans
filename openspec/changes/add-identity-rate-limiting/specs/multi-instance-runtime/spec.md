## ADDED Requirements

### Requirement: Throttle state is shared, ephemeral, and non-authoritative
When rate limiting is enabled, API instances SHALL share token-bucket state through one Redis-protocol throttle backend that holds only that state. Losing or flushing it MUST NOT lose authorization, audit, zone-binding, or DNS state, and PostgreSQL SHALL remain the only durable state engine. Backup, restore, and coordinated upgrade procedures MUST NOT require backing up or restoring throttle state.

#### Scenario: Throttle backend data is lost
- **WHEN** the throttle backend restarts empty while instances are serving
- **THEN** every identity's buckets behave as full and no authorization, audit, or DNS state changes

#### Scenario: Restore from backup
- **WHEN** an operator restores PostgreSQL from a verified backup
- **THEN** the documented procedure requires no throttle backend backup and existing throttle state may be discarded

### Requirement: Throttle backend never gates readiness or authorization
`/readyz` SHALL NOT depend on the throttle backend, and throttle backend failure MUST NOT fail, delay beyond the configured limiter timeout, or bypass authorization for any request. Authorization, audit persistence, and PowerDNS failures SHALL keep their existing fail-closed behavior regardless of throttle backend health.

#### Scenario: Throttle backend outage
- **WHEN** the throttle backend is unavailable and PostgreSQL, schema, audit storage, and PowerDNS are healthy
- **THEN** `/readyz` returns 200 and requests continue to be authorized against PostgreSQL

#### Scenario: PostgreSQL outage with healthy throttle backend
- **WHEN** the PostgreSQL primary is unavailable while the throttle backend is healthy
- **THEN** authenticated operations still fail closed and nothing is forwarded to PowerDNS

### Requirement: Throttle backend stays inside the private boundary
Supplied deployment examples that enable rate limiting SHALL place the throttle backend on the private network shared only with DANS instances, MUST NOT publish it to clients or the host, and MUST authenticate DANS to it with a file-supplied credential.

#### Scenario: Production example with rate limiting
- **WHEN** an operator applies a supplied deployment example
- **THEN** only DANS instances can reach the throttle backend, and clients reach DANS solely through the TLS ingress
