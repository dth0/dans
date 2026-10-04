# Web console design

The embedded console supports DNS editing and access management. The first-release checks and DNS capacity measurements are recorded in its [verification note](../openspec/changes/archive/2026-09-23-add-web-console/verification.md); the [management verification note](../openspec/changes/archive/2026-09-23-complete-management-console/verification.md) records the added workflows and capacity checks.

## Product and scope

Build a Route 53-inspired console for delegated users and DANS operators, with DNS editing as its primary workflow. Use dense tables, clear navigation, filtering, and explicit create/edit forms adapted to the existing Zone, RRset, and Delegation terminology. One table row represents a complete RRset, including its values.

The first release includes:

- Zone and RRset creation, editing, and deletion, subject to existing authorization rules.
- Delegation management and audit viewing for DANS operators.
- Permission explanations using zone information added to self-delegation responses.
- Explicit Save for edits and confirmation for destructive actions.

The console also supports the [management workflows](#management-workflows) below. Identity-provider integration and searching within record values are deferred.

Use React, TypeScript, and Cloudscape. Embed built assets in the existing binary and serve the console alongside the API under the same origin. Minimize backend changes while supporting the agreed authentication and large-zone browsing requirements.

The reference workflow is described in the official Route 53 documentation for [listing records](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resource-record-sets-listing.html) and [creating records](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resource-record-sets-creating.html). Cloudscape provides the [React components](https://cloudscape.design/get-started/for-developers/using-cloudscape-components/) for the console.

## Sign-in

Accept an existing API token and remember sign-in across page reloads and browser restarts for seven days, ending sooner if the token expires or is revoked. Use a persistent secure, HttpOnly cookie with CSRF protection. Remembering sign-in must retain current token and authority checks; it must not cache permissions or delay revocation.

The local Compose stack explicitly enables an HTTP development cookie for Safari compatibility. This separately named cookie omits Secure while retaining HttpOnly, SameSite=Strict, CSRF protection, and the same session/authority checks. Secure cookies remain the default for deployed services.

Sign-out clears browser authentication without revoking the original API token, which may also be used by other clients. See [the authentication decision](adr/0011-use-token-backed-browser-sign-in.md).

## Browsing and indexing

Support 400 zones, including a zone with 250,000 RRsets. This capacity target counts table rows, not individual record values.

- Allow complete browsing before entering a search term, with 100 RRsets per page and Previous/Next navigation.
- Perform exact owner-name and owner-name prefix searches and record-type filtering on the server.
- Order results by owner name, then record type.
- Use a rebuildable browsing index in the existing PostgreSQL database, populated exclusively through PowerDNS API reads. Do not connect directly to the PowerDNS database.
- Build the index on first access and show a loading state until browsing data is ready.
- During subsequent refreshes, keep previous results visible with a freshness indicator. If refresh fails, retain displayed data with an error and stale indication.
- Target visibility of successful DANS API/CLI changes within five seconds by refreshing affected RRsets instead of rebuilding the entire zone.
- Fully refresh zones being viewed every five minutes to pick up supported DNS transfers or dynamic updates, and provide manual full refresh.

The five-second target passed the recorded synthetic capacity run across two application instances; it remains workload- and dependency-dependent. A refresh schedule does not promise that an upstream read will succeed or complete within that interval.

PowerDNS remains authoritative for DNS state. The index serves browsing and filtering only; current policy remains independent of indexed DNS data. Existing zone-lifetime and fail-closed behavior must be preserved. Periodic refresh does not make unsupported external zone deletion/recreation safe. See [the index decision](adr/0012-index-api-reads-for-large-zone-browsing.md).

## Editing and outcomes

Fetch the current complete RRset when opening an editor and check it again before saving. If it changed, preserve the draft, show the difference, and require reconciliation. A successful live read is required for editing even when previous browsing results remain visible.

Retain the existing last-successful-write concurrency model. The pre-save check detects earlier changes but does not eliminate the race between checking and writing. The UI must not imply conflict-free updates or automatic merging.

Keep current API authorization for every mutation. Disabled controls and permission explanations are advisory: authority can change while a page is open. Whole-RRset authority, whole-batch authorization, and the protections for apex and literal wildcard owners continue to apply.

Distinguish confirmed success, confirmed failure, and unknown mutation outcomes. Preserve the existing prohibition on automatic mutation retries; a timeout must not silently resubmit a write. Confirm destructive actions before submission.

## Existing API gaps and implementation boundaries

- All authenticated identities can read ordinary DNS data; delegations constrain writes, not visibility.
- Existing API clients use `X-API-Key`; the console adds opaque token-backed browser sessions without replacing those clients.
- Effective self-delegations include the zone identifier and name needed for permission explanations, alongside the binding identifier.
- Zone and RRset reads have no pagination. Exact-name lookup and capped global search cannot provide complete paginated browsing; search results may also omit other values in an RRset.
- Returning a page after fetching an entire upstream zone would repeat whole-zone work on every page. Browse from the retained index instead.
- Management collections already use cursor pagination and should retain that behavior.
- There is no compare-and-set write support. Stronger concurrency guarantees remain outside this release.
- Preserve support for multiple API instances sharing PostgreSQL. Index updates and refresh coordination must work across instances.

## Validation before completion

Use synthetic DNS data to validate browsing and filtering at the agreed capacity, including complete RRset values and traversal without whole-zone browser downloads. Measure the five-second update target across API instances and exercise initial indexing, concurrent refreshes, refresh failures, and supported zone deletion/recreation.

Verify remembered login, sign-out, token expiry/revocation, and CSRF protection. Exercise delegated and operator workflows, authority changes while editing, draft preservation after detected conflicts, destructive-action confirmation, and unknown outcomes without automatic retries. Verify keyboard navigation, form labels, focus behavior, and visible loading/error states in the rendered UI.

## Management workflows

The console covers these management areas:

- Identities: users and service identities, display names, enabled state, and DANS operator roles.
- Groups: group administration and direct membership.
- API tokens and self-service: token creation and revocation, and views of the current identity, memberships, and effective authority.
- Zone bindings: inspection and explicit zone-lifetime recovery workflows.
- Audit: the remaining management API filters and export.

Advanced PowerDNS administration, including key management, TSIG, metadata, transfers, and server configuration, is a separate future slice. Existing DNSSEC switches in zone forms remain part of the first release.

The existing management API and CLI provide the core operations. Retain the console's existing authentication, authorization, and UI foundations, with the additions described below.

### Identity details and membership

DANS operators can inspect an identity's profile, groups, effective authority, and token metadata together. Operator read endpoints expose identity memberships, effective delegations, and retained assignments. Users and service identities remain distinct kinds of identity under the existing lifecycle rules.

Separate **Effective authority now** from **Retained assignments**. A disabled identity has no usable authority, while its tokens, memberships, and delegations remain inspectable. Disabled groups retain their memberships and delegations but contribute no effective authority. Explain that re-enabling can restore retained access before confirming the action. Show the DANS operator role explicitly rather than implying that an empty delegation list means an enabled DANS operator has no authority.

### Token issuance and changes to personal access

Create an identity before offering token creation on its detail page. Token creation is a separate explicit action, with a label and optional expiry. Show the newly issued secret once with a Copy action; subsequent views expose metadata only.

Mark the API token used for the current browser sign-in. The current-credential endpoint exposes only its identifier, without its secret. Allow self-revocation, self-disablement, and removal of one's own DANS operator role after explaining the consequences and obtaining confirmation. Retain the server's protection against leaving no enabled DANS operator. Revoking the sign-in token ends sessions backed by that token.

### Binding recovery

Present recovery according to the binding's current state. Offer an explicit upstream observation, explain eligible recovery actions and their consequences, and require confirmation before submitting changes. Rebinding creates a new zone lifetime and does not restore delegations from a retired binding.

### Management search

Support server-side handle-prefix search over complete identity and group collections, retaining bounded cursor pagination. Apply the same search and pagination behavior to membership and delegation selectors rather than downloading every identity or group into the browser. Preserve existing exact-handle lookup for API clients.

### Audit filtering and export

Expose the existing actor, action, target type, target ID, and result filters. Export all matching events as NDJSON through a bounded-memory stream, rechecking current authorization between pages. Describe the export as a traversal of live history rather than a consistent snapshot across pages. Interrupted downloads must fail visibly and must not be presented as complete exports. CSV, date-range filtering, snapshot exports, and background export jobs are deferred.

### Management validation targets

Use synthetic data covering 1,000 identities, 100 groups, 1,000 members in one group, 100 tokens per identity, and 100,000 audit events. These are validation targets, not product limits. Keep every management list and selector paginated, and verify handle-prefix results beyond the first page. The first release's DNS capacity and browser-session requirements continue to apply.
