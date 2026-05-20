#!/bin/sh
set -eu

job_name="${1:-}"
if [ -z "${job_name}" ]; then
  echo "Usage: $0 <job-name>" >&2
  exit 64
fi

job_dir="${JOB_DIR:-./jobs}"
job_file="${job_dir}/${job_name}.env"
if [ ! -r "${job_file}" ]; then
  echo "Job file not found or not readable: ${job_file}" >&2
  exit 66
fi

# shellcheck disable=SC1090
. "${job_file}"

pre_backup_command="${PRE_BACKUP_COMMAND:-}"
if [ -z "${pre_backup_command}" ]; then
  echo "==> No pre-backup command configured for ${job_name}"
  exit 0
fi

echo "==> Running pre-backup command for ${job_name}"
sh -eu -c "${pre_backup_command}"
