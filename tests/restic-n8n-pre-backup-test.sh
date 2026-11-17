#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/restic-n8n-pre-backup-test.XXXXXX)"
trap 'rm -rf "${test_dir}"' EXIT HUP INT TERM
mkdir -p "${test_dir}/bin" "${test_dir}/output"

cat > "${test_dir}/bin/docker" <<'MOCK'
#!/bin/sh
case "$*" in
  *pg_dump*)
    if [ "${MOCK_PG_DUMP_FAILURE:-0}" = "1" ]; then
      printf 'partial dump\n'
      exit 1
    fi
    if [ "${MOCK_PG_DUMP_EMPTY:-0}" = "1" ]; then
      exit 0
    fi
    printf -- '-- PostgreSQL database dump\nCREATE TABLE t (id int);\n'
    if [ "${MOCK_PG_DUMP_TRUNCATED:-0}" != "1" ]; then
      printf -- '-- PostgreSQL database dump complete\n'
    fi
    ;;
  *" cat "*)
    if [ "${MOCK_N8N_NO_KEY:-0}" = "1" ]; then
      printf '{"other":"value"}\n'
    else
      printf '{\n  "encryptionKey": "secret-key-123"\n}\n'
    fi
    ;;
  *) echo "Unexpected docker invocation: $*" >&2; exit 64 ;;
esac
MOCK
chmod 0755 "${test_dir}/bin/docker"

common_env="PATH=${test_dir}/bin:${PATH} N8N_PG_CONTAINER=n8n-postgres-1 N8N_CONTAINER=n8n-n8n-1"
script="${repo_dir}/scripts/restic-n8n-pre-backup.sh"

# Success: plain-text dump and 0600 key file, no gzip, no leftover temp files.
env ${common_env} \
  N8N_PG_DUMP_FILE="${test_dir}/output/ok/latest.sql" \
  N8N_KEY_FILE="${test_dir}/output/ok/key.env" \
  "${script}" >"${test_dir}/output/ok.log" 2>&1

grep -F "CREATE TABLE t" "${test_dir}/output/ok/latest.sql" >/dev/null
test "$(cat "${test_dir}/output/ok/key.env")" = "N8N_ENCRYPTION_KEY=secret-key-123"
test "$(stat -c %a "${test_dir}/output/ok/key.env")" = "600"
test "$(stat -c %a "${test_dir}/output/ok/latest.sql")" = "640"
test "$(stat -c %a "${test_dir}/output/ok")" = "750"
test -z "$(find "${test_dir}/output/ok" -name '*.tmp.*' -o -name '*.gz' | head -n 1)"
grep -F "n8n PostgreSQL dump ready" "${test_dir}/output/ok.log" >/dev/null
if grep -F "secret-key-123" "${test_dir}/output/ok.log" >/dev/null; then
  echo "encryption key leaked into the log" >&2
  exit 1
fi

# Re-run replaces the dump atomically and removes stale temp files.
stale_tmp="${test_dir}/output/ok/latest.sql.tmp.stale"
printf 'stale\n' >"${stale_tmp}"
env ${common_env} \
  N8N_PG_DUMP_FILE="${test_dir}/output/ok/latest.sql" \
  N8N_KEY_FILE="${test_dir}/output/ok/key.env" \
  "${script}" >/dev/null 2>&1
test ! -e "${stale_tmp}"

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
    N8N_PG_DUMP_FILE="${test_dir}/output/${name}/latest.sql" \
    N8N_KEY_FILE="${test_dir}/output/${name}/key.env" \
    "$@" \
    "${script}" >"${test_dir}/output/${name}.log" 2>&1
  status=$?
  set -e

  test "${status}" -eq "${expected_status}"
  test ! -e "${test_dir}/output/${name}/latest.sql"
  test -z "$(find "${test_dir}/output/${name}" -name '*.tmp.*' 2>/dev/null | head -n 1)"
  grep -F "${expected_message}" "${test_dir}/output/${name}.log" >/dev/null
}

run_failure_case dumpfail 74 "PostgreSQL dump failed" MOCK_PG_DUMP_FAILURE=1
run_failure_case empty 74 "PostgreSQL dump is empty" MOCK_PG_DUMP_EMPTY=1
run_failure_case truncated 74 "looks incomplete" MOCK_PG_DUMP_TRUNCATED=1
run_failure_case nokeyfound 78 "encryption key not found" MOCK_N8N_NO_KEY=1

echo "restic-n8n-pre-backup tests passed"
