## Why

The required restore gate copies DANS's PostgreSQL state but continues using the original PowerDNS instance. It can therefore pass without proving that authoritative zones and the restored policy state can be recovered together. The runbook explicitly leaves PowerDNS recovery to the operator.

## What Changes

- Extend each disposable PostgreSQL integration leg to restore the fixture's PowerDNS state into a separate instance and point the restored DANS service only at that instance.
- Verify a paired, quiesced restore before reopening the restored management path: retained bindings and authorization, representative zone metadata, and forward and reverse authoritative DNS answers must agree with the pre-backup fixture.
- Exercise a missing or mismatched PowerDNS restore and require a fixed, privacy-safe failure before the restored DANS service starts.
- Document the two-store recovery order and the fact that production PowerDNS backup and restore remain backend-specific operator responsibilities.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `cli-configuration-qa`: Expand the required restore-finalization rehearsal to cover a separate restored PowerDNS instance and a fail-closed pre-admission mismatch check.

## Impact

The integration Compose fixture, restore harness and contract, and recovery runbooks change. The rehearsal uses the fixture's existing SQLite-backed PowerDNS image; it does not add a generic backup product, change the production API or database schema, or claim automatic detection of an arbitrary production restore.
