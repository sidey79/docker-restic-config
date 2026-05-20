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

./scripts/pre-backup-job.sh "${job_name}" || status=$?

if [ "${status}" -eq 0 ]; then
  docker compose \
    --project-name "${compose_project_name}" \
    --project-directory "${stack_dir}" \
    -f "${compose_file}" \
    run --rm restic-job /scripts/restic-job.sh "${job_name}" || status=$?
else
  echo "==> Skipping Restic backup for ${job_name} because pre-backup failed with status ${status}" >&2
fi

./scripts/post-backup-job.sh "${job_name}" || post_status=$?
if [ "${post_status:-0}" -ne 0 ]; then
  echo "==> Post-backup command for ${job_name} failed with status ${post_status}" >&2
  if [ "${status}" -eq 0 ]; then
    status="${post_status}"
  fi
fi

exit "${status}"
