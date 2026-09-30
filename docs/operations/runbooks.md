# DANS operations runbooks

These procedures use the released `dans` executable for both API and maintenance work. Keep PostgreSQL DDL and runtime credentials separate, capture every one-time token into a restricted file or secret manager, and keep the PowerDNS API inaccessible to clients.

## Initial migration and bootstrap

1. Verify the release checksum and version before it receives credentials:

   ```sh
   sha256sum --check SHA256SUMS
   ./dans_v1.0.0_linux_amd64 version
   ```

2. Restrict the PowerDNS API listener to DANS, create the PostgreSQL DDL/runtime roles described in [database-roles.md](database-roles.md), and place their connection URLs in separate mounted files.
3. Check and migrate with the DDL credential. The API process never migrates at startup.

   ```sh
   dans --database-url-file /run/secrets/dans-ddl-url --output json db status
   dans --database-url-file /run/secrets/dans-ddl-url --output json db migrate
   ```

4. Apply `internal/database/privileges/runtime.sql` with the DDL role. Never give the runtime role schema ownership, `CREATE`, or migration-ledger write privileges.
5. Bootstrap exactly once with the runtime credential. The output contains the only copy of the new token, so create the destination with restrictive permissions before invoking DANS.

   ```sh
   umask 077
   dans --database-url-file /run/secrets/dans-runtime-url --output json \
     bootstrap --handle platform-admin --display-name 'Platform admin' \
     --token-label initial >operator-credential.json
   ```

6. Import the token from `operator-credential.json` into the client secret store, then remove access to the one-time output according to the organization's credential-handling policy.
7. Start only same-version API instances with the runtime credential and PowerDNS key. Keep them behind the trusted TLS ingress and wait for every `/readyz` response to become 200 before admitting management traffic.

Bootstrap is serialized and only initializes an empty installation. There is no HTTP bootstrap or recovery endpoint.

## Backup

Back up DANS and authoritative PowerDNS as a coordinated pair. Stop or drain every DANS writer, then coordinate any other permitted PowerDNS writer so neither store changes until both backups are captured. PowerDNS backup steps depend on its configured backend; use that backend's supported consistent-backup procedure, including zone metadata and any key material, and verify the copy can be restored. Do not hot-copy an active SQLite database. The two stores have no shared atomic snapshot, so record their capture times and treat unquiesced copies as potentially inconsistent.

Use a PostgreSQL role permitted to make backups and a format that the restore procedure has tested. A custom-format DANS example is:

```sh
umask 077
pg_dump --format=custom --file=dans-2026-08-14.dump --dbname=service=dans-backup
pg_restore --list dans-2026-08-14.dump >/dev/null
sha256sum dans-2026-08-14.dump >dans-2026-08-14.dump.sha256
```

Store the database dump, its checksum, the matching PowerDNS backup and verification record, DANS version, and expected schema status together under restricted access. Both backups are security-sensitive: DANS contains token digests and authorization/audit history, while PowerDNS may contain DNSSEC or TSIG secrets. Regularly restore both to isolated stores, run `dans db status` with the matching binary, and verify database row counts and constraints plus the deployment's required zones, records, metadata, and keys before calling the pair verified. Keep raw backups and restore diagnostics out of CI-visible output and artifacts.

## Restore finalization

Never start an API instance against restored state before finalization and authoritative preflight.

1. Stop every DANS API instance and block ingress traffic. Keep other PowerDNS writers quiesced while the backup pair is made or selected.
2. Restore the verified database backup into a clean, isolated database using the matching DANS release and reapply the runtime grants. Restore the paired PowerDNS backup into a separate authoritative instance using its backend-specific procedure. Keep every DANS instance for these restored stores stopped; do not point ingress or a background instance at them yet.
3. Before admission, compare the expected zone inventory, required metadata and key material, and representative forward and PTR answers against the captured source inventory. Verify that DANS zone bindings correspond to the restored authoritative zones. If any required item is missing or mismatched, keep DANS stopped and repair or reseed the authoritative copy. These checks sample the deployment's relevant state; they do not prove every record or an atomic cross-store snapshot.
4. Select an existing enabled operator by UUID or handle and finalize with the runtime database credential:

   ```sh
   umask 077
   dans --database-url-file /run/secrets/dans-runtime-url --output json \
     restore finalize --handle platform-admin --token-label after-restore \
     --confirm >replacement-credential.json
   ```

5. Store the replacement secret immediately. Finalization revokes every token in the restored state and emits exactly one new operator token; all old client secrets must now receive HTTP 401.
6. Configure restored DANS to use only the restored PowerDNS endpoint. Start only the matching release, wait for readiness on every instance, verify the replacement credential authenticates as the same operator, and confirm captured pre-restore credentials receive HTTP 401 before reopening the TLS ingress. Check that expected identity, delegation, and audit history survived the database restore; make one authorized test write and verify it reaches the restored authoritative instance only.

A standard PostgreSQL restore preserves the installation metadata and cannot be recognized automatically as a copy. The stop → paired restore → authoritative preflight → offline finalize → start order is therefore an operator-enforced boundary, not a readiness check that detects an accidental early start or arbitrary mismatched zones. The integration gate rehearses this sequence against disposable PostgreSQL 16 and 18 databases and a SQLite-backed PowerDNS fixture; production PowerDNS backup and recovery remain backend-specific operator procedures.

If finalization fails, keep every instance stopped, preserve its diagnostic and database logs, and retry only after correcting the durable database problem. The command is intentionally unavailable over HTTP.

## Token rotation and offline recovery

An authenticated identity rotates its own token by creating the replacement first, deploying that secret to every client, testing it, and only then revoking the old token ID:

```sh
printf '%s\n' '{"label":"automation-2026-08"}' |
  dans --output json me token-create --data - >new-token.json

# Configure the new token, verify `dans me get`, then revoke the old ID.
dans me token-revoke OLD_TOKEN_UUID
```

The token plaintext appears only in `new-token.json`. Token revocation is permanent and immediate at the next authorization decision point. Operators can use `dans identities tokens create IDENTITY_ID --data FILE` and `revoke` for another identity under the same create-before-revoke sequence.

If every usable operator token is lost, stop relying on the API and issue a token only for an existing enabled operator through the offline runtime-database path:

```sh
umask 077
dans --database-url-file /run/secrets/dans-runtime-url --output json \
  recover operator-token --handle platform-admin --token-label recovery-2026-08 \
  >recovery-credential.json
```

Recovery cannot create, enable, or promote an identity. Investigate and audit why recovery was needed, store the replacement secret, create normally rotated tokens, and revoke any recovered token no longer required.

## Coordinated upgrade and rollback

DANS v1 does not support mixed-version rolling upgrades. Follow [coordinated-upgrades.md](coordinated-upgrades.md): verify a backup, drain and stop all old instances, run the target binary's `dans db migrate` with the DDL role, reapply runtime grants, start only the target version, and reopen traffic only after readiness succeeds.

Before a migration, rollback may restart the previous version. After a migration, an in-place binary downgrade is unsupported: restore the matching verified DANS/PowerDNS backup pair, pass authoritative preflight, run restore finalization, and start only the matching older binary. Authoritative DNS continues serving while the DANS management plane is unavailable; if restoring PowerDNS is required, plan its backend-specific availability impact separately.

## Failed or unknown DNS mutation

Never automatically retry a mutation whose audit result is `failed` or `unknown`. An unknown result means PowerDNS may already have committed it.

1. Export immutable evidence and preserve the request and operation identifiers:

   ```sh
   dans audit export --result unknown >unknown-events.ndjson
   dans audit export --result failed >failed-events.ndjson
   ```

2. Inspect current state through DANS reads and, where applicable, an authoritative DNS query. For an RRset:

   ```sh
   dans --output json rrsets get ZONE_ID owner.example.com. A
   dig @authoritative.example owner.example.com. A
   ```

3. Compare the observed state with the sanitized audit summary and intended complete RRset. Do not infer success solely from a client timeout.
4. If another write is required after the state is understood, submit it explicitly. It becomes a new operation with a new durable intent; DANS never replays the earlier operation.

A successful PowerDNS zone-creation response followed by a local binding failure is recorded as an `unknown` outcome with response class `binding_error`. The affected instance stays unready so the unmanaged lifetime cannot be missed. Preserve the response and audit evidence, inspect the zone through DANS, create or verify the matching active binding with `dans bindings create --data FILE`, and confirm every `binding_error` incident is reconciled. Then restart only the affected instance to clear its sticky lifecycle alarm and wait for `/readyz` before returning it to service.

For a failed or unknown zone deletion, the old binding stays retired and all of its delegations stay revoked. Observe it first:

```sh
dans bindings observe RETIRED_BINDING_UUID
```

Then choose exactly one operator action:

- If the zone is absent, run `dans bindings confirm-absent RETIRED_BINDING_UUID`.
- If it is present and must be deleted, run `dans bindings retry-delete RETIRED_BINDING_UUID`; this creates one new audited deletion attempt.
- If a present or recreated zone must remain managed, create `rebind.json` containing `{"zone_id":"CURRENT_POWERDNS_ZONE_ID"}` and run `dans bindings rebind RETIRED_BINDING_UUID --data rebind.json`.

A rebind creates a new generation with no inherited delegations. Never reactivate the retired binding or copy its old grants; create new delegations only after independently reviewing the new zone lifetime.
