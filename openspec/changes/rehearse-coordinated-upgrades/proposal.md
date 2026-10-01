## Why

The integration gate proves recovery with the current schema, but does not run a populated older binary through a real forward migration and rollback. The documented coordinated-upgrade procedure therefore lacks an exercised version boundary.

## What Changes

- Start the pinned pre-console revision with its original schema and populate the existing authorization, audit, and authoritative DNS fixtures.
- Quiesce both instances and capture the existing paired backup before migrating with the target binary and reapplying its runtime grants.
- Verify preserved policy, credentials, audit history, and DNS; reject incompatible binaries on both sides of the migration boundary.
- Restore the pre-upgrade pair, finalize with the matching older binary, and verify recovered access and isolated DNS writes.
- Run the rehearsal in the existing PostgreSQL 16 and 18 integration legs with private diagnostics and scoped cleanup.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `cli-configuration-qa`: Require a real populated coordinated-upgrade and rollback rehearsal in the integration gate.

## Impact

Changes the integration harness, its contract, CI checkout history, and upgrade documentation. Reuses the existing images, paired-backup fixture, and offline maintenance commands. No production API, migration, or runtime dependency changes; the pinned revision is a schema-transition fixture, not a claim that all version pairs are supported.
