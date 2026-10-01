#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
wrapper=$root/scripts/integration-ci.sh
workflow=$root/.github/workflows/ci.yml

fail() {
	printf '%s\n' "integration CI contract: $*" >&2
	exit 1
}

secret=SYNTHETIC_CREDENTIAL_DO_NOT_PUBLISH
path=/synthetic/private/ci-home
identifier=SYNTHETIC_INTERNAL_NODE_DO_NOT_PUBLISH
backup=SYNTHETIC_BACKUP_BYTES_DO_NOT_PUBLISH
diagnostic=SYNTHETIC_RESTORE_DIAGNOSTIC_DO_NOT_PUBLISH

case "${2:-}" in
	fixture-fail | fixture-early | fixture-invalid | fixture-restore-fail | fixture-upgrade-fail | fixture-rollback-fail | fixture-success)
		printf '%s\n' "$secret $path $identifier $backup $diagnostic"
		printf '%s\n' "$secret $path $identifier $backup $diagnostic" >&2
		printf '%s\n' "$secret $path $identifier $backup $diagnostic" >"$DANS_QA_LOG_DIR/compose.log"
		case "$2" in
			fixture-fail)
				printf '%s\n' exercise >"$DANS_QA_PHASE_FILE"
				exit 17
				;;
			fixture-early) exit 23 ;;
			fixture-invalid)
				printf '%s\n' "$identifier" >"$DANS_QA_PHASE_FILE"
				exit 29
				;;
			fixture-restore-fail)
				printf '%s\n' restore >"$DANS_QA_PHASE_FILE"
				exit 31
				;;
			fixture-upgrade-fail | fixture-rollback-fail)
				printf '%s\n' "${2#fixture-}" | cut -d- -f1 >"$DANS_QA_PHASE_FILE"
				exit 37
				;;
			fixture-success) exit 0 ;;
		esac
		;;
esac

grep -Fq 'scripts/integration-ci.sh' "$workflow" || fail 'CI bypasses the safe entry point'
grep -Fq "if: failure() && steps.real_system.outcome == 'failure'" "$workflow" || fail 'CI skips the summary upload after an integration failure'
if grep -Fq 'path: ${{ runner.temp }}/dans-integration-logs/' "$workflow"; then
	fail 'CI uploads raw integration logs'
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/dans-ci-contract.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

run_case() {
	case_name=$1
	expected_status=$2
	expected_phase=$3
	image=$4
	leg=$5
	DANS_QA_LOG_DIR="$tmp/$case_name/raw" \
	DANS_QA_SUMMARY_DIR="$tmp/$case_name/summary" \
		"$wrapper" "$0" "$image" "fixture-$case_name" >"$tmp/$case_name-console" 2>&1 && status=0 || status=$?
	[ "$status" -eq "$expected_status" ] || fail "$case_name exit status was $status"
	for value in "$secret" "$path" "$identifier" "$backup" "$diagnostic"; do
		if grep -Fq "$value" "$tmp/$case_name-console" "$tmp/$case_name/summary/summary.txt" 2>/dev/null; then
			fail "$case_name published synthetic confidential data"
		fi
	done
	[ -f "$tmp/$case_name/raw/compose.log" ] || fail "$case_name did not retain raw diagnostics locally"
	grep -Fq "$secret" "$tmp/$case_name/raw/run.log" || fail "$case_name did not capture harness output locally"
	if [ "$expected_status" -ne 0 ]; then
		[ -f "$tmp/$case_name/summary/summary.txt" ] || fail "$case_name did not publish a summary"
		[ "$(find "$tmp/$case_name/summary" -type f | wc -l | tr -d ' ')" -eq 1 ] || fail "$case_name published extra diagnostic files"
		cmp -s "$tmp/$case_name-console" "$tmp/$case_name/summary/summary.txt" || fail "$case_name console output was not the allowlisted summary"
		grep -Fxq "integration: $leg phase=$expected_phase outcome=failed status=$expected_status" "$tmp/$case_name-console" || fail "$case_name console summary was unexpected"
		grep -Fxq "integration: $leg phase=$expected_phase outcome=failed status=$expected_status" "$tmp/$case_name/summary/summary.txt" || fail "$case_name artifact summary was unexpected"
	else
		[ -z "$(find "$tmp/$case_name/summary" -type f)" ] || fail 'success produced a failure artifact'
		[ ! -s "$tmp/$case_name-console" ] || fail 'success printed raw output to CI'
	fi
}

run_case fail 17 exercise postgres:16.14 pg16
run_case early 23 unknown postgres:18.4 pg18
run_case invalid 29 unknown postgres:16.14 pg16
run_case restore-fail 31 restore postgres:18.4 pg18
run_case upgrade-fail 37 upgrade postgres:16.14 pg16
run_case rollback-fail 37 rollback postgres:18.4 pg18
run_case success 0 unknown postgres:16.14 pg16
printf '%s\n' 'integration CI contract: ok'
