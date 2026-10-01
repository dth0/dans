## Purpose

Defines the stable command, configuration, secret-handling, release, and real-system verification contracts used to operate and test DANS.

## Requirements

### Requirement: One executable covers supported workflows
DANS SHALL distribute one executable whose command surface covers serving the API, database migration and status, bootstrap and recovery, restore finalization, DANS resource management, audit export, health, version, shell completion, and common zone and RRset workflows. Help, version, and completion MUST run without configuration, credentials, network access, or other side effects.

#### Scenario: Offline informational command
- **WHEN** a caller requests help, version, or shell completion with no configuration file or credentials
- **THEN** the command succeeds without contacting DANS, PostgreSQL, or PowerDNS

#### Scenario: Maintenance command uses the release artifact
- **WHEN** an operator invokes migration, bootstrap, recovery, or restore finalization from the distributed executable
- **THEN** the selected maintenance workflow runs without requiring a separate administrative binary

### Requirement: Configuration file selection is explicit
Each invocation SHALL optionally read one JSON configuration file selected by `--config` or `DANS_CONFIG`, with `--config` taking precedence when both are present. DANS MUST NOT search implicit locations or load an alternate configuration format, and an explicitly named file that is missing, unreadable, malformed, or not JSON MUST cause a configuration failure.

#### Scenario: No file is named
- **WHEN** neither `--config` nor `DANS_CONFIG` is set
- **THEN** the command resolves configuration from built-in defaults, documented environment variables, and flags without searching the filesystem

#### Scenario: Flag selects the file
- **WHEN** `DANS_CONFIG` names one file and `--config` names another
- **THEN** only the file named by `--config` is loaded

#### Scenario: Named file cannot be loaded
- **WHEN** the selected file is absent, unreadable, malformed, or uses a non-JSON format
- **THEN** the command performs no requested operation and exits with code 2

### Requirement: Configuration precedence is deterministic
For every non-secret setting, DANS SHALL resolve values in ascending precedence from built-in defaults, the selected JSON file, a documented explicitly bound `DANS_*` environment variable, and a command flag. Only documented environment names MUST affect configuration, and an empty environment value SHALL be treated as unset.

#### Scenario: Every source defines one setting
- **WHEN** a setting has a built-in default and is also present in the file, its bound environment variable, and a flag
- **THEN** the flag value is used

#### Scenario: Environment overrides the file
- **WHEN** a setting is present in the selected file and its bound environment variable but not a flag
- **THEN** the environment value is used

#### Scenario: Unknown environment name is present
- **WHEN** the process environment contains an undocumented `DANS_*` name
- **THEN** that name does not create or change a configuration setting

### Requirement: Configuration is strict, command-scoped, and immutable
DANS SHALL reject unknown JSON properties and values of the wrong type, then MUST validate the required settings for only the selected command. A long-running command SHALL freeze its resolved configuration at startup and MUST NOT apply later file or environment changes until it is restarted.

#### Scenario: Unknown configuration property
- **WHEN** the selected JSON file contains an unknown property
- **THEN** the command performs no requested operation and exits with code 2

#### Scenario: Online command has only client settings
- **WHEN** an online management command has valid client configuration but no server, database, or PowerDNS settings
- **THEN** it can run without reporting unrelated missing settings

#### Scenario: Configuration changes after startup
- **WHEN** an operator changes the selected file or process environment after `serve` has completed startup
- **THEN** the running server retains its original resolved settings until restart

### Requirement: Secrets use only approved sources
A secret SHALL be accepted only from its dedicated environment variable or a mutually exclusive `*_file` setting and MUST NOT be accepted as a literal command flag or JSON value. The PowerDNS key SHALL additionally accept one explicitly named rendered fragment containing exactly one plaintext `api-key` assignment; DANS MUST NOT discover it by searching general PowerDNS configuration paths.

File-backed secrets MUST be read once, support mounted or symlinked secret files, remove one terminal LF or CRLF, reject empty or malformed values, and remain redacted from command output and logs.

#### Scenario: Environment secret is supplied
- **WHEN** a required secret has a non-empty value in its dedicated environment variable and no competing file source
- **THEN** the command uses that value without printing it

#### Scenario: File secret is supplied
- **WHEN** a required secret is in a configured regular or symlinked secret file ending in one newline
- **THEN** the command removes that terminal newline and uses the remaining non-empty value

#### Scenario: Secret sources conflict
- **WHEN** both the dedicated environment value and `*_file` source are configured for the same secret
- **THEN** the command performs no requested operation and exits with code 2

#### Scenario: Literal secret is attempted
- **WHEN** a caller places a secret value in a JSON property or literal command flag
- **THEN** configuration is rejected or the unsupported flag is rejected with exit code 2

#### Scenario: Rendered PowerDNS fragment is ambiguous
- **WHEN** the explicitly named rendered fragment has zero or multiple plaintext `api-key` assignments or otherwise cannot yield one key
- **THEN** DANS rejects the source as a configuration failure

### Requirement: CLI output is deterministic and stream-safe
Supported commands SHALL offer deterministic `text` and `json` output, with JSON as the stable automation contract. Successful data MUST be written only to stdout, diagnostics and failures MUST be written only to stderr, and audit streaming export SHALL use one complete JSON object per NDJSON line. A runtime or API failure MUST NOT append command usage to the diagnostic.

#### Scenario: JSON success
- **WHEN** a command succeeds with JSON output selected
- **THEN** stdout contains the documented deterministic JSON result and stderr is empty

#### Scenario: Runtime failure
- **WHEN** a syntactically valid command fails because of a runtime or API error
- **THEN** stderr contains one diagnostic, stdout contains no success payload, and command usage is not appended

#### Scenario: Audit export streams records
- **WHEN** an operator exports more than one audit record as NDJSON
- **THEN** stdout contains one complete JSON audit object per line without surrounding array syntax

### Requirement: Exit statuses have stable meanings
The CLI SHALL exit with code 0 for success, 1 for runtime or API failure, 2 for invocation or configuration failure, and 130 when interrupted. Commands MUST NOT prompt interactively, and an operation requiring explicit destructive confirmation SHALL make no change when that confirmation is absent.

#### Scenario: Successful command
- **WHEN** a command completes its requested operation successfully
- **THEN** it exits with code 0

#### Scenario: API failure
- **WHEN** a valid online command receives an API or transport failure
- **THEN** it exits with code 1

#### Scenario: Invocation failure
- **WHEN** arguments or configuration are invalid
- **THEN** the command exits with code 2

#### Scenario: Interrupted command
- **WHEN** the caller interrupts a running command
- **THEN** it stops through cancellation and exits with code 130

#### Scenario: Destructive confirmation is absent
- **WHEN** a destructive offline command is invoked without its required explicit confirmation
- **THEN** it exits with code 2 without changing durable state and without prompting

### Requirement: Online commands dogfood the public API
Every online CLI workflow SHALL communicate only through DANS's documented public API and MUST NOT access server handlers, PostgreSQL, or the PowerDNS listener directly. The CLI SHALL cover every DANS management workflow and common zone and RRset operations, while the full PowerDNS compatibility surface remains available through HTTP and the published client rather than a handwritten clone or generic raw-request command.

#### Scenario: Online management from a separate host
- **WHEN** a caller runs a configured online management command on a host with access only to the public DANS endpoint
- **THEN** the workflow succeeds without database or direct PowerDNS connectivity

#### Scenario: Unsupported rare PowerDNS operation
- **WHEN** a caller needs a compatibility operation without a dedicated CLI command
- **THEN** the operation remains available through the documented HTTP API and published client, and no raw-request escape command is required

### Requirement: Every change passes real-system integration QA
Every change MUST pass a required Linux integration gate that builds the release executable and starts fresh real PostgreSQL, two same-version DANS instances, and PowerDNS 5.1.3 services. The gate SHALL exercise the current minor releases of the oldest and newest supported PostgreSQL majors, run migration and bootstrap through the compiled CLI, drive management and DNS workflows only through public interfaces, and verify results with actual DNS queries and upstream state.

The gate MUST cover direct and group grants, forward and PTR RRsets, apex and literal-wildcard protection, whole-batch denial, cross-instance revocation, sensitive-route denial, audit outcomes, dependency outages, schema mismatch, and ambiguous upstream results.

#### Scenario: Public behavior passes on the support matrix
- **WHEN** a proposed change passes all required workflows against current-minor PostgreSQL 16 and 18 with two DANS instances and PowerDNS 5.1.3
- **THEN** the real-system integration gate succeeds

#### Scenario: Cross-instance security regresses
- **WHEN** a revocation committed through one instance is not enforced by the other instance in the integration environment
- **THEN** the required gate fails and the change cannot be accepted

#### Scenario: Dependency outage behavior regresses
- **WHEN** an injected PostgreSQL or PowerDNS outage causes authorization bypass, mutation replay, or an incorrect readiness signal
- **THEN** the required gate fails and the change cannot be accepted

### Requirement: CI rehearses restore finalization against a real database copy
For each supported PostgreSQL major, the required integration gate SHALL back up a populated disposable installation after management writes are quiesced and restore its DANS database and authoritative PowerDNS state into isolated copies. The rehearsal MUST keep DANS instances from serving the restored copies until the offline finalization command succeeds and the restored PowerDNS fixture's expected zones, metadata, and representative forward and PTR answers have been checked. The restored DANS service MUST use only the restored PowerDNS instance. The gate SHALL verify that existing identity, authorization, and audit data survive; every pre-restore credential captured by the rehearsal is rejected afterward; one replacement credential authenticates as the same enabled operator; and the finalized installation becomes ready for public API access. CI-visible output and artifacts MUST NOT contain backup bytes, credential values, or raw restore diagnostics.

#### Scenario: Restore and finalize a populated installation
- **WHEN** the gate restores paired backups containing an operator, another active token, authorization and audit history, and authoritative zones with records and metadata, then finalizes the DANS copy offline for the existing operator
- **THEN** the restored installation becomes ready with the same operator identity and preserved data, the replacement credential can use the public API, and the restored authoritative server answers the expected forward and PTR queries

#### Scenario: Restored credentials are invalidated
- **WHEN** the finalized installation receives any pre-restore credential captured by the rehearsal
- **THEN** it rejects that credential and does not restore its authority

#### Scenario: Restored management uses only restored DNS state
- **WHEN** an authorized write is made through the finalized restored DANS service
- **THEN** the restored authoritative server reflects the write and the original authoritative server does not

#### Scenario: Authoritative restore is missing or mismatched
- **WHEN** a required restored zone, record, or metadata item does not match the pre-backup fixture
- **THEN** the gate fails without starting a DANS instance against that restored copy or publishing confidential diagnostics

#### Scenario: Finalization does not complete
- **WHEN** offline finalization fails during the rehearsal
- **THEN** the gate fails without starting a DANS instance against that restored copy or publishing confidential diagnostics

### Requirement: Fault controls remain outside production
Integration QA SHALL inject outages and ambiguous results only through test-environment process, container, or network controls. Production artifacts MUST NOT expose seed, reset, introspection, or fault-injection endpoints used solely by tests.

#### Scenario: Integration fault is injected
- **WHEN** the required gate simulates a dependency outage or ambiguous upstream result
- **THEN** the fault is produced outside the production API surface

#### Scenario: Production routes are enumerated
- **WHEN** the production OpenAPI contract and executable are inspected
- **THEN** they contain no test-only seed, reset, introspection, or fault route

### Requirement: Release artifacts support the documented deployment targets
Each release SHALL publish checksummed Linux amd64 and arm64 executables and a non-root OCI image containing the same command surface for serving and maintenance. DANS MUST provide minimal Docker-compatible and Kubernetes deployment examples that keep PostgreSQL and PowerDNS as external dependencies rather than bundling them.

#### Scenario: OCI image runs without root
- **WHEN** an operator starts the published OCI image with its default runtime identity
- **THEN** the DANS command surface runs as a non-root user

#### Scenario: Maintenance runs from the image
- **WHEN** an operator invokes a migration or recovery subcommand from the published image
- **THEN** the same image executes that workflow without a second artifact

#### Scenario: Published binary integrity is checked
- **WHEN** an operator verifies a Linux amd64 or arm64 executable against the release checksum
- **THEN** the checksum identifies the published artifact exactly

### Requirement: Development smoke offers explicit host access verification
The development workflow SHALL provide `make smoke-host` on macOS and Linux to verify published loopback HTTP and authoritative DNS access using a unique smoke fixture. The command SHALL include the existing delegated-write, denial, and audit checks, preserve their retained-fixture behavior, and report failure if any required check fails. Ordinary startup and `make smoke` MUST retain their Docker Compose v2 and Make prerequisite contract.

#### Scenario: Host tools are installed
- **WHEN** the stack is running and the caller runs `make smoke-host` with the required host tools
- **THEN** the command exercises one unique smoke fixture and reports success only after internal authorization/audit checks and all host probes succeed

#### Scenario: Host tools are unavailable
- **WHEN** a host verification prerequisite is missing
- **THEN** the command fails with a specific prerequisite diagnostic before creating a smoke fixture, while the ordinary Docker-only smoke workflow remains available

### Requirement: Host smoke verifies published HTTP and both DNS transports
Host smoke SHALL verify the expected readiness response and console shell through the published loopback HTTP port and the fixture's exact authoritative DNS answer through the published DNS port over both UDP and TCP. Requests MUST originate from the developer or CI host, honor the existing HTTP/DNS port overrides, bypass HTTP proxies for loopback probes, and use bounded request times. DNS UDP checks MUST NOT fall back to TCP.

#### Scenario: Default ports are reachable
- **WHEN** HTTP and both DNS transports are published on their documented default ports
- **THEN** host smoke verifies HTTP readiness and console delivery plus a successful authoritative DNS response containing the fixture's owner, type, and value over each transport

#### Scenario: Ports are overridden
- **WHEN** the caller uses the existing HTTP and DNS port overrides consistently for startup and smoke
- **THEN** all host probes use the overridden ports and do not probe the defaults

#### Scenario: A published path fails while internal services remain healthy
- **WHEN** the HTTP, UDP DNS, or TCP DNS host publication is independently unavailable while internal smoke still works
- **THEN** host smoke fails within its bounded probe time and identifies the failing protocol and effective port

#### Scenario: An endpoint returns the wrong content
- **WHEN** HTTP returns a generic page instead of the expected readiness/console content or DNS returns a wrong owner, type, value, non-authoritative response, or error status
- **THEN** host smoke fails even if the underlying connection succeeded

#### Scenario: Loopback requests would otherwise use a proxy
- **WHEN** the host has HTTP proxy environment settings
- **THEN** the HTTP probes still contact the published loopback listener directly

### Requirement: Host verification preserves the local exposure boundary
Host verification MUST NOT require publishing the database or upstream management API, broadening listener bindings, reading operator credentials for public HTTP probes, or adding production test endpoints. Diagnostics SHALL identify failed checks without printing credentials or authentication headers.

#### Scenario: A host access check fails
- **WHEN** host smoke reports a failed HTTP or DNS probe
- **THEN** its diagnostic contains only the relevant check and nonsecret result, and the command does not alter network exposure to repair the failure

### Requirement: CI verifies the development quickstart lifecycle
For pull requests and pushes, CI SHALL run the development documentation contract and the root development-stack workflow on Linux with failure propagation and an explicit execution timeout. The check SHALL exercise the documented Make commands against a fresh disposable installation in addition to the existing real-system integration gate.

#### Scenario: First startup and smoke succeed
- **WHEN** the check starts from a fresh checkout without local development state
- **THEN** startup produces a ready installation and usable local operator access, and both delegated-write smoke and host HTTP/DNS verification succeed

#### Scenario: Repeated startup preserves a working installation
- **WHEN** startup is repeated on the same healthy installation
- **THEN** the check verifies unchanged operator credentials and identity, preserved fixture data, and successful readiness without duplicate initialization

#### Scenario: Stop and start preserve both data stores
- **WHEN** the check stops the stack and starts it again
- **THEN** the original database fixture, audit history, authoritative DNS record, and local credential remain usable

### Requirement: CI verifies development credential recovery and reset boundaries
The development lifecycle check SHALL verify missing and rejected credential recovery, explicit reset confirmation, removal of the entire disposable installation on confirmed reset, and successful initialization afterward.

#### Scenario: Missing credential is recovered without resetting data
- **WHEN** the check removes its own local operator token file and starts the initialized stack
- **THEN** a usable replacement is installed while the existing operator identity and fixture data are preserved

#### Scenario: Revoked credential is replaced without reactivation
- **WHEN** the check revokes its local operator token and repeats startup
- **THEN** a new credential works, the revoked credential remains rejected, and existing fixtures persist

#### Scenario: Reset without confirmation changes nothing
- **WHEN** the check requests reset without confirmation
- **THEN** reset fails and leaves project metadata, credential bytes, volumes, and fixtures unchanged

#### Scenario: Confirmed reset is complete
- **WHEN** the check confirms reset of its disposable installation
- **THEN** its containers, data volumes, credential, and project metadata are removed, and the next startup creates a usable new installation without the old database or DNS fixtures

### Requirement: Development lifecycle verification is isolated and produces sanitized evidence
The lifecycle check SHALL refuse pre-existing local development state, operate only on resources owned by its disposable run, and attempt scoped cleanup on success and failure without hiding a failing result. Published output and artifacts MUST exclude credential values, secret files, raw startup output, private machine paths, and unrelated operational identifiers.

#### Scenario: A checkout already has development state
- **WHEN** the check is invoked in a checkout containing an existing local project identity or credential
- **THEN** it fails before mutating that installation and identifies the need for a disposable checkout

#### Scenario: Verification fails after startup
- **WHEN** a lifecycle assertion fails after test resources have been created
- **THEN** the check remains failed, attempts to remove only its owned resources, and emits a sanitized phase/result diagnostic

#### Scenario: Startup emits a sign-in secret
- **WHEN** the lifecycle check captures startup output containing the generated operator token
- **THEN** the token and raw output are withheld from CI logs and uploaded artifacts on both success and failure

### Requirement: Successful development startup verifies operator access
Development startup SHALL report success only after the service is ready and its chosen local credential authenticates as the expected enabled development operator through the public self-identity API. A valid cached credential SHALL be reused without issuing a replacement and SHALL retain restrictive file permissions.

#### Scenario: Cached token is valid for the expected operator
- **WHEN** startup finds a valid local credential for the expected enabled operator
- **THEN** it verifies that identity and operator role, preserves the credential bytes, enforces mode 0600, and completes without issuing another token

#### Scenario: Cached token authenticates as an unexpected identity
- **WHEN** the credential authenticates successfully as a different identity or without the operator role
- **THEN** startup fails with a nonsecret diagnostic and does not promote the identity or replace the credential with privileged access

#### Scenario: Old local credentials remain beside a new empty database
- **WHEN** startup encounters an empty migrated database while an old local token file still exists
- **THEN** it initializes the installation through bootstrap before requiring readiness and replaces the old file only after validating the new operator credential

### Requirement: Automatic development recovery is bounded and preserves authority
For an initialized ready development installation, startup SHALL attempt recovery of a missing/empty local credential or a well-formed credential rejected with HTTP 401 using the existing offline recovery command for the expected development operator. It MUST NOT create, enable, or promote identities during recovery, reactivate revoked tokens, reset data, or finalize a restore. Each invocation SHALL make at most one bootstrap attempt and one recovery attempt.

#### Scenario: Local token file is absent
- **WHEN** an initialized ready installation has no usable token file
- **THEN** startup obtains and validates one replacement for the existing enabled development operator while preserving database and DNS data

#### Scenario: Token is revoked, expired, or unknown
- **WHEN** an initialized ready installation rejects a well-formed cached token with HTTP 401 and the expected development operator remains enabled
- **THEN** startup obtains and validates a replacement, preserves existing data and identity, and leaves the old token rejected

#### Scenario: Expected operator is disabled, demoted, or absent
- **WHEN** offline recovery cannot issue a credential for an existing enabled development operator
- **THEN** startup fails without modifying identity authority or deleting the cached token and does not retry issuance indefinitely

#### Scenario: Dependency or configuration failure occurs
- **WHEN** validation fails because of a malformed cached token in an initialized installation, transport error, server error, unexpected HTTP status, or malformed success response
- **THEN** startup fails without invoking credential recovery or replacing the cached file

#### Scenario: Installation requires restore finalization
- **WHEN** readiness fails because the installation requires an explicit restore workflow
- **THEN** startup reports failure and does not finalize the restore, reset the stack, or treat the readiness failure as token rejection

### Requirement: Development credential replacement is validated and atomic
Startup SHALL validate a newly issued credential before atomically installing it in the local token file. Temporary credential files MUST have mode 0600 in a mode-0700 directory, and unsuccessful validation or replacement MUST preserve any pre-existing token file. Credential-validation diagnostics MUST NOT expose secrets; the existing local console sign-in presentation SHALL occur only after complete startup success.

#### Scenario: Replacement succeeds
- **WHEN** a bootstrap or recovery candidate authenticates as the expected enabled operator and the local file can be replaced
- **THEN** the token file is replaced atomically with mode 0600 and startup reports success

#### Scenario: Candidate validation or file publication fails
- **WHEN** the replacement cannot be validated or installed
- **THEN** startup fails, preserves any prior token file, removes its own temporary credential files where cleanup can run, and does not print the candidate secret

#### Scenario: Issuance is interrupted
- **WHEN** execution stops after database issuance but before local replacement
- **THEN** the previous local file remains intact and the next invocation remains subject to the same bounded recovery rules without revoking unrelated credentials

### Requirement: Integration CI failure evidence is privacy-safe
The real-system integration gate SHALL retain its nonzero result on failure and publish only an allowlisted summary of the matrix leg, execution phase, and outcome. Its CI-visible output and uploaded failure artifact MUST NOT contain raw container logs, process listings, response bodies, credentials, private paths, or unrelated operational identifiers. Raw diagnostics MAY remain in runner-local temporary storage but MUST NOT be uploaded.

#### Scenario: Failure after services start
- **WHEN** an integration assertion fails after test services have started
- **THEN** the job fails and its published summary identifies the matrix leg and last known phase without copying raw diagnostics

#### Scenario: Raw diagnostics contain confidential values
- **WHEN** captured diagnostics include a synthetic credential, machine path, or operational identifier
- **THEN** none of those values appears in the integration gate's CI-visible output or uploaded failure artifact

#### Scenario: Failure before a phase is recorded
- **WHEN** the integration command exits before a phase marker is available
- **THEN** the job still fails and publishes a fixed, nonsecret unknown-phase summary

#### Scenario: Successful integration
- **WHEN** the integration gate succeeds
- **THEN** no failure-diagnostics artifact is uploaded and the existing performance measurements remain available

### Requirement: Development shell CI failures remain diagnosable and bounded
The macOS development-shell contract SHALL emit only fixed, nonsecret phase markers as it advances. Its launcher-supervisor scenario SHALL fail within a test-local bound if the watchdog does not release its readers. Published diagnostics MUST NOT include raw process output, credentials, private paths, or unrelated operational identifiers.

#### Scenario: The watchdog's macOS process lookup misses a new child
- **WHEN** the watchdog cannot read its direct child's start time immediately after spawning it
- **THEN** it still releases the supervisor's readers after its existing deadline, and the launcher scenario completes within its own bound with only a fixed phase diagnostic
