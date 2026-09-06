#!/bin/sh
set -eu

# Regression tests for the orchestration script. The failure these cover is a
# redeploy of the Portainer compose unpacker stack directory while a job is
# running: the job used to keep a working directory that no longer existed, so
# ./scripts/post-backup-job.sh could not be found and containers stopped by the
# pre-backup phase were never started again.

repo_dir="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/systemd-backup-job-test.XXXXXX)"
trap 'rm -rf "${test_dir}"' EXIT HUP INT TERM
mkdir -p "${test_dir}/bin" "${test_dir}/output"

cat > "${test_dir}/bin/docker" <<'MOCK'
#!/bin/sh
case "$*" in
  *"run --rm restic-job"*) ;;
  *) echo "Unexpected docker invocation: $*" >&2; exit 64 ;;
esac

case "${MOCK_DOCKER_MODE:-success}" in
  success)
    echo "mock restic run"
    ;;
  failure)
    echo "mock restic run failed" >&2
    exit 1
    ;;
  remove-scripts)
    # Simulates the redeploy that replaces the stack directory mid-run.
    echo "mock redeploy removes the stack scripts"
    rm -rf "${MOCK_STACK_SCRIPTS:?MOCK_STACK_SCRIPTS is required}"
    ;;
  terminate)
    # systemd stopping the unit while the backup phase is still running.
    echo "mock restic run interrupted"
    kill -TERM "${PPID}"
    sleep 1
    ;;
  *)
    echo "Unknown MOCK_DOCKER_MODE: ${MOCK_DOCKER_MODE}" >&2
    exit 64
    ;;
esac
MOCK
chmod 0755 "${test_dir}/bin/docker"

# Each case runs against a fresh copy of the stack so that a case may delete
# files from it without touching the repository.
setup_stack() {
  rm -rf "${test_dir}/stack" "${test_dir}/markers"
  mkdir -p "${test_dir}/stack/scripts" "${test_dir}/stack/jobs" "${test_dir}/markers"

  for helper in systemd-backup-job.sh pre-backup-job.sh post-backup-job.sh notify-backup-job.sh; do
    cp "${repo_dir}/scripts/${helper}" "${test_dir}/stack/scripts/${helper}"
    chmod 0755 "${test_dir}/stack/scripts/${helper}"
  done

  touch "${test_dir}/stack/docker-compose.yml"
  cat > "${test_dir}/stack/jobs/demo.env" <<'JOB'
RESTIC_CONTAINER_BACKUP_SOURCE_1=/srv/demo
PRE_BACKUP_COMMAND='echo "demo pre-backup"; touch "${MARKER_DIR}/pre"; exit "${MOCK_PRE_STATUS:-0}"'
POST_BACKUP_COMMAND='echo "demo post-backup"; touch "${MARKER_DIR}/post"'
JOB
}

common_env="PATH=${test_dir}/bin:${PATH} \
STACK_DIR=${test_dir}/stack \
COMPOSE_FILE=${test_dir}/stack/docker-compose.yml \
RESTIC_OUTPUT_DIR=${test_dir}/output \
MARKER_DIR=${test_dir}/markers \
MOCK_STACK_SCRIPTS=${test_dir}/stack/scripts \
N8N_BACKUP_WEBHOOK_URL= \
BACKUP_WEBHOOK_URL="

case_name=""
job_status=0

run_job() {
  case_name="$1"
  shift
  setup_stack

  set +e
  env ${common_env} "$@" \
    "${test_dir}/stack/scripts/systemd-backup-job.sh" demo \
    >"${test_dir}/output/${case_name}.log" 2>&1
  job_status=$?
  set -e
}

# Starts the job from a working directory that is removed beforehand, which is
# what a mid-run redeploy leaves behind.
run_job_without_working_directory() {
  case_name="$1"
  shift
  setup_stack
  mkdir -p "${test_dir}/gone"

  set +e
  (
    cd "${test_dir}/gone" \
      && rmdir "${test_dir}/gone" \
      && exec env ${common_env} "$@" \
        "${test_dir}/stack/scripts/systemd-backup-job.sh" demo
  ) >"${test_dir}/output/${case_name}.log" 2>&1
  job_status=$?
  set -e
}

fail() {
  echo "FAIL (${case_name}): $*" >&2
  echo "--- log ---" >&2
  cat "${test_dir}/output/${case_name}.log" >&2
  exit 1
}

assert_status() {
  [ "${job_status}" -eq "$1" ] || fail "expected exit ${1}, got ${job_status}"
}

assert_marker() {
  [ -e "${test_dir}/markers/$1" ] || fail "expected the ${1}-backup command to run"
}

assert_no_marker() {
  [ ! -e "${test_dir}/markers/$1" ] || fail "expected the ${1}-backup command not to run"
}

assert_log() {
  grep -F "$1" "${test_dir}/output/${case_name}.log" >/dev/null || fail "expected log to contain: $1"
}

# A plain run still works end to end.
run_job success
assert_status 0
assert_marker pre
assert_marker post

# The regression: the job no longer depends on its working directory.
run_job_without_working_directory deleted-working-directory
assert_status 0
assert_marker pre
assert_marker post
assert_log "Restic backup phase completed for demo"

# A redeploy that removes the helper scripts mid-run must not keep containers
# stopped; the post-backup command is then run from the job environment.
run_job removed-scripts MOCK_DOCKER_MODE=remove-scripts
assert_status 0
assert_marker pre
assert_marker post
assert_log "post-backup-job.sh is unavailable, running POST_BACKUP_COMMAND for demo directly"

# systemd stopping the unit must still restart what the pre-backup phase stopped.
run_job terminated MOCK_DOCKER_MODE=terminate
assert_status 143
assert_marker pre
assert_marker post

# A failing backup phase reports its status and still runs the post-backup phase.
run_job restic-failure MOCK_DOCKER_MODE=failure
assert_status 1
assert_marker pre
assert_marker post
assert_log "Restic backup phase failed for demo"

# A failing pre-backup phase skips the backup but still runs the post-backup
# phase, so containers it already stopped come back.
run_job pre-backup-failure MOCK_PRE_STATUS=70
assert_status 70
assert_marker pre
assert_marker post
assert_log "Skipping Restic backup for demo because pre-backup failed with status 70"

# A job without a post-backup command must not be reported as failed.
setup_stack
sed -i '/^POST_BACKUP_COMMAND=/d' "${test_dir}/stack/jobs/demo.env"
case_name="without-post-backup-command"
set +e
env ${common_env} "${test_dir}/stack/scripts/systemd-backup-job.sh" demo \
  >"${test_dir}/output/${case_name}.log" 2>&1
job_status=$?
set -e
assert_status 0
assert_marker pre
assert_no_marker post
assert_log "No post-backup command configured for demo"

echo "systemd-backup-job tests passed"
