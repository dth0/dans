#!/bin/sh
set -eu
umask 077

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compose_file=$root/integration/compose.yaml

if [ "$#" -eq 0 ] && [ -z "${POSTGRES_IMAGE:-}" ]; then
	"$0" postgres:16.14
	"$0" postgres:18.4
	exit 0
fi

postgres_image=${1:-${POSTGRES_IMAGE:-}}
case "$postgres_image" in
	postgres:16.14 | postgres:18.4) ;;
	*)
		printf '%s\n' 'usage: scripts/integration.sh [postgres:16.14|postgres:18.4]' >&2
		exit 2
		;;
esac

for command in curl dig docker git jq mktemp tar; do
	command -v "$command" >/dev/null 2>&1 || {
		printf '%s\n' "integration: missing required command: $command" >&2
		exit 2
	}
done

major_minor=${postgres_image#postgres:}
project=dans-qa-$(printf '%s' "$major_minor" | tr . -)-$$
work=$(mktemp -d "${TMPDIR:-/tmp}/dans-qa.XXXXXX")
chmod 700 "$work"
log_dir=${DANS_QA_LOG_DIR:-$work/logs}
export POSTGRES_IMAGE=$postgres_image
export DANS_IMAGE=dans-integration:$project
target_image=$DANS_IMAGE
previous_revision=c59045c51d0e5162400de1e64334ff4ef563ee45
previous_image=dans-integration-previous:$project
port_base=${DANS_QA_PORT_BASE:-$(( 20000 + ($$ % 20000) ))}
export DANS_A_PORT=${DANS_A_PORT:-$port_base}
export DANS_B_PORT=${DANS_B_PORT:-$(( port_base + 1 ))}
export POWERDNS_PORT=${POWERDNS_PORT:-$(( port_base + 2 ))}
export POWERDNS_RESTORED_PORT=${POWERDNS_RESTORED_PORT:-$(( port_base + 5 ))}
export DANS_BAD_KEY_PORT=${DANS_BAD_KEY_PORT:-$(( port_base + 3 ))}
export DANS_RESTORED_PORT=${DANS_RESTORED_PORT:-$(( port_base + 4 ))}
export DANS_RL_A_PORT=${DANS_RL_A_PORT:-$(( port_base + 6 ))}
export DANS_RL_B_PORT=${DANS_RL_B_PORT:-$(( port_base + 7 ))}
footprint_container=

compose() {
	docker compose --project-name "$project" --file "$compose_file" "$@"
}

mark_phase() {
	if [ -n "${DANS_QA_PHASE_FILE:-}" ]; then
		printf '%s\n' "$1" >"$DANS_QA_PHASE_FILE"
	fi
}

collect_logs() {
	mkdir -p "$log_dir"
	compose --profile restore ps --all >"$log_dir/compose-ps.txt" 2>&1 || true
	compose --profile restore logs --no-color --timestamps >"$log_dir/compose.log" 2>&1 || true
	printf '%s\n' "integration: failure logs: $log_dir" >&2
}

cleanup() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ]; then
		collect_logs
	fi
	if [ -n "$footprint_container" ]; then
		docker container rm "$footprint_container" >/dev/null 2>&1 || true
	fi
	if [ "${DANS_QA_KEEP:-0}" != 1 ]; then
		compose --profile faults --profile tools --profile restore --profile ratelimit down --volumes --remove-orphans >/dev/null 2>&1 || true
		docker image rm "$target_image" "$previous_image" >/dev/null 2>&1 || true
	fi
	rm -rf "$work/powerdns"
	if [ -z "${DANS_QA_LOG_DIR:-}" ]; then
		rm -rf "$work"
	fi
	exit "$status"
}

seed_restored_powerdns() {
	docker run --rm --network none --user 0 --entrypoint sh \
		-v "$work:/backup:ro" \
		-v "${project}_powerdns_restored:/var/lib/powerdns" \
		powerdns/pdns-auth-51:5.1.3 -ec \
		'rm -f /var/lib/powerdns/pdns.sqlite3-wal /var/lib/powerdns/pdns.sqlite3-shm /var/lib/powerdns/pdns.sqlite3-journal; cp /backup/powerdns/pdns.sqlite3* /var/lib/powerdns/; chown pdns:pdns /var/lib/powerdns/pdns.sqlite3*; chmod 600 /var/lib/powerdns/pdns.sqlite3*' >/dev/null
}
trap cleanup EXIT HUP INT TERM

fail() {
	printf '%s\n' "integration: $*" >&2
	exit 1
}

wait_for() {
	label=$1
	shift
	deadline=$(( $(date +%s) + 90 ))
	while [ "$(date +%s)" -le "$deadline" ]; do
		if "$@" >/dev/null 2>&1; then
			return 0
		fi
	done
	fail "timed out waiting for $label"
}

http_is() {
	expected=$1
	url=$2
	status=$(curl --silent --show-error --max-time 3 --output /dev/null --write-out '%{http_code}' "$url" 2>/dev/null || true)
	[ "$status" = "$expected" ]
}

assert_http() {
	expected=$1
	url=$2
	shift 2
	status=$(curl --silent --show-error --max-time 5 --output "$work/http-body" --write-out '%{http_code}' "$@" "$url" || true)
	[ "$status" = "$expected" ] || fail "$url returned HTTP $status, want $expected; body: $(tr '\n' ' ' <"$work/http-body")"
}

toxiproxy() {
	compose exec -T toxiproxy /toxiproxy-cli --host http://127.0.0.1:8474 "$@"
}

cli() {
	instance=$1
	token=$2
	shift 2
	compose run --rm --no-deps -T \
		-e DANS_ENDPOINT="http://$instance:8080/api/v1" \
		-e DANS_API_TOKEN="$token" \
		-e DANS_OUTPUT=json \
		cli "$@"
}

cli_data() {
	data=$1
	instance=$2
	token=$3
	shift 3
	printf '%s\n' "$data" | cli "$instance" "$token" "$@" --data=-
}

pdns_cli() {
	compose run --rm --no-deps -T \
		-e DANS_ENDPOINT=http://powerdns:8081/api/v1 \
		-e DANS_API_TOKEN=dans_v1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
		-e DANS_OUTPUT=json \
		dans-a "$@"
}

pdns_cli_data() {
	data=$1
	shift
	printf '%s\n' "$data" | pdns_cli "$@" --data=-
}

pdns_cli_restored() {
	compose run --rm --no-deps -T \
		-e DANS_ENDPOINT=http://powerdns-restored:8081/api/v1 \
		-e DANS_API_TOKEN=dans_v1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
		-e DANS_OUTPUT=json \
		dans-a "$@"
}

expect_cli_error() {
	label=$1
	expected=$2
	instance=$3
	token=$4
	shift 4
	if cli "$instance" "$token" "$@" >"$work/cli-out" 2>"$work/cli-err"; then
		fail "$label unexpectedly succeeded"
	fi
	grep -Fq "$expected" "$work/cli-err" || fail "$label did not report $expected: $(tr '\n' ' ' <"$work/cli-err")"
}

expect_cli_data_error() {
	label=$1
	expected=$2
	data=$3
	instance=$4
	token=$5
	shift 5
	if cli_data "$data" "$instance" "$token" "$@" >"$work/cli-out" 2>"$work/cli-err"; then
		fail "$label unexpectedly succeeded"
	fi
	grep -Fq "$expected" "$work/cli-err" || fail "$label did not report $expected: $(tr '\n' ' ' <"$work/cli-err")"
}

query_dns() {
	name=$1
	type=$2
	dig @127.0.0.1 -p "$dns_port" +time=2 +tries=1 +noall +answer "$name" "$type"
}

dns_values() {
	dig @127.0.0.1 -p "$1" +time=2 +tries=1 +short "$2" "$3" | sort
}

restored_dans_stopped() {
	restored_containers=$(compose --profile restore ps --quiet dans-restored) || return 1
	[ -z "$restored_containers" ]
}

recovery_preflight() {
	printf '%s\n' stopped >"$work/preflight-step"
	restored_dans_stopped || return 1
	printf '%s\n' zones >"$work/preflight-step"
	restored_zones_json=$(pdns_cli_restored zones list 2>"$work/preflight.err") || return 1
	restored_zone_ids=$(printf '%s' "$restored_zones_json" | jq -c '[.[].id] | sort') || return 1
	[ "$restored_zone_ids" = "$source_zone_ids" ] || return 1
	printf '%s\n' metadata >"$work/preflight-step"
	restored_metadata=$(compose exec -T powerdns-restored pdnsutil metadata get example.test. ALLOW-AXFR-FROM 2>"$work/preflight.err") || return 1
	[ "$restored_metadata" = "$source_metadata" ] || return 1
	printf '%s\n' forward >"$work/preflight-step"
	[ "$(dns_values "$restored_dns_port" host.shared.example.test. A)" = "$source_forward" ] || return 1
	printf '%s\n' ptr >"$work/preflight-step"
	[ "$(dns_values "$restored_dns_port" 10.2.0.192.in-addr.arpa. PTR)" = "$source_ptr" ] || return 1
	printf '%s\n' passed >"$work/preflight-step"
}

assert_recovery_preflight() {
	if recovery_preflight 2>"$work/preflight-detail.err"; then
		return 0
	fi
	printf '%s\n' 'integration: restored PowerDNS preflight mismatch' >&2
	return 1
}

expect_preflight_rejection() {
	preflight_label=$1
	preflight_stage=$2
	shift 2
	if "$@" >"$work/preflight-rejection.out" 2>"$work/preflight-rejection.err"; then
		fail "$preflight_label unexpectedly passed preflight"
	fi
	grep -Fxq 'integration: restored PowerDNS preflight mismatch' "$work/preflight-rejection.err" || fail "$preflight_label did not report the fixed rejection label"
	[ ! -s "$work/preflight-rejection.out" ] || fail "$preflight_label emitted unexpected output"
	[ "$(sed -n '1p' "$work/preflight-step")" = "$preflight_stage" ] || fail "$preflight_label rejected at the wrong gate"
}

expect_compose_query_rejection() (
	preflight_compose_mode=$1
	compose() {
		case " $* " in
			*' ps --quiet dans-restored '*)
				[ "$preflight_compose_mode" != failed ] || return 1
				printf '%s\n' running
				return 0
				;;
		esac
		docker compose --project-name "$project" --file "$compose_file" "$@"
	}
	expect_preflight_rejection "$preflight_compose_mode Compose query" stopped assert_recovery_preflight
)

assert_dns_contains() {
	name=$1
	type=$2
	value=$3
	answer=$(query_dns "$name" "$type")
	printf '%s\n' "$answer" | grep -Fq "$value" || fail "$name $type answer did not contain $value: $answer"
}

assert_dns_absent() {
	name=$1
	type=$2
	answer=$(query_dns "$name" "$type")
	[ -z "$answer" ] || fail "$name $type unexpectedly answered: $answer"
}

binding_for() {
	zone_name=$1
	cli dans-a "$operator_token" bindings list --zone-name "$zone_name" \
		| jq -er '.items | map(select(.status == "active")) | first | .id'
}

create_delegation() {
	body=$1
	cli_data "$body" dans-a "$operator_token" delegations create
}

preserved_state() {
	compose exec -T postgres psql -X -A -t -v ON_ERROR_STOP=1 -U dans_ddl -d "$1" -c "SELECT md5(jsonb_build_object(
		'identities', (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)) FROM identities t),
		'groups', (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)) FROM groups t),
		'memberships', (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)) FROM group_memberships t),
		'bindings', (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)) FROM zone_bindings t),
		'delegations', (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)) FROM delegations t),
		'selectors', (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)) FROM delegation_selectors t),
		'record_types', (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)) FROM delegation_record_types t),
		'change_kinds', (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)) FROM delegation_change_kinds t),
		'audit', (SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)) FROM audit_events t WHERE action <> 'restore.finalize')
	)::text)"
}

stop_management() {
	compose stop --timeout 10 dans-a dans-b >/dev/null
	management_containers=$(compose ps --quiet dans-a dans-b) || fail 'could not verify source shutdown'
	[ -z "$management_containers" ] || fail 'source instance remains running'
	for service in dans-a dans-b; do
		container=$(compose ps --all --quiet "$service")
		[ -n "$container" ] || fail 'source instance is missing'
		shutdown_status=$(docker inspect --format '{{.State.ExitCode}}' "$container")
		[ "$shutdown_status" != 137 ] || fail 'source shutdown required a forced kill'
	done
	capture_runtime_logs
}

capture_runtime_logs() {
	compose --profile restore logs --no-color dans-a dans-b dans-restored powerdns-restored >>"$work/runtime.log"
}

assert_incompatible() {
	compatibility_label=$1
	wait_for "$compatibility_label readiness A" http_is 503 "$a_root/readyz"
	wait_for "$compatibility_label readiness B" http_is 503 "$b_root/readyz"
	assert_http 503 "$a_root/api/v1/servers/localhost/zones" -H "X-API-Key: $operator_token"
	assert_http 503 "$b_root/api/v1/servers/localhost/zones" -H "X-API-Key: $direct_token"
}

capture_backup_pair() {
	stop_management
	source_zones_json=$(pdns_cli zones list)
	source_zone_ids=$(printf '%s' "$source_zones_json" | jq -c '[.[].id] | sort')
	printf '%s' "$source_zones_json" | jq -e --arg forward "$forward_zone_id" --arg reverse "$reverse_zone_id" \
		'any(.[]; .id == $forward) and any(.[]; .id == $reverse)' >/dev/null || fail 'source PowerDNS zones are incomplete'
	source_metadata=$(compose exec -T powerdns pdnsutil metadata get example.test. ALLOW-AXFR-FROM)
	printf '%s' "$source_metadata" | grep -Fq '192.0.2.0/24' || fail 'source PowerDNS metadata is incomplete'
	source_forward=$(dns_values "$dns_port" host.shared.example.test. A)
	[ "$source_forward" = "$1" ] || fail 'source forward DNS fixture is incomplete'
	source_ptr=$(dns_values "$dns_port" 10.2.0.192.in-addr.arpa. PTR)
	[ "$source_ptr" = host.shared.example.test. ] || fail 'source PTR DNS fixture is incomplete'
	snapshot_sql='SELECT installation_id, (SELECT count(*) FROM identities), (SELECT count(*) FROM groups), (SELECT count(*) FROM delegations), (SELECT count(*) FROM audit_events) FROM installation_metadata'
	source_snapshot=$(compose exec -T postgres psql -X -A -t -F '|' -v ON_ERROR_STOP=1 -U dans_ddl -d dans -c "$snapshot_sql")
	[ -n "$source_snapshot" ] || fail 'source database snapshot is empty'
	source_populated=$(compose exec -T postgres psql -X -A -t -v ON_ERROR_STOP=1 -U dans_ddl -d dans -c 'SELECT EXISTS(SELECT 1 FROM identities) AND EXISTS(SELECT 1 FROM delegations) AND EXISTS(SELECT 1 FROM audit_events)')
	[ "$source_populated" = t ] || fail 'source database lacks restore fixtures'
	source_preserved=$(preserved_state dans)
	token_sql="SELECT md5(COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)), '[]'::jsonb)::text) FROM api_tokens t"
	source_tokens=$(compose exec -T postgres psql -X -A -t -v ON_ERROR_STOP=1 -U dans_ddl -d dans -c "$token_sql")
	compose exec -T postgres sh -c 'umask 077; pg_dump --format=custom -U dans_ddl -d dans --file=/tmp/dans-restore.dump'
	compose exec -T postgres test -s /tmp/dans-restore.dump || fail 'database backup is empty'
	compose stop powerdns >/dev/null
	source_powerdns_container=$(compose ps --all --quiet powerdns)
	[ -n "$source_powerdns_container" ] || fail 'source PowerDNS container is unavailable'
	rm -rf "$work/powerdns"
	mkdir -m 700 "$work/powerdns"
	docker cp "$source_powerdns_container:/var/lib/powerdns/." "$work/powerdns/" >/dev/null
	chmod 600 "$work/powerdns/"*
	[ -s "$work/powerdns/pdns.sqlite3" ] || fail 'PowerDNS backup is empty'
	compose start powerdns >/dev/null
}

restore_backup_pair() {
	compose --profile restore create powerdns-restored >/dev/null
	seed_restored_powerdns
	compose --profile restore start powerdns-restored >/dev/null
	restored_dns_port=$(compose --profile restore port --protocol udp powerdns-restored 53 | awk -F: 'END { print $NF }')
	wait_for 'restored PowerDNS startup' pdns_cli_restored zones list
	assert_recovery_preflight || exit 1
	compose exec -T postgres createdb -U dans_ddl -O dans_ddl dans_restored
	compose exec -T postgres pg_restore --exit-on-error --no-owner --no-acl -U dans_ddl -d dans_restored /tmp/dans-restore.dump
	compose exec -T postgres rm -f /tmp/dans-restore.dump
	compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U dans_ddl -d dans_restored \
		--set=database_name=dans_restored --set=schema_name=public --set=runtime_role=dans_runtime \
		--file=- <"$1" >/dev/null
	restored_snapshot=$(compose exec -T postgres psql -X -A -t -F '|' -v ON_ERROR_STOP=1 -U dans_ddl -d dans_restored -c "$snapshot_sql")
	[ "$restored_snapshot" = "$source_snapshot" ] || fail 'restored identity, authority, or audit state differs from backup'
	restored_preserved=$(preserved_state dans_restored)
	[ "$restored_preserved" = "$source_preserved" ] || fail 'restored identity, authority, or audit state differs from backup'
	restored_tokens=$(compose exec -T postgres psql -X -A -t -v ON_ERROR_STOP=1 -U dans_ddl -d dans_restored -c "$token_sql")
	[ "$restored_tokens" = "$source_tokens" ] || fail 'restored credentials differ from backup'
}

finalize_restored_pair() {
	preexisting_finalizations=$(compose exec -T postgres psql -X -A -t -v ON_ERROR_STOP=1 -U dans_ddl -d dans_restored -c "SELECT count(*) FROM audit_events WHERE action = 'restore.finalize'")
	[ "$preexisting_finalizations" -eq 0 ] || fail 'restored fixture already contains a finalization event'
	historical_audit_id=$(compose exec -T postgres psql -X -A -t -v ON_ERROR_STOP=1 -U dans_ddl -d dans_restored -c 'SELECT id FROM audit_events ORDER BY occurred_at, id LIMIT 1')
	preserved_before=$restored_preserved

	if restore_result=$(compose run --rm --no-deps -T \
		-e DANS_DATABASE_URL='postgres://dans_runtime:dans-runtime@postgres/dans_restored?sslmode=disable' \
		-e DANS_OUTPUT=json dans-a restore finalize --handle operator --token-label restored --confirm 2>"$work/restore-finalize.err"); then
		:
	else
		fail 'restore finalization failed'
	fi
	operator_id=$(printf '%s' "$bootstrap" | jq -er '.identity_id')
	restored_operator_id=$(printf '%s' "$restore_result" | jq -er '.identity_id')
	[ "$restored_operator_id" = "$operator_id" ] || fail 'restore finalization changed operator identity'
	replacement_token=$(printf '%s' "$restore_result" | jq -er '.secret')
	unset restore_result
	active_tokens=$(compose exec -T postgres psql -X -A -t -v ON_ERROR_STOP=1 -U dans_ddl -d dans_restored -c 'SELECT count(*) FROM api_tokens WHERE revoked_at IS NULL')
	[ "$active_tokens" -eq 1 ] || fail 'restore finalization did not leave exactly one active credential'
	preserved_after=$(preserved_state dans_restored)
	[ "$preserved_after" = "$preserved_before" ] || fail 'restore finalization changed historical identity, authorization, or audit state'
	finalization_events=$(compose exec -T postgres psql -X -A -t -v ON_ERROR_STOP=1 -U dans_ddl -d dans_restored -c "SELECT count(*) FROM audit_events WHERE action = 'restore.finalize'")
	[ "$finalization_events" -eq 1 ] || fail 'restore finalization did not append exactly one audit event'

	compose --profile restore up --detach dans-restored >/dev/null
	restored_port=$(compose --profile restore port dans-restored 8080 | awk -F: 'END { print $NF }')
	restored_root=http://127.0.0.1:$restored_port
	wait_for 'restored DANS readiness' http_is 200 "$restored_root/readyz"
	restored_me=$(cli dans-restored "$replacement_token" me get)
	printf '%s' "$restored_me" | jq -e --arg id "$operator_id" '.id == $id and .enabled == true and .operator == true' >/dev/null || fail 'replacement credential lacks the original operator identity'
	for token in "$operator_token" "$direct_token" "$group_token"; do
		expect_cli_error 'restored credential' '401 Unauthorized' dans-restored "$token" me get
	done
	restored_identity=$(cli dans-restored "$replacement_token" identities get "$direct_id")
	printf '%s' "$restored_identity" | jq -e --arg id "$direct_id" '.id == $id' >/dev/null || fail 'restored identity is unavailable through the public API'
	restored_group=$(cli dans-restored "$replacement_token" groups get "$group_id")
	printf '%s' "$restored_group" | jq -e --arg id "$group_id" '.id == $id' >/dev/null || fail 'restored group is unavailable through the public API'
	restored_delegation=$(cli dans-restored "$replacement_token" delegations get "$direct_delegation_id")
	printf '%s' "$restored_delegation" | jq -e --arg id "$direct_delegation_id" '.id == $id' >/dev/null || fail 'restored delegation is unavailable through the public API'
	restored_audit=$(cli dans-restored "$replacement_token" audit export)
	printf '%s' "$restored_audit" | jq -se --arg id "$historical_audit_id" '[.[] | select(.id == $id)] | length == 1' >/dev/null || fail 'historical audit event is unavailable through the public API'
	restored_zone=$(cli dans-restored "$replacement_token" zones get "$forward_zone_id")
	printf '%s' "$restored_zone" | jq -e --arg id "$forward_zone_id" '.id == $id' >/dev/null || fail 'restored zone is unavailable through the public API'
	restored_change='{"rrsets":[{"changetype":"REPLACE","name":"host.shared.example.test.","type":"A","ttl":180,"records":[{"content":"192.0.2.48"}]}]}'
	cli_data "$restored_change" dans-restored "$replacement_token" rrsets apply "$forward_zone_id" >/dev/null
	[ "$(dns_values "$restored_dns_port" host.shared.example.test. A)" = 192.0.2.48 ] || fail 'restored DANS write did not reach restored DNS'
	[ "$(dns_values "$dns_port" host.shared.example.test. A)" = "$source_forward" ] || fail 'restored DANS write changed source DNS'
}

printf '%s\n' "integration: PostgreSQL $major_minor"
mark_phase setup
compose build dans-a
git -C "$root" cat-file -e "$previous_revision^{commit}" 2>/dev/null || fail 'historical build source is missing; use a checkout with full history'
git -C "$root" archive --output="$work/previous.tar" "$previous_revision"
mkdir "$work/previous"
tar -xf "$work/previous.tar" -C "$work/previous"
docker build --build-arg VERSION=upgrade-baseline --tag "$previous_image" "$work/previous"
footprint_container=$(docker container create "$DANS_IMAGE" version)
rootfs_bytes=$(docker container inspect --size --format '{{.SizeRootFs}}' "$footprint_container")
"$root/scripts/footprint.sh" image-rootfs-bytes "$rootfs_bytes" 'OCI root filesystem'
docker container rm "$footprint_container" >/dev/null
footprint_container=
printf '%s\n' "integration: OCI root filesystem $rootfs_bytes bytes"
mark_phase services
compose up --detach postgres powerdns toxiproxy redis
wait_for PostgreSQL compose exec -T postgres pg_isready -h 127.0.0.1 -U dans_ddl -d dans
toxiproxy create --listen 0.0.0.0:18081 --upstream powerdns:8081 powerdns >/dev/null
toxiproxy create --listen 0.0.0.0:16379 --upstream redis:6379 redis >/dev/null

export DANS_IMAGE=$previous_image
compose run --rm --no-deps -T \
	-e DANS_DATABASE_URL='postgres://dans_ddl:dans-ddl@postgres/dans?sslmode=disable' \
	-e DANS_OUTPUT=json dans-a db migrate >/dev/null
compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U dans_ddl -d dans \
	--set=database_name=dans --set=schema_name=public --set=runtime_role=dans_runtime \
	--file=- <"$work/previous/internal/database/privileges/runtime.sql" >/dev/null
previous_schema=$(compose run --rm --no-deps -T -e DANS_OUTPUT=json dans-a db status)
printf '%s' "$previous_schema" | jq -e '.current_version == 1 and .compatible == true' >/dev/null || fail 'historical migration ledger is incompatible'
bootstrap=$(compose run --rm --no-deps -T -e DANS_OUTPUT=json dans-a bootstrap \
	--handle operator --display-name 'Integration operator' --token-label integration)
operator_token=$(printf '%s' "$bootstrap" | jq -er '.secret')

compose up --detach dans-a dans-b
a_port=$(compose port dans-a 8080 | awk -F: 'END { print $NF }')
b_port=$(compose port dans-b 8080 | awk -F: 'END { print $NF }')
dns_port=$(compose port --protocol udp powerdns 53 | awk -F: 'END { print $NF }')
a_root=http://127.0.0.1:$a_port
b_root=http://127.0.0.1:$b_port
wait_for 'DANS A readiness' http_is 200 "$a_root/readyz"
wait_for 'DANS B readiness' http_is 200 "$b_root/readyz"

mark_phase exercise
forward_zone=$(cli_data '{"name":"example.test.","kind":"Native","nameservers":["ns1.example.test."]}' dans-a "$operator_token" zones create)
forward_zone_id=$(printf '%s' "$forward_zone" | jq -er '.id')
forward_binding=$(binding_for example.test.)
reverse_zone=$(cli_data '{"name":"2.0.192.in-addr.arpa.","kind":"Native","nameservers":["ns1.example.test."]}' dans-b "$operator_token" zones create)
reverse_zone_id=$(printf '%s' "$reverse_zone" | jq -er '.id')
reverse_binding=$(binding_for 2.0.192.in-addr.arpa.)

direct_identity=$(cli_data '{"kind":"user","handle":"direct-user","display_name":"Direct user"}' dans-a "$operator_token" identities create)
direct_id=$(printf '%s' "$direct_identity" | jq -er '.id')
direct_credential=$(cli_data '{"label":"integration"}' dans-b "$operator_token" identities tokens create "$direct_id")
direct_token=$(printf '%s' "$direct_credential" | jq -er '.secret')
group_identity=$(cli_data '{"kind":"service","handle":"group-service"}' dans-b "$operator_token" identities create)
group_identity_id=$(printf '%s' "$group_identity" | jq -er '.id')
group_credential=$(cli_data '{"label":"integration"}' dans-a "$operator_token" identities tokens create "$group_identity_id")
group_token=$(printf '%s' "$group_credential" | jq -er '.secret')
group=$(cli_data '{"handle":"dns-team","display_name":"DNS team"}' dans-a "$operator_token" groups create)
group_id=$(printf '%s' "$group" | jq -er '.id')
cli dans-b "$operator_token" groups members add "$group_id" "$group_identity_id" >/dev/null
cli dans-b "$operator_token" groups members add "$group_id" "$direct_id" >/dev/null

direct_body=$(printf '{"zone_binding_id":"%s","identity_id":"%s","selectors":[{"kind":"glob","value":"*.shared.example.test."}],"record_types":["A"],"change_kinds":["REPLACE","DELETE","EXTEND","PRUNE"]}' "$forward_binding" "$direct_id")
direct_delegation=$(create_delegation "$direct_body")
direct_delegation_id=$(printf '%s' "$direct_delegation" | jq -er '.id')
overlap_body=$(printf '{"zone_binding_id":"%s","group_id":"%s","selectors":[{"kind":"exact","value":"host.shared.example.test."}],"record_types":["A"]}' "$forward_binding" "$group_id")
create_delegation "$overlap_body" >/dev/null
ptr_body=$(printf '{"zone_binding_id":"%s","group_id":"%s","selectors":[{"kind":"exact","value":"10.2.0.192.in-addr.arpa."}],"record_types":["PTR"]}' "$reverse_binding" "$group_id")
create_delegation "$ptr_body" >/dev/null
replace_body='{"rrsets":[{"changetype":"REPLACE","name":"host.shared.example.test.","type":"A","ttl":120,"records":[{"content":"192.0.2.10"}],"comments":[{"account":"integration","content":"delegated forward RRset"}]}]}'
cli_data "$replace_body" dans-a "$direct_token" rrsets apply "$forward_zone_id" >/dev/null
ptr_replace='{"rrsets":[{"changetype":"REPLACE","name":"10.2.0.192.in-addr.arpa.","type":"PTR","ttl":300,"records":[{"content":"host.shared.example.test."}]}]}'
cli_data "$ptr_replace" dans-b "$group_token" rrsets apply "$reverse_zone_id" >/dev/null
metadata='{"kind":"ALLOW-AXFR-FROM","metadata":["192.0.2.0/24"]}'
assert_http 200 "$a_root/api/v1/servers/localhost/zones/$forward_zone_id/metadata/ALLOW-AXFR-FROM" \
	-X PUT -H 'Content-Type: application/json' -H "X-API-Key: $operator_token" --data "$metadata"

mark_phase upgrade
capture_backup_pair 192.0.2.10
export DANS_IMAGE=$target_image
compose up --detach --no-build dans-a dans-b >/dev/null
assert_incompatible 'target before migration'
stop_management
compose run --rm --no-deps -T \
	-e DANS_DATABASE_URL='postgres://dans_ddl:dans-ddl@postgres/dans?sslmode=disable' \
	-e DANS_OUTPUT=json dans-a db migrate >/dev/null
compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U dans_ddl -d dans \
	--set=database_name=dans --set=schema_name=public --set=runtime_role=dans_runtime \
	--file=/dans/runtime.sql >/dev/null
[ "$(preserved_state dans)" = "$source_preserved" ] || fail 'upgrade changed historical policy or audit data'
upgraded_tokens=$(compose exec -T postgres psql -X -A -t -v ON_ERROR_STOP=1 -U dans_ddl -d dans -c "$token_sql")
[ "$upgraded_tokens" = "$source_tokens" ] || fail 'upgrade changed existing credentials'
export DANS_IMAGE=$previous_image
compose up --detach --no-build dans-a dans-b >/dev/null
assert_incompatible 'older binary after migration'
stop_management
export DANS_IMAGE=$target_image
compose up --detach --no-build dans-a dans-b >/dev/null
wait_for 'upgraded DANS A readiness' http_is 200 "$a_root/readyz"
wait_for 'upgraded DANS B readiness' http_is 200 "$b_root/readyz"
upgraded_schema=$(compose run --rm --no-deps -T -e DANS_OUTPUT=json dans-a db status)
printf '%s' "$upgraded_schema" | jq -e '.current_version == 3 and .compatible == true' >/dev/null || fail 'target migration ledger is incompatible'
for token in "$operator_token" "$direct_token" "$group_token"; do
	cli dans-a "$token" me get >/dev/null
	cli dans-b "$token" me get >/dev/null
done
assert_dns_contains host.shared.example.test. A "$source_forward"
assert_dns_contains 10.2.0.192.in-addr.arpa. PTR "$source_ptr"
upgrade_change='{"rrsets":[{"changetype":"REPLACE","name":"upgrade.shared.example.test.","type":"A","ttl":120,"records":[{"content":"192.0.2.49"}]}]}'
cli_data "$upgrade_change" dans-b "$direct_token" rrsets apply "$forward_zone_id" >/dev/null
assert_dns_contains upgrade.shared.example.test. A 192.0.2.49

mark_phase rollback
export DANS_IMAGE=$previous_image
restore_backup_pair "$work/previous/internal/database/privileges/runtime.sql"
finalize_restored_pair
[ -z "$(dns_values "$restored_dns_port" upgrade.shared.example.test. A)" ] || fail 'rollback retained a post-backup DNS change'
rollback_token=$replacement_token
compose --profile restore stop --timeout 10 dans-restored powerdns-restored >/dev/null
capture_runtime_logs
compose --profile restore rm --force --stop dans-restored powerdns-restored >/dev/null
compose exec -T postgres dropdb -U dans_ddl dans_restored
export DANS_IMAGE=$target_image
cli dans-a "$operator_token" me get >/dev/null
assert_dns_contains upgrade.shared.example.test. A 192.0.2.49

if [ "$(uname -s)" = Linux ]; then
	for service in dans-a dans-b; do
		container=$(compose ps --quiet "$service")
		pid=$(docker inspect --format '{{.State.Pid}}' "$container")
		[ -r "/proc/$pid/status" ] || fail "local Docker PID $pid for $service is not readable in host /proc"
		maximum_rss_kib=0
		for sample in 1 2 3 4 5; do
			rss_kib=$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status")
			[ -n "$rss_kib" ] || fail "could not measure $service VmRSS sample $sample"
			"$root/scripts/footprint.sh" rss-kib "$rss_kib" "$service"
			[ "$rss_kib" -le "$maximum_rss_kib" ] || maximum_rss_kib=$rss_kib
		done
		printf '%s\n' "integration: $service ready-idle VmRSS max $maximum_rss_kib KiB across 5 samples"
	done
else
	printf '%s\n' 'integration: ready-idle VmRSS gate runs on native-Linux CI only'
fi

if [ -n "${DANS_QA_PERFORMANCE_DIR:-}" ]; then
	mark_phase measurement
	"$root/scripts/measure-runtime.sh" "$compose_file" "$project" dans-a "$a_root" "$DANS_QA_PERFORMANCE_DIR"
fi

mark_phase exercise
forward_rrset=$(cli dans-b "$direct_token" rrsets get "$forward_zone_id" host.shared.example.test. A)
printf '%s' "$forward_rrset" | jq -e '.ttl == 120 and .comments[0].content == "delegated forward RRset"' >/dev/null || fail 'forward RRset lost TTL or comments'
assert_dns_contains host.shared.example.test. A 192.0.2.10
cli dans-b "$direct_token" rrsets add-value "$forward_zone_id" host.shared.example.test. A 192.0.2.11 --ttl 120 >/dev/null
assert_dns_contains host.shared.example.test. A 192.0.2.11
cli dans-a "$direct_token" rrsets remove-value "$forward_zone_id" host.shared.example.test. A 192.0.2.10 --ttl 120 >/dev/null
assert_dns_absent_value=$(query_dns host.shared.example.test. A)
printf '%s\n' "$assert_dns_absent_value" | grep -Fq 192.0.2.10 && fail 'PRUNE retained the removed value'
cli dans-b "$direct_token" rrsets delete "$forward_zone_id" host.shared.example.test. A --confirm >/dev/null
assert_dns_absent host.shared.example.test. A

cli_data "$ptr_replace" dans-b "$group_token" rrsets apply "$reverse_zone_id" >/dev/null
ptr_answer=$(dig @127.0.0.1 -p "$dns_port" +time=2 +tries=1 +noall +answer -x 192.0.2.10)
printf '%s\n' "$ptr_answer" | grep -Fq host.shared.example.test. || fail "PTR query did not return delegated target: $ptr_answer"

apex_change='{"rrsets":[{"changetype":"REPLACE","name":"shared.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.20"}]}]}'
expect_cli_data_error 'glob apex write' '403 Forbidden' "$apex_change" dans-a "$direct_token" rrsets apply "$forward_zone_id"
wildcard_change='{"rrsets":[{"changetype":"REPLACE","name":"*.shared.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.21"}]}]}'
expect_cli_data_error 'glob literal-wildcard write' '403 Forbidden' "$wildcard_change" dans-b "$direct_token" rrsets apply "$forward_zone_id"
mixed_change='{"rrsets":[{"changetype":"REPLACE","name":"batch.shared.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.30"}]},{"changetype":"REPLACE","name":"forbidden.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.31"}]}]}'
expect_cli_data_error 'mixed RRset batch' '403 Forbidden' "$mixed_change" dans-a "$direct_token" rrsets apply "$forward_zone_id"
assert_dns_absent batch.shared.example.test. A

cli dans-b "$group_token" zones list >/dev/null
expect_cli_error 'non-operator identity administration' '403 Forbidden' dans-a "$direct_token" identities list
expect_cli_error 'non-operator audit visibility' '403 Forbidden' dans-b "$group_token" audit list
assert_http 403 "$a_root/api/v1/servers/localhost/tsigkeys" -H "X-API-Key: $direct_token"
assert_http 403 "$b_root/api/v1/servers/localhost/config" -H "X-API-Key: $group_token"

assert_http 200 "$a_root/api/v1/servers/localhost/zones/$forward_zone_id/metadata/ALLOW-AXFR-FROM" \
	-X PUT -H 'Content-Type: application/json' -H "X-API-Key: $operator_token" --data "$metadata"
assert_http 200 "$b_root/api/v1/servers/localhost/zones/$forward_zone_id/metadata/ALLOW-AXFR-FROM" \
	-H "X-API-Key: $operator_token"
jq -e '.kind == "ALLOW-AXFR-FROM" and .metadata == ["192.0.2.0/24"]' "$work/http-body" >/dev/null || fail 'PowerDNS metadata PUT body was not preserved'

unbound_zone=$(pdns_cli_data '{"name":"unbound.test.","kind":"Native","nameservers":["ns1.example.test."]}' zones create)
unbound_zone_id=$(printf '%s' "$unbound_zone" | jq -er '.id')
unbound_bindings=$(cli dans-a "$operator_token" bindings list --zone-name unbound.test.)
printf '%s' "$unbound_bindings" | jq -e '.items | length == 0' >/dev/null || fail 'direct PowerDNS setup unexpectedly created a DANS binding'
cli dans-b "$operator_token" zones delete "$unbound_zone_id" --confirm >/dev/null
if pdns_cli zones get "$unbound_zone_id" >"$work/cli-out" 2>"$work/cli-err"; then
	fail 'existing unbound PowerDNS zone remained after operator deletion'
fi
grep -Fq '404' "$work/cli-err" || fail "deleted unbound PowerDNS zone did not report 404 upstream: $(tr '\n' ' ' <"$work/cli-err")"

cli_data "$replace_body" dans-a "$direct_token" rrsets apply "$forward_zone_id" >/dev/null
successful_audit=$(cli dans-b "$operator_token" audit list --result succeeded)
printf '%s' "$successful_audit" | jq -e '.items | any(.action == "powerdns.zone.patch")' >/dev/null || fail 'successful DNS mutation audit outcome is missing'

missing_change='{"rrsets":[{"changetype":"REPLACE","name":"host.missing.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.40"}]}]}'
expect_cli_data_error 'definite upstream failure' '404' "$missing_change" dans-a "$operator_token" rrsets apply missing.test.
failed_audit=$(cli dans-a "$operator_token" audit list --result failed)
printf '%s' "$failed_audit" | jq -e '.items | any(.action == "powerdns.zone.patch")' >/dev/null || fail 'failed DNS mutation audit outcome is missing'

timeout_change='{"rrsets":[{"changetype":"REPLACE","name":"timeout.shared.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.41"}]}]}'
toxiproxy toxic add --type latency --downstream --toxicName response-timeout --attribute latency=5000 powerdns >/dev/null
expect_cli_data_error 'ambiguous upstream response' '504 Gateway Timeout' "$timeout_change" dans-b "$direct_token" rrsets apply "$forward_zone_id"
toxiproxy toxic remove --toxicName response-timeout powerdns >/dev/null
assert_dns_contains timeout.shared.example.test. A 192.0.2.41
unknown_audit=$(cli dans-a "$operator_token" audit list --result unknown)
printf '%s' "$unknown_audit" | jq -e '.items | any(.action == "powerdns.zone.patch")' >/dev/null || fail 'unknown DNS mutation audit outcome is missing'

audit_failure_change='{"rrsets":[{"changetype":"REPLACE","name":"auditfail.shared.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.42"}]}]}'
toxiproxy toxic add --type latency --downstream --toxicName outcome-delay --attribute latency=1500 powerdns >/dev/null
cli_data "$audit_failure_change" dans-a "$direct_token" rrsets apply "$forward_zone_id" >"$work/audit-failure-out" 2>"$work/audit-failure-err" &
mutation_pid=$!
pending_intent() {
	count=$(compose exec -T postgres psql -X -At -U dans_ddl -d dans -c "SELECT count(*) FROM audit_events AS intent WHERE event_kind = 'dns_intent' AND NOT EXISTS (SELECT 1 FROM audit_events AS outcome WHERE outcome.operation_id = intent.operation_id AND outcome.event_kind = 'dns_outcome')")
	[ "$count" -gt 0 ]
}
wait_for 'persisted mutation intent' pending_intent
compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U dans_ddl -d dans -c 'REVOKE INSERT ON TABLE audit_events FROM dans_runtime' >/dev/null
if ! wait "$mutation_pid"; then
	fail "observed PowerDNS response was rewritten after outcome persistence failed: $(tr '\n' ' ' <"$work/audit-failure-err")"
fi
toxiproxy toxic remove --toxicName outcome-delay powerdns >/dev/null
wait_for 'audit failure readiness degradation' http_is 503 "$a_root/readyz"
compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U dans_ddl -d dans -c 'GRANT INSERT ON TABLE audit_events TO dans_runtime' >/dev/null
wait_for 'audit persistence recovery' http_is 200 "$a_root/readyz"
assert_dns_contains auditfail.shared.example.test. A 192.0.2.42
pending_audit=$(cli dans-b "$operator_token" audit list --result pending)
printf '%s' "$pending_audit" | jq -e '.items | any(.action == "powerdns.zone.patch")' >/dev/null || fail 'unmatched audit intent was not preserved'

db_failure_change='{"rrsets":[{"changetype":"REPLACE","name":"dbdown.shared.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.43"}]}]}'
compose pause postgres >/dev/null
wait_for 'database outage readiness' http_is 503 "$b_root/readyz"
expect_cli_data_error 'database outage authorization' '503 Service Unavailable' "$db_failure_change" dans-a "$direct_token" rrsets apply "$forward_zone_id"
compose unpause postgres >/dev/null
wait_for 'database recovery' http_is 200 "$a_root/readyz"
assert_dns_absent dbdown.shared.example.test. A

powerdns_failure_change='{"rrsets":[{"changetype":"REPLACE","name":"pdnsdown.shared.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.44"}]}]}'
toxiproxy toggle powerdns >/dev/null
wait_for 'PowerDNS outage readiness' http_is 503 "$a_root/readyz"
expect_cli_data_error 'transient PowerDNS outage after compatibility success' '502 Bad Gateway' "$powerdns_failure_change" dans-b "$direct_token" rrsets apply "$forward_zone_id"
toxiproxy toggle powerdns >/dev/null
wait_for 'PowerDNS recovery' http_is 200 "$b_root/readyz"
assert_dns_absent pdnsdown.shared.example.test. A

compose --profile faults up --detach dans-bad-key
bad_port=$(compose --profile faults port dans-bad-key 8080 | awk -F: 'END { print $NF }')
bad_root=http://127.0.0.1:$bad_port
wait_for 'rejected-key readiness' http_is 503 "$bad_root/readyz"
assert_http 503 "$bad_root/api/v1/servers/localhost/zones" -H "X-API-Key: $operator_token"
compose --profile faults stop dans-bad-key >/dev/null

compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U dans_ddl -d dans -c "INSERT INTO schema_migrations (version, name, checksum) VALUES (99, 'fault', repeat('0', 64))" >/dev/null
wait_for 'schema mismatch readiness' http_is 503 "$a_root/readyz"
assert_http 503 "$a_root/api/v1/servers/localhost/zones" -H "X-API-Key: $operator_token"
compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U dans_ddl -d dans -c 'DELETE FROM schema_migrations WHERE version = 99' >/dev/null
wait_for 'schema recovery' http_is 200 "$a_root/readyz"

revoked_body=$(printf '{"zone_binding_id":"%s","identity_id":"%s","selectors":[{"kind":"exact","value":"revoked.example.test."}],"record_types":["A"]}' "$forward_binding" "$direct_id")
revoked_delegation=$(create_delegation "$revoked_body")
revoked_delegation_id=$(printf '%s' "$revoked_delegation" | jq -er '.id')
revoked_change='{"rrsets":[{"changetype":"REPLACE","name":"revoked.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.45"}]}]}'
cli_data "$revoked_change" dans-a "$direct_token" rrsets apply "$forward_zone_id" >/dev/null
cli dans-a "$operator_token" delegations revoke "$revoked_delegation_id" >/dev/null
revoked_second='{"rrsets":[{"changetype":"REPLACE","name":"revoked.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.46"}]}]}'
expect_cli_data_error 'cross-instance delegation revocation' '403 Forbidden' "$revoked_second" dans-b "$direct_token" rrsets apply "$forward_zone_id"
assert_dns_contains revoked.example.test. A 192.0.2.45
revoked_answer=$(query_dns revoked.example.test. A)
printf '%s\n' "$revoked_answer" | grep -Fq 192.0.2.46 && fail 'cross-instance revocation allowed a later value'

cli dans-b "$operator_token" delegations revoke "$direct_delegation_id" >/dev/null
overlap_change='{"rrsets":[{"changetype":"REPLACE","name":"host.shared.example.test.","type":"A","ttl":180,"records":[{"content":"192.0.2.47"}]}]}'
cli_data "$overlap_change" dans-a "$direct_token" rrsets apply "$forward_zone_id" >/dev/null
assert_dns_contains host.shared.example.test. A 192.0.2.47

lifecycle_zone=$(cli_data '{"name":"lifecycle.test.","kind":"Native","nameservers":["ns1.example.test."]}' dans-a "$operator_token" zones create)
lifecycle_zone_id=$(printf '%s' "$lifecycle_zone" | jq -er '.id')
lifecycle_binding=$(binding_for lifecycle.test.)
lifecycle_grant_body=$(printf '{"zone_binding_id":"%s","identity_id":"%s","selectors":[{"kind":"exact","value":"host.lifecycle.test."}],"record_types":["A"]}' "$lifecycle_binding" "$direct_id")
lifecycle_grant=$(create_delegation "$lifecycle_grant_body")
lifecycle_grant_id=$(printf '%s' "$lifecycle_grant" | jq -er '.id')
lifecycle_change='{"rrsets":[{"changetype":"REPLACE","name":"host.lifecycle.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.50"}]}]}'
cli_data "$lifecycle_change" dans-b "$direct_token" rrsets apply "$lifecycle_zone_id" >/dev/null
cli dans-a "$operator_token" zones delete "$lifecycle_zone_id" --confirm >/dev/null
retired_binding=$(cli dans-b "$operator_token" bindings get "$lifecycle_binding")
printf '%s' "$retired_binding" | jq -e '.status == "retired"' >/dev/null || fail 'zone deletion did not retire its binding'
retired_grant=$(cli dans-a "$operator_token" delegations get "$lifecycle_grant_id")
printf '%s' "$retired_grant" | jq -e '.revoked_at != null' >/dev/null || fail 'zone deletion did not revoke its grants'
recreated=$(cli_data '{"name":"lifecycle.test.","kind":"Native","nameservers":["ns1.example.test."]}' dans-b "$operator_token" zones create)
recreated_zone_id=$(printf '%s' "$recreated" | jq -er '.id')
recreated_binding=$(binding_for lifecycle.test.)
[ "$recreated_binding" != "$lifecycle_binding" ] || fail 'same-name recreation reused a retired binding'
expect_cli_data_error 'same-name recreation inherited an old grant' '403 Forbidden' "$lifecycle_change" dans-a "$direct_token" rrsets apply "$recreated_zone_id"

reconcile_zone=$(cli_data '{"name":"reconcile.test.","kind":"Native","nameservers":["ns1.example.test."]}' dans-a "$operator_token" zones create)
reconcile_zone_id=$(printf '%s' "$reconcile_zone" | jq -er '.id')
reconcile_binding=$(binding_for reconcile.test.)
reconcile_grant_body=$(printf '{"zone_binding_id":"%s","identity_id":"%s","selectors":[{"kind":"exact","value":"host.reconcile.test."}],"record_types":["A"]}' "$reconcile_binding" "$direct_id")
create_delegation "$reconcile_grant_body" >/dev/null
reconcile_change='{"rrsets":[{"changetype":"REPLACE","name":"host.reconcile.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.51"}]}]}'
cli_data "$reconcile_change" dans-b "$direct_token" rrsets apply "$reconcile_zone_id" >/dev/null
toxiproxy toggle powerdns >/dev/null
expect_cli_error 'unknown zone deletion' '502 Bad Gateway' dans-a "$operator_token" zones delete "$reconcile_zone_id" --confirm
toxiproxy toggle powerdns >/dev/null
wait_for 'PowerDNS recovery after deletion fault' http_is 200 "$a_root/readyz"
delete_intents_before=$(cli dans-a "$operator_token" audit list --action powerdns.zone.delete --result pending --limit 500 | jq -er '.items | length')
expect_cli_error 'retired binding repeat deletion' '409 Conflict' dans-b "$operator_token" zones delete "$reconcile_zone_id" --confirm
delete_intents_after=$(cli dans-b "$operator_token" audit list --action powerdns.zone.delete --result pending --limit 500 | jq -er '.items | length')
[ "$delete_intents_after" = "$delete_intents_before" ] || fail 'retired binding repeat deletion created another DNS intent'
observation=$(cli dans-b "$operator_token" bindings observe "$reconcile_binding")
printf '%s' "$observation" | jq -e '.zone_present == true' >/dev/null || fail 'reconciliation did not observe the retained upstream zone'
rebound_body=$(printf '{"zone_id":"%s"}' "$reconcile_zone_id")
rebound=$(cli_data "$rebound_body" dans-a "$operator_token" bindings rebind "$reconcile_binding")
rebound_id=$(printf '%s' "$rebound" | jq -er '.id')
[ "$rebound_id" != "$reconcile_binding" ] || fail 'rebind reused the retired binding'
expect_cli_data_error 'rebind inherited an old grant' '403 Forbidden' "$reconcile_change" dans-b "$direct_token" rrsets apply "$reconcile_zone_id"

assert_http 200 "$a_root/api/docs" -H "X-API-Key: $operator_token"
jq -e '[.paths | keys[] | select(test("/(test|fault|seed|reset|introspect|metrics|pprof|profil|benchmark)(/|$)"; "i"))] | length == 0' "$work/http-body" >/dev/null || fail 'served production contract exposes a test-only route'
for path in test/seed fault reset introspect metrics pprof profiling benchmark; do
	assert_http 404 "$b_root/api/v1/dans/$path"
done
assert_http 404 "$b_root/metrics"
assert_http 404 "$b_root/debug/pprof/"
compose run --rm --no-deps -T cli --help >"$work/help"
if grep -Eqi '(^|[[:space:]])(seed|reset|fault|introspect|metrics|pprof|profil|benchmark)([[:space:]]|$)' "$work/help"; then
	fail 'production CLI exposes a test-only command'
fi

mark_phase ratelimit
# A tight-policy pair shares the generous pair's Redis. Scenario identities
# talk only to the tight pair so generous refills never touch their buckets.
compose --profile ratelimit up --detach dans-rl-a dans-rl-b
rl_a_root=http://127.0.0.1:$(compose --profile ratelimit port dans-rl-a 8080 | awk -F: 'END { print $NF }')
rl_b_root=http://127.0.0.1:$(compose --profile ratelimit port dans-rl-b 8080 | awk -F: 'END { print $NF }')
wait_for 'rate-limited DANS A readiness' http_is 200 "$rl_a_root/readyz"
wait_for 'rate-limited DANS B readiness' http_is 200 "$rl_b_root/readyz"
rl_started=$(docker inspect --format '{{.State.StartedAt}}' "$(compose --profile ratelimit ps --quiet dans-rl-a)" "$(compose --profile ratelimit ps --quiet dans-rl-b)")

rate_reader=$(cli_data '{"kind":"service","handle":"rate-reader"}' dans-a "$operator_token" identities create)
rate_reader_id=$(printf '%s' "$rate_reader" | jq -er '.id')
rate_reader_token=$(cli_data '{"label":"integration"}' dans-a "$operator_token" identities tokens create "$rate_reader_id" | jq -er '.secret')
rate_writer=$(cli_data '{"kind":"service","handle":"rate-writer"}' dans-a "$operator_token" identities create)
rate_writer_id=$(printf '%s' "$rate_writer" | jq -er '.id')
rate_writer_token=$(cli_data '{"label":"integration"}' dans-a "$operator_token" identities tokens create "$rate_writer_id" | jq -er '.secret')
rate_writer_body=$(printf '{"zone_binding_id":"%s","identity_id":"%s","selectors":[{"kind":"glob","value":"*.rate.example.test."}],"record_types":["A"]}' "$forward_binding" "$rate_writer_id")
create_delegation "$rate_writer_body" >/dev/null

rate_status() {
	curl --silent --max-time 5 --output /dev/null --write-out '%{http_code}\n' -H "X-API-Key: $2" "$1/api/v1/servers/localhost/zones" || true
}
rate_patch() {
	curl --silent --max-time 5 --dump-header "$work/rate-headers" --output "$work/rate-body" --write-out '%{http_code}' \
		-X PATCH -H 'Content-Type: application/json' -H "X-API-Key: $rate_writer_token" --data "$2" \
		"$1/api/v1/servers/localhost/zones/$forward_zone_id" || true
}
rate_tokens() {
	compose exec -T redis redis-cli HGET "dans:rl:{$1}:$2" t
}
rate_key_absent() {
	[ "$(compose exec -T redis redis-cli EXISTS "dans:rl:{$1}:$2")" = 0 ]
}
rate_header() {
	tr -d '\r' <"$work/rate-headers" | awk -v name="$1" 'tolower($0) ~ "^" tolower(name) ":" { sub(/^[^:]*:[[:space:]]*/, ""); print }'
}
rate_count() {
	grep -Fxc "$1" "$work/rate-codes" || true
}

# Concurrent requests across both instances never overspend the identity bucket.
rate_burst_started=$(date +%s)
seq 1 120 | xargs -P 16 -I '{}' sh -c 'if [ $(( $1 % 2 )) -eq 0 ]; then root=$2; else root=$3; fi; curl --silent --max-time 5 --output /dev/null --write-out "%{http_code}\n" -H "X-API-Key: $4" "$root/api/v1/servers/localhost/zones" || true' \
	_ '{}' "$rl_a_root" "$rl_b_root" "$rate_reader_token" >"$work/rate-codes"
rate_burst_elapsed=$(( $(date +%s) - rate_burst_started + 1 ))
rate_admitted=$(rate_count 200)
rate_throttled=$(rate_count 429)
[ "$(( rate_admitted + rate_throttled ))" -eq 120 ] || fail "concurrent rate-limit burst returned unexpected statuses: $(sort "$work/rate-codes" | uniq -c | tr '\n' ' ')"
[ "$rate_admitted" -ge 30 ] || fail "concurrent burst admitted $rate_admitted requests, below the 30-token capacity"
[ "$rate_admitted" -le "$(( 30 + rate_burst_elapsed + 1 ))" ] || fail "concurrent burst admitted $rate_admitted requests in ${rate_burst_elapsed}s, overspending capacity 30 at 1/s"

# A throttled request receives the documented 429 shape.
curl --silent --max-time 5 --dump-header "$work/rate-headers" --output "$work/rate-body" \
	-H "X-API-Key: $rate_reader_token" "$rl_b_root/api/v1/servers/localhost/zones" >/dev/null || true
head -n 1 "$work/rate-headers" | grep -Fq ' 429' || fail "exhausted identity was not throttled: $(head -n 1 "$work/rate-headers")"
rate_header X-DANS-RateLimit-Bucket | grep -Fq requests || fail 'throttle did not name the requests bucket'
rate_retry=$(rate_header Retry-After)
[ "${rate_retry:-0}" -ge 1 ] || fail "throttle Retry-After was $rate_retry"
jq -e '.error == "Rate exceeded" and (.errors | index("bucket: requests"))' "$work/rate-body" >/dev/null || fail "throttle body was $(cat "$work/rate-body")"

# Idle state expires after the full-refill time; the 1000/s operation bucket lives about 2s.
rate_key_absent "$rate_reader_id" op:listZones && fail 'operation bucket state was not stored'
wait_for 'idle rate-limit state expiry' rate_key_absent "$rate_reader_id" op:listZones

# A change throttle leaves the request buckets untouched.
rate_replace='{"rrsets":[{"changetype":"REPLACE","name":"one.rate.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.60"}]},{"changetype":"REPLACE","name":"two.rate.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.61"}]}]}'
[ "$(rate_patch "$rl_a_root" "$rate_replace")" = 204 ] || fail "cost-4 rate-limit patch was refused: $(cat "$work/rate-body")"
rate_request_before=$(rate_tokens "$rate_writer_id" req)
rate_delete='{"rrsets":[{"changetype":"DELETE","name":"one.rate.example.test.","type":"A"}]}'
[ "$(rate_patch "$rl_b_root" "$rate_delete")" = 429 ] || fail "change-exhausted patch was not throttled: $(cat "$work/rate-body")"
rate_header X-DANS-RateLimit-Bucket | grep -Fxq changes || fail 'change throttle did not name only the changes bucket'
rate_request_after=$(rate_tokens "$rate_writer_id" req)
awk -v before="$rate_request_before" -v after="$rate_request_after" 'BEGIN { exit !(after + 0 >= before + 0) }' ||
	fail "refused change consumed request tokens ($rate_request_before -> $rate_request_after)"
assert_dns_contains one.rate.example.test. A 192.0.2.60
expect_cli_data_error 'throttled CLI change' 'rate limited by changes' "$rate_delete" dans-rl-a "$rate_writer_token" rrsets apply "$forward_zone_id"

# A request that can never fit receives 413 without Retry-After.
rate_oversized='{"rrsets":[{"changetype":"REPLACE","name":"a.rate.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.62"}]},{"changetype":"REPLACE","name":"b.rate.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.63"}]},{"changetype":"REPLACE","name":"c.rate.example.test.","type":"A","ttl":60,"records":[{"content":"192.0.2.64"}]}]}'
[ "$(rate_patch "$rl_a_root" "$rate_oversized")" = 413 ] || fail "over-capacity patch was not rejected with 413: $(cat "$work/rate-body")"
[ -z "$(rate_header Retry-After)" ] || fail 'over-capacity rejection included Retry-After'
jq -e '.errors == ["bucket: changes", "cost: 6", "capacity: 4"]' "$work/rate-body" >/dev/null || fail "over-capacity body was $(cat "$work/rate-body")"
assert_dns_absent a.rate.example.test. A

# Redis outages fail open without affecting readiness, then metering resumes.
rate_unmetered() {
	: >"$work/rate-codes"
	for _ in $(seq 1 40); do
		rate_status "$rl_a_root" "$rate_reader_token" >>"$work/rate-codes"
	done
	[ "$(rate_count 200)" -eq 40 ] || fail "$1: requests were refused while Redis was unavailable: $(sort "$work/rate-codes" | uniq -c | tr '\n' ' ')"
	assert_http 200 "$rl_a_root/readyz"
	assert_http 200 "$rl_b_root/readyz"
}
rate_recoveries() {
	compose --profile ratelimit logs --no-color dans-rl-a | grep -Fc '"event":"rate_limit.recovered"' || true
}
rate_recovered_after() {
	rate_status "$rl_a_root" "$rate_reader_token" >/dev/null
	[ "$(rate_recoveries)" -gt "$1" ]
}
rate_recoveries_before=$(rate_recoveries)
toxiproxy toggle redis >/dev/null
rate_unmetered 'Redis unreachable'
toxiproxy toggle redis >/dev/null
# Each outage is one warning episode; recovery between faults starts a new one.
wait_for 'metering after Redis returns' rate_recovered_after "$rate_recoveries_before"
rate_recoveries_before=$(rate_recoveries)
toxiproxy toxic add --type latency --downstream --toxicName redis-slow --attribute latency=1000 redis >/dev/null
rate_unmetered 'Redis slower than the timeout'
toxiproxy toxic remove --toxicName redis-slow redis >/dev/null
wait_for 'metering after Redis speeds up' rate_recovered_after "$rate_recoveries_before"
rate_throttle_resumed() {
	for _ in $(seq 1 80); do
		[ "$(rate_status "$rl_a_root" "$rate_reader_token")" = 429 ] && return 0
	done
	return 1
}
wait_for 'resumed rate limiting after Redis recovery' rate_throttle_resumed
[ "$(docker inspect --format '{{.State.StartedAt}}' "$(compose --profile ratelimit ps --quiet dans-rl-a)" "$(compose --profile ratelimit ps --quiet dans-rl-b)")" = "$rl_started" ] ||
	fail 'rate-limited instances restarted during the Redis faults'
compose --profile ratelimit logs --no-color dans-rl-a dans-rl-b >"$work/rate-logs"
for rate_event in '"reason":"connection"' '"reason":"timeout"' '"event":"rate_limit.recovered"' '"rate_limit":"throttled"' '"rate_limit":"exceeds_capacity"'; do
	grep -Fq "$rate_event" "$work/rate-logs" || fail "rate-limited instance logs lack $rate_event"
done
grep -Fq 'toxiproxy:16379' "$work/rate-logs" && fail 'rate-limit logs exposed the Redis address'
cat "$work/rate-logs" >>"$work/runtime.log"
compose --profile ratelimit stop dans-rl-a dans-rl-b >/dev/null

mark_phase restore
restored_dans_stopped || fail 'restored service started before finalization'
capture_backup_pair 192.0.2.47
restore_backup_pair "$root/internal/database/privileges/runtime.sql"
expect_compose_query_rejection failed
expect_compose_query_rejection running
(
	pdns_cli_restored() { return 1; }
	expect_preflight_rejection 'unavailable PowerDNS API' zones assert_recovery_preflight
)
(
	source_zone_ids='[]'
	expect_preflight_rejection 'wrong zone inventory' zones assert_recovery_preflight
)
(
	source_forward=198.51.100.1
	expect_preflight_rejection 'wrong forward answer' forward assert_recovery_preflight
)
(
	source_ptr=wrong.example.test.
	expect_preflight_rejection 'wrong PTR answer' ptr assert_recovery_preflight
)
compose exec -T powerdns-restored pdnsutil metadata set example.test. ALLOW-AXFR-FROM 198.51.100.0/24 >/dev/null
mismatched_metadata=$(compose exec -T powerdns-restored pdnsutil metadata get example.test. ALLOW-AXFR-FROM)
[ "$mismatched_metadata" != "$source_metadata" ] || fail 'mismatched PowerDNS fixture was not applied'
expect_preflight_rejection 'mismatched PowerDNS fixture' metadata assert_recovery_preflight
restored_dans_stopped || fail 'restored DANS started after preflight rejection'
compose --profile restore stop powerdns-restored >/dev/null
seed_restored_powerdns
compose --profile restore start powerdns-restored >/dev/null
wait_for 'restored PowerDNS restart' pdns_cli_restored zones list
assert_recovery_preflight || exit 1
finalize_restored_pair

capture_runtime_logs
for secret in "$operator_token" "$direct_token" "$group_token" "$replacement_token" "$rollback_token" "$rate_reader_token" "$rate_writer_token" dans_v1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; do
	if grep -Fq "$secret" "$work/runtime.log"; then
		fail 'runtime logs exposed a credential'
	fi
done

printf '%s\n' "integration: PostgreSQL $major_minor passed"
