## 1. Recovery contract and fixture

- [x] 1.1 Add a focused failing contract for a separate restored PowerDNS service, the pre-admission mismatch boundary, and privacy-safe failure output; confirm it fails against the current harness.
- [x] 1.2 Add an isolated restored PowerDNS profile with separate storage and loopback DNS publication; include it in scoped teardown and private failure diagnostics.

## 2. Paired backup and preflight

- [x] 2.1 Quiesce source DANS writers, cold-copy the fixture's SQLite-backed PowerDNS state with its service stopped, and restore it alongside the existing PostgreSQL backup without publishing either backup.
- [x] 2.2 Compare expected restored zones, selected metadata, and representative forward and PTR DNS answers with the pre-backup fixture before finalization or restored DANS startup.
- [x] 2.3 Exercise a missing or mismatched authoritative fixture; prove preflight fails with a fixed safe label and leaves restored DANS stopped, then reseed a clean restored copy for the success path.

## 3. Isolated finalized service

- [x] 3.1 Point restored DANS only at restored PowerDNS, keep its existing offline finalization and old-token rejection checks, and verify readiness and preserved public API state.
- [x] 3.2 Submit an authorized RRset write through restored DANS and verify the restored authoritative server changes while the source authoritative server does not.

## 4. Operations and verification

- [x] 4.1 Update restore and coordinated-upgrade runbooks with the two-store sequence, backend-specific PowerDNS backup responsibility, and the limits of sampled validation and non-atomic snapshots.
- [x] 4.2 Run the focused contract, strict OpenSpec validation, shell checks, and local Docker integration for both supported PostgreSQL majors; record only sanitized outcomes.
- [x] 4.3 Review the exact change with OCR, inspect excluded Markdown locally, fix confirmed findings, and rerun affected checks before publication.
