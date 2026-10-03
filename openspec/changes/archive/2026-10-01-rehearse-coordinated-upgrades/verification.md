# Verification

Local Docker integration passed through the privacy-safe entry point on macOS with PostgreSQL 16.14 and 18.4. Both runs built the pinned historical revision with its original schema and exercised target migration, incompatible-binary rejection, preserved policy/audit/token state, matching-version paired rollback, restored credential invalidation, and isolated DNS writes. The existing authorization scenarios ran against the upgraded target, followed by the current-version recovery and authoritative-preflight rejection checks.

Both final runs passed the cumulative credential-log scan, including logs retained before source container recreation and rollback container removal. Raw output and backup bytes remained private and were not added to the repository. Disposable containers, volumes, and run-owned image tags were cleaned up.

`scripts/integration-contract.sh`, its injected upgrade/rollback diagnostic checks, shell syntax checks, `git diff --check`, and strict OpenSpec validation passed. Go unit tests, race tests, and `go vet ./...` passed with the native Go 1.27.1 toolchain; executable builds used the pinned Go 1.26.5 Docker builder. The first race invocation could not bind its local test listeners inside the sandbox; rerunning with socket access passed.

The rehearsal covers the pinned one-to-three-migration transition and the disposable SQLite-backed authoritative fixture. Native Linux RSS and hosted workflow execution remain CI checks; no local Linux or production-backend result is claimed.

## Review

The first OCR review confirmed two coverage gaps: initial behavior checks had moved to the historical binary, and removed containers escaped the credential-log scan. Both were fixed and the affected real integration legs rerun successfully. The final committed-diff OCR review completed with no findings across all seven selected code/configuration files; no selected files failed or were waived.

OCR does not support Markdown. These changed or moved files were inspected locally for scope, privacy, contract preservation, and correspondence with the implemented checks:

- `docs/operations/coordinated-upgrades.md`
- `openspec/specs/cli-configuration-qa/spec.md`
- `openspec/changes/archive/2026-09-30-rehearse-full-stack-recovery/design.md`
- `openspec/changes/archive/2026-09-30-rehearse-full-stack-recovery/proposal.md`
- `openspec/changes/archive/2026-09-30-rehearse-full-stack-recovery/specs/cli-configuration-qa/spec.md`
- `openspec/changes/archive/2026-09-30-rehearse-full-stack-recovery/tasks.md`
- `openspec/changes/rehearse-coordinated-upgrades/design.md`
- `openspec/changes/rehearse-coordinated-upgrades/proposal.md`
- `openspec/changes/rehearse-coordinated-upgrades/specs/cli-configuration-qa/spec.md`
- `openspec/changes/rehearse-coordinated-upgrades/tasks.md`
- `openspec/changes/rehearse-coordinated-upgrades/verification.md`

The archived recovery files were byte-compared with their merged versions, and the complete recovery requirement block was verified in the main spec before archiving.
