#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compose=$root/integration/compose.yaml
harness=$root/scripts/integration.sh
measurement=$root/scripts/measure-runtime.sh
workflow=$root/.github/workflows/ci.yml

fail() {
	printf '%s\n' "integration contract: $*" >&2
	exit 1
}

[ -f "$compose" ] || fail "missing integration/compose.yaml"
[ -f "$harness" ] || fail "missing scripts/integration.sh"
[ -x "$measurement" ] || fail "missing executable runtime measurement harness"

for service in postgres powerdns powerdns-restored toxiproxy dans-a dans-b dans-restored; do
	grep -Eq "^  $service:" "$compose" || fail "compose service $service is missing"
done

grep -Fq 'postgres:16.14' "$harness" || fail "PostgreSQL 16.14 is not pinned"
grep -Fq 'postgres:18.4' "$harness" || fail "PostgreSQL 18.4 is not pinned"
grep -Fq 'powerdns/pdns-auth-51:5.1.3' "$compose" || fail "PowerDNS 5.1.3 is not pinned"
grep -Fq 'internal: true' "$compose" || fail "the dependency network is not isolated"
grep -Fq 'networks: [control, client, ingress]' "$compose" || fail "DANS lacks a dedicated host-ingress network"
grep -Fq 'ingress:' "$compose" || fail "the host-ingress network is missing"
grep -Fq 'dans-a:' "$compose" || fail "first DANS instance is missing"
grep -Fq 'dans-b:' "$compose" || fail "second DANS instance is missing"
grep -Fq '${DANS_A_PORT:?}' "$compose" || fail "the first DANS loopback port is not explicit"
grep -Fq '${DANS_B_PORT:?}' "$compose" || fail "the second DANS loopback port is not explicit"
grep -Fq '${DANS_BAD_KEY_PORT:?}' "$compose" || fail "the fault-instance loopback port is not explicit"
grep -Fq '${DANS_RESTORED_PORT:?}' "$compose" || fail "the restored-instance loopback port is not explicit"
grep -Fq 'profiles: [restore]' "$compose" || fail "the restored instance is not isolated behind a profile"
grep -Fq 'compose --profile faults --profile tools --profile restore down' "$harness" || fail "the restored instance is not included in scoped teardown"
grep -Fq '${POWERDNS_PORT:?}' "$compose" || fail "the PowerDNS loopback port is not explicit"
grep -Fq '${POWERDNS_RESTORED_PORT:?}' "$compose" || fail "the restored PowerDNS loopback port is not explicit"
grep -Fq 'powerdns_restored:/var/lib/powerdns' "$compose" || fail "the restored PowerDNS store is not isolated"
grep -Fq 'DANS_POWERDNS_URL: http://powerdns-restored:8081' "$compose" || fail "restored DANS still uses source PowerDNS"

if grep -Eq '(^|[^[:alnum:]_])sleep([[:space:]]|$)' "$harness"; then
	fail "fixed sleeps are forbidden; poll a readiness condition"
fi
grep -Fq 'collect_logs' "$harness" || fail "failure logs are not collected"
grep -Fq 'db migrate' "$harness" || fail "migration is not driven by the compiled CLI"
grep -Fq 'bootstrap' "$harness" || fail "bootstrap is not driven by the compiled CLI"
grep -Fq 'pg_dump --format=custom' "$harness" || fail "the populated database is not backed up"
grep -Fq 'pg_restore' "$harness" || fail "a database copy is not restored"
grep -Fq 'compose stop powerdns' "$harness" || fail "PowerDNS backup is not a cold copy"
grep -Fq ':/var/lib/powerdns/.' "$harness" || fail "the cold copy omits SQLite sidecars"
grep -Fq 'assert_recovery_preflight() {' "$harness" || fail "restored DNS admission gate is missing"
grep -Fq 'restored_containers=$(compose --profile restore ps --quiet dans-restored) || return 1' "$harness" || fail "a failed stopped-service query can pass the preflight"
grep -Fq 'restored_dans_stopped || return 1' "$harness" || fail "the preflight does not check restored DANS stopped state"
grep -Fq 'restore finalize' "$harness" || fail "the restored copy is not finalized offline"
grep -Fq 'preserved_after=$(preserved_state dans_restored)' "$harness" || fail "finalization does not verify preserved authorization and audit state"
grep -Fq 'source_preserved=$(preserved_state dans)' "$harness" || fail "source authorization and audit fingerprint is not captured"
grep -Fq '[ "$restored_preserved" = "$source_preserved" ]' "$harness" || fail "restored authorization and audit state is not compared with source"
grep -Fq '[ "$restored_tokens" = "$source_tokens" ]' "$harness" || fail "restored credentials are not compared with source before revocation"
if grep -Eq 'cli dans-restored .*\| jq' "$harness"; then
	fail "restored CLI failures can be hidden by a jq pipeline"
fi
finalize_line=$(grep -n 'restore finalize' "$harness" | cut -d: -f1)
start_line=$(grep -n 'compose --profile restore up --detach dans-restored' "$harness" | cut -d: -f1)
[ -n "$start_line" ] && [ "$finalize_line" -lt "$start_line" ] || fail "the restored service starts before finalization"
preflight_line=$(grep -n -m 1 'assert_recovery_preflight || exit 1' "$harness" | cut -d: -f1)
[ -n "$preflight_line" ] && [ "$preflight_line" -lt "$finalize_line" ] || fail "the restored DNS preflight runs too late"
grep -Fq '/readyz' "$harness" || fail "readiness is not polled"
grep -Fq 'dig ' "$harness" || fail "authoritative DNS is not queried"
grep -Fq 'toxiproxy' "$harness" || fail "external upstream fault control is missing"
grep -Fq 'docker compose' "$harness" || fail "the harness does not use the pinned compose environment"
grep -Fq 'pdns_cli_data' "$harness" || fail "an existing unbound PowerDNS zone is not created through the compiled client"
grep -Fq 'unbound.test.' "$harness" || fail "existing unbound PowerDNS zone deletion is not exercised"
grep -Fq "transient PowerDNS outage after compatibility success' '502 Bad Gateway'" "$harness" || fail "transient PowerDNS loss is not distinguished from the compatibility gate"
grep -Fq "retired binding repeat deletion' '409 Conflict'" "$harness" || fail "retired binding history is not enforced before a repeated zone DELETE"
grep -Fq 'docker container inspect --size' "$harness" || fail "the production OCI root filesystem is not measured"
grep -Fq 'footprint.sh" image-rootfs-bytes' "$harness" || fail "the 26 MiB OCI root-filesystem ceiling is not enforced"
grep -Fq '/proc/$pid/status' "$harness" || fail "native-Linux DANS RSS is not measured"
grep -Fq 'footprint.sh" rss-kib' "$harness" || fail "the 64 MiB ready-idle RSS ceiling is not enforced"
grep -Fq 'DANS_QA_PERFORMANCE_DIR' "$harness" || fail "the integration harness cannot emit repeated runtime measurements"
grep -Fq 'for run in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15' "$measurement" || fail "runtime readiness measurement does not repeat 15 starts"
grep -Fq 'for sample in 1 2 3 4 5' "$measurement" || fail "runtime resource measurement does not take five samples"
grep -Fq 'assert_http 404 "$b_root/metrics"' "$harness" || fail "the real-system gate does not reject a production metrics route"
grep -Fq 'assert_http 404 "$b_root/debug/pprof/"' "$harness" || fail "the real-system gate does not reject a production profiling route"

if grep -Eqi '"/api/[^"]*(test|fault|seed|reset|introspect|metrics|pprof|profil|benchmark)' "$root/api/openapi/openapi.json"; then
	fail "production OpenAPI exposes a test-only route"
fi

grep -Fq 'make generate-check' "$workflow" || fail "generation drift is not required in CI"
grep -Fq 'go test ./...' "$workflow" || fail "unit tests are not required in CI"
grep -Fq 'go test -race ./...' "$workflow" || fail "race-tested unit suite is not required in CI"
grep -Fq 'go vet ./...' "$workflow" || fail "static analysis is not required in CI"
grep -Fq 'make benchmark-check' "$workflow" || fail "benchmark correctness smoke is not required in CI"
grep -Fq 'make benchmark-postgres-check' "$workflow" || fail "real PostgreSQL benchmark smoke is not required in CI"
grep -Fq 'scripts/oci-smoke.sh dans-ci-smoke linux/amd64' "$workflow" || fail "CI omits the amd64 OCI footprint gate"
grep -Fq 'scripts/oci-smoke.sh dans-ci-smoke linux/arm64' "$workflow" || fail "CI omits the arm64 OCI footprint gate"
grep -Fq 'DANS_QA_PERFORMANCE_DIR' "$workflow" || fail "CI does not retain repeated runtime measurements"
grep -Eq '^FROM .*golang:\$\{GO_VERSION\}-alpine@sha256:[0-9a-f]{64} AS build$' "$root/Dockerfile" || fail "the Go builder image is not digest-pinned"
grep -Fq 'scripts/integration.sh' "$workflow" || fail "real-system integration is not required in CI"
grep -Fq 'scripts/integration-ci.sh scripts/integration.sh' "$workflow" || fail "CI bypasses the safe integration entry point"
grep -Fq 'path: ${{ runner.temp }}/dans-integration-summary/${{ matrix.name }}' "$workflow" || fail "CI does not upload the safe integration summary"
if grep -Fq 'path: ${{ runner.temp }}/dans-integration-logs/' "$workflow"; then
	fail "CI uploads raw integration logs"
fi
grep -Fq 'postgres:16.14' "$workflow" || fail "CI omits PostgreSQL 16.14"
grep -Fq 'postgres:18.4' "$workflow" || fail "CI omits PostgreSQL 18.4"
if grep -Fq '\${{' "$workflow"; then
	fail "CI contains escaped GitHub expressions"
fi

"$root/scripts/integration-ci_test.sh"
printf '%s\n' 'integration contract: ok'
