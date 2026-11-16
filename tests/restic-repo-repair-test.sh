#!/bin/sh
set -eu

# Tests for the repository repair helper. The mock docker does not start a
# container. It runs the generated container script with a mock restic instead,
# so the tests see the restic command line that would run in the container.

repo_dir="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/restic-repo-repair-test.XXXXXX)"
trap 'rm -rf "${test_dir}"' EXIT HUP INT TERM
mkdir -p "${test_dir}/bin" "${test_dir}/output" "${test_dir}/config" \
  "${test_dir}/stack/jobs" "${test_dir}/container/bin"
touch "${test_dir}/stack/docker-compose.yml"

cat > "${test_dir}/stack/jobs/demo.env" <<'JOB'
RESTIC_REPOSITORY=sftp:host:/repo/demo
RESTIC_TAG=demotag
BACKUP_PATHS="/source/1 /source/2"
RESTIC_CONTAINER_BACKUP_SOURCE_1=/srv/demo
PRE_BACKUP_COMMAND='"${REPO_DIR}/scripts/never-called.sh"'
JOB

cat > "${test_dir}/config/systemd.env" <<ENV
# comment
STACK_DIR=${test_dir}/stack
COMPOSE_FILE=${test_dir}/stack/docker-compose.yml
RESTIC_OUTPUT_DIR=${test_dir}/output
ENV
cat > "${test_dir}/config/secrets.env" <<'ENV'
RESTIC_PASSWORD="secret with spaces"
ENV

cat > "${test_dir}/container/bin/restic" <<'MOCK'
#!/bin/sh
{
  echo "repository=${RESTIC_REPOSITORY:-} cache=${RESTIC_CACHE_DIR:-}"
  for arg in "$@"; do echo "arg=${arg}"; done
} > "${MOCK_RESTIC_LOG:?}"
echo "mock restic $*"
exit "${MOCK_RESTIC_STATUS:-0}"
MOCK
chmod 0755 "${test_dir}/container/bin/restic"

cat > "${test_dir}/bin/docker" <<'MOCK'
#!/bin/sh
{
  echo "password=${RESTIC_PASSWORD:-}"
  echo "source1=${RESTIC_CONTAINER_BACKUP_SOURCE_1:-}"
  echo "docker=$*"
} > "${MOCK_DOCKER_LOG:?}"
while [ "$#" -gt 0 ] && [ "$1" != "restic-job" ]; do shift; done
[ "${1:-}" = "restic-job" ] && [ "${2:-}" = "-c" ] || { echo "Unexpected docker invocation" >&2; exit 64; }
shift 2
script="$(printf '%s' "$1" | sed "s#/jobs/#${MOCK_JOBS_DIR:?}/#")"
shift
PATH="${MOCK_CONTAINER_BIN:?}:${PATH}" exec sh -c "${script}" "$@"
MOCK
chmod 0755 "${test_dir}/bin/docker"

case_name=""
status=0
pack_id="96b4336c2ecba98c5fe0ae70b28764b21b9dc21cada909867491b02a31387a4c"

run_repair() {
  case_name="$1"
  shift
  rm -f "${test_dir}/docker.log" "${test_dir}/restic.log"
  set +e
  env -u STACK_DIR -u COMPOSE_FILE -u RESTIC_OUTPUT_DIR -u RESTIC_PASSWORD -u JOB_DIR \
    PATH="${test_dir}/bin:${PATH}" \
    CONFIG_DIR="${test_dir}/config" \
    MOCK_DOCKER_LOG="${test_dir}/docker.log" \
    MOCK_RESTIC_LOG="${test_dir}/restic.log" \
    MOCK_JOBS_DIR="${test_dir}/stack/jobs" \
    MOCK_CONTAINER_BIN="${test_dir}/container/bin" \
    MOCK_RESTIC_STATUS="${MOCK_RESTIC_STATUS:-0}" \
    "${repo_dir}/scripts/restic-repo-repair.sh" "$@" \
    >"${test_dir}/${case_name}.out" 2>&1
  status=$?
  set -e
}

fail() {
  echo "FAIL (${case_name}): $*" >&2
  echo "--- output" >&2
  cat "${test_dir}/${case_name}.out" >&2 || true
  echo "--- restic" >&2
  cat "${test_dir}/restic.log" >&2 2>/dev/null || true
  exit 1
}

expect_status() {
  [ "${status}" -eq "$1" ] || fail "expected exit status $1, got ${status}"
}

restic_args() {
  grep '^arg=' "${test_dir}/restic.log" | sed 's/^arg=//' | tr '\n' ' ' | sed 's/ $//'
}

expect_restic() {
  [ -f "${test_dir}/restic.log" ] || fail "restic was not called"
  actual="$(restic_args)"
  [ "${actual}" = "$1" ] || fail "expected restic '$1', got '${actual}'"
  grep -q '^repository=sftp:host:/repo/demo cache=/cache$' "${test_dir}/restic.log" \
    || fail "repository or cache directory not passed to restic"
}

expect_no_docker() {
  [ ! -f "${test_dir}/docker.log" ] || fail "docker must not be called"
}

run_repair check demo check
expect_status 0
expect_restic "check --read-data"
grep -q '^password=secret with spaces$' "${test_dir}/docker.log" \
  || fail "RESTIC_PASSWORD from secrets.env not passed to docker compose"
grep -q "docker=compose --project-name restic --project-directory ${test_dir}/stack -f ${test_dir}/stack/docker-compose.yml run --rm -T restic-job -c " "${test_dir}/docker.log" \
  || fail "unexpected docker compose invocation"
grep -q 'step=check finished with exit status 0' "${test_dir}/output/demo-repair.log" \
  || fail "run not written to the log file"

run_repair snapshots demo snapshots
expect_status 0
expect_restic "snapshots"

run_repair repair-packs demo repair-packs "${pack_id}"
expect_status 0
expect_restic "repair packs ${pack_id}"

run_repair repair-packs-invalid-id demo repair-packs "96b4336c"
expect_status 64
expect_no_docker

run_repair repair-packs-injection demo repair-packs "${pack_id}; rm -rf /"
expect_status 64
expect_no_docker

run_repair repair-packs-without-id demo repair-packs
expect_status 64
expect_no_docker

run_repair backup-force demo backup-force
expect_status 0
expect_restic "backup --force --host zeus --tag demotag /source/1 /source/2"
grep -q '^source1=/srv/demo$' "${test_dir}/docker.log" \
  || fail "backup source of the job not passed to docker compose"

run_repair repair-snapshots-dry-run demo repair-snapshots-dry-run
expect_status 0
expect_restic "repair snapshots --dry-run"

run_repair repair-snapshots demo repair-snapshots
expect_status 0
expect_restic "repair snapshots --forget"

run_repair prune demo prune
expect_status 0
expect_restic "prune"

run_repair passthrough demo restic list locks --no-lock
expect_status 0
expect_restic "list locks --no-lock"

MOCK_RESTIC_STATUS=3
run_repair restic-failure demo check
MOCK_RESTIC_STATUS=0
expect_status 3
grep -q 'step=check finished with exit status 3' "${test_dir}/output/demo-repair.log" \
  || fail "failing run not written to the log file"

run_repair unknown-step demo destroy
expect_status 64
expect_no_docker

run_repair unknown-job missing check
expect_status 66
expect_no_docker

run_repair missing-arguments demo
expect_status 64
expect_no_docker

echo "restic-repo-repair tests passed"
