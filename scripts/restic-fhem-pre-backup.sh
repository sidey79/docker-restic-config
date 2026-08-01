#!/bin/sh
set -eu

fhem_web_url="${FHEM_WEB_URL:-https://zeus:8088/fhem}"
fhem_web_insecure="${FHEM_WEB_INSECURE:-1}"
wait_timeout="${FHEM_BACKUP_WAIT_TIMEOUT:-10800}"
wait_interval="${FHEM_BACKUP_WAIT_INTERVAL:-30}"

pg_container="${FHEM_PG_CONTAINER:?FHEM_PG_CONTAINER must be set}"
pg_db_name="${FHEM_PG_DB_NAME:?FHEM_PG_DB_NAME must be set}"
pg_dump_file="${FHEM_PG_DUMP_FILE:?FHEM_PG_DUMP_FILE must be set}"

status_cmd='%7Bjoin(%22%7C%22%2CReadingsVal(%22LoggingDB.reduce2%22%2C%22current_job%22%2C%22unknown%22)%2CReadingsTimestamp(%22LoggingDB.reduce2%22%2C%22current_job%22%2C%221970-01-01%2000%3A00%3A00%22)%2CReadingsVal(%22FHEM.Backup%22%2C%22Backupnow%22%2C%22on%22)%2CReadingsVal(%22FHEM.Backup%22%2C%22pipeline_complete%22%2C%22missing%22)%2CReadingsTimestamp(%22FHEM.Backup%22%2C%22pipeline_complete%22%2C%221970-01-01%2000%3A00%3A00%22)%2CReadingsVal(%22FHEM.Backup%22%2C%22csv_status%22%2C%22missing%22))%7D'
today="$(date +%F)"
deadline=$(( $(date +%s) + wait_timeout ))

curl_opts="--fail --silent --show-error"
if [ "${fhem_web_insecure}" = "1" ]; then
  curl_opts="${curl_opts} --insecure"
fi

echo "==> Waiting for FHEM DB reduce and backup pipeline to finish for ${today}"
while :; do
  status="$(curl ${curl_opts} "${fhem_web_url}?cmd=${status_cmd}&XHR=1")"

  old_ifs="${IFS}"
  IFS='|'
  set -- ${status}
  IFS="${old_ifs}"

  reduce_job="${1:-unknown}"
  reduce_timestamp="${2:-1970-01-01 00:00:00}"
  backup_now="${3:-on}"
  pipeline_complete="${4:-missing}"
  pipeline_timestamp="${5:-1970-01-01 00:00:00}"
  csv_status="${6:-missing}"

  reduce_date="${reduce_timestamp%% *}"
  pipeline_date="${pipeline_timestamp%% *}"

  if [ "${reduce_job}" = "none" ] &&
     [ "${reduce_date}" = "${today}" ] &&
     [ "${backup_now}" = "off" ] &&
     [ "${pipeline_date}" = "${today}" ]; then
    case "${pipeline_complete}" in
      ok|warning)
        if [ "${csv_status}" != "ok" ]; then
          echo "==> WARNING: FHEM CSV export status is ${csv_status}; continuing with authoritative PostgreSQL dump" >&2
        fi
        echo "==> FHEM is ready for database dump"
        break
        ;;
    esac
  fi

  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "Timed out waiting for FHEM readiness: reduce_job=${reduce_job} reduce_timestamp=${reduce_timestamp} backup_now=${backup_now} pipeline_complete=${pipeline_complete} pipeline_timestamp=${pipeline_timestamp} csv_status=${csv_status}" >&2
    exit 75
  fi

  echo "==> FHEM not ready yet: reduce_job=${reduce_job} reduce_timestamp=${reduce_timestamp} backup_now=${backup_now} pipeline_complete=${pipeline_complete} pipeline_timestamp=${pipeline_timestamp} csv_status=${csv_status}"
  sleep "${wait_interval}"
done

pg_dump_dir="$(dirname "${pg_dump_file}")"
mkdir -p "${pg_dump_dir}"
pg_tmp_dump="$(mktemp "${pg_dump_file}.tmp.XXXXXX")"

echo "==> Creating FHEM PostgreSQL custom-format dump from ${pg_container}/${pg_db_name}: ${pg_dump_file}"
if ! docker exec "${pg_container}" \
  sh -eu -c 'exec pg_dump --format=custom --compress=0 --username="${POSTGRES_USER:?POSTGRES_USER is not set}" --dbname="$1"' \
  sh "${pg_db_name}" > "${pg_tmp_dump}"; then
  echo "PostgreSQL dump failed; incomplete temporary file left at ${pg_tmp_dump}" >&2
  exit 74
fi

if [ ! -s "${pg_tmp_dump}" ]; then
  echo "PostgreSQL dump is empty; temporary file left at ${pg_tmp_dump}" >&2
  exit 74
fi

if ! docker exec -i "${pg_container}" pg_restore --list < "${pg_tmp_dump}" >/dev/null; then
  echo "PostgreSQL dump validation failed; temporary file left at ${pg_tmp_dump}" >&2
  exit 74
fi

chmod 0640 "${pg_tmp_dump}"
mv "${pg_tmp_dump}" "${pg_dump_file}"
echo "==> FHEM PostgreSQL dump ready: ${pg_dump_file}"
