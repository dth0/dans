## Why

The deployment examples are checked for valid configuration, but their TLS ingress and default secure browser authentication are not exercised by required CI. A valid manifest can still leave the documented operator path unusable or expose a private listener.

## What Changes

- Run the existing Docker deployment example with disposable PostgreSQL and PowerDNS dependencies, synthetic file secrets, and a locally trusted test certificate.
- Verify TLS readiness, embedded console delivery, cookie authentication, allowed DNS changes, forgery rejection, and logout without revoking the original token.
- Check published sockets and network isolation; contain raw diagnostics and clean up only the disposable project.
- Require the rehearsal in CI and document exactly what it covers.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `cli-configuration-qa`: Require runtime verification of the documented Compose TLS deployment boundary.

## Impact

Adds a disposable deployment fixture and runtime smoke harness, using the existing Docker example, image build, maintenance CLI, and safe CI entry point. No new production API or runtime dependency. Kubernetes configuration validation remains its existing check; this slice does not certify a cluster ingress controller.
