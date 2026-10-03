## Context

See `proposal.md`. The Docker deployment already provides non-root DANS, Caddy TLS ingress, mounted secrets, and separate external dependency networks. Its existing smoke check only renders Compose and Kubernetes configuration. Browser authentication has handler-level checks and optional live tests, but no required TLS deployment rehearsal.

## Goals / Non-Goals

Exercise the exact Docker deployment configuration with a small test-only override for loopback ports and disposable dependencies. Kubernetes runtime certification and a new browser UI suite are outside this slice.

## Decisions

1. Layer a fixture over `deploy/docker/compose.yaml`, preserving its service security, file-secret configuration, and Caddyfile. Reuse the existing PostgreSQL role initialization, grants, compiled maintenance commands, and pinned PowerDNS image. Fixture networks stand in for the external private networks and remain project-owned.
2. Use curl with a generated certificate explicitly trusted through `--cacert`; never use insecure TLS. Assert cookie transport and session lifecycle through the public API. The existing browser tests remain responsible for rendered UI behavior.
3. Inspect actual container port bindings and probe the PowerDNS API from the ingress network. Check one authorized RRset via an authoritative DNS query; verify denied requests leave it unchanged.
4. Run through the existing safe integration CI wrapper with the existing PostgreSQL 16 leg and allowlisted phase names. Keep generated credentials, response headers, and container output private. Always remove the scoped project, volumes, networks, image tag, and temporary secrets.
5. The first real rehearsal found the stock Caddy executable cannot start when its `cap_net_bind_service=ep` file capability is excluded from the container bounding set. Retain only `NET_BIND_SERVICE` on ingress while preserving its read-only filesystem, no-new-privileges setting, and private networks. DANS continues to drop every capability.
6. The next rehearsal found Docker did not publish the TLS socket while ingress belonged only to an internal network. Add an external-facing bridge to ingress only. Assert every network attached to DANS is internal and ingress still cannot contact the PowerDNS API directly.

## Risks / Trade-offs

- Docker and Podman can differ in secret mount semantics → claim only the Docker runtime tested in CI, retaining existing Podman documentation.
- Synthetic leaf secret files need to be readable by container UID 65532 → keep their parent directory private and remove all generated files after the run; production secret provisioning remains operator-specific.
- A cookie jar cannot certify browser rendering → limit claims to TLS deployment and API session transport, without new screenshots or trace uploads.

## Migration Plan

No production schema or API change. Removing the new CI rehearsal restores the previous verification scope.
