#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
unit_dir="${UNIT_DIR:-/etc/systemd/system}"
config_dir="${CONFIG_DIR:-/etc/docker-restic-config}"
stack_dir="${STACK_DIR:-${repo_dir}}"
compose_file="${COMPOSE_FILE:-${stack_dir}/docker-compose.yml}"
enable_timers="${ENABLE_TIMERS:-1}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer as root so it can write ${unit_dir} and reload systemd." >&2
  exit 1
fi

install -d "${unit_dir}" "${config_dir}"
install -m 0644 "${repo_dir}/systemd/restic-backup@.service" "${unit_dir}/restic-backup@.service"

cat > "${config_dir}/systemd.env" <<EOF
STACK_DIR=${stack_dir}
COMPOSE_FILE=${compose_file}
EOF
chmod 0644 "${config_dir}/systemd.env"

installed_timers=""
for job_file in "${repo_dir}"/jobs/*.env; do
  [ -e "${job_file}" ] || continue

  job_name="$(basename "${job_file}" .env)"
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
  echo "No timers installed because no jobs/*.env file defines SYSTEMD_ON_CALENDAR."
fi
