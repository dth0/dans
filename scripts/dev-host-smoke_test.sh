#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/dans-host-smoke-test.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
if /bin/ps -p "$$" -o lstart= >/dev/null 2>&1; then
	host_fake_identities=0
else
	host_fake_identities=1
fi

fake_root=$work/repo
mkdir -p "$fake_root/scripts" "$work/bin"
cp "$root/scripts/dev-stack.sh" "$fake_root/scripts/dev-stack.sh"
chmod 755 "$fake_root/scripts/dev-stack.sh"
: >"$fake_root/compose.yaml"
fake_project_root=$(CDPATH= cd -P -- "$fake_root" && pwd)
fake_project_id=$(printf '%s\n' "$fake_project_root" | cksum | awk '{print $1}')
fake_user_id=$(id -u)
export DEV_HOST_REAL_PGREP=$(command -v pgrep)
fake_lock_dir=/tmp/dans-dev-locks-$fake_user_id
fake_project=dans-dev-$fake_user_id-$fake_project_id
fake_stack_lock=$fake_lock_dir/dans-dev-stack-$fake_project_id.lock.lockdir
fake_project_lock=$fake_lock_dir/dans-dev-compose-$fake_project.lock.lockdir

cat >"$work/bin/docker" <<'STUB'
#!/bin/sh
set -eu

case "$*" in
	*" ps --status running --services"*)
		printf '%s\n' dans
		;;
	*" port dans 8080"*)
		case "${DEV_HOST_TEST_MODE:?}" in
			port-fail) exit 1 ;;
			port-empty) exit 0 ;;
			port-malformed) printf '%s\n' invalid ; exit 0 ;;
		esac
		printf '%s\n' "127.0.0.1:${DEV_HOST_EFFECTIVE_HTTP_PORT:?}"
		;;
	*" port --protocol tcp powerdns 53"*)
		case "${DEV_HOST_TEST_MODE:?}" in
			port-tcp-fail) exit 1 ;;
			port-empty) exit 0 ;;
			port-malformed) printf '%s\n' invalid ; exit 0 ;;
		esac
		printf '%s\n' "127.0.0.1:${DEV_HOST_EFFECTIVE_DNS_TCP_PORT:?}"
		;;
	*" port --protocol udp powerdns 53"*)
		case "${DEV_HOST_TEST_MODE:?}" in
			port-udp-fail) exit 1 ;;
			port-empty) exit 0 ;;
			port-malformed) printf '%s\n' invalid ; exit 0 ;;
		esac
		printf '%s\n' "127.0.0.1:${DEV_HOST_EFFECTIVE_DNS_UDP_PORT:?}"
		;;
	*" health ready"*)
		;;
	*" identities tokens create"*)
		body=$(cat)
		[ -n "$body" ] || exit 1
		printf '%s\n' '{"secret":"service-token"}'
		;;
	*" identities create"*)
		body=$(cat)
		[ -n "$body" ] || exit 1
		printf '%s\n' '{"id":"identity"}'
		;;
	*" zones create"*)
		body=$(cat)
		[ -n "$body" ] || exit 1
		printf '%s\n' '{"id":"zone"}'
		;;
	*" bindings list"*)
		printf '%s\n' '{"id":"binding"}'
		;;
	*" rrsets replace"*" denied."*)
		printf '%s\n' 'DANS API returned 403 Forbidden' >&2
		exit 1
		;;
	*" rrsets replace"*)
		;;
	*" nslookup "*)
		printf '%s\n' 'Address: 192.0.2.10'
		;;
	*" audit list"*)
		printf '%s\n' '{"action":"powerdns.zone.patch","result":"succeeded","actor_id":"identity","target_id":"binding"}'
		;;
esac
STUB
chmod 755 "$work/bin/docker"

cat >"$work/bin/ps" <<'STUB'
#!/bin/sh
set -eu
pid=
for arg do
	case "$arg" in
		[0-9]*) pid=$arg ;;
		lstart=)
			[ "${DEV_HOST_FAKE_IDENTITIES:-0}" = 1 ] || exec /bin/ps "$@"
			printf 'pid-%s\n' "$pid"
			exit 0
			;;
		pgid=)
			[ "${DEV_HOST_FAKE_GROUPS:-0}" = 1 ] || exec /bin/ps "$@"
			printf '%s\n' "$pid"
			exit 0
			;;
		ppid=)
			[ "${DEV_HOST_FAKE_IDENTITIES:-0}" = 1 ] || exec /bin/ps "$@"
			[ "$pid" = "${DANS_DEV_LOCK_WRAPPER_PID:-}" ] &&
				[ -n "${DANS_DEV_LOCK_PARENT_WRAPPER_PID:-}" ] || exec /bin/ps "$@"
			printf '%s\n' "$DANS_DEV_LOCK_PARENT_WRAPPER_PID"
			exit 0
			;;
	esac
done
exec /bin/ps "$@"
STUB
chmod 755 "$work/bin/ps"

cat >"$work/bin/pgrep" <<'STUB'
#!/bin/sh
set -eu
if [ "${DEV_HOST_FAKE_IDENTITIES:-0}" = 1 ] && [ "${1:-}" = -P ]; then
	exit 1
fi
if [ "${DEV_HOST_FAKE_IDENTITIES:-0}" = 1 ] &&
	[ "${1:-}" = -g ] &&
	[ "${2:-}" = "${DANS_DEV_LOCK_WRAPPER_PID:-}" ] &&
	[ -n "${DANS_DEV_LOCK_WRAPPER_PID:-}" ]; then
	printf '%s\n' "$DANS_DEV_LOCK_WRAPPER_PID"
	exit 0
fi
if [ "${DEV_HOST_FAKE_IDENTITIES:-0}" = 1 ] && [ "${1:-}" = -g ]; then
	exit 1
fi
exec "$DEV_HOST_REAL_PGREP" "$@"
STUB
chmod 755 "$work/bin/pgrep"

cat >"$work/bin/curl" <<'STUB'
#!/bin/sh
set -eu
url=
write_status=0
output_file=
previous=
for arg do
	if [ "$previous" = --output ]; then
		output_file=$arg
	fi
	previous=$arg
	url=$arg
	[ "$arg" = --write-out ] && write_status=1
done
printf '%s\n' "$*" >>"${DEV_HOST_CURL_LOG:?}"
emit() {
	if [ -n "$output_file" ]; then
		printf '%s\n' "$1" >"$output_file"
	else
		printf '%s\n' "$1"
	fi
}
case "${DEV_HOST_TEST_MODE:?}:$url" in
	timeout:*) exit 1 ;;
	ready-flap:*/readyz)
		if [ "$write_status" -eq 1 ]; then
			printf '%s\n' 503
		fi
		;;
	bad-ready-body:*/readyz)
		emit 'unexpected readiness body'
		if [ "$write_status" -eq 1 ]; then
			printf '%s\n' 200
		fi
		;;
	*:*/readyz)
		if [ "$write_status" -eq 1 ]; then
			printf '%s\n' 200
		fi
		;;
	bad-console:*/console/)
		emit 'unexpected console body'
		if [ "$write_status" -eq 1 ]; then
			printf '%s\n' 200
		fi
		;;
	*:*/console/)
		emit '<div id="root"></div>'
		if [ "$write_status" -eq 1 ]; then
			printf '%s\n' 200
		fi
		;;
esac
STUB
chmod 755 "$work/bin/curl"

cat >"$work/bin/dig" <<'STUB'
#!/bin/sh
set -eu
owner=
for arg do
	case "$arg" in
		*.test.) owner=$arg ;;
	esac
done
printf '%s\n' "$*" >>"${DEV_HOST_DNS_LOG:?}"
answer=192.0.2.10
[ "${DEV_HOST_TEST_MODE:?}" = bad-dns ] && answer=192.0.2.11
case "${DEV_HOST_TEST_MODE:?}:$*" in
	bad-udp:*+notcp*) exit 1 ;;
	bad-tcp:*+tcp*) exit 1 ;;
esac
flags=';; flags: qr aa; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1'
[ "${DEV_HOST_TEST_MODE:?}" = truncated ] && flags=';; flags: qr aa tc; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1'
[ "${DEV_HOST_TEST_MODE:?}" = bad-authority ] && flags=';; flags: qr; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1'
status=NOERROR
[ "${DEV_HOST_TEST_MODE:?}" = bad-status ] && status=SERVFAIL
printf '%s\n' ";; ->>HEADER<<- opcode: QUERY, status: $status, id: 1"
printf '%s\n' "$flags"
printf '%s\n' "$owner 60 IN A $answer"
STUB
chmod 755 "$work/bin/dig"

run_smoke() {
	mode=$1
	printf '%s\n' "host smoke contract: scenario=$mode" >&2
	http_port=$2
	udp_port=$3
	tcp_port=$4
	expected_status=$5
	expected_diag=${6:-}
	rm -rf "$fake_root/.dans"
	mkdir -p "$fake_root/.dans/dev"
	printf '%s\n' operator-token >"$fake_root/.dans/dev/operator-token"
	printf '%s\n' "dans-dev-$fake_user_id-$fake_project_id" >"$fake_root/.dans/dev/compose-project"
	curl_log=$work/curl.log
	dns_log=$work/dns.log
	: >"$curl_log"
	: >"$dns_log"
	stdout=$work/stdout
	stderr=$work/stderr
	if DEV_HOST_TEST_MODE=$mode \
		DEV_HOST_FAKE_IDENTITIES=$host_fake_identities \
		DEV_HOST_FAKE_GROUPS=$host_fake_identities \
		DEV_HOST_CURL_LOG=$curl_log \
		DEV_HOST_DNS_LOG=$dns_log \
		DEV_HOST_EFFECTIVE_HTTP_PORT=$http_port \
		DEV_HOST_EFFECTIVE_DNS_UDP_PORT=$udp_port \
		DEV_HOST_EFFECTIVE_DNS_TCP_PORT=$tcp_port \
		PATH="$work/bin:$PATH" \
		"$fake_root/scripts/dev-stack.sh" smoke-host >"$stdout" 2>"$stderr"; then
		status=0
	else
		status=$?
	fi
	[ "$status" -eq "$expected_status" ] || {
		printf '%s\n' "host smoke: $mode exited $status, want $expected_status" >&2
		exit 1
	}
	if [ -n "$expected_diag" ]; then
		grep -Fq "$expected_diag" "$stderr" || {
			printf '%s\n' "host smoke: $mode omitted diagnostic $expected_diag" >&2
			exit 1
		}
	fi
	if [ "$expected_status" -eq 0 ]; then
		grep -Fq 'smoke-host: ok' "$stdout"
		grep -Fq "127.0.0.1:$http_port" "$curl_log"
		grep -Fq -- '--noproxy *' "$curl_log"
		[ "$(grep -Fc '/readyz' "$curl_log")" -eq 1 ]
		[ "$(grep -Fc '/console/' "$curl_log")" -eq 1 ]
		grep -F '/readyz' "$curl_log" | grep -Fq -- '--output'
		grep -F '/readyz' "$curl_log" | grep -Fq -- '--write-out'
		grep -F '/console/' "$curl_log" | grep -Fq -- '--output'
		grep -F '/console/' "$curl_log" | grep -Fq -- '--write-out'
		grep -Fq -- "-p $udp_port +time=2 +tries=1" "$dns_log"
		grep -Fq -- "-p $tcp_port +time=2 +tries=1" "$dns_log"
		grep -Fq '+notcp' "$dns_log"
		grep -Fq '+tcp' "$dns_log"
	fi
}

run_smoke normal 8080 1053 1053 0
run_smoke normal 18080 11053 11054 0
run_smoke bad-console 8080 1053 1053 1 'unexpected content'
run_smoke bad-ready-body 8080 1053 1053 1 'unexpected content'
run_smoke ready-flap 8080 1053 1053 1 'returned status 503'
run_smoke bad-dns 8080 1053 1053 1 'wrong answer'
run_smoke bad-udp 8080 1053 1053 1 'host DNS udp probe failed'
run_smoke bad-tcp 8080 1053 1053 1 'host DNS tcp probe failed'
run_smoke truncated 8080 1053 1053 1 'truncated response'
run_smoke bad-authority 8080 1053 1053 1 'not authoritative'
run_smoke bad-status 8080 1053 1053 1 'non-success status'
run_smoke timeout 8080 1053 1053 1 'host HTTP probe failed'
run_smoke port-fail 8080 1053 1053 1 'port lookup failed'
run_smoke port-empty 8080 1053 1053 1 'port lookup failed'
run_smoke port-malformed 8080 1053 1053 1 'invalid port'
run_smoke port-udp-fail 8080 1053 1053 1 'port lookup failed for powerdns 53'
run_smoke port-tcp-fail 8080 1053 1053 1 'port lookup failed for powerdns 53'

printf '%s\n' 'host smoke contract: scenario=missing-tool' >&2
missing_bin=$work/missing-bin
mkdir -p "$missing_bin"
ln -s "$(command -v dirname)" "$missing_bin/dirname"
ln -s "$(command -v cksum)" "$missing_bin/cksum"
ln -s "$(command -v awk)" "$missing_bin/awk"
ln -s "$(command -v mkdir)" "$missing_bin/mkdir"
ln -s "$(command -v rmdir)" "$missing_bin/rmdir"
ln -s "$(command -v rm)" "$missing_bin/rm"
ln -s "$(command -v env)" "$missing_bin/env"
ln -s "$(command -v id)" "$missing_bin/id"
ln -s "$(command -v mktemp)" "$missing_bin/mktemp"
ln -s "$(command -v ls)" "$missing_bin/ls"
ln -s "$(command -v mkfifo)" "$missing_bin/mkfifo"
ln -s "$(command -v tee)" "$missing_bin/tee"
ln -s "$work/bin/pgrep" "$missing_bin/pgrep"
ln -s "$work/bin/ps" "$missing_bin/ps"
ln -s "$(command -v chmod)" "$missing_bin/chmod"
ln -s "$(command -v sed)" "$missing_bin/sed"
ln -s "$(command -v stat)" "$missing_bin/stat"
ln -s "$(command -v sleep)" "$missing_bin/sleep"
ln -s "$(command -v sh)" "$missing_bin/sh"
ln -s "$(command -v tr)" "$missing_bin/tr"
rm -rf "$fake_root/.dans"
mkdir -p "$fake_root/.dans/dev"
printf '%s\n' operator-token >"$fake_root/.dans/dev/operator-token"
printf '%s\n' "dans-dev-$fake_user_id-$fake_project_id" >"$fake_root/.dans/dev/compose-project"
if DEV_HOST_TEST_MODE=missing \
	DEV_HOST_FAKE_IDENTITIES=$host_fake_identities \
	DEV_HOST_FAKE_GROUPS=$host_fake_identities \
	DEV_HOST_CURL_LOG=$work/curl.log \
	DEV_HOST_DNS_LOG=$work/dns.log \
	PATH="$missing_bin" \
	"$fake_root/scripts/dev-stack.sh" smoke-host >"$work/missing.stdout" 2>"$work/missing.stderr"; then
	status=0
else
	status=$?
fi
[ "$status" -eq 1 ] || {
	printf '%s\n' "host smoke: missing-tool check exited $status, want 1" >&2
	exit 1
}
grep -Fq 'host command curl' "$work/missing.stderr"
[ ! -e "$fake_stack_lock" ]
[ ! -e "$fake_project_lock" ]

printf '%s\n' 'host smoke behavior: ok'
