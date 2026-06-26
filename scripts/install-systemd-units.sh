#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
unit_dir="${UNIT_DIR:-/etc/systemd/system}"
config_dir="${CONFIG_DIR:-/etc/docker-restic-config}"
stack_dir="${STACK_DIR:-${repo_dir}}"
compose_file="${COMPOSE_FILE:-${stack_dir}/docker-compose.yml}"
compose_project_name="${COMPOSE_PROJECT_NAME:-restic}"
enable_timers="${ENABLE_TIMERS:-1}"
selected_jobs="${JOBS:-}"
update_existing_only="${UPDATE_EXISTING_ONLY:-0}"

job_has_existing_timer() {
  [ -f "${unit_dir}/restic-backup@$1.timer" ]
}

job_is_selected() {
  if [ -n "${selected_jobs}" ]; then
    selected_match=1

    for selected_job in ${selected_jobs}; do
      if [ "${selected_job}" = "$1" ]; then
        selected_match=0
        break
      fi
    done

    [ "${selected_match}" -eq 0 ] || return 1
  fi

  if [ "${update_existing_only}" = "1" ]; then
    job_has_existing_timer "$1" || return 1
  fi

  return 0
}

if [ ! -d "${stack_dir}" ]; then
  echo "STACK_DIR does not exist: ${stack_dir}" >&2
  exit 66
fi

if [ ! -f "${compose_file}" ]; then
  echo "COMPOSE_FILE does not exist: ${compose_file}" >&2
  exit 66
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer as root so it can write ${unit_dir} and reload systemd." >&2
  exit 1
fi

install -d "${unit_dir}" "${config_dir}"
sed \
  -e "s|@CONFIG_DIR@|${config_dir}|g" \
  "${repo_dir}/systemd/restic-backup@.service" \
  > "${unit_dir}/restic-backup@.service"
chmod 0644 "${unit_dir}/restic-backup@.service"

cat > "${config_dir}/systemd.env" <<EOF_SYSTEMD_ENV
STACK_DIR=${stack_dir}
COMPOSE_FILE=${compose_file}
COMPOSE_PROJECT_NAME=${compose_project_name}
RESTIC_OUTPUT_DIR=${RESTIC_OUTPUT_DIR:-/opt/docker/restic/output}
N8N_BACKUP_WEBHOOK_URL=${N8N_BACKUP_WEBHOOK_URL:-https://127.0.0.1:5678/webhook/restic/status}
N8N_BACKUP_WEBHOOK_TIMEOUT=${N8N_BACKUP_WEBHOOK_TIMEOUT:-10}
N8N_BACKUP_WEBHOOK_INSECURE=${N8N_BACKUP_WEBHOOK_INSECURE:-1}
EOF_SYSTEMD_ENV
chmod 0644 "${config_dir}/systemd.env"

if [ ! -e "${config_dir}/secrets.env" ]; then
  cat > "${config_dir}/secrets.env" <<EOF_SECRETS_ENV
# Set secrets used by docker compose when jobs are started through systemd.
# RESTIC_PASSWORD=
# Optional override. By default the FHEM job uses MYSQL_ROOT_PASSWORD from the MariaDB container.
# FHEM_DB_PASSWORD=
# Portainer backup API credentials. PORTAINER_BACKUP_PASSWORD is optional but recommended.
# PORTAINER_API_KEY=
# PORTAINER_BACKUP_PASSWORD=
EOF_SECRETS_ENV
fi
chmod 0600 "${config_dir}/secrets.env"

installed_timers=""
for job_file in "${repo_dir}"/jobs/*.env; do
  [ -e "${job_file}" ] || continue

  job_name="$(basename "${job_file}" .env)"
  job_is_selected "${job_name}" || continue
  unset SYSTEMD_ON_CALENDAR SYSTEMD_RANDOMIZED_DELAY_SEC SYSTEMD_ACCURACY_SEC
  # shellcheck disable=SC1090
  . "${job_file}"

  on_calendar="${SYSTEMD_ON_CALENDAR:-}"
  [ -n "${on_calendar}" ] || continue

  randomized_delay_sec="${SYSTEMD_RANDOMIZED_DELAY_SEC:-}"
  accuracy_sec="${SYSTEMD_ACCURACY_SEC:-}"

  randomized_delay_sec="${randomized_delay_sec:-5m}"
  accuracy_sec="${accuracy_sec:-1m}"
  timer_name="restic-backup@${job_name}.timer"

  sed \
    -e "s|@JOB@|${job_name}|g" \
    -e "s|@ON_CALENDAR@|${on_calendar}|g" \
    -e "s|@RANDOMIZED_DELAY_SEC@|${randomized_delay_sec}|g" \
    -e "s|@ACCURACY_SEC@|${accuracy_sec}|g" \
    "${repo_dir}/systemd/restic-backup@.timer.template" \
    > "${unit_dir}/${timer_name}"

  chmod 0644 "${unit_dir}/${timer_name}"
  installed_timers="${installed_timers} ${timer_name}"
done

systemctl daemon-reload

if [ "${enable_timers}" = "1" ]; then
  for timer_name in ${installed_timers}; do
    systemctl enable --now "${timer_name}"
  done
fi

echo "Installed restic-backup@.service"
if [ -n "${installed_timers}" ]; then
  echo "Installed timers:${installed_timers}"
else
  echo "No timers installed because no jobs/*.env file matched the current selector."
fi
