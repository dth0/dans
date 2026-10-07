# Verification

Local verification on 2026-10-06 (macOS arm64, Docker 29.8.2, Go 1.27.1 for tests and the pinned Go 1.26.5 toolchain for release builds). CI runs the same checks on Linux.

## Footprint

Release executables were built with the Dockerfile's flags (`CGO_ENABLED=0 -trimpath -buildvcs=false -ldflags "-s -w -buildid= -X main.version=ci"`, Go 1.26.5).

| Linux executable | Before (`aedfe2a`) | After | Change | Budget |
| --- | --- | --- | --- | --- |
| amd64 | 23,285,886 | 23,470,206 | +184,320 | 25,165,824 |
| arm64 | 21,758,078 | 21,889,150 | +131,072 | 25,165,824 |

The integration gate measured the arm64 OCI root filesystem at 22,138,880 bytes, against a budget of 27,262,976.

The first implementation used `github.com/redis/go-redis/v9`. It produced 31,494,270 bytes on amd64 and 29,163,646 on arm64, and the gate's image check failed at 29,413,376 bytes. The client was replaced with `github.com/gomodule/redigo` (design D6).

The ready-idle VmRSS gate runs only on native-Linux CI, so it was not measured locally.

## Results

| Check | Result |
| --- | --- |
| `go test ./...`, `go test -race ./...`, `go vet ./...` | pass (624 tests) |
| `go test -race -tags integration ./internal/ratelimit/` against `redis:8.10.2` | pass |
| `make generate-check`, `make benchmark-check`, `make integration-contract`, `make dev-contract` | pass |
| `make frontend-test` (unit, typecheck, Playwright) | pass (26 browser tests, 2 skipped) |
| `make up`, `make smoke`, `make smoke-host`, `scripts/dev-stack_lifecycle_test.sh` with rate limiting enabled | pass; a burst against the dev stack returned `429` after 56 admitted requests |
| `scripts/integration.sh postgres:16.14` and `postgres:18.4` | pass, including the `ratelimit` phase |
| `scripts/integration-ci.sh scripts/deploy-runtime_test.sh postgres:16.14` | pass: Redis is private and unpublished, ingress cannot reach it, the ACL user works, and a burst returns `429` |
| `scripts/deploy-smoke.sh` (Compose config and Kubernetes render) | pass |
| `openspec validate add-identity-rate-limiting --strict` | pass |
