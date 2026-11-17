#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/restic-n8n-pre-backup-test.XXXXXX)"
trap 'rm -rf "${test_dir}"' EXIT HUP INT TERM
mkdir -p "${test_dir}/bin" "${test_dir}/output"

# Fake pg_dump. The docker mock below runs the real inline `sh -c` script from
# the hook against it, so the database/user fallback logic is exercised.
cat > "${test_dir}/bin/pg_dump" <<'MOCK'
#!/bin/sh
printf '%s|PGPASSWORD=%s\n' "$*" "${PGPASSWORD:-}" >> "${MOCK_PG_DUMP_ARGS:?MOCK_PG_DUMP_ARGS is required}"
if [ "${MOCK_PG_DUMP_FAILURE:-0}" = "1" ]; then
  printf 'partial dump\n'
  exit 1
fi
if [ "${MOCK_PG_DUMP_EMPTY:-0}" = "1" ]; then
  exit 0
fi
printf -- '-- PostgreSQL database dump\nCREATE TABLE t (id int);\n'
if [ -n "${MOCK_PG_DUMP_SLEEP:-}" ]; then
  sleep "${MOCK_PG_DUMP_SLEEP}"
fi
if [ "${MOCK_PG_DUMP_TRUNCATED:-0}" != "1" ]; then
  printf -- '-- PostgreSQL database dump complete\n'
fi
MOCK

cat > "${test_dir}/bin/docker" <<'MOCK'
#!/bin/sh
# docker exec [-e VAR=value] <container> <command...>
[ "${1:-}" = "exec" ] || { echo "Unexpected docker invocation: $*" >&2; exit 64; }
shift
while [ "${1:-}" = "-e" ]; do
  export "$2"
  shift 2
done
container="$1"
shift

case "$1" in
  cat)
    if [ "${MOCK_N8N_NO_KEY:-0}" = "1" ]; then
      printf '{"other":"value"}\n'
    else
      printf '{\n  "encryptionKey": "secret-key-123"\n}\n'
    fi
    ;;
  sh)
    # Environment of the postgres container.
    unset POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD
    [ -z "${MOCK_POSTGRES_USER+x}" ] || export POSTGRES_USER="${MOCK_POSTGRES_USER}"
    [ -z "${MOCK_POSTGRES_DB+x}" ] || export POSTGRES_DB="${MOCK_POSTGRES_DB}"
    [ -z "${MOCK_POSTGRES_PASSWORD+x}" ] || export POSTGRES_PASSWORD="${MOCK_POSTGRES_PASSWORD}"
    exec "$@"
    ;;
  *) echo "Unexpected docker command in ${container}: $*" >&2; exit 64 ;;
esac
MOCK
chmod 0755 "${test_dir}/bin/docker" "${test_dir}/bin/pg_dump"

pg_args="${test_dir}/pg_dump.args"
common_env="PATH=${test_dir}/bin:${PATH} N8N_PG_CONTAINER=n8n-postgres-1 N8N_CONTAINER=n8n-n8n-1 N8N_LOCK_FILE=${test_dir}/lock MOCK_PG_DUMP_ARGS=${pg_args} MOCK_POSTGRES_USER=n8n MOCK_POSTGRES_DB=n8ndb MOCK_POSTGRES_PASSWORD=pw"
script="${repo_dir}/scripts/restic-n8n-pre-backup.sh"

# Success: plain-text dump and 0600 key file, no gzip, no leftover temp files.
env ${common_env} \
  N8N_PG_DUMP_FILE="${test_dir}/output/ok/db/latest.sql" \
  N8N_KEY_FILE="${test_dir}/output/ok/meta/key.env" \
  "${script}" >"${test_dir}/output/ok.log" 2>&1

grep -F "CREATE TABLE t" "${test_dir}/output/ok/db/latest.sql" >/dev/null
test "$(cat "${test_dir}/output/ok/meta/key.env")" = "N8N_ENCRYPTION_KEY=secret-key-123"
test "$(stat -c %a "${test_dir}/output/ok/meta/key.env")" = "600"
test "$(stat -c %a "${test_dir}/output/ok/db/latest.sql")" = "640"
test "$(stat -c %a "${test_dir}/output/ok/db")" = "750"
test "$(stat -c %a "${test_dir}/output/ok/meta")" = "750"
test -z "$(find "${test_dir}/output/ok" -name '*.tmp.*' -o -name '*.gz' | head -n 1)"
grep -F "n8n PostgreSQL dump ready" "${test_dir}/output/ok.log" >/dev/null
if grep -F "secret-key-123" "${test_dir}/output/ok.log" >/dev/null; then
  echo "encryption key leaked into the log" >&2
  exit 1
fi
# The database and user come from the postgres container environment.
grep -F -e "--username=n8n --dbname=n8ndb|PGPASSWORD=pw" "${pg_args}" >/dev/null

# Re-run replaces the dump atomically and removes stale temp files.
stale_tmp="${test_dir}/output/ok/db/latest.sql.tmp.stale"
printf 'stale\n' >"${stale_tmp}"
env ${common_env} \
  N8N_PG_DUMP_FILE="${test_dir}/output/ok/db/latest.sql" \
  N8N_KEY_FILE="${test_dir}/output/ok/meta/key.env" \
  "${script}" >/dev/null 2>&1
test ! -e "${stale_tmp}"

# Paths with spaces work.
env ${common_env} \
  N8N_PG_DUMP_FILE="${test_dir}/output/with space/db/latest.sql" \
  N8N_KEY_FILE="${test_dir}/output/with space/meta/key.env" \
  "${script}" >/dev/null 2>&1
test -s "${test_dir}/output/with space/db/latest.sql"
test -z "$(find "${test_dir}/output/with space" -name '*.tmp.*' | head -n 1)"

# N8N_PG_DB_NAME overrides POSTGRES_DB.
: > "${pg_args}"
env ${common_env} N8N_PG_DB_NAME=override \
  N8N_PG_DUMP_FILE="${test_dir}/output/override/latest.sql" \
  N8N_KEY_FILE= \
  "${script}" >/dev/null 2>&1
grep -F -e "--dbname=override" "${pg_args}" >/dev/null

# Without POSTGRES_PASSWORD no PGPASSWORD is set; the dump still works.
: > "${pg_args}"
env ${common_env} MOCK_POSTGRES_PASSWORD= \
  N8N_PG_DUMP_FILE="${test_dir}/output/nopw/latest.sql" \
  N8N_KEY_FILE= \
  "${script}" >/dev/null 2>&1
grep -F -e "|PGPASSWORD=" "${pg_args}" >/dev/null
if grep -F -e "PGPASSWORD=pw" "${pg_args}" >/dev/null; then
  echo "unexpected PGPASSWORD" >&2
  exit 1
fi

# Key snapshot can be disabled.
env ${common_env} \
  N8N_PG_DUMP_FILE="${test_dir}/output/nokey/latest.sql" \
  N8N_KEY_FILE= \
  "${script}" >/dev/null 2>&1
test -s "${test_dir}/output/nokey/latest.sql"

run_failure_case() {
  name="$1"
  expected_status="$2"
  expected_message="$3"
  shift 3

  set +e
  env ${common_env} \
    N8N_PG_DUMP_FILE="${test_dir}/output/${name}/db/latest.sql" \
    N8N_KEY_FILE="${test_dir}/output/${name}/meta/key.env" \
    "$@" \
    "${script}" >"${test_dir}/output/${name}.log" 2>&1
  status=$?
  set -e

  test "${status}" -eq "${expected_status}"
  test ! -e "${test_dir}/output/${name}/db/latest.sql"
  test -z "$(find "${test_dir}/output/${name}" -name '*.tmp.*' 2>/dev/null | head -n 1)"
  grep -F "${expected_message}" "${test_dir}/output/${name}.log" >/dev/null
}

run_failure_case dumpfail 74 "PostgreSQL dump failed" MOCK_PG_DUMP_FAILURE=1
run_failure_case empty 74 "PostgreSQL dump is empty" MOCK_PG_DUMP_EMPTY=1
run_failure_case truncated 74 "looks incomplete" MOCK_PG_DUMP_TRUNCATED=1
run_failure_case nokeyfound 78 "encryption key not found" MOCK_N8N_NO_KEY=1
run_failure_case nouser 74 "POSTGRES_USER is not set" MOCK_POSTGRES_USER=
unset_db_case() {
  # No POSTGRES_DB in the container and no N8N_PG_DB_NAME.
  set +e
  env ${common_env} MOCK_POSTGRES_DB= \
    N8N_PG_DUMP_FILE="${test_dir}/output/nodb/db/latest.sql" \
    N8N_KEY_FILE= \
    "${script}" >"${test_dir}/output/nodb.log" 2>&1
  status=$?
  set -e
  test "${status}" -eq 74
  test ! -e "${test_dir}/output/nodb/db/latest.sql"
  test -z "$(find "${test_dir}/output/nodb" -name '*.tmp.*' | head -n 1)"
  grep -F "Neither N8N_PG_DB_NAME nor POSTGRES_DB is set" "${test_dir}/output/nodb.log" >/dev/null
}
unset_db_case

# The key snapshot is written before the dump; a failing dump keeps the key
# and publishes no dump.
test "$(cat "${test_dir}/output/dumpfail/meta/key.env")" = "N8N_ENCRYPTION_KEY=secret-key-123"

# A failed dump leaves the previous good dump in place.
mkdir -p "${test_dir}/output/keep/db"
printf 'previous good dump\n' > "${test_dir}/output/keep/db/latest.sql"
set +e
env ${common_env} MOCK_PG_DUMP_FAILURE=1 \
  N8N_PG_DUMP_FILE="${test_dir}/output/keep/db/latest.sql" \
  N8N_KEY_FILE= \
  "${script}" >/dev/null 2>&1
status=$?
set -e
test "${status}" -eq 74
test "$(cat "${test_dir}/output/keep/db/latest.sql")" = "previous good dump"
test -z "$(find "${test_dir}/output/keep" -name '*.tmp.*' | head -n 1)"

# SIGTERM while pg_dump runs: the script must stop with 143, remove its temp
# file and publish nothing, not carry on and publish the dump.
env ${common_env} MOCK_PG_DUMP_SLEEP=2 \
  N8N_PG_DUMP_FILE="${test_dir}/output/term/db/latest.sql" \
  N8N_KEY_FILE= \
  "${script}" >"${test_dir}/output/term.log" 2>&1 &
pid=$!
waited=0
while [ -z "$(find "${test_dir}/output/term/db" -name '*.tmp.*' 2>/dev/null | head -n 1)" ] && [ "${waited}" -lt 50 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
kill -TERM "${pid}"
set +e
wait "${pid}"
status=$?
set -e
test "${status}" -eq 143
test ! -e "${test_dir}/output/term/db/latest.sql"
test -z "$(find "${test_dir}/output/term" -name '*.tmp.*' | head -n 1)"

# A second run while the lock is held aborts without touching the first run's
# files.
if command -v flock >/dev/null 2>&1; then
  flock "${test_dir}/lock" sleep 3 &
  lock_pid=$!
  sleep 0.5
  set +e
  env ${common_env} \
    N8N_PG_DUMP_FILE="${test_dir}/output/locked/db/latest.sql" \
    N8N_KEY_FILE= \
    "${script}" >"${test_dir}/output/locked.log" 2>&1
  status=$?
  set -e
  test "${status}" -eq 75
  test ! -e "${test_dir}/output/locked/db/latest.sql"
  grep -F "holds" "${test_dir}/output/locked.log" >/dev/null
  wait "${lock_pid}"
else
  echo "flock not available; skipping the lock test"
fi

echo "restic-n8n-pre-backup tests passed"
