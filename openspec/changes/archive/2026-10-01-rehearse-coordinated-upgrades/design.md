## Context

See `proposal.md`. The existing integration harness already has two DANS instances, PostgreSQL 16/18 legs, populated policy fixtures, a cold SQLite PowerDNS copy, and a separately restored service. Revision `c59045c51d0e5162400de1e64334ff4ef563ee45` has the original migration and pinned builder; the target adds browser-session and browse-index migrations.

## Goals / Non-Goals

**Goals:** Exercise real forward migration, incompatible-binary rejection, retained authorization, and rollback with the matching historical executable.

**Non-Goals:** Mixed-version rolling upgrades, arbitrary version-pair certification, production backup automation, or new runtime behavior.

## Decisions

1. Build the fixed historical source with `git archive` and its original Dockerfile instead of fabricating an old migration ledger. The integration checkout retains history so this works in CI without an unpinned source download. Missing history is an explicit setup failure.
2. Seed the existing representative fixtures through the historical service, then reuse paired backup and restore operations for both rollback and the existing current-version recovery gate. Stop both source instances within the bounded shutdown interval before snapshots or migration; reject forced-kill shutdowns.
3. Exercise the target against the old schema and the historical binary against the upgraded schema. Both must remain unready and reject authenticated management requests. Upgrade preserves token bytes; rollback uses offline finalization and revokes restored tokens.
4. Verify preserved state before new target writes, then exercise both allowed and denied delegated operations. Measure the target's footprint after upgrade rather than reporting the historical binary's measurements as target evidence.
5. Reuse the restored profile for rollback, then remove its stopped services and disposable database before the existing current-version recovery rehearsal. Raw output stays under the existing private CI wrapper; add only allowlisted upgrade/rollback phase labels.

## Risks / Trade-offs

- An additional historical build increases CI duration → reuse cached pinned Go dependencies and the existing matrix rather than adding another job.
- The fixed revision covers one real schema transition → document the exact revision and avoid claiming support for all historical releases.
- Paired snapshots are not cross-store atomic → retain quiescence and backend-specific sampled authoritative preflight.

## Migration Plan

No production migration is added. Revert the harness and CI changes to remove the rehearsal without changing deployed state.
