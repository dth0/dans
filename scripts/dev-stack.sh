#!/bin/sh
set -eu

root=$(CDPATH= cd -P -- "$(dirname -- "$0")/.." && pwd)
if ! (true <&0) 2>/dev/null; then
	exec 0</dev/null
fi

validate_no_extended_acl() {
	acl_path=$1
	acl_strict=${2:-0}
	acl_listing=$(ls -lde "$acl_path" 2>/dev/null || ls -ld "$acl_path" 2>/dev/null) ||
		die 'development path ACLs could not be checked'
	acl_mode=$(printf '%s\n' "$acl_listing" | awk 'NR == 1 { print $1 }')
	case "$acl_mode" in
		*+)
			[ "$acl_strict" -eq 0 ] || die 'development path has an unsupported extended ACL'
			acl_inspected=0
			if command -v getfacl >/dev/null 2>&1; then
				acl_entries=$(getfacl -cpn "$acl_path" 2>/dev/null) ||
					die 'development path ACL entries could not be inspected'
				current_user_id=$(id -u)
				current_user_name=$(id -un)
				current_group_ids=$(id -G)
				if printf '%s\n' "$acl_entries" | awk -F: \
					-v current_user_id="$current_user_id" \
					-v current_user_name="$current_user_name" '
					{
						entry_kind = $1
						principal = $2
						if ($1 == "default") {
							entry_kind = $2
							principal = $3
						}
						if (entry_kind == "user" && principal != "" &&
							principal != current_user_id && principal != current_user_name &&
							principal != 0 && $NF ~ /w/) found = 1
					}
					END { exit found ? 0 : 1 }
				'; then
					die 'development path has an ACL write grant to another user'
				fi
				if printf '%s\n' "$acl_entries" | awk -F: \
					-v current_group_ids="$current_group_ids" '
					BEGIN { group_count = split(current_group_ids, group_ids, /[[:space:]]+/) }
					{
						entry_kind = $1
						principal = $2
						if ($1 == "default") {
							entry_kind = $2
							principal = $3
						}
						if (entry_kind != "group" || principal == "" || $NF !~ /w/) next
						group_is_current = 0
						for (group_index = 1; group_index <= group_count; group_index++) {
							if (principal == group_ids[group_index]) group_is_current = 1
						}
						if (!group_is_current) found = 1
					}
					END { exit found ? 0 : 1 }
				'; then
					die 'development path has an ACL write grant to another group'
				fi
				acl_inspected=1
			elif printf '%s\n' "$acl_listing" | awk 'NR > 1 && /allow/ && /(write|delete|add_file|add_subdirectory|append|chown)/ { found = 1 } END { exit found ? 0 : 1 }'; then
				die 'development path has an ACL write grant'
			fi
			[ "$acl_inspected" -eq 1 ] ||
				[ "$(printf '%s\n' "$acl_listing" | awk 'END { print NR }')" -gt 1 ] ||
				die 'development path ACL entries could not be inspected'
			;;
	esac
}

validate_checkout_ancestors() {
	ancestor=$root
	while :; do
		[ -d "$ancestor" ] && [ ! -L "$ancestor" ] || die 'development checkout path is not a trusted directory'
		validate_no_extended_acl "$ancestor"
		ancestor_permissions=$(stat -c '%A' "$ancestor" 2>/dev/null ||
			stat -f '%Sp' "$ancestor" 2>/dev/null) ||
			die 'development checkout permissions could not be checked'
		ancestor_owner=$(stat -c '%u' "$ancestor" 2>/dev/null ||
			stat -f '%u' "$ancestor" 2>/dev/null) ||
			die 'development checkout ownership could not be checked'
		current_user_id=$(id -u)
		case "$ancestor_owner" in
			0|"$current_user_id") ;;
			*) die 'development checkout path is owned by another user' ;;
		esac
		ancestor_writable=$(printf '%s\n' "$ancestor_permissions" |
			awk '{print (substr($0, 6, 1) == "w" || substr($0, 9, 1) == "w") ? 1 : 0}')
		ancestor_sticky=$(printf '%s\n' "$ancestor_permissions" |
			awk '{print (substr($0, 10, 1) == "t" || substr($0, 10, 1) == "T") ? 1 : 0}')
		if [ "$ancestor_writable" -ne 0 ]; then
			[ "$ancestor" != "$root" ] && [ "$ancestor_sticky" -eq 1 ] ||
				die 'development checkout path is writable by another user'
		fi
		[ "$ancestor" = / ] && break
		ancestor=$(CDPATH= cd -P -- "$ancestor/.." && pwd) ||
			die 'development checkout parent could not be trusted'
	done
}

compose_file=$root/compose.yaml
credential_dir=$root/.dans/dev
token_file=$credential_dir/operator-token
project_file=$credential_dir/compose-project
ddl_url='postgres://dans_ddl:dans-ddl@postgres/dans?sslmode=disable'
runtime_url='postgres://dans_runtime:dans-runtime@postgres/dans?sslmode=disable'

die() {
	printf '%s\n' "dev stack: $*" >&2
	mark_worker_done
	exit 1
}

validate_local_state() {
	validate_all=$1
	if [ -e "$root/.dans" ] || [ -L "$root/.dans" ]; then
		[ ! -L "$root/.dans" ] || die 'local development state directory is a symlink'
		[ -d "$root/.dans" ] && [ -O "$root/.dans" ] ||
			die 'local development state directory is not owned by this user'
		validate_no_extended_acl "$root/.dans" 1
		state_permissions=$(stat -c '%A' "$root/.dans" 2>/dev/null || stat -f '%Sp' "$root/.dans" 2>/dev/null) ||
			die 'local development state directory permissions could not be checked'
		[ "$(printf '%s\n' "$state_permissions" | awk '{print (substr($0, 6, 1) == "w" || substr($0, 9, 1) == "w") ? 1 : 0}')" -eq 0 ] ||
			die 'local development state directory is writable by another user'
		[ ! -L "$root/.dans" ] || die 'local development state directory is a symlink'
	fi
	if [ -e "$credential_dir" ] || [ -L "$credential_dir" ]; then
		[ ! -L "$credential_dir" ] || die 'local development credential directory is a symlink'
		[ -d "$credential_dir" ] && [ -O "$credential_dir" ] ||
			die 'local development credential directory is not owned by this user'
		validate_no_extended_acl "$credential_dir" 1
		state_permissions=$(stat -c '%A' "$credential_dir" 2>/dev/null || stat -f '%Sp' "$credential_dir" 2>/dev/null) ||
			die 'local development credential directory permissions could not be checked'
		[ "$(printf '%s\n' "$state_permissions" | awk '{print (substr($0, 6, 1) == "w" || substr($0, 9, 1) == "w") ? 1 : 0}')" -eq 0 ] ||
			die 'local development credential directory is writable by another user'
		[ ! -L "$credential_dir" ] || die 'local development credential directory is a symlink'
	fi
	for state_file in "$token_file" "$project_file"; do
		if [ -e "$state_file" ] || [ -L "$state_file" ]; then
			[ -f "$state_file" ] && [ ! -L "$state_file" ] && [ -O "$state_file" ] ||
				die 'local development state file is not a trusted regular file'
			validate_no_extended_acl "$state_file" 1
			state_link_count=$(stat -c '%h' "$state_file" 2>/dev/null ||
				stat -f '%l' "$state_file" 2>/dev/null) ||
				die 'local development state file link count could not be checked'
			[ "$state_link_count" -eq 1 ] ||
				die 'local development state file has unexpected hard links'
			chmod 600 "$state_file" ||
				die 'local development state file permissions could not be secured'
			[ ! -L "$state_file" ] && [ -f "$state_file" ] && [ -O "$state_file" ] ||
				die 'local development state file changed while being secured'
		fi
	done
	[ "$validate_all" -eq 1 ] || return 0
	for state_file in \
		"$token_file.tmp" "$project_file.tmp" \
		"$credential_dir"/bootstrap-error "$credential_dir"/bootstrap-output \
		"$credential_dir"/recovery-error "$credential_dir"/recovery-output \
		"$credential_dir"/bootstrap-error.* "$credential_dir"/bootstrap-output.* \
		"$credential_dir"/recovery-error.* "$credential_dir"/recovery-output.* \
		"$credential_dir"/compose-project.* "$credential_dir"/operator-token.*; do
		if [ -e "$state_file" ] || [ -L "$state_file" ]; then
			[ -f "$state_file" ] && [ ! -L "$state_file" ] && [ -O "$state_file" ] ||
				die 'local development state file is not a trusted regular file'
			validate_no_extended_acl "$state_file" 1
			state_link_count=$(stat -c '%h' "$state_file" 2>/dev/null ||
				stat -f '%l' "$state_file" 2>/dev/null) ||
				die 'local development state file link count could not be checked'
			[ "$state_link_count" -eq 1 ] ||
				die 'local development state file has unexpected hard links'
			chmod 600 "$state_file" ||
				die 'local development state file permissions could not be secured'
			[ ! -L "$state_file" ] && [ -f "$state_file" ] && [ -O "$state_file" ] ||
				die 'local development state file changed while being secured'
		fi
	done
}

physical_root=$(CDPATH= cd -P -- "$root" && pwd)
project_id=$(printf '%s\n' "$physical_root" | cksum | awk '{print $1}')
user_id=$(id -u)
lock_dir=/tmp/dans-dev-locks-$user_id
stack_lock_file=$lock_dir/dans-dev-stack-$project_id.lock
default_project=dans-dev-$user_id-$project_id
operation_marker=${DANS_DEV_OPERATION_MARKER:-}
completion_marker=${DANS_DEV_COMPLETION_MARKER:-}

mark_operation_uncertain() {
	[ -n "$operation_marker" ] || return 0
	(umask 077 && : >"$operation_marker") 2>/dev/null || true
}

mark_worker_done() {
	[ -z "${DANS_DEV_LOCK_WORKER_DONE:-}" ] ||
		(umask 077 && : >"$DANS_DEV_LOCK_WORKER_DONE") 2>/dev/null || true
}

validate_checkout_ancestors

mark_operation_complete() {
	[ -n "$completion_marker" ] || return 0
	[ -e "$operation_marker" ] && return 0
	(umask 077 && : >"$completion_marker") 2>/dev/null || true
}

prepare_lock_dir() {
	if [ -L "$lock_dir" ] || { [ -e "$lock_dir" ] && [ ! -d "$lock_dir" ]; }; then
		die 'development stack lock directory is not a directory'
	fi
	if [ ! -e "$lock_dir" ]; then
		(umask 077 && mkdir "$lock_dir") || [ -d "$lock_dir" ] ||
			die 'could not create development stack lock directory'
	fi
	[ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] ||
		die 'development stack lock directory is not a trusted directory'
	[ -O "$lock_dir" ] || die 'development stack lock directory is not owned by this user'
	validate_no_extended_acl "$lock_dir" 1
	chmod 700 "$lock_dir" 2>/dev/null || die 'development stack lock directory is not owned by this user'
	[ -r "$lock_dir" ] && [ -w "$lock_dir" ] && [ -x "$lock_dir" ] ||
		die 'development stack lock directory is not accessible'
}

prepare_lock_path() {
	lock_path=$1
	lock_parent=${lock_path%/*}
	[ "$lock_parent" = "$lock_path" ] && lock_parent=.
	validate_no_extended_acl "$lock_parent" 1
	[ ! -L "$lock_path" ] && { [ ! -e "$lock_path" ] || [ -d "$lock_path" ]; } ||
		die 'development stack lock path is not a trusted directory'
	[ ! -e "$lock_path" ] || validate_no_extended_acl "$lock_path" 1
}

for command in awk ls mkfifo pgrep ps tee tr; do
	command -v "$command" >/dev/null 2>&1 || die "development stack locking requires $command"
done

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
		[ -n "$process_start" ] || return 1
		printf '%s\n' "$process_start"
	fi
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

process_parent() {
	process_id=$1
	if [ "$process_id" = "$$" ] && [ -n "${PPID:-}" ]; then
		printf '%s\n' "$PPID"
	elif [ -r "/proc/$process_id/stat" ]; then
		awk '{
			prefix = "^[0-9]+ \\(.*\\) [[:alpha:]] "
			matched = match($0, prefix)
			if (!matched) exit 1
			stat_fields = substr($0, RSTART + RLENGTH)
			split(stat_fields, fields, " ")
			if (fields[1] == "") exit 1
			print fields[1]
		}' "/proc/$process_id/stat" 2>/dev/null
	else
		parent_id=$(ps -p "$process_id" -o ppid= 2>/dev/null | tr -d '[:space:]')
		case "$parent_id" in
			''|*[!0-9]*) return 1 ;;
			*) printf '%s\n' "$parent_id" ;;
		esac
	fi
}

process_is_descendant() {
	ancestor_id=$1
	candidate_id=${2:-$$}
	ancestor_steps=0
	while [ "$candidate_id" != "$ancestor_id" ]; do
		[ "$ancestor_steps" -lt 64 ] || return 1
		candidate_parent=$(process_parent "$candidate_id" || true)
		case "$candidate_parent" in
			''|0|*[!0-9]*) return 1 ;;
		esac
		[ "$candidate_parent" != "$candidate_id" ] || return 1
		candidate_id=$candidate_parent
		ancestor_steps=$((ancestor_steps + 1))
	done
}

process_is_baseline_descendant() {
	baseline_candidate=$1
	baseline_file=$2
	baseline_steps=0
	while [ "$baseline_steps" -lt 64 ]; do
		baseline_parent=$(process_parent "$baseline_candidate" || true)
		case "$baseline_parent" in
			''|0|*[!0-9]*) return 1 ;;
		esac
		while IFS=/ read -r baseline_pid baseline_identity; do
			[ "$baseline_pid" = "$baseline_parent" ] || continue
			[ "$(process_identity "$baseline_parent" || true)" = "$baseline_identity" ] && return 0
		done <"$baseline_file"
		[ "$baseline_parent" != "$baseline_candidate" ] || return 1
		baseline_candidate=$baseline_parent
		baseline_steps=$((baseline_steps + 1))
	done
	return 1
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
		}' "/proc/$process_id/stat"
	else
		group_id=$(ps -p "$process_id" -o pgid= 2>/dev/null | tr -d '[:space:]')
		case "$group_id" in
			''|*[!0-9]*) return 1 ;;
			*) printf '%s\n' "$group_id" ;;
		esac
	fi
}

process_group_isolated() {
	candidate_group_id=$1
	caller_group_id=$(process_group_id "$$" || true)
	[ -n "$caller_group_id" ] &&
		[ "$candidate_group_id" != "$caller_group_id" ] &&
		[ "$candidate_group_id" != 0 ]
}

capture_group_baseline() {
	baseline_group_id=$1
	baseline_file=$2
	baseline_status=0
	pgrep -g "$baseline_group_id" >"$baseline_file.members" 2>/dev/null || baseline_status=$?
	[ "$baseline_status" -le 1 ] || {
		rm -f "$baseline_file" "$baseline_file.members"
		return 1
	}
	: >"$baseline_file" || return 1
	while IFS= read -r baseline_member; do
		[ -n "$baseline_member" ] || continue
		baseline_identity=$(process_identity "$baseline_member" || true)
		if [ -n "$baseline_identity" ]; then
			printf '%s/%s\n' "$baseline_member" "$baseline_identity" >>"$baseline_file"
		elif kill -0 "$baseline_member" 2>/dev/null; then
			rm -f "$baseline_file" "$baseline_file.members"
			return 1
		fi
	done <"$baseline_file.members"
	rm -f "$baseline_file.members"
}

group_has_trusted_member() {
	[ -n "${shutdown_group_id:-}" ] || return 1
	for tracked_record in $shutdown_records; do
		tracked_pid=${tracked_record%%/*}
		tracked_identity=${tracked_record#*/}
		[ "$(process_identity "$tracked_pid" || true)" = "$tracked_identity" ] || continue
		[ "$(process_group_id "$tracked_pid" || true)" = "$shutdown_group_id" ] && return 0
	done
	return 1
}

has_trusted_record() {
	for tracked_record in $shutdown_records; do
		tracked_pid=${tracked_record%%/*}
		[ "$tracked_pid" = "$shutdown_pid" ] && continue
		tracked_identity=${tracked_record#*/}
		[ "$(process_identity "$tracked_pid" || true)" = "$tracked_identity" ] && return 0
	done
	return 1
}

wait_for_lock_owner_record() {
	lock_ready_file=${DANS_DEV_LOCK_OWNER_READY:-}
	[ -n "$lock_ready_file" ] || return 0
	lock_ready_attempt=0
	while [ ! -f "$lock_ready_file" ]; do
		lock_parent=${DANS_DEV_LOCK_OWNER_PARENT:-}
		if [ -n "$lock_parent" ] && ! kill -0 "$lock_parent" 2>/dev/null; then
			die 'development stack lock owner exited before publishing its record'
		fi
		[ "$lock_ready_attempt" -lt 30 ] || die 'development stack lock owner record was not published'
		lock_ready_attempt=$((lock_ready_attempt + 1))
		sleep 1
	done
}

wait_for_lock_owner_record

validate_lock_owner() {
	owner_lock_path=$1
	[ -d "$owner_lock_path" ] && [ ! -L "$owner_lock_path" ] && [ -O "$owner_lock_path" ] || return 1
	[ -f "$owner_lock_path/pid" ] && [ ! -L "$owner_lock_path/pid" ] || return 1
	owner_pid=$(sed -n '1p' "$owner_lock_path/pid" 2>/dev/null || true)
	owner_identity=$(sed -n '2p' "$owner_lock_path/pid" 2>/dev/null || true)
	case "$owner_pid" in
		''|0|*[!0-9]*) return 1 ;;
	esac
	[ -n "$owner_identity" ] || return 1
	process_running "$owner_pid" || return 1
	current_owner_identity=$(process_identity "$owner_pid" || true)
	[ "$current_owner_identity" = "$owner_identity" ] || return 1
	process_is_descendant "$owner_pid"
}

track_process_tree() {
	track_pid=$1
	track_expected_parent=${2:-}
	if [ -n "$track_expected_parent" ] &&
		[ "$(process_parent "$track_pid" || true)" != "$track_expected_parent" ]; then
		return 0
	fi
	track_identity=$(process_identity "$track_pid" || true)
	[ -n "$track_identity" ] || return 0
	if [ -n "$track_expected_parent" ] &&
		[ "$(process_parent "$track_pid" || true)" != "$track_expected_parent" ]; then
		return 0
	fi
	track_seen=0
	for tracked_record in $shutdown_records; do
		[ "${tracked_record%%/*}" = "$track_pid" ] && track_seen=1
	done
	[ "$track_seen" -eq 1 ] || shutdown_records="$shutdown_records $track_pid/$track_identity"
	track_children=$(pgrep -P "$1" 2>/dev/null || true)
	for descendant_pid in $track_children; do
		track_process_tree "$descendant_pid" "$1"
	done
}

capture_process_tree() {
	captured_process_pid=$1
	captured_process_parent=${2:-}
	shutdown_records=
	track_process_tree "$captured_process_pid" "$captured_process_parent"
	captured_process_records=$shutdown_records
}

captured_process_matches() {
	captured_expected_pid=$1
	captured_expected_identity=$2
	for captured_record in $captured_process_records; do
		[ "${captured_record%%/*}" = "$captured_expected_pid" ] || continue
		[ "${captured_record#*/}" = "$captured_expected_identity" ] && return 0
	done
	return 1
}

signal_tracked_processes() {
	track_signal=$1
	for tracked_record in $shutdown_records; do
		tracked_pid=${tracked_record%%/*}
		tracked_identity=${tracked_record#*/}
		[ "$(process_identity "$tracked_pid" || true)" = "$tracked_identity" ] &&
			kill "-$track_signal" "$tracked_pid" 2>/dev/null || true
	done
}

reap_stopped_process() {
	reap_pid=$1
	if ! process_running "$reap_pid"; then
		wait "$reap_pid" 2>/dev/null || true
	fi
}

shutdown_process() {
	shutdown_pid=$1
	shutdown_grace=$2
	shutdown_delegate=$3
	shutdown_expected_group=${4:-}
	shutdown_expected_identity=${5:-}
	shutdown_seed_records=${6:-}
	[ -n "$shutdown_grace" ] || shutdown_grace=10
	shutdown_records=$shutdown_seed_records
	[ -n "$shutdown_expected_identity" ] || return 0
	shutdown_current_identity=$(process_identity "$shutdown_pid" || true)
	shutdown_root_matches=0
	[ "$shutdown_current_identity" = "$shutdown_expected_identity" ] && shutdown_root_matches=1
	shutdown_identity=$shutdown_expected_identity
	[ "$shutdown_root_matches" -eq 1 ] || has_trusted_record || return 0
	if [ "$shutdown_root_matches" -eq 1 ]; then
		shutdown_group_id=${shutdown_expected_group:-$(process_group_id "$shutdown_pid" || true)}
	else
		shutdown_group_id=$shutdown_expected_group
	fi
	shutdown_group=0
	[ -n "$shutdown_group_id" ] || shutdown_group_id=$shutdown_pid
	[ "$shutdown_root_matches" -eq 1 ] && track_process_tree "$shutdown_pid"
	[ -n "$shutdown_expected_group" ] &&
		group_has_trusted_member &&
		process_group_isolated "$shutdown_group_id" &&
		kill -0 "-$shutdown_group_id" 2>/dev/null && shutdown_group=1
	shutdown_attempt=0
	while :; do
		shutdown_root_matches=0
		[ -n "$shutdown_expected_identity" ] &&
			[ "$(process_identity "$shutdown_pid" || true)" = "$shutdown_expected_identity" ] &&
			shutdown_root_matches=1
		if [ "$shutdown_root_matches" -eq 0 ] &&
			[ "$shutdown_group" -eq 1 ] &&
			! group_has_trusted_member; then
			shutdown_group=0
		fi
		if [ "$shutdown_root_matches" -eq 1 ] && kill -0 "$shutdown_pid" 2>/dev/null; then
			track_process_tree "$shutdown_pid"
			if [ "$shutdown_group" -eq 1 ]; then
				if [ "$shutdown_delegate" -eq 1 ]; then
					if [ "$shutdown_root_matches" -eq 1 ]; then
						kill -TERM "$shutdown_pid" 2>/dev/null || true
					else
						signal_tracked_processes TERM
					fi
				else
					if ! kill -TERM "-$shutdown_group_id" 2>/dev/null; then
						signal_tracked_processes TERM
					fi
				fi
				[ "$shutdown_delegate" -eq 1 ] || signal_tracked_processes TERM
			else
				if [ "$shutdown_delegate" -eq 1 ]; then
					if [ "$shutdown_root_matches" -eq 1 ]; then
						kill -TERM "$shutdown_pid" 2>/dev/null || true
					else
						signal_tracked_processes TERM
					fi
				else
					signal_tracked_processes TERM
				fi
			fi
		fi
		[ "$shutdown_root_matches" -eq 1 ] || group_has_trusted_member || shutdown_group=0
		alive=0
		if [ "$shutdown_group" -eq 1 ]; then
			[ "$shutdown_root_matches" -eq 1 ] && process_running "$shutdown_pid" && alive=1
			if [ "$alive" -eq 0 ]; then
				for tracked_record in $shutdown_records; do
					tracked_pid=${tracked_record%%/*}
					[ "$tracked_pid" = "$shutdown_pid" ] && continue
					tracked_identity=${tracked_record#*/}
					[ "$(process_identity "$tracked_pid" || true)" = "$tracked_identity" ] &&
						process_running "$tracked_pid" && alive=1
				done
			fi
		else
			for tracked_record in $shutdown_records; do
				tracked_pid=${tracked_record%%/*}
			tracked_identity=${tracked_record#*/}
				[ "$(process_identity "$tracked_pid" || true)" = "$tracked_identity" ] &&
					process_running "$tracked_pid" && alive=1
			done
		fi
		[ "$alive" -eq 0 ] && break
		[ "$shutdown_attempt" -lt "$shutdown_grace" ] || break
		shutdown_attempt=$((shutdown_attempt + 1))
		sleep 1
	done
	if [ "$shutdown_group" -eq 1 ] &&
		group_has_trusted_member &&
		kill -0 "-$shutdown_group_id" 2>/dev/null; then
		if ! kill -KILL "-$shutdown_group_id" 2>/dev/null; then
			signal_tracked_processes KILL
		fi
	elif [ "$shutdown_group" -eq 0 ]; then
		signal_tracked_processes KILL
	fi
	if [ "$shutdown_group" -eq 0 ]; then
		shutdown_attempt=0
		while :; do
			alive=0
			for tracked_record in $shutdown_records; do
				tracked_pid=${tracked_record%%/*}
				[ "$tracked_pid" = "$shutdown_pid" ] && continue
				tracked_identity=${tracked_record#*/}
				[ "$(process_identity "$tracked_pid" || true)" = "$tracked_identity" ] &&
					process_running "$tracked_pid" && alive=1
			done
			[ "$alive" -eq 0 ] && break
			[ "$shutdown_attempt" -lt 10 ] || break
			shutdown_attempt=$((shutdown_attempt + 1))
			sleep 1
		done
	fi
	signal_tracked_processes KILL
	reap_stopped_process "$shutdown_pid"
}

shutdown_descendants() {
	shutdown_round=0
	while descendants=$(pgrep -P "$1" 2>/dev/null) && [ -n "$descendants" ]; do
		for shutdown_descendant_pid in $descendants; do
			shutdown_descendant_identity=$(process_identity "$shutdown_descendant_pid" || true)
			[ -n "$shutdown_descendant_identity" ] || continue
			capture_process_tree "$shutdown_descendant_pid" "$1"
			captured_process_matches "$shutdown_descendant_pid" "$shutdown_descendant_identity" || continue
			shutdown_process "$shutdown_descendant_pid" 10 0 '' "$shutdown_descendant_identity" "$captured_process_records"
		done
		shutdown_round=$((shutdown_round + 1))
		[ "$shutdown_round" -lt 4 ] || break
	done
}

diagnose_mkdir_lock() {
	lock_path=$1
	[ -f "$lock_path/pid" ] || die 'development stack is already in use (lock owner is unknown)'
	owner_pid=$(sed -n '1p' "$lock_path/pid" 2>/dev/null || true)
	owner_identity=$(sed -n '2p' "$lock_path/pid" 2>/dev/null || true)
	case "$owner_pid" in
		''|0|*[!0-9]*) die 'development stack lock owner is unknown or inaccessible; verify no operation is active before removing its lock directory' ;;
	esac
	[ -n "$owner_identity" ] ||
		die 'development stack lock owner is unknown or inaccessible; verify no operation is active before removing its lock directory'
	current_owner_identity=$(process_identity "$owner_pid" || true)
	[ -n "$current_owner_identity" ] ||
		die 'development stack lock owner is unknown or inaccessible; verify no operation is active before removing its lock directory'
	if [ "$current_owner_identity" != "$owner_identity" ]; then
		die 'development stack lock is stale; recorded owner no longer matches the process at that PID'
	fi
	if process_running "$owner_pid"; then
		die "development stack is already in use by process $owner_pid"
	fi
	die 'development stack lock is stale; verify no operation is active, then remove its lock directory'
}

acquire_mkdir_lock() {
	lock_path=$1
	env_name=$2
	shift 2
	lock_acquired=0
	worker_pid=
	worker_group_id=
	worker_records=
	initializing=1
	signal_pending=0
	signal_cleanup() {
		status=$1
		retain_lock=$2
		trap '' HUP INT TERM
		if [ -n "${worker_pid:-}" ]; then
			shutdown_process "$worker_pid" 180 1 "$worker_group_id" "${worker_identity:-}" "${worker_records:-}"
			reap_stopped_process "$worker_pid"
		fi
		if [ "$retain_lock" -eq 0 ] && [ "$lock_acquired" -eq 1 ]; then
			rm -f "$lock_path/pid" "$lock_path/ready" "$lock_path/worker-done"
			rmdir "$lock_path" 2>/dev/null || true
		elif [ "$retain_lock" -eq 1 ] && [ "$lock_acquired" -eq 1 ]; then
			printf '%s\n' 'dev stack: interrupted operation left its lock for manual stale-lock recovery' >&2
		fi
		exit "$status"
	}
	signal_handler() {
		if [ "$initializing" -eq 1 ]; then
			signal_pending=1
		else
			signal_cleanup 143 1
		fi
	}
	trap signal_handler HUP INT TERM
	prepare_lock_path "$lock_path"
	if ! (umask 077 && mkdir "$lock_path") 2>/dev/null; then
		diagnose_mkdir_lock "$lock_path"
	fi
	lock_acquired=1
	set -m
		env "$env_name=1" \
		DANS_DEV_OPERATION_MARKER="$lock_path/operation-uncertain" \
		DANS_DEV_LOCK_WORKER_DONE="$lock_path/worker-done" \
		DANS_DEV_LOCK_OWNER_READY="$lock_path/ready" \
		DANS_DEV_LOCK_OWNER_PARENT="$$" \
		DANS_DEV_LOCK_PARENT_GROUP="$(process_group_id "$$" || true)" \
		DANS_DEV_STACK_LOCK_OWNER="${DANS_DEV_STACK_LOCK_OWNER:-$stack_lock_file}" \
		DANS_DEV_PROJECT_LOCK_OWNER="${DANS_DEV_PROJECT_LOCK_OWNER:-${project_lock_file:-}}" \
		sh -c '
			wrapper_child_pid=
			wrapper_child_identity=
			wrapper_identity_unavailable=0
			wrapper_interrupted=0
			wrapper_process_identity() {
				wrapper_process_id=$1
				if [ -r "/proc/$wrapper_process_id/stat" ]; then
					IFS= read -r wrapper_process_stat <"/proc/$wrapper_process_id/stat" || return 1
					wrapper_process_stat=${wrapper_process_stat##*) }
					set -- $wrapper_process_stat
					[ -n "${20:-}" ] || return 1
					printf "%s\\n" "${20}"
					return 0
				fi
				wrapper_process_start=$(ps -p "$wrapper_process_id" -o lstart= 2>/dev/null | tr -d "[:space:]")
				[ -n "$wrapper_process_start" ] || return 1
				printf "%s\\n" "$wrapper_process_start"
			}
			wrapper_child_matches() {
				[ -n "$wrapper_child_identity" ] &&
					kill -0 "$wrapper_child_pid" 2>/dev/null &&
					[ "$(wrapper_process_identity "$wrapper_child_pid" || true)" = "$wrapper_child_identity" ]
			}
			wrapper_signal() {
				wrapper_interrupted=1
				[ -n "$wrapper_child_pid" ] && wrapper_child_matches &&
					kill -TERM "$wrapper_child_pid" 2>/dev/null || true
			}
			trap wrapper_signal HUP INT TERM
			set +m
			export DANS_DEV_LOCK_PARENT_WRAPPER_PID=${DANS_DEV_LOCK_WRAPPER_PID:-}
			export DANS_DEV_LOCK_WRAPPER_PID=$$
			export DANS_DEV_LOCK_OWNER_PARENT=$$
			wrapper_parent_group=${DANS_DEV_LOCK_PARENT_GROUP:-}
			wrapper_baseline_file=
			wrapper_baseline_probe_failed=0
			wrapper_cleanup_baseline() {
				[ -z "${wrapper_baseline_file:-}" ] ||
					rm -f "$wrapper_baseline_file" "$wrapper_baseline_file.records"
			}
			trap wrapper_cleanup_baseline 0
			if [ -n "$wrapper_parent_group" ]; then
				wrapper_baseline_file=$(mktemp "$DANS_DEV_LOCK_WORKER_DONE.baseline.XXXXXX") || exit 125
				wrapper_baseline_status=0
				pgrep -g "$wrapper_parent_group" >"$wrapper_baseline_file" 2>/dev/null || wrapper_baseline_status=$?
				[ "$wrapper_baseline_status" -le 1 ] || wrapper_baseline_probe_failed=1
				: >"$wrapper_baseline_file.records" || exit 125
				if [ "$wrapper_baseline_probe_failed" -eq 0 ]; then
					while IFS= read -r wrapper_baseline_member; do
						[ -n "$wrapper_baseline_member" ] || continue
						wrapper_baseline_identity=$(wrapper_process_identity "$wrapper_baseline_member" || true)
						if [ -n "$wrapper_baseline_identity" ]; then
							printf "%s/%s\\n" "$wrapper_baseline_member" "$wrapper_baseline_identity" >>"$wrapper_baseline_file.records"
						elif kill -0 "$wrapper_baseline_member" 2>/dev/null; then
							wrapper_baseline_probe_failed=1
						fi
					done <"$wrapper_baseline_file"
				fi
			fi
			[ "$wrapper_interrupted" -eq 0 ] || exit 143
			"$@" &
			wrapper_child_pid=$!
			wrapper_child_identity=$(wrapper_process_identity "$wrapper_child_pid" || true)
			[ -n "$wrapper_child_identity" ] || wrapper_identity_unavailable=1
			if [ "$wrapper_interrupted" -ne 0 ]; then
				[ "$wrapper_identity_unavailable" -eq 0 ] || exit 125
				wrapper_child_matches || exit 143
				kill -TERM "$wrapper_child_pid" 2>/dev/null || true
			fi
			if wait "$wrapper_child_pid"; then
				wrapper_status=0
			else
				wrapper_status=$?
			fi
			[ -n "${DANS_DEV_LOCK_WORKER_DONE:-}" ] || exit 125
			wrapper_group_id=$(ps -p "$$" -o pgid= 2>/dev/null | tr -d "[:space:]")
			wrapper_group_isolated=0
			if [ -n "$wrapper_group_id" ] && [ -n "$wrapper_parent_group" ]; then
				case "$wrapper_group_id" in
					0|*[!0-9]*) ;;
					*)
						case "$wrapper_parent_group" in
							0|*[!0-9]*) ;;
							*)
								if [ "$wrapper_group_id" != "$wrapper_parent_group" ]; then
									wrapper_group_isolated=1
								fi
								;;
						esac
						;;
				esac
			fi
			wrapper_group_baseline=0
			if [ "$wrapper_group_isolated" -eq 0 ] &&
				[ -n "$wrapper_parent_group" ] &&
				[ "$wrapper_group_id" = "$wrapper_parent_group" ]; then
				wrapper_group_baseline=1
			fi
			wrapper_members_file=
			wrapper_remaining=0
			if [ "$wrapper_group_isolated" -eq 1 ] || [ "$wrapper_group_baseline" -eq 1 ]; then
				wrapper_members_file=$(mktemp "$DANS_DEV_LOCK_WORKER_DONE.members.XXXXXX") || exit 125
				wrapper_attempt=0
				wrapper_probe_failed=0
				if [ "$wrapper_group_baseline" -eq 1 ] &&
					[ "$wrapper_baseline_probe_failed" -ne 0 ]; then
					wrapper_probe_failed=1
				fi
				while :; do
					wrapper_remaining=0
					if [ "$wrapper_probe_failed" -eq 0 ]; then
						wrapper_pgrep_status=0
						: >"$wrapper_members_file" || wrapper_probe_failed=1
						: >"$wrapper_members_file.records" || wrapper_probe_failed=1
						pgrep -g "$wrapper_group_id" >"$wrapper_members_file" 2>/dev/null || wrapper_pgrep_status=$?
						[ "$wrapper_pgrep_status" -le 1 ] || wrapper_probe_failed=1
						while IFS= read -r wrapper_member; do
							[ -n "$wrapper_member" ] || continue
							wrapper_member_identity=$(wrapper_process_identity "$wrapper_member" || true)
							if [ -z "$wrapper_member_identity" ]; then
								kill -0 "$wrapper_member" 2>/dev/null && wrapper_probe_failed=1
								continue
							fi
							wrapper_baseline_match=0
							if [ "$wrapper_group_baseline" -eq 1 ]; then
								while IFS=/ read -r wrapper_baseline_pid wrapper_baseline_identity; do
									if [ "$wrapper_baseline_pid" = "$wrapper_member" ] &&
										[ "$wrapper_baseline_identity" = "$wrapper_member_identity" ]; then
										wrapper_baseline_match=1
										break
									fi
								done <"$wrapper_baseline_file.records"
							fi
							[ "$wrapper_baseline_match" -eq 1 ] ||
								printf "%s/%s\\n" "$wrapper_member" "$wrapper_member_identity" >>"$wrapper_members_file.records"
							if [ "$wrapper_member" != "$$" ]; then
								[ "$wrapper_baseline_match" -eq 1 ] || wrapper_remaining=1
							fi
						done <"$wrapper_members_file"
					else
						wrapper_remaining=1
					fi
					if [ "$wrapper_probe_failed" -ne 0 ]; then
						wrapper_remaining=1
						wrapper_attempt=30
					fi
					[ "$wrapper_remaining" -eq 0 ] || [ "$wrapper_attempt" -ge 30 ] || {
						wrapper_attempt=$((wrapper_attempt + 1))
						sleep 1
						continue
					}
					break
				done
				if [ "$wrapper_remaining" -ne 0 ]; then
					if [ "$wrapper_group_isolated" -eq 1 ]; then
						while IFS=/ read -r wrapper_member wrapper_member_identity; do
							[ "$wrapper_member" = "$$" ] ||
								{ [ -n "$wrapper_member_identity" ] &&
									[ "$(wrapper_process_identity "$wrapper_member" || true)" = "$wrapper_member_identity" ] &&
									kill -KILL "$wrapper_member" 2>/dev/null || true; }
						done <"$wrapper_members_file.records"
					fi
					rm -f "$wrapper_members_file"
					rm -f "$wrapper_members_file.records"
					exit 125
				fi
				rm -f "$wrapper_members_file"
				rm -f "$wrapper_members_file.records"
				[ -z "$wrapper_baseline_file" ] || {
					rm -f "$wrapper_baseline_file" "$wrapper_baseline_file.records"
				}
			else
				wrapper_descendant_probe_status=0
				pgrep -P "$$" >/dev/null 2>&1 || wrapper_descendant_probe_status=$?
				[ "$wrapper_descendant_probe_status" -eq 1 ] || exit 125
			fi
			if [ "$wrapper_interrupted" -eq 0 ]; then
				if [ -n "${DANS_DEV_LOCK_WORKER_DONE:-}" ] &&
					[ ! -e "$DANS_DEV_LOCK_WORKER_DONE" ]; then
					exit 125
				fi
				exit "$wrapper_status"
			fi
			[ "$wrapper_identity_unavailable" -eq 0 ] || exit 125
			wrapper_child_matches || exit 143
			kill -TERM "$wrapper_child_pid" 2>/dev/null || true
			wrapper_attempt=0
			while wrapper_child_matches; do
				if [ "$wrapper_attempt" -ge 180 ]; then
					wrapper_child_matches && kill -KILL "$wrapper_child_pid" 2>/dev/null || true
					exit 125
				fi
				wrapper_attempt=$((wrapper_attempt + 1))
				sleep 1
			done
			exit 143
		' dans-lock-wrapper "$@" &
	worker_pid=$!
	set +m
	worker_group_id=$(process_group_id "$worker_pid" || true)
	worker_identity=$(process_identity "$worker_pid" || true)
	capture_process_tree "$worker_pid"
	worker_records=$captured_process_records
	if [ -n "${DANS_DEV_LOCK_PUBLISH_DELAY:-}" ]; then
		sleep "$DANS_DEV_LOCK_PUBLISH_DELAY"
	fi
	if [ -z "$worker_identity" ] ||
		! (umask 077 && printf '%s\n%s\n' "$worker_pid" "$worker_identity" >"$lock_path/pid" &&
			: >"$lock_path/ready"); then
		initializing=0
		signal_cleanup 1 0
		die 'could not initialize development stack lock'
	fi
	initializing=0
	capture_process_tree "$worker_pid"
	worker_records=$captured_process_records
	[ "$signal_pending" -eq 0 ] || signal_cleanup 143 1
	if wait "$worker_pid"; then
		rc=0
	else
		rc=$?
	fi
	if [ -e "$lock_path/operation-uncertain" ]; then
		trap ':' HUP INT TERM
		printf '%s\n' 'dev stack: Docker operation completion is uncertain; lock retained for manual stale-lock recovery' >&2
		return 125
	fi
	if [ "$rc" -eq 125 ] || [ "$rc" -ge 128 ]; then
		shutdown_process "$worker_pid" 180 1 "$worker_group_id" "${worker_identity:-}" "${worker_records:-}"
		reap_stopped_process "$worker_pid"
		trap ':' HUP INT TERM
		printf '%s\n' 'dev stack: worker terminated abnormally; lock retained for manual stale-lock recovery' >&2
		return "$rc"
	fi
	trap ':' HUP INT TERM
	rm -f "$lock_path/pid" "$lock_path/ready" "$lock_path/worker-done"
	rmdir "$lock_path" 2>/dev/null || die 'could not release development stack lock'
	return "$rc"
}

acquire_stack_lock() {
	if [ "${DANS_DEV_STACK_LOCK_HELD:-}" = 1 ]; then
		validate_lock_owner "$stack_lock_file.lockdir" "${DANS_DEV_STACK_LOCK_OWNER_IDENTITY:-}" ||
			die 'development stack lock ownership could not be verified'
		return 0
	fi
	if [ -n "${DANS_DEV_STACK_LOCK_OWNER:-}" ]; then
		[ "$DANS_DEV_STACK_LOCK_OWNER" = "$stack_lock_file" ] &&
			validate_lock_owner "$stack_lock_file.lockdir" "${DANS_DEV_STACK_LOCK_OWNER_IDENTITY:-}" ||
			die 'development stack lock ownership could not be verified'
		return 0
	fi
	prepare_lock_dir
	if acquire_mkdir_lock "$stack_lock_file.lockdir" DANS_DEV_STACK_LOCK_HELD "$0" "$@"; then
		acquire_status=0
	else
		acquire_status=$?
	fi
	mark_worker_done
	exit "$acquire_status"
}

acquire_project_lock() {
	if [ "${DANS_DEV_PROJECT_LOCK_HELD:-}" = 1 ]; then
		validate_lock_owner "$project_lock_file.lockdir" "${DANS_DEV_PROJECT_LOCK_OWNER_IDENTITY:-}" ||
			die 'development project lock ownership could not be verified'
		return 0
	fi
	[ "${project_lock_shared:-0}" -eq 1 ] || prepare_lock_dir
	if acquire_mkdir_lock "$project_lock_file.lockdir" DANS_DEV_PROJECT_LOCK_HELD "$@"; then
		acquire_status=0
	else
		acquire_status=$?
	fi
	mark_worker_done
	exit "$acquire_status"
}

command=${1:-}
case "$command" in
	up|down|smoke|smoke-host|reset|status) acquire_stack_lock "$@" ;;
esac
case "$command" in
	up|down|smoke|smoke-host|reset) validate_local_state 0 ;;
	status|logs) validate_local_state 0 ;;
esac

if [ -s "$project_file" ]; then
	[ -O "$credential_dir" ] && [ -O "$project_file" ] ||
		die 'local development state is owned by another user'
	COMPOSE_PROJECT_NAME=$(sed -n '1p' "$project_file")
elif [ -s "$token_file" ]; then
	[ -O "$credential_dir" ] && [ -O "$token_file" ] ||
		die 'local development credentials are owned by another user'
	[ "$command" = reset ] ||
		die 'local project ownership is missing; refusing automatic recovery'
	COMPOSE_PROJECT_NAME=${DANS_DEV_LEGACY_PROJECT_NAME:-}
	[ -n "$COMPOSE_PROJECT_NAME" ] ||
		die 'local project ownership is missing; set DANS_DEV_LEGACY_PROJECT_NAME after verifying the legacy Compose project'
else
	COMPOSE_PROJECT_NAME=$default_project
fi
case "$COMPOSE_PROJECT_NAME" in
	''|[!a-z0-9]*|*[!a-z0-9_-]*) die 'invalid local Compose project identity' ;;
	dans-dev|dans-dev-$user_id-*) : ;;
	dans-dev-[0-9]*)
		legacy_suffix=${COMPOSE_PROJECT_NAME#dans-dev-}
		case "$legacy_suffix" in
			''|*[!0-9]*) die 'invalid legacy local Compose project identity' ;;
		esac
		;;
	*) die 'local Compose project identity belongs to another user' ;;
esac
export COMPOSE_PROJECT_NAME
project_lock_shared=0
case "$COMPOSE_PROJECT_NAME" in
	dans-dev)
		# Legacy names can be independently owned by different users; share one
		# sticky-directory lock so their Docker resources cannot be mutated concurrently.
		project_lock_shared=1
		project_lock_file=/tmp/dans-dev-compose-$COMPOSE_PROJECT_NAME.lock
		;;
	dans-dev-[0-9]*)
	legacy_suffix=${COMPOSE_PROJECT_NAME#dans-dev-}
	case "$legacy_suffix" in
		''|*[!0-9]*)
			prepare_lock_dir
			project_lock_file=$lock_dir/dans-dev-compose-$COMPOSE_PROJECT_NAME.lock
			;;
		*)
			project_lock_shared=1
			project_lock_file=/tmp/dans-dev-compose-$COMPOSE_PROJECT_NAME.lock
			;;
	esac
		;;
	*)
		prepare_lock_dir
		project_lock_file=$lock_dir/dans-dev-compose-$COMPOSE_PROJECT_NAME.lock
		;;
esac
case "$command" in
	status|logs) prepare_lock_dir ;;
esac
case "$command" in
	up|down|smoke|smoke-host|reset) acquire_project_lock "$0" "$@" ;;
esac
case "$command" in
	up|down|smoke|smoke-host|reset) validate_local_state 1 ;;
	status|logs) validate_local_state 0 ;;
esac

running_pid=
running_group_id=
running_identity=
running_records=
running_launch_marker=
running_launch_wait=
running_launch_lease=
running_launch_capture_stderr=1
running_group_baseline_file=
launching=0
pending_signal=0
capture_output_file=
capture_error_file=
project_temp=
token_temp=
forward_signal() {
	status=$1
	if [ "$launching" -eq 1 ]; then
		pending_signal=1
		return
	fi
	trap ':' HUP INT TERM
	mark_operation_uncertain
	if [ -n "${running_pid:-}" ]; then
		shutdown_process "$running_pid" 10 0 "${running_group_id:-}" "${running_identity:-}" "${running_records:-}"
	else
		shutdown_descendants "$$"
	fi
	clear_stopped_supervised_launch
	[ -z "$capture_output_file" ] || rm -f "$capture_output_file"
	[ -z "$capture_error_file" ] || rm -f "$capture_error_file"
	exit "$status"
}
trap 'forward_signal 143' HUP INT TERM

running_processes_drained() {
	for tracked_record in $running_records; do
		tracked_pid=${tracked_record%%/*}
		[ "$tracked_pid" = "$running_pid" ] && continue
		if process_running "$tracked_pid"; then
			tracked_current_identity=$(process_identity "$tracked_pid" || true)
			if [ -z "$tracked_current_identity" ]; then
				return 1
			elif [ "$tracked_current_identity" = "${tracked_record#*/}" ]; then
				return 1
			fi
		fi
	done
	return 0
}

running_group_drained() {
	if [ -z "${running_group_id:-}" ]; then
		return 1
	fi
	if ! process_group_isolated "$running_group_id"; then
		[ -n "${running_group_baseline_file:-}" ] || return 1
		running_group_file=$(mktemp "$lock_dir/process-group.XXXXXX") || return 1
		running_group_status=0
		pgrep -g "$running_group_id" >"$running_group_file" 2>/dev/null || running_group_status=$?
		if [ "$running_group_status" -gt 1 ]; then
			rm -f "$running_group_file"
			return 1
		fi
		running_group_operation_seen=0
		while IFS= read -r running_group_member; do
			[ -n "$running_group_member" ] || continue
			[ "$running_group_member" = "$running_pid" ] && continue
			process_running "$running_group_member" || continue
			running_group_identity=$(process_identity "$running_group_member" || true)
			if [ -z "$running_group_identity" ]; then
				process_running "$running_group_member" || continue
				rm -f "$running_group_file"
				return 1
			fi
			running_group_baseline_match=0
			while IFS=/ read -r running_baseline_pid running_baseline_identity; do
				if [ "$running_baseline_pid" = "$running_group_member" ] &&
					[ "$running_baseline_identity" = "$running_group_identity" ]; then
					running_group_baseline_match=1
					break
				fi
			done <"$running_group_baseline_file"
			if [ "$running_group_baseline_match" -eq 0 ]; then
				running_group_operation_member=0
				if process_is_descendant "$running_pid" "$running_group_member"; then
					running_group_operation_member=1
				else
					running_group_parent=$(process_parent "$running_group_member" || true)
					[ -n "$running_group_parent" ] || {
						rm -f "$running_group_file"
						process_running "$running_group_member" || continue
						return 1
					}
					for tracked_record in $running_records; do
						[ "${tracked_record%%/*}" = "$running_group_member" ] || continue
						[ "${tracked_record#*/}" = "$running_group_identity" ] || continue
						running_group_operation_member=1
						break
					done
					if [ "$running_group_operation_member" -eq 0 ] &&
						process_is_baseline_descendant "$running_group_member" "$running_group_baseline_file"; then
						continue
					fi
				fi
				process_running "$running_group_member" || continue
				if [ "$running_group_operation_member" -ne 1 ]; then
					rm -f "$running_group_file"
					return 1
				fi
				running_group_operation_seen=1
			fi
		done <"$running_group_file"
		rm -f "$running_group_file"
		[ "${running_group_operation_seen:-0}" -eq 0 ]
		return $?
	fi
	running_group_file=$(mktemp "$lock_dir/process-group.XXXXXX") || return 1
	running_group_status=0
	pgrep -g "$running_group_id" >"$running_group_file" 2>/dev/null || running_group_status=$?
	if [ "$running_group_status" -gt 1 ]; then
		rm -f "$running_group_file"
		return 1
	fi
	while IFS= read -r running_group_member; do
		[ -n "$running_group_member" ] || continue
		[ "$running_group_member" = "$running_pid" ] && continue
		process_running "$running_group_member" || continue
		process_running "$running_group_member" || continue
		rm -f "$running_group_file"
		return 1
	done <"$running_group_file"
	rm -f "$running_group_file"
}

terminate_running_group() {
	[ -n "${running_group_id:-}" ] || return 1
	process_group_isolated "$running_group_id" || return 1
	running_group_file=$(mktemp "$lock_dir/process-group.XXXXXX") || return 1
	running_group_status=0
	pgrep -g "$running_group_id" >"$running_group_file" 2>/dev/null || running_group_status=$?
	if [ "$running_group_status" -gt 1 ]; then
		rm -f "$running_group_file"
		return 1
	fi
	running_group_trusted=0
	while IFS= read -r running_group_member; do
		[ -n "$running_group_member" ] || continue
		running_group_identity=$(process_identity "$running_group_member" || true)
		[ -n "$running_group_identity" ] || continue
		for tracked_record in $running_records; do
			tracked_pid=${tracked_record%%/*}
			tracked_identity=${tracked_record#*/}
			[ "$tracked_pid" = "$running_group_member" ] || continue
			[ "$tracked_identity" = "$running_group_identity" ] || continue
			[ "$(process_group_id "$running_group_member" || true)" = "$running_group_id" ] || continue
			running_group_trusted=1
			break
		done
		[ "$running_group_trusted" -eq 1 ] && break
	done <"$running_group_file"
	[ "$running_group_trusted" -eq 1 ] || {
		rm -f "$running_group_file"
		return 1
	}
	while IFS= read -r running_group_member; do
		[ -n "$running_group_member" ] || continue
		[ "$running_group_member" = "$$" ] && continue
		[ "$running_group_member" = "$running_pid" ] && continue
		running_group_identity=$(process_identity "$running_group_member" || true)
		[ -n "$running_group_identity" ] || {
			rm -f "$running_group_file"
			return 1
		}
		[ "$(process_group_id "$running_group_member" || true)" = "$running_group_id" ] || continue
		[ "$(process_identity "$running_group_member" || true)" = "$running_group_identity" ] || continue
		kill -KILL "$running_group_member" 2>/dev/null || true
	done <"$running_group_file"
	rm -f "$running_group_file"
}

drain_running_processes() {
	if ! running_group_drained; then
		printf '%s\n' 'dev stack: operation process-group drain check failed' >&2
	elif ! running_processes_drained; then
		printf '%s\n' 'dev stack: tracked operation process drain check failed' >&2
	else
		return 0
	fi
	terminate_running_group || return 1
	return 1
}

clear_supervised_launch() {
	[ -z "${running_launch_marker:-}" ] ||
		rm -f "$running_launch_marker" "$running_launch_marker.ready" \
		"$running_launch_marker.go" "$running_launch_marker.cancel" \
		"$running_launch_marker.status" "$running_launch_marker.finished" \
		"$running_launch_marker.escaped" "$running_launch_marker.lease-ready" \
		"$running_launch_marker.stderr" "$running_launch_marker.stderr.pipe" \
		"$running_launch_marker.watchdog"
	[ -z "${running_launch_wait:-}" ] || rm -f "$running_launch_wait" "$running_launch_wait.writer"
	[ -z "${running_launch_lease:-}" ] || rm -f "$running_launch_lease"
	[ -z "${running_group_baseline_file:-}" ] ||
		rm -f "$running_group_baseline_file" "$running_group_baseline_file.members"
	running_launch_marker=
	running_launch_wait=
	running_launch_lease=
	running_launch_capture_stderr=1
	running_group_baseline_file=
}

clear_stopped_supervised_launch() {
	if [ -n "${running_pid:-}" ] && process_running "$running_pid"; then
		return 0
	fi
	clear_supervised_launch
}

write_supervised_signal() {
	supervised_signal=$1
	[ -n "${running_launch_wait:-}" ] || return 1
	supervised_writer_status_file=$running_launch_wait.writer
	rm -f "$supervised_writer_status_file"
	(
		if printf '%s\n' "$supervised_signal" >"$running_launch_wait"; then
			printf '%s\n' 0 >"$supervised_writer_status_file"
		else
			printf '%s\n' 1 >"$supervised_writer_status_file"
		fi
	) &
	supervised_writer_pid=$!
	supervised_writer_attempt=0
	while [ ! -s "$supervised_writer_status_file" ]; do
		if [ "$supervised_writer_attempt" -ge 30 ]; then
			kill -TERM "$supervised_writer_pid" 2>/dev/null || true
			wait "$supervised_writer_pid" 2>/dev/null || true
			rm -f "$supervised_writer_status_file"
			return 1
		fi
		supervised_writer_attempt=$((supervised_writer_attempt + 1))
		sleep 0.1
	done
	wait "$supervised_writer_pid" 2>/dev/null || true
	supervised_writer_status=$(sed -n '1p' "$supervised_writer_status_file" 2>/dev/null || true)
	rm -f "$supervised_writer_status_file"
	[ "$supervised_writer_status" = 0 ]
}

cancel_supervised_launch() {
	[ -z "${running_launch_marker:-}" ] ||
		(umask 077 && : >"$running_launch_marker.cancel") 2>/dev/null || true
	if [ -n "${running_pid:-}" ]; then
		cancel_attempt=0
		supervisor_signal_sent=0
		while process_running "$running_pid"; do
			[ -z "${running_identity:-}" ] ||
				[ "$(process_identity "$running_pid" || true)" = "$running_identity" ] || break
			kill -CONT "$running_pid" 2>/dev/null || true
			if [ "$supervisor_signal_sent" -eq 0 ] && [ -e "${running_launch_marker:-}.finished" ]; then
				write_supervised_signal cancel || true
				supervisor_signal_sent=1
			fi
			if [ "$cancel_attempt" -ge 30 ]; then
				kill -TERM "$running_pid" 2>/dev/null || true
				sleep 1
				[ "$(process_identity "$running_pid" || true)" = "$running_identity" ] &&
					kill -KILL "$running_pid" 2>/dev/null || true
				break
			fi
			cancel_attempt=$((cancel_attempt + 1))
			sleep 0.1
		done
		wait "$running_pid" 2>/dev/null || true
	fi
	clear_supervised_launch
	running_pid=
	running_group_id=
	running_identity=
	running_records=
	running_launch_wait=
}

launch_supervised() {
	# Detached/daemonizing launchers are unsupported; keep the foreground allowlist explicit.
	case "${1:-}:${2:-}" in
		docker:compose|sh:-c) ;;
		*) return 1 ;;
	esac
	running_launch_capture_stderr=1
	case " $* " in
		*" logs "*) running_launch_capture_stderr=0 ;;
	esac
	running_launch_marker=$(mktemp "$lock_dir/operation-launch.XXXXXX") || return 1
	rm -f "$running_launch_marker"
	running_launch_wait=$running_launch_marker.wait
	running_launch_lease=$running_launch_marker.lease
	mkfifo "$running_launch_wait" || {
		running_launch_wait=
		clear_supervised_launch
		return 1
	}
	mkfifo "$running_launch_lease" || {
		clear_supervised_launch
		return 1
	}
	mkfifo "$running_launch_marker.stderr.pipe" || {
		clear_supervised_launch
		return 1
	}
	exec 9<&0
	sh -c '
		launch_marker=$1
		stderr_capture=$2
		shift 2
		stderr_forward_pid=
		supervisor_watchdog_pid=
		watchdog_process_identity() {
			watchdog_process_id=$1
			if [ -r "/proc/$watchdog_process_id/stat" ]; then
				IFS= read -r watchdog_process_stat <"/proc/$watchdog_process_id/stat" || return 1
				watchdog_process_stat=${watchdog_process_stat##*) }
				set -- $watchdog_process_stat
				[ -n "${20:-}" ] || return 1
				printf "%s\\n" "${20}"
				return 0
			fi
			watchdog_process_start=$(ps -p "$watchdog_process_id" -o lstart= 2>/dev/null | tr -d "[:space:]")
			[ -n "$watchdog_process_start" ] || return 1
			printf "%s\\n" "$watchdog_process_start"
		}
		stop_supervisor_watchdog() {
			if [ -n "${supervisor_watchdog_pid:-}" ]; then
				watchdog_attempt=0
				while [ ! -s "$launch_marker.watchdog" ] && [ "$watchdog_attempt" -lt 30 ]; do
					watchdog_attempt=$((watchdog_attempt + 1))
					sleep 0.1
				done
				watchdog_sleep_pid=$(sed -n "1p" "$launch_marker.watchdog" 2>/dev/null || true)
				watchdog_sleep_identity=$(sed -n "2p" "$launch_marker.watchdog" 2>/dev/null || true)
				if [ -n "$watchdog_sleep_pid" ] && [ -n "$watchdog_sleep_identity" ] &&
					[ "$(watchdog_process_identity "$watchdog_sleep_pid" || true)" = "$watchdog_sleep_identity" ]; then
					kill -KILL "$watchdog_sleep_pid" 2>/dev/null || true
				fi
				kill -TERM "$supervisor_watchdog_pid" 2>/dev/null || true
				wait "$supervisor_watchdog_pid" 2>/dev/null || true
			fi
			rm -f "$launch_marker.watchdog"
		}
		supervisor_cleanup() {
			stop_supervisor_watchdog
			[ -z "${stderr_forward_pid:-}" ] || {
				kill -TERM "$stderr_forward_pid" 2>/dev/null || true
				wait "$stderr_forward_pid" 2>/dev/null || true
			}
		}
		trap supervisor_cleanup EXIT
		if [ "$stderr_capture" -eq 1 ]; then
			tee "$launch_marker.stderr" <"$launch_marker.stderr.pipe" >&2 8>&- &
		else
			tee <"$launch_marker.stderr.pipe" >&2 8>&- &
		fi
		stderr_forward_pid=$!
		exec 8<>"$launch_marker.lease" || exit 125
		(
			exec 7<"$launch_marker.lease" || exit 125
			: >"$launch_marker.lease-ready" || exit 125
			while IFS= read -r lease_line; do :; done <&7
		) 8>&- &
		lease_reader_pid=$!
		lease_reader_attempt=0
		while [ ! -e "$launch_marker.lease-ready" ]; do
			kill -0 "$lease_reader_pid" 2>/dev/null || exit 125
			[ "$lease_reader_attempt" -lt 300 ] || exit 125
			lease_reader_attempt=$((lease_reader_attempt + 1))
			sleep 0.1
		done
		(umask 077 && : >"$launch_marker.ready") || exit 125
		while [ ! -e "$launch_marker.go" ]; do
			[ ! -e "$launch_marker.cancel" ] || exit 125
			sleep 0.1
		done
		"$@" 2>"$launch_marker.stderr.pipe"
		supervisor_status=$?
		[ "${DANS_DEV_TEST_TRACE_SUPERVISOR:-0}" != 1 ] || printf "%s\n" "dev stack contract: supervisor=child-exited" >&5
		exec 8>&-
			(
				watchdog_sleep_pid=
				watchdog_stop() { exit 0; }
				watchdog_cleanup() {
					if [ -n "${watchdog_sleep_pid:-}" ]; then
						watchdog_cleanup_pid=$watchdog_sleep_pid
						watchdog_cleanup_identity=${watchdog_sleep_identity:-}
						watchdog_sleep_pid=
						watchdog_sleep_identity=
						if [ -n "$watchdog_cleanup_identity" ] &&
							[ "$(watchdog_process_identity "$watchdog_cleanup_pid" || true)" = "$watchdog_cleanup_identity" ]; then
							kill -KILL "$watchdog_cleanup_pid" 2>/dev/null || true
						fi
						wait "$watchdog_cleanup_pid" 2>/dev/null || true
					fi
				}
				trap watchdog_cleanup EXIT
				trap watchdog_stop HUP INT TERM
				sleep 10 &
				watchdog_sleep_pid=$!
				watchdog_sleep_identity=$(watchdog_process_identity "$watchdog_sleep_pid" || true)
				printf "%s\\n%s\\n" "$watchdog_sleep_pid" "$watchdog_sleep_identity" >"$launch_marker.watchdog"
				if wait "$watchdog_sleep_pid" 2>/dev/null; then
					watchdog_sleep_pid=
					watchdog_sleep_identity=
				else
					watchdog_sleep_pid=
					watchdog_sleep_identity=
					exit 0
				fi
			(umask 077 && : >"$launch_marker.escaped") 2>/dev/null || true
			kill -TERM "$lease_reader_pid" 2>/dev/null || true
			kill -TERM "$stderr_forward_pid" 2>/dev/null || true
		) &
		supervisor_watchdog_pid=$!
		wait "$lease_reader_pid" 2>/dev/null || true
		wait "$stderr_forward_pid" 2>/dev/null || true
		[ "${DANS_DEV_TEST_TRACE_SUPERVISOR:-0}" != 1 ] || printf "%s\n" "dev stack contract: supervisor=streams-drained" >&5
		stop_supervisor_watchdog
		[ "${DANS_DEV_TEST_TRACE_SUPERVISOR:-0}" != 1 ] || printf "%s\n" "dev stack contract: supervisor=watchdog-stopped" >&5
		supervisor_watchdog_pid=
		stderr_forward_pid=
		[ ! -e "$launch_marker.escaped" ] || supervisor_status=125
		(umask 077 && printf "%s\\n" "$supervisor_status" >"$launch_marker.status" &&
			: >"$launch_marker.finished") || exit 125
		[ "${DANS_DEV_TEST_TRACE_SUPERVISOR:-0}" != 1 ] || printf "%s\n" "dev stack contract: supervisor=finished" >&5
		read -r supervisor_release <"$launch_marker.wait" || exit 125
		[ "${DANS_DEV_TEST_TRACE_SUPERVISOR:-0}" != 1 ] || printf "%s\n" "dev stack contract: supervisor=released" >&5
		exit "$supervisor_status"
	' dans-operation-supervisor "$running_launch_marker" "$running_launch_capture_stderr" "$@" <&9 &
	running_pid=$!
	exec 9<&-
	launch_attempt=0
	while [ ! -e "$running_launch_marker.ready" ]; do
		if ! kill -0 "$running_pid" 2>/dev/null; then
			wait "$running_pid" 2>/dev/null || true
			clear_supervised_launch
			running_pid=
			return 1
		fi
		if [ "$launch_attempt" -ge 300 ]; then
			cancel_supervised_launch
			return 1
		fi
		launch_attempt=$((launch_attempt + 1))
		sleep 0.1
	done
	running_group_id=$(process_group_id "$running_pid" || true)
	running_identity=$(process_identity "$running_pid" || true)
	if [ -z "$running_group_id" ] || [ -z "$running_identity" ]; then
		cancel_supervised_launch
		return 1
	fi
	if ! process_group_isolated "$running_group_id"; then
		running_group_baseline_file=$(mktemp "$lock_dir/operation-group.XXXXXX") || {
			cancel_supervised_launch
			return 1
		}
		if ! capture_group_baseline "$running_group_id" "$running_group_baseline_file"; then
			cancel_supervised_launch
			return 1
		fi
	fi
	capture_process_tree "$running_pid"
	if ! (umask 077 && : >"$running_launch_marker.go"); then
		cancel_supervised_launch
		return 1
	fi
}

merge_running_records() {
	for observed_record in $1; do
		observed_seen=0
		for tracked_record in $running_records; do
			[ "$tracked_record" = "$observed_record" ] && {
				observed_seen=1
				break
			}
		done
		[ "$observed_seen" -eq 1 ] || running_records="$running_records $observed_record"
	done
}

	wait_supervised() {
		while [ ! -e "$running_launch_marker.finished" ]; do
			process_running "$running_pid" || {
				printf '%s\n' 'dev stack: supervisor exited before completion was recorded' >&2
				mark_operation_uncertain
				return 125
			}
		capture_process_tree "$running_pid"
		merge_running_records "$captured_process_records"
		sleep 0.1
	done
	capture_process_tree "$running_pid"
	merge_running_records "$captured_process_records"
	[ ! -e "$running_launch_marker.escaped" ] || {
		printf '%s\n' 'dev stack: supervisor watchdog detected an escaped process' >&2
		mark_operation_uncertain
		return 125
	}
	running_status=$(sed -n '1p' "$running_launch_marker.status" 2>/dev/null || true)
	case "$running_status" in
		''|*[!0-9]*)
			printf '%s\n' 'dev stack: supervisor status was not verifiable' >&2
			mark_operation_uncertain
			return 125
			;;
		*) ;;
	esac
	if [ "$running_status" -ne 0 ] && [ "$running_launch_capture_stderr" -eq 1 ] &&
		[ -s "$running_launch_marker.stderr" ] &&
		grep -Eiq '(cannot connect to the Docker daemon|error during connect|context deadline exceeded|i/o timeout|tls handshake timeout|server gave HTTP response|daemon.*(unavailable|not responding))' \
		"$running_launch_marker.stderr"; then
		printf '%s\n' 'dev stack: Docker transport failure made completion uncertain' >&2
		mark_operation_uncertain
		return 125
	fi
	return "$running_status"
}

release_supervised_launch() {
	write_supervised_signal release || return 1
	[ -z "${running_pid:-}" ] || wait "$running_pid" 2>/dev/null || true
}

compose() {
	[ -z "$operation_marker" ] || [ ! -e "$operation_marker" ] || return 125
	pending_signal=0
	launching=1
	set -m
	if [ -t 0 ]; then
		if ! launch_supervised docker compose --file "$compose_file" "$@" </dev/null; then
			launching=0
			printf '%s\n' 'dev stack: Docker operation could not be started or supervised' >&2
			mark_operation_uncertain
			return 125
		fi
	else
		exec 3<&0
		if ! launch_supervised docker compose --file "$compose_file" "$@" <&3; then
			exec 3<&-
			launching=0
			printf '%s\n' 'dev stack: Docker operation could not be started or supervised' >&2
			mark_operation_uncertain
			return 125
		fi
		exec 3<&-
	fi
	running_records=$captured_process_records
	set +m
	launching=0
	[ "$pending_signal" -eq 0 ] || forward_signal 143
	[ "${DANS_DEV_TEST_TRACE_SUPERVISOR:-0}" != 1 ] || printf '%s\n' 'dev stack contract: caller=wait-start' >&5
	if wait_supervised; then
		rc=0
	else
		rc=$?
	fi
	[ "${DANS_DEV_TEST_TRACE_SUPERVISOR:-0}" != 1 ] || printf '%s\n' 'dev stack contract: caller=wait-done' >&5
	if ! drain_running_processes; then
		printf '%s\n' 'dev stack: Docker operation left an untrusted process behind' >&2
		mark_operation_uncertain
		cancel_supervised_launch
		running_pid=
		running_group_id=
		running_identity=
		running_records=
		return 125
	fi
	[ "${DANS_DEV_TEST_TRACE_SUPERVISOR:-0}" != 1 ] || printf '%s\n' 'dev stack contract: caller=processes-drained' >&5
	release_supervised_launch || {
		printf '%s\n' 'dev stack: Docker operation supervisor could not be released' >&2
		mark_operation_uncertain
		cancel_supervised_launch
		return 125
	}
	[ "${DANS_DEV_TEST_TRACE_SUPERVISOR:-0}" != 1 ] || printf '%s\n' 'dev stack contract: caller=release-done' >&5
	[ "$rc" -ge 128 ] && mark_operation_uncertain
	clear_supervised_launch
	running_pid=
	running_group_id=
	running_identity=
	running_records=
	return "$rc"
}

json_string() {
	field=$1
	value=$(sed -n 's/.*"'"$field"'":"\([^"]*\)".*/\1/p')
	[ -n "$value" ] || die "response omitted $field"
	printf '%s\n' "$value"
}

json_bool() {
	field=$1
	value=$(sed -n \
		's/.*"'"$field"'":true.*/true/p; s/.*"'"$field"'":false.*/false/p')
	[ -n "$value" ] || die "response omitted $field"
	printf '%s\n' "$value"
}

wait_postgres() {
	attempt=0
	until compose exec -T postgres pg_isready -U dans_ddl -d dans >/dev/null 2>&1; do
		[ -n "$operation_marker" ] && [ -e "$operation_marker" ] && exit 125
		attempt=$((attempt + 1))
		[ "$attempt" -lt 60 ] || die 'PostgreSQL did not become ready'
		sleep 1
	done
}

wait_ready() {
	attempt=0
	# `dans health ready` calls the public /readyz endpoint.
	until compose exec -T dans /usr/local/bin/dans health ready >/dev/null 2>&1; do
		[ -n "$operation_marker" ] && [ -e "$operation_marker" ] && exit 125
		attempt=$((attempt + 1))
		[ "$attempt" -lt 60 ] || die 'DANS did not become ready'
		sleep 1
	done
}

offline_capture() {
	[ -z "$operation_marker" ] || [ ! -e "$operation_marker" ] || return 125
	output_file=$1
	error_file=$2
	shift 2
	capture_output_file=$output_file
	capture_error_file=$error_file
	pending_signal=0
	launching=1
	set -m
	if ! launch_supervised docker compose --file "$compose_file" run --rm --no-deps -T \
		-e DANS_DATABASE_URL="$runtime_url" -e DANS_OUTPUT=json dans "$@" \
		</dev/null >"$output_file" 2>"$error_file"; then
		launching=0
		mark_operation_uncertain
		return 125
	fi
	running_records=$captured_process_records
	set +m
	launching=0
	[ "$pending_signal" -eq 0 ] || forward_signal 143
	if wait_supervised; then
		rc=0
	else
		rc=$?
	fi
	if ! drain_running_processes; then
		mark_operation_uncertain
		cancel_supervised_launch
		running_pid=
		running_group_id=
		running_identity=
		running_records=
		return 125
	fi
	release_supervised_launch || {
		mark_operation_uncertain
		cancel_supervised_launch
		return 125
	}
	[ "$rc" -ge 128 ] && mark_operation_uncertain
	clear_supervised_launch
	running_pid=
	running_group_id=
	running_identity=
	running_records=
	return "$rc"
}

capture_temp() {
	capture_prefix=$1
	capture_path=$(mktemp "$credential_dir/$capture_prefix.XXXXXX") ||
		die 'could not create private development capture file'
	chmod 600 "$capture_path" || {
		rm -f "$capture_path"
		die 'could not secure private development capture file'
	}
	case "$capture_prefix" in
		*-output) capture_output_file=$capture_path ;;
		*-error) capture_error_file=$capture_path ;;
	esac
}

cleanup_captures() {
	clear_stopped_supervised_launch
	[ -z "$capture_output_file" ] || rm -f "$capture_output_file"
	[ -z "$capture_error_file" ] || rm -f "$capture_error_file"
	[ -z "$project_temp" ] || rm -f "$project_temp"
	[ -z "$token_temp" ] || rm -f "$token_temp"
	mark_operation_complete
	mark_worker_done
}
trap cleanup_captures EXIT

validate_identity() {
	response=$1
	handle=$(printf '%s\n' "$response" | json_string handle)
	enabled=$(printf '%s\n' "$response" | json_bool enabled)
	operator=$(printf '%s\n' "$response" | json_bool operator)
	[ "$handle" = dev-operator ] || return 1
	[ "$enabled" = true ] || return 1
	[ "$operator" = true ] || return 1
}

validate_credential() {
	token=$1
	if response=$(cli_with_token "$token" me get 2>&1); then
		validate_identity "$response" || {
			printf '%s\n' 'dev stack: credential belongs to an unexpected identity' >&2
			return 1
		}
		return 0
	else
		status=$?
		if [ "$status" -eq 1 ] && printf '%s\n' "$response" | grep -Fq '401 Unauthorized'; then
			return 10
		fi
		printf '%s\n' 'dev stack: credential validation failed' >&2
		return 1
	fi
}

publish_credential() {
	credential=$1
	secret=$(printf '%s\n' "$credential" | json_string secret)
	validate_credential "$secret" || die 'issued credential failed validation'
	rm -f "$token_file.tmp"
	token_temp=$(mktemp "$credential_dir/operator-token.XXXXXX") ||
		die 'could not create private development token file'
	if ! (umask 077; printf '%s\n' "$secret" >"$token_temp"); then
		rm -f "$token_temp"
		token_temp=
		die 'write operator token failed'
	fi
	if ! chmod 600 "$token_temp"; then
		rm -f "$token_temp"
		token_temp=
		die 'secure operator token failed'
	fi
	if ! mv "$token_temp" "$token_file"; then
		rm -f "$token_temp"
		token_temp=
		die 'install operator token failed'
	fi
	token_temp=
	rm -f "$token_file.tmp"
}

ensure_token() {
	if [ -s "$token_file" ]; then
		token=$(sed -n '1p' "$token_file")
		if validate_credential "$token"; then
			chmod 600 "$token_file"
			return
		else
			status=$?
			[ "$status" -eq 10 ] || die 'cached operator credential is unusable'
		fi
	fi
	recovery_label=local-recovery-$(date +%s)-$$
	capture_temp recovery-output
	recovery_output=$capture_path
	capture_temp recovery-error
	recovery_error=$capture_path
	if offline_capture "$recovery_output" "$recovery_error" recover operator-token \
		--handle dev-operator --token-label "$recovery_label"; then
		credential=$(cat "$recovery_output")
		rm -f "$recovery_output" "$recovery_error"
		capture_output_file=
		capture_error_file=
	else
		recovery_status=$?
		if [ "$recovery_status" -ge 128 ]; then
			cat "$recovery_error" >&2
			rm -f "$recovery_output" "$recovery_error"
			capture_output_file=
			capture_error_file=
			printf '%s\n' 'dev stack: credential recovery was interrupted; the operation may still be active' >&2
			exit "$recovery_status"
		fi
		cat "$recovery_error" >&2
		rm -f "$recovery_output" "$recovery_error"
		capture_output_file=
		capture_error_file=
		die 'operator credential recovery failed'
	fi
	publish_credential "$credential"
}

cli_with_token() {
	token=$1
	shift
	compose exec -T \
		-e DANS_ENDPOINT=http://127.0.0.1:8080/api/v1 \
		-e DANS_API_TOKEN="$token" -e DANS_OUTPUT=json \
		dans /usr/local/bin/dans "$@"
}

operator_cli() {
	[ -s "$token_file" ] || die 'operator token is missing; run make up'
	token=$(sed -n '1p' "$token_file")
	cli_with_token "$token" "$@"
}

operator_data() {
	body=$1
	shift
	printf '%s\n' "$body" | operator_cli "$@" --data=-
}

host_prerequisites() {
	for command in curl dig; do
		command -v "$command" >/dev/null 2>&1 || die "make smoke-host requires host command $command"
	done
}

host_published_port() {
	service=$1
	private_port=$2
	protocol=${3:-}
	if [ -n "$protocol" ]; then
		if ! mapping=$(compose port --protocol "$protocol" "$service" "$private_port" 2>/dev/null); then
			die "host port lookup failed for $service $private_port"
		fi
	else
		if ! mapping=$(compose port "$service" "$private_port" 2>/dev/null); then
			die "host port lookup failed for $service $private_port"
		fi
	fi
	[ -n "$mapping" ] ||
		die "host port lookup failed for $service $private_port"
	port=${mapping##*:}
	case "$port" in
		''|*[!0-9]*) die "host port lookup returned an invalid port for $service $private_port" ;;
	esac
	printf '%s\n' "$port"
}

host_http_probe() {
	url=$1
	expected_status=$2
	expected_body=$3
	response=$(mktemp "${TMPDIR:-/tmp}/dans-host-http.XXXXXX") ||
		die 'host HTTP probe could not create a temporary response file'
	if ! status=$(curl --noproxy '*' --connect-timeout 2 --max-time 5 --silent --show-error \
		--output "$response" --write-out '%{http_code}' "$url" 2>/dev/null); then
		rm -f "$response"
		die "host HTTP probe failed (url $url)"
	fi
	if [ "$status" != "$expected_status" ]; then
		rm -f "$response"
		die "host HTTP probe returned status $status (url $url)"
	fi
	case "$expected_body" in
		empty)
		if [ -s "$response" ]; then
			rm -f "$response"
			die "host HTTP probe returned unexpected content (url $url)"
		fi
		;;
	*)
		if ! grep -Fq "$expected_body" "$response"; then
			rm -f "$response"
			die "host HTTP probe returned unexpected content (url $url)"
		fi
		;;
	esac
	rm -f "$response"
}

host_dns_probe() {
	transport=$1
	owner=$2
	value=$3
	dns_port=$(host_published_port powerdns 53 "$transport")
	case "$transport" in
		udp) transport_options='+notcp' ;;
		tcp) transport_options='+tcp' ;;
		*) die "host DNS probe has unknown transport $transport" ;;
	esac
	if ! answer=$(dig @127.0.0.1 -p "$dns_port" +time=2 +tries=1 +norecurse \
		+noedns +ignore +noall +comments +answer "$transport_options" "$owner" A 2>/dev/null); then
		die "host DNS $transport probe failed (port $dns_port)"
	fi
	printf '%s\n' "$answer" | grep -Fq 'status: NOERROR' ||
		die "host DNS $transport probe returned a non-success status (port $dns_port)"
	if printf '%s\n' "$answer" | grep -Eq '^;; flags:.*(^|[[:space:]])tc([;[:space:]]|$)'; then
		die "host DNS $transport probe returned a truncated response (port $dns_port)"
	fi
	printf '%s\n' "$answer" | grep -Eq '^;; flags:.*(^|[[:space:]])aa([;[:space:]]|$)' ||
		die "host DNS $transport probe was not authoritative (port $dns_port)"
	printf '%s\n' "$answer" | awk -v owner="$owner" -v value="$value" \
		'$1 == owner && $4 == "A" && $5 == value { found = 1 } END { exit found ? 0 : 1 }' ||
		die "host DNS $transport probe returned the wrong answer (port $dns_port)"
}

host_smoke() {
	owner=$1
	value=$2
	http_port=$(host_published_port dans 8080)
	http_root=http://127.0.0.1:$http_port
	host_http_probe "$http_root/readyz" 200 empty
	host_http_probe "$http_root/console/" 200 '<div id="root">'
	host_dns_probe udp "$owner" "$value"
	host_dns_probe tcp "$owner" "$value"
}

up() {
	(umask 077 && mkdir -p "$credential_dir") ||
		die 'could not create private development state directory'
	chmod 700 "$root/.dans" "$credential_dir" ||
		die 'could not secure private development state directory'
	validate_local_state 1
	if [ ! -s "$project_file" ]; then
		project_temp=$(mktemp "$credential_dir/compose-project.XXXXXX") ||
			die 'could not create private development project file'
		if ! (umask 077; printf '%s\n' "$COMPOSE_PROJECT_NAME" >"$project_temp"); then
			rm -f "$project_temp"
			project_temp=
			die 'could not write private development project file'
		fi
		chmod 600 "$project_temp" || {
			rm -f "$project_temp"
			project_temp=
			die 'could not secure private development project file'
		}
		mv "$project_temp" "$project_file" || {
			rm -f "$project_temp"
			project_temp=
			die 'could not install private development project file'
		}
		project_temp=
	fi
	compose build dans
	compose up --detach postgres powerdns
	wait_postgres
	compose run --rm --no-deps -T -e DANS_DATABASE_URL="$ddl_url" \
		-e DANS_OUTPUT=json dans db migrate >/dev/null
	compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U dans_ddl -d dans \
		--set=database_name=dans --set=schema_name=public \
		--set=runtime_role=dans_runtime --file=/dans/runtime.sql >/dev/null
	capture_temp bootstrap-output
	bootstrap_output=$capture_path
	capture_temp bootstrap-error
	bootstrap_error=$capture_path
	if offline_capture "$bootstrap_output" "$bootstrap_error" bootstrap \
		--handle dev-operator --display-name 'Dev operator' --token-label local; then
		bootstrap_candidate=$(cat "$bootstrap_output")
		rm -f "$bootstrap_output" "$bootstrap_error"
		capture_output_file=
		capture_error_file=
	else
		bootstrap_status=$?
		if [ "$bootstrap_status" -ge 128 ]; then
			cat "$bootstrap_error" >&2
			rm -f "$bootstrap_output" "$bootstrap_error"
			capture_output_file=
			capture_error_file=
			printf '%s\n' 'dev stack: bootstrap was interrupted; the operation may still be active' >&2
			exit "$bootstrap_status"
		fi
		if ! grep -Fq 'database: conflict' "$bootstrap_error"; then
			cat "$bootstrap_error" >&2
			rm -f "$bootstrap_output" "$bootstrap_error"
			capture_output_file=
			capture_error_file=
			die 'bootstrap failed'
		fi
		rm -f "$bootstrap_output" "$bootstrap_error"
		capture_output_file=
		capture_error_file=
		bootstrap_candidate=
	fi
	compose up --detach dans
	wait_ready
	if [ -n "$bootstrap_candidate" ]; then
		publish_credential "$bootstrap_candidate"
	else
		ensure_token
	fi
	printf '%s\n' \
		"DANS: http://127.0.0.1:${DANS_DEV_HTTP_PORT:-8080}" \
		"DNS:  127.0.0.1:${DANS_DEV_DNS_PORT:-1053}" \
		"Console: http://localhost:${DANS_DEV_HTTP_PORT:-8080}/console/" \
		"Console token: $(sed -n '1p' "$token_file")"
}

smoke() {
	host_access=0
	if [ "${1:-}" = host ]; then
		host_access=1
		host_prerequisites
	fi
	compose ps --status running --services | grep -Fxq dans || die 'DANS is not running; run make up'
	wait_ready
	suffix=$(date +%s)-$$
	handle=smoke-$suffix
	zone=smoke-$suffix.test.
	allowed=allowed.$zone
	denied=denied.$zone

	identity=$(operator_data "{\"kind\":\"service\",\"handle\":\"$handle\",\"display_name\":\"Smoke service\"}" identities create)
	identity_id=$(printf '%s\n' "$identity" | json_string id)
	credential=$(operator_data '{"label":"smoke"}' identities tokens create "$identity_id")
	service_token=$(printf '%s\n' "$credential" | json_string secret)
	created_zone=$(operator_data "{\"name\":\"$zone\",\"kind\":\"Native\",\"nameservers\":[\"ns1.$zone\"]}" zones create)
	zone_id=$(printf '%s\n' "$created_zone" | json_string id)
	binding=$(operator_cli bindings list --zone-name "$zone")
	binding_id=$(printf '%s\n' "$binding" | json_string id)
	operator_data "{\"zone_binding_id\":\"$binding_id\",\"identity_id\":\"$identity_id\",\"selectors\":[{\"kind\":\"exact\",\"value\":\"$allowed\"}],\"record_types\":[\"A\"],\"change_kinds\":[\"REPLACE\"]}" delegations create >/dev/null

	cli_with_token "$service_token" rrsets replace "$zone_id" "$allowed" A \
		--ttl 60 --value 192.0.2.10 >/dev/null
	set +e
	denied_output=$(cli_with_token "$service_token" rrsets replace "$zone_id" "$denied" A \
		--ttl 60 --value 192.0.2.11 2>&1)
	denied_status=$?
	set -e
	[ "$denied_status" -eq 1 ] || die "denied RRset write exited $denied_status instead of 1"
	printf '%s\n' "$denied_output" | grep -Fq '403 Forbidden' || die 'denied RRset write did not report 403 Forbidden'

	dns=$(compose run --rm --no-deps -T cli nslookup "$allowed" powerdns 2>&1)
	printf '%s\n' "$dns" | grep -Fq 192.0.2.10 || die 'authoritative DNS answer omitted 192.0.2.10'
	audit=$(operator_cli audit list --actor "$identity_id" --action powerdns.zone.patch \
		--target-type zone_binding --target "$binding_id" --result succeeded)
	printf '%s\n' "$audit" | grep -Fq '"action":"powerdns.zone.patch"' || die 'succeeded RRset audit event is missing'
	printf '%s\n' "$audit" | grep -Fq '"result":"succeeded"' || die 'RRset audit event did not succeed'
	printf '%s\n' "$audit" | grep -Fq '"actor_id":"'"$identity_id"'"' || die 'audit event has the wrong actor'
	printf '%s\n' "$audit" | grep -Fq '"target_id":"'"$binding_id"'"' || die 'audit event has the wrong binding'
	if [ "$host_access" -eq 1 ]; then
		host_smoke "$allowed" 192.0.2.10
		printf '%s\n' "smoke-host: ok (zone $zone, identity $handle; fixtures retained)"
	else
		printf '%s\n' "smoke: ok (zone $zone, identity $handle; fixtures retained)"
	fi
}

reset() {
	[ "${CONFIRM:-}" = 1 ] || die 'reset deletes local data; rerun with CONFIRM=1'
	if [ ! -s "$project_file" ]; then
		if [ ! -d "$credential_dir" ]; then
			(umask 077 && mkdir -p "$credential_dir") ||
				die 'could not create private development state directory for reset'
		fi
		chmod 700 "$root/.dans" "$credential_dir" ||
			die 'could not secure private development state directory for reset'
		project_temp=$(mktemp "$credential_dir/compose-project.XXXXXX") ||
			die 'could not create private development project file for reset recovery'
		if ! (umask 077; printf '%s\n' "$COMPOSE_PROJECT_NAME" >"$project_temp"); then
			rm -f "$project_temp"
			project_temp=
			die 'could not persist the development project identity for reset recovery'
		fi
		chmod 600 "$project_temp" || {
			rm -f "$project_temp"
			project_temp=
			die 'could not secure the development project identity for reset recovery'
		}
		mv "$project_temp" "$project_file" || {
			rm -f "$project_temp"
			project_temp=
			die 'could not persist the development project identity for reset recovery'
		}
		project_temp=
	fi
	compose --profile tools down --volumes --remove-orphans
	rm -f "$token_file" "$token_file.tmp" \
		"$credential_dir/bootstrap-error" "$credential_dir/bootstrap-output" \
		"$credential_dir/recovery-error" "$credential_dir/recovery-output" \
		"$credential_dir"/bootstrap-error.* "$credential_dir"/bootstrap-output.* \
		"$credential_dir"/recovery-error.* "$credential_dir"/recovery-output.* \
		"$credential_dir"/compose-project.* "$credential_dir"/operator-token.*
	rm -f "$project_file" "$project_file.tmp"
	rmdir "$credential_dir" 2>/dev/null || true
	rmdir "$root/.dans" 2>/dev/null || true
}

case "$command" in
	up) up ;;
	down) compose --profile tools down --remove-orphans ;;
	status) compose ps; compose exec -T dans /usr/local/bin/dans health ready ;;
	logs) compose logs --follow dans postgres powerdns ;;
	smoke) smoke ;;
	smoke-host) smoke host ;;
	reset) reset ;;
	*) die 'usage: scripts/dev-stack.sh {up|down|status|logs|smoke|smoke-host|reset}' ;;
esac

exit 0
