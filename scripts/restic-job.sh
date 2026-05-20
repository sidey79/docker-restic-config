#!/bin/sh
set -eu

job_name="${1:-}"
if [ -z "${job_name}" ]; then
  echo "Usage: $0 <job-name>" >&2
  exit 64
fi

job_file="/jobs/${job_name}.env"
if [ ! -r "${job_file}" ]; then
  echo "Job file not found or not readable: ${job_file}" >&2
  exit 66
fi

# shellcheck disable=SC1090
. "${job_file}"

export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/cache}"
export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:?RESTIC_REPOSITORY must be set in ${job_file}}"

restic_tag="${RESTIC_TAG:-${job_name}}"
keep_daily="${KEEP_DAILY:-${RESTIC_KEEP_DAILY:-14}}"
keep_weekly="${KEEP_WEEKLY:-${RESTIC_KEEP_WEEKLY:-8}}"
keep_monthly="${KEEP_MONTHLY:-${RESTIC_KEEP_MONTHLY:-12}}"
backup_paths="${BACKUP_PATHS:?BACKUP_PATHS must be set in ${job_file}}"
json_output_dir="${RESTIC_JSON_OUTPUT_DIR:-/output}"
json_output_file="${RESTIC_BACKUP_JSON_FILE:-${json_output_dir}/${job_name}-backup.jsonl}"

echo "==> Checking repository availability for ${job_name}"
if ! restic snapshots >/dev/null 2>&1; then
  echo "Repository is not initialized or not reachable. Running restic init..."
  restic init
fi

echo "==> Backing up ${job_name} with restic JSON output"
set -- ${backup_paths}
tmp_json="${json_output_file}.tmp"
rm -f "${tmp_json}"
if restic backup \
  --json \
  --host "${RESTIC_HOST:-zeus}" \
  --tag "${restic_tag}" \
  "$@" > "${tmp_json}"; then
  cat "${tmp_json}"
  mv "${tmp_json}" "${json_output_file}"
else
  status=$?
  if [ -s "${tmp_json}" ]; then
    cat "${tmp_json}"
    mv "${tmp_json}" "${json_output_file}"
  fi
  exit "${status}"
fi

echo "==> Wrote restic backup JSON output: ${json_output_file}"

echo "==> Applying retention policy for ${job_name}"
restic forget \
  --tag "${restic_tag}" \
  --keep-daily "${keep_daily}" \
  --keep-weekly "${keep_weekly}" \
  --keep-monthly "${keep_monthly}" \
  --prune

echo "==> Running repository check for ${job_name}"
restic check
