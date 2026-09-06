#!/bin/sh
set -u

# Resolve every helper and job file through an absolute path. The stack
# directory is managed by the Portainer compose unpacker, which deletes and
# re-clones it on redeploy. A job that was started before such a redeploy keeps
# a working directory that no longer exists, so relative paths like
# ./scripts/post-backup-job.sh fail with ENOENT halfway through the run.
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd)"

job_name="${1:-}"
if [ -z "${job_name}" ]; then
  echo "Usage: $0 <job-name>" >&2
  exit 64
fi

stack_dir="${STACK_DIR:?STACK_DIR must be set}"
compose_file="${COMPOSE_FILE:?COMPOSE_FILE must be set}"
compose_project_name="${COMPOSE_PROJECT_NAME:-restic}"
restic_output_dir="${RESTIC_OUTPUT_DIR:-/opt/docker/restic/output}"
restic_json_file="${restic_output_dir}/${job_name}-backup.jsonl"
job_dir="${JOB_DIR:-${repo_dir}/jobs}"
job_file="${job_dir}/${job_name}.env"

if [ ! -r "${job_file}" ]; then
  echo "Job file not found or not readable: ${job_file}" >&2
  exit 66
fi

set -a
# shellcheck disable=SC1090
. "${job_file}"
set +a

: "${RESTIC_CONTAINER_BACKUP_SOURCE_1:?RESTIC_CONTAINER_BACKUP_SOURCE_1 must be set in ${job_file}}"

# Pass the resolved job directory on, so the helpers do not depend on the
# working directory either.
JOB_DIR="${job_dir}"
export JOB_DIR

status=0
post_status=0
post_backup_ran=0

notify() {
  "${script_dir}/notify-backup-job.sh" "$@" || true
}

# Runs the post-backup phase exactly once, no matter which path leads out of
# this script. Without this, an interrupted run leaves the containers that the
# pre-backup phase stopped shut down until someone notices.
run_post_backup() {
  [ "${post_backup_ran}" -eq 0 ] || return 0
  post_backup_ran=1

  echo "==> Starting post-backup phase for ${job_name}"
  if [ -x "${script_dir}/post-backup-job.sh" ]; then
    "${script_dir}/post-backup-job.sh" "${job_name}" || post_status=$?
  elif [ -n "${POST_BACKUP_COMMAND:-}" ]; then
    # Last resort when the stack directory disappeared mid-run: the command was
    # already sourced from the job file, so it can run without touching disk.
    echo "==> post-backup-job.sh is unavailable, running POST_BACKUP_COMMAND for ${job_name} directly" >&2
    sh -eu -c "${POST_BACKUP_COMMAND}" || post_status=$?
  else
    echo "==> No post-backup command configured for ${job_name}"
  fi

  if [ "${post_status}" -ne 0 ]; then
    echo "==> Post-backup command for ${job_name} failed with status ${post_status}" >&2
  fi
}

started_epoch="$(date +%s)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "${restic_output_dir}"
rm -f "${restic_json_file}"

echo "==> Starting orchestrated backup job: ${job_name}"
notify "${job_name}" started 0 "${started_at}" "" 0

trap 'run_post_backup' EXIT
trap 'run_post_backup; exit 143' TERM
trap 'run_post_backup; exit 130' INT

"${script_dir}/pre-backup-job.sh" "${job_name}" || status=$?

if [ "${status}" -eq 0 ]; then
  echo "==> Starting Restic backup phase for ${job_name}"
  docker compose \
    --project-name "${compose_project_name}" \
    --project-directory "${stack_dir}" \
    -f "${compose_file}" \
    run --rm restic-job /scripts/restic-job.sh "${job_name}" || status=$?
  if [ "${status}" -eq 0 ]; then
    echo "==> Restic backup phase completed for ${job_name}"
  else
    echo "==> Restic backup phase failed for ${job_name} with status ${status}" >&2
  fi
else
  echo "==> Skipping Restic backup for ${job_name} because pre-backup failed with status ${status}" >&2
fi

run_post_backup
trap - EXIT TERM INT

if [ "${post_status}" -ne 0 ] && [ "${status}" -eq 0 ]; then
  status="${post_status}"
fi

finished_epoch="$(date +%s)"
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
duration_seconds=$((finished_epoch - started_epoch))

if [ "${status}" -eq 0 ]; then
  echo "==> Orchestrated backup job completed: ${job_name}"
  notify "${job_name}" success 0 "${started_at}" "${finished_at}" "${duration_seconds}" "${restic_json_file}"
else
  echo "==> Orchestrated backup job failed: ${job_name} status ${status}" >&2
  notify "${job_name}" failure "${status}" "${started_at}" "${finished_at}" "${duration_seconds}" "${restic_json_file}"
fi

exit "${status}"
