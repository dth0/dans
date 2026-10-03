## 1. Contract and historical fixture

- [x] 1.1 Add a focused failing integration contract for the pinned historical build, upgrade/rollback boundaries, and safe phase summaries.
- [x] 1.2 Build the pinned historical revision from retained Git history and seed the existing fixtures with its original migration and runtime grants.

## 2. Upgrade and rollback

- [x] 2.1 Reuse paired backup/restore operations, verify bounded source shutdown, and preserve the existing current-version recovery assertions.
- [x] 2.2 Reject incompatible binaries before and after migration; migrate with the target binary, apply runtime grants, and verify preserved state plus allowed/denied cross-instance writes.
- [x] 2.3 Restore and finalize the pre-upgrade pair with the historical binary; verify credential invalidation, preserved policy/DNS, isolated writes, and scoped cleanup.

## 3. Verification and handoff

- [x] 3.1 Update the upgrade documentation with the exact exercised transition and its limits; keep diagnostics private.
- [x] 3.2 Run focused contracts, shell checks, strict OpenSpec validation, Go checks, and local Docker integration for PostgreSQL 16 and 18.
- [x] 3.3 Privacy-screen the exact outgoing diff, run OCR, inspect excluded Markdown locally, and address confirmed findings before handoff.
