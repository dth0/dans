#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ -z "${DANS_QA_LOG_DIR:-}" ] || [ -z "${DANS_QA_SUMMARY_DIR:-}" ]; then
	printf '%s\n' 'integration: CI entry point is not configured' >&2
	exit 2
fi

harness=$1
image=$2
shift 2
case "$image" in
	postgres:16.14) leg=pg16 ;;
	postgres:18.4) leg=pg18 ;;
	*) printf '%s\n' 'integration: unsupported CI matrix leg' >&2; exit 2 ;;
esac

umask 077
if ! mkdir -p "$DANS_QA_LOG_DIR" "$DANS_QA_SUMMARY_DIR" 2>/dev/null ||
	! rm -f "$DANS_QA_SUMMARY_DIR/summary.txt" 2>/dev/null; then
	printf '%s\n' 'integration: cannot prepare CI diagnostics' >&2
	exit 2
fi

DANS_QA_PHASE_FILE=$DANS_QA_LOG_DIR/phase
export DANS_QA_PHASE_FILE
rm -f "$DANS_QA_PHASE_FILE" 2>/dev/null || {
	printf '%s\n' 'integration: cannot prepare CI diagnostics' >&2
	exit 2
}

if ("$harness" "$image" "$@" >"$DANS_QA_LOG_DIR/run.log" 2>&1) 2>/dev/null; then
	exit 0
else
	status=$?
fi

phase=unknown
if [ -f "$DANS_QA_PHASE_FILE" ]; then
	IFS= read -r candidate 2>/dev/null <"$DANS_QA_PHASE_FILE" || candidate=
	case "$candidate" in
		setup | services | measurement | exercise | upgrade | rollback | ratelimit | restore) phase=$candidate ;;
	esac
fi

summary="integration: $leg phase=$phase outcome=failed status=$status"
printf '%s\n' "$summary" 2>/dev/null >"$DANS_QA_SUMMARY_DIR/summary.txt" || {
	printf '%s\n' 'integration: cannot write CI summary' >&2
	exit "$status"
}
printf '%s\n' "$summary" >&2
exit "$status"
