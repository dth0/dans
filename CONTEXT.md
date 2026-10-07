# DNS Authorization and Name Service

DANS lets multiple parties share DNS zones by delegating control over selected names without creating subzones.

## Language

**Identity**:
An authenticated DANS actor, either a user or a service identity.
_Avoid_: Principal, account

**Zone**:
An administrative DNS namespace containing RRsets. A zone may be shared by multiple grantees.

**RRset**:
All DNS records with the same owner name and record type in one zone. An RRset may contain multiple record values and is the unit of delegated authority.
_Avoid_: Record, when referring to the whole set

**Owner name**:
The absolute DNS name to which an RRset belongs.
_Avoid_: Hostname

**Name pattern**:
A Route 53-style glob defined by a DANS operator and used to select canonical absolute owner names within a zone for a delegation. `*` may span DNS labels.
_Avoid_: Regex, regular expression

**Delegation**:
An allow-only grant defined by a DANS operator over RRsets selected by a zone, one or more name patterns, and optional record-type and change-kind restrictions.
_Avoid_: Subzone

**DANS operator**:
A privileged identity who defines delegations and administers DANS.
_Avoid_: Operator, tenant

**Platform operator**:
A person or team responsible for deploying and running DANS. A platform operator is not necessarily a DANS operator.
_Avoid_: Operator

**Grantee**:
An identity (user or service) or group named by a delegation.
_Avoid_: Tenant, principal

**User**:
A human identity managed and authenticated by DANS.

**Group**:
A DANS-managed, non-nested collection of identities that may be named as a grantee.

**Service identity**:
A non-human identity managed and authenticated by DANS.
_Avoid_: Shared user

**API token**:
An opaque DANS credential belonging to a user or service identity. It is distinct from the PowerDNS API key held by DANS.

**Resource ID**:
An immutable, server-generated lowercase UUIDv4 identifier for an identity, group, token, delegation, or zone binding. Relationships use resource IDs rather than names.

**Handle**:
An immutable lowercase ASCII name used to recognize an identity or group. Identity handles and group handles each have their own uniqueness namespace and remain reserved when disabled.

**Display name**:
A mutable, non-unique Unicode label shown to people.

**Selector**:
An exact owner name or name pattern within a delegation. Exact selectors are required for the zone apex and literal wildcard RRsets.

**Effective authority**:
The authority an enabled identity can currently use: effective direct delegations, delegations through enabled groups, and its DANS operator role. Disabled identities have no effective authority.
_Avoid_: Cached permissions

**Retained assignment**:
A membership or delegation preserved when an identity or group is disabled. Retention alone does not make an assignment effective; re-enabling can restore eligible access, but revocation and zone retirement remain final.

**Authorization decision point**:
The primary-database statement snapshot at which DANS computes an identity's effective authority for one request. Authority committed before this point applies; a request that has reached this point may finish after a concurrent revocation.

**Route class**:
The exhaustive authorization classification attached to a supported API operation: authenticated read, delegated RRset write, or `operator-only` (restricted to DANS operators). Unknown operations have no implicit class and fail closed.

**Compatibility surface**:
The operations in DANS's pinned PowerDNS `/api/v1` OpenAPI contract. PowerDNS web UI, metrics, and undocumented routes are outside this surface.

**Zone binding**:
DANS's association with the current lifetime of an upstream zone. Deleting a zone retires its binding so recreating the same name cannot revive old delegations.

**Rebind**:
An explicit DANS operator action that creates a new zone binding after a zone has been recreated. A rebind never copies delegations from a retired binding.

**Audit intent**:
An immutable record written before DANS forwards a DNS mutation.

**Audit outcome**:
An immutable record of the observed result of an audit intent.

**Unknown outcome**:
An audit outcome used when DANS cannot determine whether PowerDNS applied a forwarded mutation. Unknown operations are never replayed automatically.

**Ordinary DNS data**:
Zones, RRsets, comments, searches, and exports that any authenticated identity may read.

**Sensitive PowerDNS data**:
Secrets and operational information, including TSIG secrets, DNSSEC private keys, configuration, and statistics, that only DANS operators may read.

**Literal wildcard RRset**:
An RRset whose owner name contains the DNS wildcard label `*`. It requires an exact-name delegation and is not selected implicitly by a glob wildcard.

**Rate-limit bucket**:
A token bucket owned by one identity that meters its requests (identity-level and per-operation buckets) or its DNS changes (the change-throughput bucket). Bucket state is disposable and shared by all API instances.
_Avoid_: Quota

**Change cost**:
The change-throughput tokens a request consumes: per RRset in a zone patch by change kind, or a flat cost for zone creation and deletion.
