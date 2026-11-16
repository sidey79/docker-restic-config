#!/bin/sh
set -eu

# Runs the restic maintenance commands that are needed to diagnose and repair a
# damaged repository of one backup job, for example after a disk error on the
# remote host truncated a pack file.
#
# The commands run through the same Compose service as the scheduled backup, so
# they use the same restic version, SSH key, host key pinning and cache. The
# repository password and the stack location are read from the files that the
# systemd units use, which is why the script has to run as root on the backup
# host.
#
# Every run is appended to a log file below RESTIC_OUTPUT_DIR.

usage() {
  cat >&2 <<USAGE
Usage: $0 <job-name> <step> [arguments]

Steps, in the order a repair uses them:
  snapshots                 List the snapshots (connection and password test)
  check                     Read and verify every pack (restic check --read-data)
  repair-packs <id>...      Salvage the readable blobs of the given damaged packs
  backup-force              Re-read all source files and upload missing blobs
  repair-snapshots-dry-run  Show what repair-snapshots would change
  repair-snapshots          Remove unrecoverable files from old snapshots
  prune                     Remove data that is no longer referenced
  restic <args>...          Run any other restic command against the repository
USAGE
  exit 64
}

job_name="${1:-}"
step="${2:-}"
[ -n "${job_name}" ] && [ -n "${step}" ] || usage
shift 2

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(CDPATH= cd -- "${script_dir}/.." && pwd)"
config_dir="${CONFIG_DIR:-/etc/docker-restic-config}"

# Values that are already set in the environment win, so the script can also be
# pointed at another stack without touching the installed configuration.
for env_file in "${config_dir}/systemd.env" "${config_dir}/secrets.env"; do
  if [ -e "${env_file}" ] && [ ! -r "${env_file}" ]; then
    echo "Cannot read ${env_file}. Run this script as root (sudo)." >&2
    exit 77
  fi
  [ -r "${env_file}" ] || continue
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    name="${line%%=*}"
    value="${line#*=}"
    # systemd drops one pair of surrounding quotes from EnvironmentFile values.
    case "${value}" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    case "${name}" in
      *[!A-Za-z0-9_]*|'') continue ;;
    esac
    if eval "[ -z \"\${${name}+set}\" ]"; then
      export "${name}=${value}"
    fi
  done < "${env_file}"
done

stack_dir="${STACK_DIR:?STACK_DIR must be set in ${config_dir}/systemd.env or the environment}"
compose_file="${COMPOSE_FILE:?COMPOSE_FILE must be set in ${config_dir}/systemd.env or the environment}"
compose_project_name="${COMPOSE_PROJECT_NAME:-restic}"
restic_output_dir="${RESTIC_OUTPUT_DIR:-/opt/docker/restic/output}"

# The container reads the job file from the stack directory, so the host side
# uses the same file to keep the mounted sources and the repository in sync.
job_dir="${JOB_DIR:-${stack_dir}/jobs}"
job_file="${job_dir}/${job_name}.env"
if [ ! -r "${job_file}" ]; then
  echo "Job file not found or not readable: ${job_file}" >&2
  exit 66
fi

REPO_DIR="${repo_dir}"
export REPO_DIR
set -a
# shellcheck disable=SC1090
. "${job_file}"
set +a

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY must be set in ${job_file}}"

# In the container: $0 is the job name, "$@" is the restic command line.
container_prelude='. "/jobs/$0.env"; export RESTIC_REPOSITORY RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/cache}"'

case "${step}" in
  snapshots)
    [ "$#" -eq 0 ] || usage
    container_script="${container_prelude}; exec restic snapshots"
    ;;
  check)
    [ "$#" -eq 0 ] || usage
    container_script="${container_prelude}; exec restic check --read-data"
    ;;
  repair-packs)
    [ "$#" -ge 1 ] || usage
    for pack_id in "$@"; do
      case "${pack_id}" in
        *[!0-9a-f]*)
          echo "Not a pack ID: ${pack_id}" >&2
          exit 64
          ;;
      esac
      if [ "${#pack_id}" -ne 64 ]; then
        echo "A pack ID has 64 hex characters: ${pack_id}" >&2
        exit 64
      fi
    done
    container_script="${container_prelude}; exec restic repair packs \"\$@\""
    ;;
  backup-force)
    [ "$#" -eq 0 ] || usage
    : "${RESTIC_CONTAINER_BACKUP_SOURCE_1:?RESTIC_CONTAINER_BACKUP_SOURCE_1 must be set in ${job_file}}"
    # Without --force restic skips files that are unchanged since the parent
    # snapshot and would not notice that their blobs are gone. No forget or
    # prune here: retention stays with the scheduled job.
    container_script="${container_prelude}"'; set -- ${BACKUP_PATHS:?BACKUP_PATHS must be set}; exec restic backup --force --host "${RESTIC_HOST:-zeus}" --tag "${RESTIC_TAG:-$0}" "$@"'
    ;;
  repair-snapshots-dry-run)
    [ "$#" -eq 0 ] || usage
    container_script="${container_prelude}; exec restic repair snapshots --dry-run"
    ;;
  repair-snapshots)
    [ "$#" -eq 0 ] || usage
    container_script="${container_prelude}; exec restic repair snapshots --forget"
    ;;
  prune)
    [ "$#" -eq 0 ] || usage
    container_script="${container_prelude}; exec restic prune"
    ;;
  restic)
    [ "$#" -ge 1 ] || usage
    container_script="${container_prelude}; exec restic \"\$@\""
    ;;
  *)
    usage
    ;;
esac

mkdir -p "${restic_output_dir}"
log_file="${restic_output_dir}/${job_name}-repair.log"
status_file="$(mktemp "${restic_output_dir}/${job_name}-repair.status.XXXXXX")"
trap 'rm -f "${status_file}"' EXIT

{
  echo "=================================================================="
  echo "==> $(date '+%Y-%m-%d %H:%M:%S %Z') job=${job_name} step=${step} $*"
  echo "==> repository=${RESTIC_REPOSITORY}"
  status=0
  docker compose \
    --project-name "${compose_project_name}" \
    --project-directory "${stack_dir}" \
    -f "${compose_file}" \
    run --rm -T restic-job -c "${container_script}" "${job_name}" "$@" || status=$?
  echo "==> step=${step} finished with exit status ${status}"
  echo "${status}" > "${status_file}"
} 2>&1 | tee -a "${log_file}"

status="$(cat "${status_file}" 2>/dev/null || echo 1)"
echo "==> Log appended to ${log_file}" >&2
exit "${status:-1}"
