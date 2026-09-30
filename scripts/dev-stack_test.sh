#!/bin/sh
set -eu

if /bin/ps -p "$$" -o lstart= >/dev/null 2>&1; then
	export DEV_TEST_FAKE_IDENTITIES=0
else
	export DEV_TEST_FAKE_IDENTITIES=1
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/dans-dev-stack-test.XXXXXX")
lock_holder=
mismatch_holder=
lock_stop=
test_lock_paths=
interrupt_operation_pid=
interrupt_operation_identity=
interrupt_operation_child_pid=
interrupt_operation_child_identity=
interrupt_child_pid=
interrupt_child_identity=
launcher_child_pid=
launcher_child_identity=
logs_pid=
kill_process_tree() {
	[ -n "${2:-}" ] || return 0
	[ "$(process_identity "$1" || true)" = "$2" ] || return 0
	for kill_tree_child in $(pgrep -P "$1" 2>/dev/null || true); do
		kill_process_tree "$kill_tree_child" "$(process_identity "$kill_tree_child" || true)"
	done
	[ "$(process_identity "$1" || true)" = "$2" ] || return 0
	kill -KILL "$1" 2>/dev/null || true
	wait "$1" 2>/dev/null || true
}
process_running() {
	process_id=$1
	if [ -r "/proc/$process_id/stat" ]; then
		process_state=$(awk '{
			line = $0
			sub(/^[0-9]+ \(.*\) /, "", line)
			print substr(line, 1, 1)
		}' "/proc/$process_id/stat")
		[ "$process_state" != Z ]
	elif process_state=$(ps -p "$process_id" -o state= 2>/dev/null); then
		process_state=$(printf '%s' "$process_state" | tr -d '[:space:]')
		case "$process_state" in
			''|Z*) return 1 ;;
			*) return 0 ;;
		esac
	else
		kill -0 "$process_id" 2>/dev/null
	fi
}
process_identity() {
	process_id=$1
	if [ -r "/proc/$process_id/stat" ]; then
		awk '{
			prefix = "^[0-9]+ \\(.*\\) [[:alpha:]] "
			matched = match($0, prefix)
			if (!matched) exit 1
			stat_fields = substr($0, RSTART + RLENGTH)
			split(stat_fields, fields, " ")
			if (fields[19] == "") exit 1
			print fields[19]
		}' "/proc/$process_id/stat" 2>/dev/null
	else
		process_start=$(ps -p "$process_id" -o lstart= 2>/dev/null | tr -d '[:space:]')
		if [ -n "$process_start" ]; then
			printf '%s\n' "$process_start"
		else
			printf 'pid-%s\n' "$process_id"
		fi
	fi
}
process_group_id() {
	process_id=$1
	if [ -r "/proc/$process_id/stat" ]; then
		awk '{
			prefix = "^[0-9]+ \\(.*\\) [[:alpha:]] "
			matched = match($0, prefix)
			if (!matched) exit 1
			stat_fields = substr($0, RSTART + RLENGTH)
			split(stat_fields, fields, " ")
			if (fields[2] == "") exit 1
			print fields[2]
		}' "/proc/$process_id/stat" 2>/dev/null
	else
		process_group=$(ps -p "$process_id" -o pgid= 2>/dev/null | tr -d '[:space:]')
		case "$process_group" in
			''|*[!0-9]*) return 1 ;;
			*) printf '%s\n' "$process_group" ;;
		esac
	fi
}
cleanup() {
	printf '%s\n' 'dev stack contract: phase=cleanup' >&2
	if [ -n "${lock_holder:-}" ]; then
		: >"$lock_stop" 2>/dev/null || true
		wait "$lock_holder" 2>/dev/null || true
		lock_holder=
	fi
	if [ -n "${mismatch_holder:-}" ]; then
		[ -z "${mismatch_stop:-}" ] || : >"$mismatch_stop" 2>/dev/null || true
		wait "$mismatch_holder" 2>/dev/null || true
		mismatch_holder=
	fi
	if [ -n "${interrupt_operation_pid:-}" ]; then
		kill_process_tree "$interrupt_operation_pid" "$interrupt_operation_identity"
		interrupt_operation_pid=
		interrupt_operation_identity=
	fi
	if [ -n "${interrupt_operation_child_pid:-}" ]; then
		kill_process_tree "$interrupt_operation_child_pid" "$interrupt_operation_child_identity"
		interrupt_operation_child_pid=
		interrupt_operation_child_identity=
	fi
	if [ -n "${interrupt_child_pid:-}" ]; then
		if [ "$(process_identity "$interrupt_child_pid" || true)" = "$interrupt_child_identity" ]; then
			kill -KILL "$interrupt_child_pid" 2>/dev/null || true
		fi
		wait "$interrupt_child_pid" 2>/dev/null || true
		interrupt_child_pid=
		interrupt_child_identity=
	fi
	if [ -n "${launcher_child_pid:-}" ]; then
		kill_process_tree "$launcher_child_pid" "$launcher_child_identity"
		launcher_child_pid=
		launcher_child_identity=
	fi
	if [ -n "${logs_pid:-}" ]; then
		kill_process_tree "$logs_pid" "$(process_identity "$logs_pid" || true)"
		logs_pid=
	fi
	for lock_path in $test_lock_paths; do
		if [ -L "$lock_path" ]; then
			rm -f "$lock_path"
		else
			rm -f "$lock_path/pid" "$lock_path/ready" "$lock_path/worker-done" "$lock_path/operation-uncertain" 2>/dev/null || true
			rmdir "$lock_path" 2>/dev/null || true
		fi
	done
	rm -rf "$work"
}
cleanup_signal() {
	trap '' HUP INT TERM
	exit 143
}
trap cleanup EXIT
trap cleanup_signal HUP INT TERM

printf '%s\n' 'dev stack contract: phase=setup' >&2
fake_root=$work/repo
mkdir -p "$fake_root/scripts" "$work/bin"
cp "$root/scripts/dev-stack.sh" "$fake_root/scripts/dev-stack.sh"
chmod 755 "$fake_root/scripts/dev-stack.sh"
: >"$fake_root/compose.yaml"
fake_project_root=$(CDPATH= cd -P -- "$fake_root" && pwd)
fake_project_id=$(printf '%s\n' "$fake_project_root" | cksum | awk '{print $1}')
fake_user_id=$(id -u)
export DEV_TEST_REAL_PGREP=$(command -v pgrep)

cat >"$work/bin/docker" <<'STUB'
#!/bin/sh
set -eu

mode=${DEV_TEST_MODE:?}
recover_count_file=${DEV_TEST_RECOVER_COUNT_FILE:?}
me_count_file=${DEV_TEST_ME_COUNT_FILE:?}
api_token=
for arg do
	case "$arg" in
		DANS_API_TOKEN=*) api_token=${arg#DANS_API_TOKEN=} ;;
	esac
done

if [ "${DEV_TEST_TRACE_OPERATIONS:-0}" = 1 ]; then
	case "$*" in
		*" recover operator-token "*) operation=recover ;;
		*" me get"*) operation=validate ;;
		*" bootstrap "*) operation=bootstrap ;;
		*) operation=setup ;;
	esac
	printf '%s\n' "dev stack contract: operation=$operation start" >&5
	trap 'printf "%s\n" "dev stack contract: operation=$operation done" >&5' EXIT
fi

if [ "$mode" = reset-teardown-failure ]; then
	case "$*" in
		*down*--volumes*)
			[ -z "${DEV_TEST_PARTIAL_TEARDOWN_FILE:-}" ] || : >"$DEV_TEST_PARTIAL_TEARDOWN_FILE"
			printf '%s\n' 'teardown failed after removing database volumes' >&2
			exit 1
			;;
	esac
fi

if [ "$mode" = transport-failure ]; then
	case "$*" in
		*down*--volumes*)
			printf '%s\n' 'Cannot connect to the Docker daemon' >&2
			exit 1
			;;
	esac
fi

if [ "$mode" = diagnostic-success ]; then
	case "$*" in
		*' db migrate '*) printf '%s\n' 'context deadline exceeded' >&2 ;;
	esac
fi

increment() {
	count=$(sed -n '1p' "$1")
	count=$((count + 1))
	printf '%s\n' "$count" >"$1"
}

if [ "$mode" = blocking ]; then
	(
		trap '' HUP INT TERM
		while :; do sleep 1; done
	) &
	interrupt_child=$!
	printf '%s\n' "$interrupt_child" >"${DEV_TEST_CHILD_PID_FILE:?}"
	trap 'kill -KILL "$interrupt_child" 2>/dev/null || true; wait "$interrupt_child" 2>/dev/null || true; exit 143' HUP INT TERM
	while :; do sleep 1; done
fi

if [ "$mode" = logs-blocking ]; then
	case "$*" in
		*"logs --follow"*)
			printf '%s\n' 'live log diagnostic' >&2
			: >"${DEV_TEST_LOGS_READY:?}"
			while [ ! -e "${DEV_TEST_LOGS_STOP:?}" ]; do sleep 1; done
			exit 0
			;;
	esac
fi

if [ "$mode" = launcher-leaves-child ]; then
	[ ! -s "${DEV_TEST_LAUNCHER_CHILD_PID_FILE:?}" ] || exit 1
	(
		trap '' HUP INT TERM
		sleep 40
	) &
	launcher_child=$!
	printf '%s\n' "$launcher_child" >"${DEV_TEST_LAUNCHER_CHILD_PID_FILE:?}"
	exit 0
fi

case "$*" in
	*" bootstrap "*)
		case "$mode" in
			fresh|diagnostic-success|fresh-invalid|fresh-write-failure|database-loss)
				printf '%s\n' '{"secret":"candidate"}'
				exit 0
				;;
			bootstrap-interrupted)
				exit 143
				;;
		esac
		printf '%s\n' 'database: conflict' >&2
		exit 1
		;;
	*" recover operator-token "*)
		increment "$recover_count_file"
		if [ "$mode" = existing-recover-failure ]; then
			printf '%s\n' 'recovery unavailable' >&2
			exit 1
		fi
		[ "$mode" = recover-interrupted ] && exit 137
		printf '%s\n' '{"secret":"recovered"}'
		exit 0
		;;
	*" me get"*)
		increment "$me_count_file"
		case "$mode:$api_token" in
			existing-unauthorized:old|existing-recover-failure:old|recover-interrupted:old|existing-recovered-unauthorized:old|existing-recovered-wrong:old)
				printf '%s\n' 'DANS API returned 401 Unauthorized' >&2
				exit 1
				;;
			existing-recovered-unauthorized:recovered)
				printf '%s\n' 'DANS API returned 401 Unauthorized' >&2
				exit 1
				;;
			existing-transport:*)
				printf '%s\n' 'connection refused' >&2
				exit 1
				;;
			existing-unexpected:*)
				printf '%s\n' 'DANS API returned 500 Internal Server Error' >&2
				exit 1
				;;
			existing-malformed:*)
				printf '%s\n' '{"enabled":true,"operator":true}'
				exit 0
				;;
			existing-wrong:*|fresh-invalid:*|existing-recovered-wrong:recovered|missing-recovered-wrong:*)
				printf '%s\n' '{"handle":"other","enabled":true,"operator":true}'
				exit 0
				;;
			existing-disabled:*)
				printf '%s\n' '{"handle":"dev-operator","enabled":false,"operator":true}'
				exit 0
				;;
			existing-nonoperator:*)
				printf '%s\n' '{"handle":"dev-operator","enabled":true,"operator":false}'
				exit 0
				;;
		esac
		printf '%s\n' '{"handle":"dev-operator","enabled":true,"operator":true}'
		exit 0
		;;
esac

exit 0
STUB
chmod 755 "$work/bin/docker"

cat >"$work/bin/mv" <<'STUB'
#!/bin/sh
set -eu
destination=
for arg do
	destination=$arg
done
case "${DEV_TEST_BLOCK_TOKEN_MV:-0}:$destination" in
	1:*/operator-token) exit 1 ;;
esac
exec /bin/mv "$@"
STUB
chmod 755 "$work/bin/mv"

cat >"$work/bin/chmod" <<'STUB'
#!/bin/sh
set -eu
destination=
for arg do
	destination=$arg
done
case "${DEV_TEST_BLOCK_TOKEN_CHMOD:-0}:$destination" in
	1:*/operator-token.*) exit 1 ;;
esac
exec /bin/chmod "$@"
STUB
chmod 755 "$work/bin/chmod"

cat >"$work/bin/mktemp" <<'STUB'
#!/bin/sh
set -eu
case "${DEV_TEST_BLOCK_TOKEN_MKTEMP:-0}:$*" in
	1:*operator-token.*) exit 1 ;;
esac
exec /usr/bin/mktemp "$@"
STUB
chmod 755 "$work/bin/mktemp"

cat >"$work/bin/ps" <<'STUB'
#!/bin/sh
set -eu
pid=
for arg do
	case "$arg" in
		[0-9]*) pid=$arg ;;
		lstart=)
		if [ -n "${DEV_TEST_WATCHDOG_PS_MISS_FILE:-}" ] &&
			[ ! -e "$DEV_TEST_WATCHDOG_PS_MISS_FILE" ]; then
			probe=0
			while [ "$probe" -lt 4 ]; do
				case "$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)" in
					*'sleep 10') : >"$DEV_TEST_WATCHDOG_PS_MISS_FILE"; exit 1 ;;
				esac
				probe=$((probe + 1))
				sleep 0.05
			done
		fi
			[ "${DEV_TEST_FAKE_IDENTITIES:-0}" = 1 ] || exec /bin/ps "$@"
			printf 'pid-%s\n' "$pid"
			exit 0
			;;
		pgid=)
			[ "${DEV_TEST_FAKE_IDENTITIES:-0}" = 1 ] || exec /bin/ps "$@"
			if [ "${DEV_TEST_NONISOLATED:-0}" = 1 ] &&
				[ -n "${DANS_DEV_LOCK_PARENT_GROUP:-}" ]; then
				printf '%s\n' "$DANS_DEV_LOCK_PARENT_GROUP"
				exit 0
			fi
			printf '%s\n' "$pid"
			exit 0
			;;
		ppid=)
			[ "${DEV_TEST_FAKE_IDENTITIES:-0}" = 1 ] || exec /bin/ps "$@"
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
[ "${DEV_TEST_PGREP_FAILURE:-0}" = 1 ] && exit 2
if [ "${DEV_TEST_FAKE_IDENTITIES:-0}" = 1 ] && [ "${1:-}" = -P ]; then
	exit 1
fi
if [ "${DEV_TEST_FAKE_IDENTITIES:-0}" = 1 ] &&
	[ "${1:-}" = -g ] &&
	[ "${2:-}" = "${DANS_DEV_LOCK_WRAPPER_PID:-}" ] &&
	[ -n "${DANS_DEV_LOCK_WRAPPER_PID:-}" ]; then
	printf '%s\n' "$DANS_DEV_LOCK_WRAPPER_PID"
	if [ -n "${DEV_TEST_LAUNCHER_CHILD_PID_FILE:-}" ] &&
		[ -s "$DEV_TEST_LAUNCHER_CHILD_PID_FILE" ]; then
		cat "$DEV_TEST_LAUNCHER_CHILD_PID_FILE"
	fi
	exit 0
fi
if [ "${DEV_TEST_FAKE_IDENTITIES:-0}" = 1 ] && [ "${1:-}" = -g ]; then
	if [ -n "${DEV_TEST_LAUNCHER_CHILD_PID_FILE:-}" ] &&
		[ -s "$DEV_TEST_LAUNCHER_CHILD_PID_FILE" ]; then
		cat "$DEV_TEST_LAUNCHER_CHILD_PID_FILE"
		exit 0
	fi
	exit 1
fi
exec "$DEV_TEST_REAL_PGREP" "$@"
STUB
chmod 755 "$work/bin/pgrep"

awk '
{
	prefix = "^[0-9]+ \\(.*\\) [[:alpha:]] "
	matched = match($0, prefix)
	if (!matched) exit 1
	stat_fields = substr($0, RSTART + RLENGTH)
	split(stat_fields, fields, " ")
	exit (fields[19] == "start" ? 0 : 1)
}
' <<'STAT'
123 (worker)with)parentheses) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 start 20
STAT

rm -rf "$fake_root/.dans"
if DANS_DEV_STACK_LOCK_HELD=1 PATH="$work/bin:$PATH" \
	"$fake_root/scripts/dev-stack.sh" up >"$work/unowned-lock.stdout" 2>"$work/unowned-lock.stderr"; then
	unowned_lock_status=0
else
	unowned_lock_status=$?
fi
[ "$unowned_lock_status" -eq 1 ] || {
	printf '%s\n' "dev stack behavior: unowned lock bypass exited $unowned_lock_status, want 1" >&2
	exit 1
}
grep -Fq 'development stack lock ownership could not be verified' \
	"$work/unowned-lock.stdout" "$work/unowned-lock.stderr"

run_scenario() {
	name=$1
	printf '%s\n' "dev stack contract: scenario=$name" >&2
	expected_status=$2
	expected_token=$3
	token_state=$4
	expected_recover=$5
	expected_me=$6
	fault=$7
	publish_delay=
	[ "$name" = fresh ] && publish_delay=1
	block_mv=0
	block_chmod=0
	block_mktemp=0
	case "$fault" in
		mv) block_mv=1 ;;
		chmod) block_chmod=1 ;;
		write) block_mktemp=1 ;;
		stale) ;;
		none) ;;
		*) printf '%s\n' "dev stack behavior: unknown fault $fault" >&2; exit 1 ;;
	esac

	rm -rf "$fake_root/.dans"
	mkdir -p "$fake_root/.dans/dev"
	if [ "$token_state" = old ]; then
		printf '%s\n' old >"$fake_root/.dans/dev/operator-token"
		printf '%s\n' "dans-dev-$fake_user_id-$fake_project_id" >"$fake_root/.dans/dev/compose-project"
	fi
	if [ "$fault" = write ]; then
		printf '%s\n' partial >"$fake_root/.dans/dev/operator-token.tmp"
	fi
	if [ "$fault" = stale ]; then
		printf '%s\n' stale >"$fake_root/.dans/dev/operator-token.tmp"
	fi
	recover_count_file=$work/recover-count
	me_count_file=$work/me-count
	printf '%s\n' 0 >"$recover_count_file"
	printf '%s\n' 0 >"$me_count_file"
	stdout=$work/stdout
	stderr=$work/stderr
	if DEV_TEST_MODE=$name \
		DEV_TEST_RECOVER_COUNT_FILE=$recover_count_file \
		DEV_TEST_ME_COUNT_FILE=$me_count_file \
		DEV_TEST_BLOCK_TOKEN_MV=$block_mv \
		DEV_TEST_BLOCK_TOKEN_CHMOD=$block_chmod \
		DEV_TEST_BLOCK_TOKEN_MKTEMP=$block_mktemp \
		DEV_TEST_TRACE_OPERATIONS=1 \
		DANS_DEV_TEST_TRACE_SUPERVISOR=1 \
		DANS_DEV_LOCK_PUBLISH_DELAY=$publish_delay \
		PATH="$work/bin:$PATH" \
		"$fake_root/scripts/dev-stack.sh" up 5>&2 >"$stdout" 2>"$stderr"; then
		status=0
	else
		status=$?
	fi
	[ "$status" -eq "$expected_status" ] || {
		printf '%s\n' "dev stack behavior: $name exited $status, want $expected_status" >&2
		exit 1
	}
	if [ "$expected_token" = none ]; then
		[ ! -e "$fake_root/.dans/dev/operator-token" ] || {
			printf '%s\n' "dev stack behavior: $name created a token unexpectedly" >&2
			exit 1
		}
	else
		actual_token=$(sed -n '1p' "$fake_root/.dans/dev/operator-token" 2>/dev/null || true)
		[ "$actual_token" = "$expected_token" ] || {
			printf '%s\n' "dev stack behavior: $name changed the cached token unexpectedly" >&2
			exit 1
		}
	fi
	[ "$(sed -n '1p' "$recover_count_file")" -eq "$expected_recover" ] || {
		printf '%s\n' "dev stack behavior: $name recovered an unexpected number of times" >&2
		exit 1
	}
	[ "$(sed -n '1p' "$me_count_file")" -eq "$expected_me" ] || {
		printf '%s\n' "dev stack behavior: $name validated an unexpected number of credentials" >&2
		exit 1
	}
	if [ "$fault" != stale ]; then
		[ ! -e "$fake_root/.dans/dev/operator-token.tmp" ] || {
			printf '%s\n' "dev stack behavior: $name left a temporary token behind" >&2
			exit 1
		}
	fi
}

printf '%s\n' 'dev stack contract: phase=credential-cases' >&2
run_scenario fresh 0 candidate old 0 1 none
run_scenario existing-valid 0 old old 0 1 none
run_scenario existing-unauthorized 0 recovered old 1 2 none
run_scenario existing-missing 0 recovered none 1 1 none
run_scenario existing-recover-failure 1 old old 1 1 none
run_scenario existing-recovered-unauthorized 1 old old 1 2 none
run_scenario existing-recovered-wrong 1 old old 1 2 none
run_scenario missing-recovered-wrong 1 none none 1 1 none
run_scenario existing-wrong 1 old old 0 1 none
run_scenario existing-disabled 1 old old 0 1 none
run_scenario existing-nonoperator 1 old old 0 1 none
run_scenario existing-transport 1 old old 0 1 none
run_scenario diagnostic-success 0 candidate old 0 1 none
run_scenario existing-unexpected 1 old old 0 1 none
run_scenario existing-malformed 1 old old 0 1 none
run_scenario fresh-invalid 1 old old 0 1 none
run_scenario fresh-write-failure 1 old old 0 1 mv
run_scenario fresh-write-failure 1 old old 0 1 write
run_scenario fresh-write-failure 1 old old 0 1 chmod
run_scenario existing-valid-stale-temp 0 old old 0 1 stale

rm -rf "$fake_root/.dans"
mkdir -p "$fake_root/.dans/dev"
printf '%s\n' old >"$fake_root/.dans/dev/operator-token"
if DEV_TEST_MODE=missing-project-reset \
	DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
	DEV_TEST_ME_COUNT_FILE=$work/me-count \
	PATH="$work/bin:$PATH" CONFIRM=1 \
	"$fake_root/scripts/dev-stack.sh" reset >"$work/missing-project.stdout" 2>"$work/missing-project.stderr"; then
	missing_project_status=0
else
	missing_project_status=$?
fi
[ "$missing_project_status" -eq 1 ] || {
	printf '%s\n' "dev stack behavior: missing project reset exited $missing_project_status, want 1" >&2
	exit 1
}
grep -Fq 'DANS_DEV_LEGACY_PROJECT_NAME' \
	"$work/missing-project.stdout" "$work/missing-project.stderr"
[ "$(sed -n '1p' "$fake_root/.dans/dev/operator-token")" = old ]

fake_lock_dir=/tmp/dans-dev-locks-$fake_user_id
mkdir -p "$fake_lock_dir"
chmod 700 "$fake_lock_dir"
fake_lock=$fake_lock_dir/dans-dev-stack-$fake_project_id.lock
fake_project_lock=$fake_lock_dir/dans-dev-compose-dans-dev-$fake_user_id-$fake_project_id.lock.lockdir
test_lock_paths="$test_lock_paths $fake_lock.lockdir $fake_project_lock"

rm -rf "$fake_lock.lockdir" "$fake_project_lock"
rm -rf "$fake_root/.dans"
mkdir -p "$fake_root/.dans/dev"
printf '%s\n' old >"$fake_root/.dans/dev/operator-token"
printf '%s\n' "dans-dev-$fake_user_id-$fake_project_id" >"$fake_root/.dans/dev/compose-project"
printf '%s\n' 'dev stack contract: phase=log-stream' >&2
logs_ready=$work/logs-ready
logs_stop=$work/logs-stop
printf '%s\n' 0 >"$work/recover-count"
printf '%s\n' 0 >"$work/me-count"
rm -f "$logs_ready" "$logs_stop"
DEV_TEST_MODE=logs-blocking \
	DEV_TEST_LOGS_READY=$logs_ready \
	DEV_TEST_LOGS_STOP=$logs_stop \
	DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
	DEV_TEST_ME_COUNT_FILE=$work/me-count \
	PATH="$work/bin:$PATH" \
	"$fake_root/scripts/dev-stack.sh" logs >"$work/logs.stdout" 2>"$work/logs.stderr" &
logs_pid=$!
attempt=0
while [ ! -e "$logs_ready" ]; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 20 ] || {
		printf '%s\n' 'dev stack behavior: logs command did not start' >&2
		exit 1
	}
	sleep 1
done
[ ! -e "$fake_lock.lockdir" ] && [ ! -e "$fake_project_lock" ] || {
	printf '%s\n' 'dev stack behavior: logs command retained an exclusive lock' >&2
	exit 1
}
stream_attempt=0
while ! grep -Fq 'live log diagnostic' "$work/logs.stderr"; do
	stream_attempt=$((stream_attempt + 1))
	[ "$stream_attempt" -lt 20 ] || {
		printf '%s\n' 'dev stack behavior: logs command buffered stderr' >&2
		exit 1
	}
	sleep 0.1
done
: >"$logs_stop"
printf '%s\n' 'dev stack contract: phase=log-stream-wait' >&2
if wait "$logs_pid"; then
	logs_status=0
else
	logs_status=$?
fi
logs_pid=
[ "$logs_status" -eq 0 ] || {
	printf '%s\n' "dev stack behavior: logs command exited $logs_status, want 0" >&2
	exit 1
}

rm -rf "$fake_root/.dans"
mkdir -p "$fake_root/.dans/dev"
printf '%s\n' old >"$fake_root/.dans/dev/operator-token"
printf '%s\n' "dans-dev-$fake_user_id-$fake_project_id" >"$fake_root/.dans/dev/compose-project"
printf '%s\n' 'dev stack contract: phase=launcher-drain' >&2
launcher_child_file=$work/launcher-child
rm -f "$launcher_child_file"
launcher_parent_group=$(process_group_id "$$" || true)
watchdog_ps_miss_file=
if [ "$(uname -s)" = Darwin ] && [ "$DEV_TEST_FAKE_IDENTITIES" = 0 ]; then
	watchdog_ps_miss_file=$work/watchdog-ps-miss
fi
if DEV_TEST_MODE=launcher-leaves-child \
	DEV_TEST_WATCHDOG_PS_MISS_FILE=$watchdog_ps_miss_file \
	DEV_TEST_LAUNCHER_CHILD_PID_FILE=$launcher_child_file \
	DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
	DEV_TEST_ME_COUNT_FILE=$work/me-count \
	PATH="$work/bin:$PATH" \
	"$fake_root/scripts/dev-stack.sh" up >"$work/launcher-child.stdout" 2>"$work/launcher-child.stderr"; then
	launcher_child_status=0
else
	launcher_child_status=$?
fi
[ -z "$watchdog_ps_miss_file" ] || [ -e "$watchdog_ps_miss_file" ] || {
	printf '%s\n' 'dev stack behavior: watchdog identity fault was not exercised' >&2
	exit 1
}
grep -Fq 'supervisor watchdog detected an escaped process' "$work/launcher-child.stderr" || {
	printf '%s\n' 'dev stack behavior: launcher watchdog did not identify escaped process' >&2
	exit 1
}
[ "$launcher_child_status" -eq 125 ] || {
	printf '%s\n' "dev stack behavior: launcher child exited $launcher_child_status, want 125" >&2
	exit 1
}
launcher_child_pid=$(sed -n '1p' "$launcher_child_file")
launcher_child_identity=$(process_identity "$launcher_child_pid" || true)
attempt=0
while process_running "$launcher_child_pid"; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 25 ] || {
		# Shared groups are fail-closed; clean only the identity recorded by this test.
		[ -z "$launcher_parent_group" ] ||
			[ "$(process_group_id "$launcher_child_pid" || true)" = "$launcher_parent_group" ] || {
				printf '%s\n' 'dev stack behavior: isolated launcher child survived drain' >&2
				exit 1
			}
		kill_process_tree "$launcher_child_pid" "$launcher_child_identity"
		launcher_child_pid=
		launcher_child_identity=
		break
	}
	sleep 1
done
[ -d "$fake_lock.lockdir" ] && [ -s "$fake_lock.lockdir/pid" ] || {
	printf '%s\n' 'dev stack behavior: launcher child did not retain the stack lock' >&2
	exit 1
}
[ -d "$fake_project_lock" ] && [ -s "$fake_project_lock/pid" ] || {
	printf '%s\n' 'dev stack behavior: launcher child did not retain the project lock' >&2
	exit 1
}
rm -f "$fake_lock.lockdir/pid" "$fake_lock.lockdir/ready" "$fake_lock.lockdir/worker-done" "$fake_lock.lockdir/operation-uncertain"
rmdir "$fake_lock.lockdir"
rm -f "$fake_project_lock/pid" "$fake_project_lock/ready" "$fake_project_lock/worker-done" "$fake_project_lock/operation-uncertain"
rmdir "$fake_project_lock"

rm -rf "$fake_root/.dans"
mkdir -p "$fake_root/.dans/dev"
printf '%s\n' old >"$fake_root/.dans/dev/operator-token"
printf '%s\n' "dans-dev-$fake_user_id-$fake_project_id" >"$fake_root/.dans/dev/compose-project"
if DEV_TEST_MODE=existing-valid \
	DEV_TEST_PGREP_FAILURE=1 \
	DEV_TEST_NONISOLATED=1 \
	DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
	DEV_TEST_ME_COUNT_FILE=$work/me-count \
	PATH="$work/bin:$PATH" \
	"$fake_root/scripts/dev-stack.sh" up >"$work/pgrep-failure.stdout" 2>"$work/pgrep-failure.stderr"; then
	pgrep_failure_status=0
else
	pgrep_failure_status=$?
fi
[ "$pgrep_failure_status" -eq 125 ] || {
	printf '%s\n' "dev stack behavior: pgrep failure exited $pgrep_failure_status, want 125" >&2
	exit 1
}
[ -d "$fake_lock.lockdir" ] && [ -s "$fake_lock.lockdir/pid" ] || {
	printf '%s\n' 'dev stack behavior: pgrep failure did not retain the stack lock' >&2
	exit 1
}
[ -d "$fake_project_lock" ] && [ -s "$fake_project_lock/pid" ] || {
	printf '%s\n' 'dev stack behavior: pgrep failure did not retain the project lock' >&2
	exit 1
}
rm -f "$fake_lock.lockdir/pid" "$fake_lock.lockdir/ready" "$fake_lock.lockdir/worker-done" "$fake_lock.lockdir/operation-uncertain"
rmdir "$fake_lock.lockdir"
rm -f "$fake_project_lock/pid" "$fake_project_lock/ready" "$fake_project_lock/worker-done" "$fake_project_lock/operation-uncertain"
rmdir "$fake_project_lock"

run_interrupted_operation() {
	interrupt_mode=$1
	interrupt_expected_status=$2
	rm -rf "$fake_root/.dans"
	mkdir -p "$fake_root/.dans/dev"
	printf '%s\n' old >"$fake_root/.dans/dev/operator-token"
	printf '%s\n' "dans-dev-$fake_user_id-$fake_project_id" >"$fake_root/.dans/dev/compose-project"
	if DEV_TEST_MODE=$interrupt_mode \
		DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
		DEV_TEST_ME_COUNT_FILE=$work/me-count \
		PATH="$work/bin:$PATH" \
		"$fake_root/scripts/dev-stack.sh" up >"$work/$interrupt_mode.stdout" 2>"$work/$interrupt_mode.stderr"; then
		interrupt_status=0
	else
		interrupt_status=$?
	fi
	[ "$interrupt_status" -eq "$interrupt_expected_status" ] || {
		printf '%s\n' "dev stack behavior: $interrupt_mode exited $interrupt_status, want $interrupt_expected_status" >&2
		exit 1
	}
	[ -d "$fake_lock.lockdir" ] && [ -s "$fake_lock.lockdir/pid" ] || {
		printf '%s\n' "dev stack behavior: $interrupt_mode did not retain the stack lock" >&2
		exit 1
	}
	[ -d "$fake_project_lock" ] && [ -s "$fake_project_lock/pid" ] || {
		printf '%s\n' "dev stack behavior: $interrupt_mode did not retain the project lock" >&2
		exit 1
	}
	rm -f "$fake_lock.lockdir/pid" "$fake_lock.lockdir/ready" "$fake_lock.lockdir/worker-done" "$fake_lock.lockdir/operation-uncertain" \
		"$fake_project_lock/pid" "$fake_project_lock/ready" "$fake_project_lock/worker-done" "$fake_project_lock/operation-uncertain"
	rmdir "$fake_lock.lockdir" "$fake_project_lock"
}

printf '%s\n' 'dev stack contract: phase=interrupt-shutdown' >&2
run_interrupted_operation bootstrap-interrupted 125
run_interrupted_operation recover-interrupted 125

interrupt_child_file=$work/interrupt-child
interrupt_operation_child_file=$work/interrupt-operation-child
interrupt_completion_marker=$work/interrupt-completion
rm -rf "$fake_root/.dans"
mkdir -p "$fake_root/.dans/dev"
rm -f "$interrupt_completion_marker"
(
	interrupt_child_process=
	interrupt_handler() {
		trap '' HUP INT TERM
		[ -n "$interrupt_child_process" ] && kill -TERM "$interrupt_child_process" 2>/dev/null || true
		exit 143
	}
	trap interrupt_handler HUP INT TERM
	export DEV_TEST_MODE=blocking
	export DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count
	export DEV_TEST_ME_COUNT_FILE=$work/me-count
	export DEV_TEST_CHILD_PID_FILE=$interrupt_child_file
	export DANS_DEV_COMPLETION_MARKER=$interrupt_completion_marker
	export PATH="$work/bin:$PATH"
	"$fake_root/scripts/dev-stack.sh" up &
	interrupt_child_process=$!
	printf '%s\n' "$interrupt_child_process" >"$interrupt_operation_child_file"
	while process_running "$interrupt_child_process"; do
		sleep 1
	done
	wait "$interrupt_child_process" 2>/dev/null || true
) >"$work/interrupt.stdout" 2>"$work/interrupt.stderr" &
interrupt_operation_pid=$!
interrupt_operation_identity=$(process_identity "$interrupt_operation_pid" || true)
attempt=0
while [ ! -s "$interrupt_child_file" ] || [ ! -s "$interrupt_operation_child_file" ]; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 20 ] || {
		printf '%s\n' 'dev stack behavior: interrupt worker did not start' >&2
		exit 1
	}
	sleep 1
done
interrupt_child_pid=$(sed -n '1p' "$interrupt_child_file")
interrupt_child_identity=$(process_identity "$interrupt_child_pid" || true)
interrupt_operation_child_pid=$(sed -n '1p' "$interrupt_operation_child_file")
interrupt_operation_child_identity=$(process_identity "$interrupt_operation_child_pid" || true)
interrupt_lock_worker_pid=$(sed -n '1p' "$fake_lock.lockdir/pid")
kill -TERM "$interrupt_lock_worker_pid"
attempt=0
while process_running "$interrupt_operation_pid"; do
	attempt=$((attempt + 1))
	# Shared process groups may use the supervisor's bounded 30-second residual probe.
	[ "$attempt" -lt 40 ] || {
		kill_process_tree "$interrupt_operation_pid" "$interrupt_operation_identity"
		printf '%s\n' 'dev stack behavior: interrupt wrapper did not exit' >&2
		exit 1
	}
	sleep 1
done
attempt=0
while process_running "$interrupt_operation_child_pid"; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 25 ] || {
		printf '%s\n' 'dev stack behavior: interrupt worker survived shutdown' >&2
		exit 1
	}
		sleep 1
	done
attempt=0
while process_running "$interrupt_child_pid"; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 25 ] || {
		printf '%s\n' 'dev stack behavior: Docker descendant survived shutdown' >&2
		exit 1
	}
	sleep 1
done

[ -d "$fake_lock.lockdir" ] && [ -s "$fake_lock.lockdir/pid" ] || {
	printf '%s\n' 'dev stack behavior: interrupt lock was not retained' >&2
	exit 1
}
[ -d "$fake_project_lock" ] && [ -s "$fake_project_lock/pid" ] || {
	printf '%s\n' 'dev stack behavior: interrupt project lock was not retained' >&2
	exit 1
}
[ ! -e "$interrupt_completion_marker" ] || {
	printf '%s\n' 'dev stack behavior: interrupted recipe published a completion marker' >&2
	exit 1
}
interrupt_operation_pid=
interrupt_operation_identity=
interrupt_operation_child_pid=
interrupt_operation_child_identity=
interrupt_child_pid=
interrupt_child_identity=
rm -f "$fake_lock.lockdir/pid" "$fake_lock.lockdir/ready" "$fake_lock.lockdir/worker-done" "$fake_lock.lockdir/operation-uncertain"
rmdir "$fake_lock.lockdir"
rm -f "$fake_project_lock/pid" "$fake_project_lock/ready" "$fake_project_lock/worker-done" "$fake_project_lock/operation-uncertain"
rmdir "$fake_project_lock"

printf '%s\n' 'dev stack contract: phase=lock-contention' >&2
lock_ready=$work/lock-ready
lock_stop=$work/lock-stop
rm -f "$lock_ready"
(umask 077 && mkdir "$fake_lock.lockdir")
(sh -c 'printf ready >"$1"; while [ ! -e "$2" ]; do sleep 1; done' sh "$lock_ready" "$lock_stop") &
lock_holder=$!
printf '%s\n' "$lock_holder" >"$fake_lock.lockdir/pid"
attempt=0
while [ ! -e "$lock_ready" ]; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 20 ] || {
		printf '%s\n' 'dev stack behavior: lock holder did not start' >&2
		exit 1
	}
	sleep 1
done
kill -0 "$lock_holder" 2>/dev/null || {
	printf '%s\n' 'dev stack behavior: lock holder exited early' >&2
	exit 1
}
printf '%s\n%s\n' "$lock_holder" "$(process_identity "$lock_holder")" >"$fake_lock.lockdir/pid"
mkdir "$fake_lock.lockdir" 2>/dev/null && lock_probe=0 || lock_probe=$?
lock_failure_status=1
[ "$lock_probe" -ne 0 ] || {
	printf '%s\n' 'dev stack behavior: lock holder did not hold the expected file' >&2
	exit 1
}
lock_dir_mode=$(stat -c '%a' "$fake_lock_dir" 2>/dev/null || stat -f '%Lp' "$fake_lock_dir")
[ "$lock_dir_mode" = 700 ] || {
	printf '%s\n' "dev stack behavior: lock directory mode is $lock_dir_mode, want 700" >&2
	exit 1
}
lock_mode=$(stat -c '%a' "$fake_lock.lockdir" 2>/dev/null || stat -f '%Lp' "$fake_lock.lockdir")
[ "$lock_mode" = 700 ] || {
	printf '%s\n' "dev stack behavior: lock directory mode is $lock_mode, want 700" >&2
	exit 1
}
run_scenario live-lock "$lock_failure_status" old old 0 0 none
grep -Fq 'development stack is already in use by process' "$work/stdout" "$work/stderr"
rm -rf "$fake_root/.dans"
mkdir -p "$fake_root/.dans/dev"
printf '%s\n' old >"$fake_root/.dans/dev/operator-token"
printf '%s\n' "dans-dev-$fake_user_id-$fake_project_id" >"$fake_root/.dans/dev/compose-project"
if DEV_TEST_MODE=existing-valid \
	DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
	DEV_TEST_ME_COUNT_FILE=$work/me-count \
	DANS_DEV_STACK_LOCK_HELD=1 PATH="$work/bin:$PATH" \
	"$fake_root/scripts/dev-stack.sh" up >"$work/unrelated-lock.stdout" 2>"$work/unrelated-lock.stderr"; then
	unrelated_lock_status=0
else
	unrelated_lock_status=$?
fi
[ "$unrelated_lock_status" -eq 1 ] || {
	printf '%s\n' "dev stack behavior: unrelated lock bypass exited $unrelated_lock_status, want 1" >&2
	exit 1
}
grep -Fq 'development stack lock ownership could not be verified' \
	"$work/unrelated-lock.stdout" "$work/unrelated-lock.stderr"
symlink_root=$work/repo-link
ln -s "$fake_root" "$symlink_root"
symlink_project_root=$(CDPATH= cd -P -- "$symlink_root" && pwd)
symlink_project_id=$(printf '%s\n' "$symlink_project_root" | cksum | awk '{print $1}')
[ "$symlink_project_id" = "$fake_project_id" ] || {
	printf '%s\n' 'dev stack behavior: symlink changed the project identity' >&2
	exit 1
}
if DEV_TEST_MODE=live-link \
	DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
	DEV_TEST_ME_COUNT_FILE=$work/me-count \
	PATH="$work/bin:$PATH" \
	"$symlink_root/scripts/dev-stack.sh" up >"$work/live-link.stdout" 2>"$work/live-link.stderr"; then
	symlink_status=0
else
	symlink_status=$?
fi
[ "$symlink_status" -eq "$lock_failure_status" ] || {
	printf '%s\n' "dev stack behavior: symlink lock exited $symlink_status, want $lock_failure_status" >&2
	exit 1
}
touch "$lock_stop"
printf '%s\n' 'dev stack contract: phase=lock-release-wait' >&2
wait "$lock_holder" 2>/dev/null || true
rm -f "$fake_lock.lockdir/pid"
rmdir "$fake_lock.lockdir" 2>/dev/null || true
(stale_pid=$$; exit 0) &
stale_pid=$!
wait "$stale_pid" 2>/dev/null || true
(umask 077 && mkdir "$fake_lock.lockdir")
printf '%s\n' "$stale_pid" >"$fake_lock.lockdir/pid"
run_scenario stale-lock 1 old old 0 0 none
grep -Fq 'development stack lock owner is unknown or inaccessible' "$work/stdout" "$work/stderr" || {
	printf '%s\n' 'dev stack behavior: inaccessible lock diagnostic was omitted' >&2
	exit 1
}
rm -f "$fake_lock.lockdir/pid"
rmdir "$fake_lock.lockdir"
lock_holder=

mismatch_stop=$work/mismatch-stop
(while [ ! -e "$mismatch_stop" ]; do sleep 1; done) &
mismatch_holder=$!
(umask 077 && mkdir "$fake_lock.lockdir")
printf '%s\n%s\n' "$mismatch_holder" mismatched-identity >"$fake_lock.lockdir/pid"
run_scenario pid-reused-lock 1 old old 0 0 none
grep -Fq 'recorded owner no longer matches' "$work/stdout" "$work/stderr" || {
	printf '%s\n' 'dev stack behavior: PID reuse diagnostic was omitted' >&2
	exit 1
}
touch "$mismatch_stop"
wait "$mismatch_holder" 2>/dev/null || true
mismatch_holder=
rm -f "$fake_lock.lockdir/pid"
rmdir "$fake_lock.lockdir"

printf '%s\n' 'dev stack contract: phase=state-paths' >&2
symlink_state=$work/foreign-state
mkdir -p "$symlink_state"
printf '%s\n' sentinel >"$symlink_state/operator-token"
rm -rf "$fake_root/.dans"
ln -s "$symlink_state" "$fake_root/.dans"
if CONFIRM=1 PATH="$work/bin:$PATH" "$fake_root/scripts/dev-stack.sh" reset \
	>"$work/state-symlink.stdout" 2>"$work/state-symlink.stderr"; then
	state_symlink_status=0
else
	state_symlink_status=$?
fi
[ "$state_symlink_status" -eq 1 ] || {
	printf '%s\n' "dev stack behavior: state symlink reset exited $state_symlink_status, want 1" >&2
	exit 1
}
grep -Fq 'local development state directory is a symlink' \
	"$work/state-symlink.stdout" "$work/state-symlink.stderr"
grep -Fxq sentinel "$symlink_state/operator-token"

shared_parent=$work/shared-parent
shared_root=$shared_parent/repo
mkdir -p "$shared_root/scripts"
cp "$root/scripts/dev-stack.sh" "$shared_root/scripts/dev-stack.sh"
chmod 755 "$shared_root/scripts/dev-stack.sh"
: >"$shared_root/compose.yaml"
chmod 777 "$shared_parent"
if PATH="$work/bin:$PATH" "$shared_root/scripts/dev-stack.sh" up \
	>"$work/shared-parent.stdout" 2>"$work/shared-parent.stderr"; then
	shared_parent_status=0
else
	shared_parent_status=$?
fi
[ "$shared_parent_status" -eq 1 ] || {
	printf '%s\n' "dev stack behavior: shared parent exited $shared_parent_status, want 1" >&2
	exit 1
}
grep -Fq 'development checkout path is writable by another user' \
	"$work/shared-parent.stdout" "$work/shared-parent.stderr"
chmod 700 "$shared_parent"

sticky_root=$work/sticky-repo
mkdir -p "$sticky_root/scripts"
cp "$root/scripts/dev-stack.sh" "$sticky_root/scripts/dev-stack.sh"
chmod 755 "$sticky_root/scripts/dev-stack.sh"
: >"$sticky_root/compose.yaml"
chmod 1777 "$sticky_root"
if PATH="$work/bin:$PATH" "$sticky_root/scripts/dev-stack.sh" up \
	>"$work/sticky-root.stdout" 2>"$work/sticky-root.stderr"; then
	sticky_root_status=0
else
	sticky_root_status=$?
fi
[ "$sticky_root_status" -eq 1 ] || {
	printf '%s\n' "dev stack behavior: sticky checkout exited $sticky_root_status, want 1" >&2
	exit 1
}
grep -Fq 'development checkout path is writable by another user' \
	"$work/sticky-root.stdout" "$work/sticky-root.stderr"

rm -rf "$fake_root/.dans"
mkdir -p "$fake_root/.dans/dev/operator-token"
if PATH="$work/bin:$PATH" "$fake_root/scripts/dev-stack.sh" up \
	>"$work/state-directory.stdout" 2>"$work/state-directory.stderr"; then
	state_directory_status=0
else
	state_directory_status=$?
fi
[ "$state_directory_status" -eq 1 ] || {
	printf '%s\n' "dev stack behavior: token directory exited $state_directory_status, want 1" >&2
	exit 1
}
grep -Fq 'local development state file is not a trusted regular file' \
	"$work/state-directory.stdout" "$work/state-directory.stderr"

rm -rf "$fake_root/.dans"
mkdir -p "$fake_root/.dans/dev"
printf '%s\n' external >"$work/external-token"
ln "$work/external-token" "$fake_root/.dans/dev/operator-token"
if PATH="$work/bin:$PATH" "$fake_root/scripts/dev-stack.sh" up \
	>"$work/state-hardlink.stdout" 2>"$work/state-hardlink.stderr"; then
	state_hardlink_status=0
else
	state_hardlink_status=$?
fi
[ "$state_hardlink_status" -eq 1 ] || {
	printf '%s\n' "dev stack behavior: token hardlink exited $state_hardlink_status, want 1" >&2
	exit 1
}
grep -Fq 'local development state file has unexpected hard links' \
	"$work/state-hardlink.stdout" "$work/state-hardlink.stderr"
grep -Fxq external "$work/external-token"

printf '%s\n' 'dev stack contract: phase=project-lock' >&2
other_root=$work/repo-other
mkdir -p "$other_root/scripts" "$other_root/.dans/dev"
cp "$root/scripts/dev-stack.sh" "$other_root/scripts/dev-stack.sh"
chmod 755 "$other_root/scripts/dev-stack.sh"
: >"$other_root/compose.yaml"
shared_project=dans-dev-$fake_user_id-shared-$fake_project_id
printf '%s\n' "$shared_project" >"$other_root/.dans/dev/compose-project"
printf '%s\n' old >"$other_root/.dans/dev/operator-token"
other_lock=$fake_lock_dir/dans-dev-compose-$shared_project.lock
test_lock_paths="$test_lock_paths $other_lock.lockdir"
lock_ready=$work/project-lock-ready
lock_stop=$work/project-lock-stop
rm -f "$lock_ready" "$lock_stop" "$other_lock"
(umask 077 && mkdir "$other_lock.lockdir")
(sh -c 'printf ready >"$1"; while [ ! -e "$2" ]; do sleep 1; done' sh "$lock_ready" "$lock_stop") &
lock_holder=$!
printf '%s\n' "$lock_holder" >"$other_lock.lockdir/pid"
attempt=0
while [ ! -e "$lock_ready" ]; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 20 ] || {
		printf '%s\n' 'dev stack behavior: project lock holder did not start' >&2
		exit 1
	}
	sleep 1
done
printf '%s\n%s\n' "$lock_holder" "$(process_identity "$lock_holder")" >"$other_lock.lockdir/pid"
if DEV_TEST_MODE=project-lock \
	DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
	DEV_TEST_ME_COUNT_FILE=$work/me-count \
	PATH="$work/bin:$PATH" \
	"$other_root/scripts/dev-stack.sh" up >"$work/project-lock.stdout" 2>"$work/project-lock.stderr"; then
	project_lock_status=0
else
	project_lock_status=$?
fi
[ "$project_lock_status" -eq "$lock_failure_status" ] || {
	printf '%s\n' "dev stack behavior: project lock exited $project_lock_status, want $lock_failure_status" >&2
	exit 1
}
grep -Fq 'development stack is already in use by process' \
	"$work/project-lock.stdout" "$work/project-lock.stderr"
touch "$lock_stop"
printf '%s\n' 'dev stack contract: phase=project-lock-release-wait' >&2
wait "$lock_holder" 2>/dev/null || true
rm -f "$other_lock.lockdir/pid"
rmdir "$other_lock.lockdir" 2>/dev/null || true
lock_holder=
foreign_lock_target=$work/foreign-lock-target
printf '%s\n' sentinel >"$foreign_lock_target"
rm -f "$other_lock"
ln -s "$foreign_lock_target" "$other_lock.lockdir"
if DEV_TEST_MODE=project-lock \
	DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
	DEV_TEST_ME_COUNT_FILE=$work/me-count \
	PATH="$work/bin:$PATH" \
	"$other_root/scripts/dev-stack.sh" up >"$work/project-symlink.stdout" 2>"$work/project-symlink.stderr"; then
	project_symlink_status=0
else
	project_symlink_status=$?
fi
[ "$project_symlink_status" -eq 1 ] || {
	printf '%s\n' "dev stack behavior: project lock symlink exited $project_symlink_status, want 1" >&2
	exit 1
}
grep -Fq 'development stack lock path is not a trusted directory' \
	"$work/project-symlink.stdout" "$work/project-symlink.stderr"
grep -Fxq sentinel "$foreign_lock_target"
rm -f "$other_lock.lockdir"
printf '%s\n' 0 >"$work/recover-count"
printf '%s\n' 0 >"$work/me-count"
if ! DEV_TEST_MODE=existing-valid \
	DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
	DEV_TEST_ME_COUNT_FILE=$work/me-count \
	PATH="$work/bin:$PATH" \
	"$other_root/scripts/dev-stack.sh" up >"$work/project-unlocked.stdout" 2>"$work/project-unlocked.stderr"; then
	printf '%s\n' 'dev stack behavior: project lock did not release' >&2
	exit 1
fi

run_scenario fresh 0 candidate none 0 1 none
[ -s "$fake_root/.dans/dev/compose-project" ] || {
	printf '%s\n' 'dev stack behavior: fresh startup did not record project ownership' >&2
	exit 1
}

rm -rf "$fake_root/.dans"

mkdir -p "$fake_root/.dans/dev"
printf '%s\n' old >"$fake_root/.dans/dev/operator-token"
printf '%s\n' "dans-dev-$fake_user_id-$fake_project_id" >"$fake_root/.dans/dev/compose-project"
printf '%s\n' 'dev stack contract: phase=reset-recovery' >&2
partial_teardown_file=$work/partial-teardown
rm -f "$partial_teardown_file"
if CONFIRM=1 DEV_TEST_MODE=reset-teardown-failure \
	DEV_TEST_PARTIAL_TEARDOWN_FILE=$partial_teardown_file \
	DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
	DEV_TEST_ME_COUNT_FILE=$work/me-count \
	PATH="$work/bin:$PATH" \
	"$fake_root/scripts/dev-stack.sh" reset >"$work/reset-teardown-failure.stdout" 2>"$work/reset-teardown-failure.stderr"; then
	reset_failure_status=0
else
	reset_failure_status=$?
fi
[ "$reset_failure_status" -eq 1 ] || {
	printf '%s\n' "dev stack behavior: failed reset exited $reset_failure_status, want 1" >&2
	exit 1
}
[ -e "$partial_teardown_file" ] || {
	printf '%s\n' 'dev stack behavior: failed reset did not model partial teardown' >&2
	exit 1
}
[ "$(sed -n '1p' "$fake_root/.dans/dev/operator-token")" = old ] || {
	printf '%s\n' 'dev stack behavior: failed reset removed the cached token' >&2
	exit 1
}
[ "$(sed -n '1p' "$fake_root/.dans/dev/compose-project")" = "dans-dev-$fake_user_id-$fake_project_id" ] || {
	printf '%s\n' 'dev stack behavior: failed reset removed project ownership' >&2
	exit 1
}

if CONFIRM=1 DEV_TEST_MODE=transport-failure \
	DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
	DEV_TEST_ME_COUNT_FILE=$work/me-count \
	PATH="$work/bin:$PATH" \
	"$fake_root/scripts/dev-stack.sh" reset >"$work/reset-transport-failure.stdout" 2>"$work/reset-transport-failure.stderr"; then
	transport_failure_status=0
else
	transport_failure_status=$?
fi
[ "$transport_failure_status" -eq 125 ] || {
	printf '%s\n' "dev stack behavior: transport failure exited $transport_failure_status, want 125" >&2
	exit 1
}
[ -d "$fake_lock.lockdir" ] && [ -d "$fake_project_lock" ] || {
	printf '%s\n' 'dev stack behavior: transport failure did not retain both locks' >&2
	exit 1
}
grep -Fq 'Cannot connect to the Docker daemon' "$work/reset-transport-failure.stderr"
rm -f "$fake_lock.lockdir/pid" "$fake_lock.lockdir/ready" "$fake_lock.lockdir/worker-done" "$fake_lock.lockdir/operation-uncertain"
rmdir "$fake_lock.lockdir"
rm -f "$fake_project_lock/pid" "$fake_project_lock/ready" "$fake_project_lock/worker-done" "$fake_project_lock/operation-uncertain"
rmdir "$fake_project_lock"

if DEV_TEST_MODE=database-preserved \
	DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
	DEV_TEST_ME_COUNT_FILE=$work/me-count \
	PATH="$work/bin:$PATH" \
	"$fake_root/scripts/dev-stack.sh" up >"$work/database-preserved.stdout" 2>"$work/database-preserved.stderr"; then
	partial_teardown_status=0
else
	partial_teardown_status=$?
fi
[ "$partial_teardown_status" -eq 0 ] || {
	printf '%s\n' "dev stack behavior: startup after partial teardown exited $partial_teardown_status" >&2
	exit 1
}
[ "$(sed -n '1p' "$fake_root/.dans/dev/operator-token")" = old ] || {
	printf '%s\n' 'dev stack behavior: database-preserved startup replaced the cached token' >&2
	exit 1
}

if DEV_TEST_MODE=database-loss \
	DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
	DEV_TEST_ME_COUNT_FILE=$work/me-count \
	PATH="$work/bin:$PATH" \
	"$fake_root/scripts/dev-stack.sh" up >"$work/database-loss.stdout" 2>"$work/database-loss.stderr"; then
	database_loss_status=0
else
	database_loss_status=$?
fi
[ "$database_loss_status" -eq 0 ] || {
	printf '%s\n' "dev stack behavior: startup after database loss exited $database_loss_status" >&2
	exit 1
}
[ "$(sed -n '1p' "$fake_root/.dans/dev/operator-token")" = candidate ] || {
	printf '%s\n' 'dev stack behavior: database-loss startup did not replace the cached token' >&2
	exit 1
}

if CONFIRM=1 DEV_TEST_MODE=reset-teardown-success \
	DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
	DEV_TEST_ME_COUNT_FILE=$work/me-count \
	PATH="$work/bin:$PATH" \
	"$fake_root/scripts/dev-stack.sh" reset >"$work/reset-teardown-success.stdout" 2>"$work/reset-teardown-success.stderr"; then
	reset_retry_status=0
else
	reset_retry_status=$?
fi
[ "$reset_retry_status" -eq 0 ] || {
	printf '%s\n' "dev stack behavior: successful reset retry exited $reset_retry_status" >&2
	exit 1
}
[ ! -e "$fake_root/.dans" ] || {
	printf '%s\n' 'dev stack behavior: successful reset retry left local state behind' >&2
	exit 1
}

for reset_attempt in clean-reset repeated-reset; do
	if CONFIRM=1 DEV_TEST_MODE="$reset_attempt" \
		DEV_TEST_RECOVER_COUNT_FILE=$work/recover-count \
		DEV_TEST_ME_COUNT_FILE=$work/me-count \
		PATH="$work/bin:$PATH" \
		"$fake_root/scripts/dev-stack.sh" reset >"$work/$reset_attempt.stdout" 2>"$work/$reset_attempt.stderr"; then
		reset_status=0
	else
		reset_status=$?
	fi
	[ "$reset_status" -eq 0 ] || {
		printf '%s\n' "dev stack behavior: $reset_attempt exited $reset_status" >&2
		exit 1
	}
	done
[ ! -e "$fake_root/.dans" ] || {
	printf '%s\n' 'dev stack behavior: clean reset left local state behind' >&2
	exit 1
}

printf '%s\n' 'dev stack behavior: ok'
