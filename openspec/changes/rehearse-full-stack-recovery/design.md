## Context

See `proposal.md` and the changed `cli-configuration-qa` requirement. The existing matrix restores the DANS database into an isolated PostgreSQL database, finalizes it offline, then starts `dans-restored`; that service still points to the source PowerDNS instance. The disposable PowerDNS 5.1.3 image already uses a SQLite backend, while deployed PowerDNS is external and may use another backend. Readiness probes PowerDNS server compatibility, not zone inventory.

## Goals / Non-Goals

**Goals:** Prove that the restored DANS copy uses a separately restored authoritative data store, that expected fixture data survives in both stores, and that a mismatched authoritative copy cannot pass the rehearsal's pre-admission gate.

**Non-Goals:** A production backup tool, a universal PowerDNS restore command, atomic hot snapshots across independent stores, or automatic detection of arbitrary restored or externally recreated zones by the running service.

## Decisions

1. Reuse the existing integration matrix and PowerDNS image. Stop both source DANS API instances after the exercise to quiesce management writes, then stop the source PowerDNS container and take a cold copy of its SQLite backend alongside the existing PostgreSQL backup. Seed a fresh, separately stored `powerdns-restored` profile service from that copy. A zone-export-only approach is insufficient: PowerDNS describes its export as AXFR, while metadata and key material have separate state. The [PowerDNS backend documentation](https://doc.powerdns.com/authoritative/backends/index.html) also makes a backend-neutral file-copy recipe inappropriate. Keep backup bytes inside disposable local storage with restrictive permissions.
2. Point `dans-restored` only at `powerdns-restored`; give the restored authoritative server its own loopback DNS port. Check the expected bound zones, selected zone metadata, and representative forward and PTR answers against the pre-backup fixture before offline finalization or restored DANS startup. Restart the source PowerDNS service after the cold copy so a later test can prove an authorized restored write changes only the restored DNS instance. Reusing the original upstream would leave the current gap untested.
3. Exercise the failure boundary with one disposable restored copy missing a required fixture item. The same preflight used for the successful path must reject it with a fixed failure label while `dans-restored` remains stopped. Discard or reseed that copy from the protected backup before the successful path. Do not weaken runtime readiness with a full zone scan: this is an operator/CI recovery gate, not a claim that a normal service can recognize an arbitrary clone.
4. Preserve the existing offline finalization, credential invalidation, retained PostgreSQL-state checks, and privacy-safe CI wrapper. After starting restored DANS, verify its public API and an authorized RRset write against restored DNS, then query both authoritative instances to prove isolation. Add the restored PowerDNS service and storage to scoped teardown and private failure logs.

## Risks / Trade-offs

- Cold-copying SQLite interrupts authoritative DNS in the disposable fixture → perform it only after the main integration exercise; document that production backup scheduling and availability depend on the chosen PowerDNS backend. PowerDNS [does not permit replacing its SQLite database while running](https://doc.powerdns.com/authoritative/backends/generic-sqlite3.html).
- Separate database and authoritative backups can represent different logical times if writes continue → quiesce DANS writers in the rehearsal and require operators to coordinate other permitted upstream writers before a production paired backup. Do not claim a cross-store atomic snapshot.
- PowerDNS storage may contain DNSSEC or TSIG secrets → keep the copy private, omit raw data and diagnostics from CI output and artifacts, and clean up only the disposable project resources.
- Fixture checks sample representative data rather than every production zone or backend feature → state that production restore verification remains backend-specific and must include the deployment's relevant DNS state.

## Migration Plan

No production schema or API migration is required. Land the integration gate and runbook together; rollback removes the rehearsal without changing deployed state.
