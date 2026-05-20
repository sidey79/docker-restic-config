#!/bin/sh
set -u

job_name="${1:-}"
if [ -z "${job_name}" ]; then
  echo "Usage: $0 <job-name>" >&2
  exit 64
fi

stack_dir="${STACK_DIR:?STACK_DIR must be set}"
compose_file="${COMPOSE_FILE:?COMPOSE_FILE must be set}"
compose_project_name="${COMPOSE_PROJECT_NAME:-restic}"

status=0
started_epoch="$(date +%s)"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "==> Starting orchestrated backup job: ${job_name}"
./scripts/notify-backup-job.sh "${job_name}" started 0 "${started_at}" "" 0
./scripts/pre-backup-job.sh "${job_name}" || status=$?

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

echo "==> Starting post-backup phase for ${job_name}"
./scripts/post-backup-job.sh "${job_name}" || post_status=$?
if [ "${post_status:-0}" -ne 0 ]; then
  echo "==> Post-backup command for ${job_name} failed with status ${post_status}" >&2
  if [ "${status}" -eq 0 ]; then
    status="${post_status}"
  fi
fi

finished_epoch="$(date +%s)"
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
duration_seconds=$((finished_epoch - started_epoch))

if [ "${status}" -eq 0 ]; then
  echo "==> Orchestrated backup job completed: ${job_name}"
  ./scripts/notify-backup-job.sh "${job_name}" success 0 "${started_at}" "${finished_at}" "${duration_seconds}"
else
  echo "==> Orchestrated backup job failed: ${job_name} status ${status}" >&2
  ./scripts/notify-backup-job.sh "${job_name}" failure "${status}" "${started_at}" "${finished_at}" "${duration_seconds}"
fi

exit "${status}"
