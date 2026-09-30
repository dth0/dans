# Coordinated upgrades

DANS v1 supports coordinated upgrades only. Do not run different DANS binary
versions against one database, and do not perform an in-place binary downgrade
after a migration.

## Upgrade

1. Remove every DANS instance from service. Each instance must enter drain mode,
   return `503` from `/readyz`, stop accepting new work, and finish or terminate
   in-flight work within its configured drain deadline.
2. Stop every old-version instance.
3. Quiesce any other permitted PowerDNS writers, create a paired PostgreSQL and backend-specific PowerDNS backup, and verify that both can be restored. The stores have no shared atomic snapshot.
4. Run the target binary's forward-only `db migrate` command with the DDL
   database role. API runtime credentials are intentionally insufficient. Reapply
   `internal/database/privileges/runtime.sql` with explicit role/schema/database
   variables before starting the new binary; new session and index tables require
   their reviewed runtime privileges.
5. Start only instances built from that same target version.
6. Wait for `/readyz` on every instance before reopening traffic. Readiness
   requires a writable PostgreSQL primary in the supported 16–18 range, the
   exact migration ledger expected by the binary, usable append-only audit
   storage, a finalized installation, and a compatible authenticated PowerDNS
   upstream.

Authoritative DNS can continue serving during DANS-only drain and migration;
the chosen PowerDNS backend's backup or restore procedure may have a separate
availability impact.

## Rollback and recovery

Before applying a migration, rollback may restart the previous binary. After a
migration, starting an older binary against the upgraded database is unsupported
and remains unready because its expected migration ledger differs.

To return to an older release after migration:

1. Stop all DANS instances.
2. Restore the verified pair created for that older release into an isolated database and a separate authoritative PowerDNS instance, then reapply runtime grants. Keep every DANS instance for those stores stopped. Compare required zones, metadata, keys, and representative forward/PTR answers with the captured source inventory; fail closed on a mismatch. This is a deployment-specific sample, not proof of an atomic snapshot.
3. Run that release's `restore finalize --confirm` maintenance command. This revokes every
   token restored from the backup and emits one replacement enabled-operator
   token exactly once.
4. Point DANS only at the restored PowerDNS instance, start only the matching older binary, and verify readiness and an authorized isolated DNS write before reopening
   management traffic.

All instances must remain stopped or drained between steps 1 and 4. The
[restore runbook](runbooks.md#restore-finalization) gives the exercised credential
and data checks before reopening ingress. A standard PostgreSQL restore does not
carry a signal that DANS can use to distinguish the restored copy from the original
database, so starting an instance before restore finalization is unsupported and
cannot be detected automatically. Never edit
`schema_migrations`, copy authority into a new schema, or reopen traffic before
the replacement credential has been issued.

## Console state during upgrade and restore

The console release adds browser-session and rebuildable RRset-index tables. No migration or eager zone collection runs on service startup. Session digests remain security-sensitive backup material even though the original API-token secrets are never retained. Restore finalization revokes the original tokens, which also invalidates all restored browser sessions.

Index workers coordinate leases and publication in PostgreSQL across same-version instances. Stop workers with the service before migration or restore. A failed full read keeps the previous complete generation visibly stale; the next viewed-zone or manual refresh rebuilds it from PowerDNS API reads. The index does not permit unsupported external zone deletion/recreation or restore delegated authority from old zone lifetimes.
