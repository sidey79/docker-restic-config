#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/restic-fhem-pre-backup-test.XXXXXX)"
trap 'rm -rf "${test_dir}"' EXIT HUP INT TERM
mkdir -p "${test_dir}/bin" "${test_dir}/output"

cat > "${test_dir}/bin/curl" <<'MOCK'
#!/bin/sh
printf '%s\n' "${MOCK_FHEM_STATUS:?MOCK_FHEM_STATUS is required}"
MOCK
cat > "${test_dir}/bin/docker" <<'MOCK'
#!/bin/sh
case "$*" in
  *pg_dump*)
    if [ "${MOCK_PG_DUMP_FAILURE:-0}" = "1" ]; then
      printf 'partial dump\n'
      exit 1
    fi
    printf 'PGDMP-test-archive\n'
    ;;
  *pg_restore*--list*) cat >/dev/null ;;
  *) echo "Unexpected docker invocation: $*" >&2; exit 64 ;;
esac
MOCK
chmod 0755 "${test_dir}/bin/curl" "${test_dir}/bin/docker"

today="$(date +%F)"
common_env="PATH=${test_dir}/bin:${PATH} FHEM_PG_CONTAINER=postgres-fhem FHEM_PG_DB_NAME=fhem FHEM_BACKUP_WAIT_INTERVAL=0"

run_ready_case() {
  status="$1"
  expected_message="$2"
  dump_file="${test_dir}/output/$3.dump"
  log_file="${test_dir}/output/$3.log"

  env ${common_env} \
    FHEM_BACKUP_WAIT_TIMEOUT=5 \
    FHEM_PG_DUMP_FILE="${dump_file}" \
    MOCK_FHEM_STATUS="none|${today} 00:16:01|off|${status}|${today} 00:32:00|$3" \
    "${repo_dir}/scripts/restic-fhem-pre-backup.sh" >"${log_file}" 2>&1

  test -s "${dump_file}"
  grep -F "${expected_message}" "${log_file}" >/dev/null
}

run_ready_case ok "FHEM PostgreSQL dump ready" ok
run_ready_case warning "WARNING: FHEM CSV export status is error" error

set +e
env ${common_env} \
  FHEM_BACKUP_WAIT_TIMEOUT=0 \
  FHEM_PG_DUMP_FILE="${test_dir}/output/timeout.dump" \
  MOCK_FHEM_STATUS="none|${today} 00:16:01|on|running|${today} 00:31:00|pending" \
  "${repo_dir}/scripts/restic-fhem-pre-backup.sh" >"${test_dir}/output/timeout.log" 2>&1
status=$?
set -e

test "${status}" -eq 75
test ! -e "${test_dir}/output/timeout.dump"
grep -F "Timed out waiting for FHEM readiness" "${test_dir}/output/timeout.log" >/dev/null

stale_tmp="${test_dir}/output/failure.dump.tmp.stale"
printf 'stale partial dump\n' >"${stale_tmp}"
set +e
env ${common_env} \
  FHEM_BACKUP_WAIT_TIMEOUT=5 \
  FHEM_PG_DUMP_FILE="${test_dir}/output/failure.dump" \
  MOCK_PG_DUMP_FAILURE=1 \
  MOCK_FHEM_STATUS="none|${today} 00:16:01|off|ok|${today} 00:32:00|ok" \
  "${repo_dir}/scripts/restic-fhem-pre-backup.sh" >"${test_dir}/output/failure.log" 2>&1
status=$?
set -e

test "${status}" -eq 74
test ! -e "${stale_tmp}"
test -z "$(find "${test_dir}/output" -maxdepth 1 -type f -name 'failure.dump.tmp.*' -print -quit)"
test ! -e "${test_dir}/output/failure.dump"
grep -F "removing incomplete temporary file" "${test_dir}/output/failure.log" >/dev/null

echo "restic-fhem-pre-backup tests passed"
