# Verification

The upgrade rehearsal was archived after its merged PR passed all hosted CI checks. Its complete added requirement was copied into the main spec, and archived artifacts were byte-compared with their merged versions before moving.

The Docker TLS deployment rehearsal passed locally on macOS using the production image build, PostgreSQL 16.14, and PowerDNS 5.1.3. It verified certificate validation, readiness, embedded console delivery, cookie attributes and authentication, an authoritative DNS write, cross-origin sign-in/write/sign-out rejection, unchanged DNS after a rejected write, logout replay rejection, and continued API-token access. It also checked actual port bindings, every DANS network's internal status, and denied direct ingress access to the upstream API. Credentials were absent from runtime logs.

The unchanged deployment first failed because Caddy's file capability was absent from its bounding set. After retaining only `NET_BIND_SERVICE`, Caddy started but TLS remained unreachable while ingress belonged only to an internal network. Giving only ingress an external-facing bridge made the complete rehearsal pass. DANS still drops all capabilities and joins only private networks.

An injected post-readiness failure returned the expected fixed phase summary. The exact CI cleanup assertions passed: no run-owned containers, volumes, networks, or image tag remained, and the generated secret directory was removed. Raw evidence remained private and was not staged or uploaded.

A temporary fixture change attached ingress directly to the upstream network. The gate rejected that exposure with the expected exercise-phase summary, and the original fixture bytes were restored. A Docker CLI shim then reproduced the initial cleanup defect: failed image removal still returned success. After tracking successful image creation and propagating removal errors, the same failure was rejected with a safe summary; the retained run-owned image was removed using the real CLI.

Shell syntax, deployment configuration rendering, the integration/diagnostic contracts, `git diff --check`, and strict OpenSpec validation passed. Baseline Go tests passed with the native Go 1.27.1 toolchain after permitting their local HTTP test listeners; the initial sandbox listener denial was not a code failure. No Go application code changed. Image compilation used the pinned Docker builder.

This evidence covers Docker Compose and API session transport. Hosted Linux execution, Podman runtime, browser rendering, and Kubernetes NetworkPolicy enforcement are not claimed as local results.

## Review

The first OCR review completed across six selected files and confirmed the image-cleanup finding above. That finding was fixed; readiness retries were also paced to avoid a busy loop. The final committed-code review completed with no findings across all six selected files; none failed or were waived. The final complete runtime rehearsal and scoped cleanup checks passed after these fixes. Raw review output and operational evidence remain outside the repository.

OCR excludes Markdown. These files were inspected locally for privacy, scope, contract preservation, and correspondence with the checks:

- `deploy/README.md`
- `openspec/specs/cli-configuration-qa/spec.md`
- `openspec/changes/archive/2026-10-01-rehearse-coordinated-upgrades/design.md`
- `openspec/changes/archive/2026-10-01-rehearse-coordinated-upgrades/proposal.md`
- `openspec/changes/archive/2026-10-01-rehearse-coordinated-upgrades/specs/cli-configuration-qa/spec.md`
- `openspec/changes/archive/2026-10-01-rehearse-coordinated-upgrades/tasks.md`
- `openspec/changes/archive/2026-10-01-rehearse-coordinated-upgrades/verification.md`
- `openspec/changes/verify-tls-deployment/design.md`
- `openspec/changes/verify-tls-deployment/proposal.md`
- `openspec/changes/verify-tls-deployment/specs/cli-configuration-qa/spec.md`
- `openspec/changes/verify-tls-deployment/tasks.md`
- `openspec/changes/verify-tls-deployment/verification.md`

## macOS CI follow-up

Two hosted macOS attempts stopped progressing within their first minute after a foreground command exited and its streams drained, then reached the forty-five-minute job limit. The exact hosted signal timing was not reproduced locally. A focused regression against the actual embedded supervisor did reproduce blocked cancellation when its process lookup was delayed: the original implementation failed its two-second completion bound. The simplified watchdog passed both ordinary and delayed-lookup cases.

Cancellation now uses an owned stop marker and short synchronous sleeps, removing timer PID exchange, process identity lookups, and signal/EXIT-trap timer cleanup. The escaped-reader watchdog still fails closed; the complete native stack suite exercised that path, interruption, locking, state validation, and reset recovery. The native stack suite passed in 4m21s and the host-probe suite in 3m10s. The complete stack suite also passed with the native Linux shell in the existing disposable test image. Initialization checks, shell syntax, the integration diagnostic contracts, workflow YAML parsing, strict OpenSpec validation, and whitespace checks passed. These are local measurements, not hosted runtime claims.

The stack and host-probe checks now run independently of each other and the unit gate. Each macOS job has a twelve-minute limit, each complete shell-suite step has a ten-minute limit, and the focused cancellation step has a one-minute limit. No checks were removed.

OCR completed the follow-up with zero findings in `.github/workflows/ci.yml`, `scripts/dev-stack.sh`, and `scripts/dev-stack_test.sh`. It excludes the new `scripts/dev-supervisor_test.py` through its default test-path rule and excludes Markdown. The Python regression, this verification note, `tasks.md`, and the modified main `cli-configuration-qa` spec were reviewed locally, including bounded FIFO release, owned-process cleanup, privacy-safe failure output, preserved escaped-reader rejection, and correspondence with the CI limits. Raw diagnosis and review evidence remains private.
