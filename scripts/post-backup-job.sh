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

set -a
# shellcheck disable=SC1090
. "${job_file}"
set +a

post_backup_command="${POST_BACKUP_COMMAND:-}"
if [ -z "${post_backup_command}" ]; then
  echo "==> No post-backup command configured for ${job_name}"
  exit 0
fi

echo "==> Running post-backup command for ${job_name}"
sh -eu -c "${post_backup_command}"
