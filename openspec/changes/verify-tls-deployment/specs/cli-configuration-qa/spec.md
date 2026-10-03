## ADDED Requirements

### Requirement: CI exercises the documented TLS deployment
Required CI SHALL start the documented Compose deployment against disposable real dependencies using the production executable, file-based secrets, and TLS ingress. The gate MUST verify certificate validation without disabling it, readiness and console delivery, default secure cookie authentication, an authorized DNS mutation, rejection of cross-origin state changes without side effects, and session invalidation after logout while the original API token remains usable. Only ingress and authoritative DNS test sockets MAY be published; DANS, PostgreSQL, and the PowerDNS management API MUST remain private. Raw output and credentials MUST remain private, and cleanup MUST affect only the disposable run.

#### Scenario: A client uses the supported deployment path
- **WHEN** a client trusts the fixture certificate and connects through TLS ingress
- **THEN** readiness and the embedded console are available, sign-in issues a host-scoped Secure HttpOnly SameSite=Strict cookie, and an authenticated DNS change is observable through authoritative DNS

#### Scenario: A forged write or revoked browser credential is used
- **WHEN** an authenticated cookie accompanies a cross-origin write, or a logged-out cookie is replayed
- **THEN** the request is rejected without changing managed state, and logout leaves the original API token usable

#### Scenario: A private management listener is exposed
- **WHEN** the deployment publishes a private listener or lets the ingress reach the upstream management API directly
- **THEN** the gate fails rather than treating successful TLS requests as sufficient deployment verification

#### Scenario: Runtime verification fails
- **WHEN** a required deployment assertion fails
- **THEN** CI receives only a fixed safe phase summary, raw evidence stays private, and run-owned resources are cleaned up
