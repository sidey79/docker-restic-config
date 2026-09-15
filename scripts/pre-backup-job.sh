#!/bin/sh
set -eu

job_name="${1:-}"
if [ -z "${job_name}" ]; then
  echo "Usage: $0 <job-name>" >&2
  exit 64
fi

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
job_dir="${JOB_DIR:-${repo_dir}/jobs}"
job_file="${job_dir}/${job_name}.env"
if [ ! -r "${job_file}" ]; then
  echo "Job file not found or not readable: ${job_file}" >&2
  exit 66
fi

# Hook commands that call a script from this repository must address it through
# ${REPO_DIR}. The systemd service runs with / as its working directory, so a
# relative ./scripts/... path in a job file fails with status 127. The export
# happens before the job file is read, because a hook written with double quotes
# expands the variable at source time and would abort under set -u.
REPO_DIR="${repo_dir}"
export REPO_DIR

set -a
# shellcheck disable=SC1090
. "${job_file}"
set +a

pre_backup_command="${PRE_BACKUP_COMMAND:-}"
if [ -z "${pre_backup_command}" ]; then
  echo "==> No pre-backup command configured for ${job_name}"
  exit 0
fi

echo "==> Running pre-backup command for ${job_name}"
sh -eu -c "${pre_backup_command}"
