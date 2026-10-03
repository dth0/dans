## ADDED Requirements

### Requirement: CI rehearses coordinated upgrades and paired rollback
For each supported PostgreSQL integration major, the required gate SHALL populate a pinned older application revision using its original schema, quiesce every source application instance, and capture a paired database and authoritative backup before running the target binary's forward migration and applying its runtime grants. It MUST verify preserved identities, groups, delegations, audit history, credentials, and representative authoritative DNS data, then exercise authorized and denied operations through the target version. The gate MUST also restore the pre-upgrade pair into isolated stores, finalize with the matching older binary, and verify recovered operator access, invalidation of captured old credentials, preserved policy and DNS, and an authorized write affecting only restored DNS. Backups and raw diagnostics MUST remain private and cleanup MUST be restricted to the disposable run.

#### Scenario: A populated installation upgrades successfully
- **WHEN** all older instances are stopped and the target binary migrates the database with DDL credentials before target runtime grants are applied
- **THEN** both target instances become ready with preserved policy, credential and audit data, representative DNS answers remain correct, and delegated authorization works across instances

#### Scenario: Incompatible binaries fail closed
- **WHEN** the target binary starts before migration or the older binary starts against the migrated schema
- **THEN** neither incompatible instance becomes ready or admits authenticated management requests

#### Scenario: Rollback restores the matching version and backup pair
- **WHEN** the pre-upgrade database and authoritative state are restored, checked, and finalized offline with the matching older binary
- **THEN** the older service becomes ready with preserved identity and policy data, captured pre-restore credentials are rejected, and an authorized test write affects only restored DNS

#### Scenario: Upgrade or rollback verification fails
- **WHEN** any required migration, preservation, compatibility, or restored-state assertion fails
- **THEN** the integration gate fails, publishes only a fixed privacy-safe phase summary, and attempts scoped cleanup without admitting an unverified restored service
