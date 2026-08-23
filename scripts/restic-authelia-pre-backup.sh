#!/bin/sh
set -eu

stop_containers="${AUTHELIA_STOP_CONTAINERS:?AUTHELIA_STOP_CONTAINERS must be set}"
pg_container="${AUTHELIA_PG_CONTAINER:?AUTHELIA_PG_CONTAINER must be set}"
pg_db_name="${AUTHELIA_PG_DB_NAME:?AUTHELIA_PG_DB_NAME must be set}"
pg_dump_file="${AUTHELIA_PG_DUMP_FILE:?AUTHELIA_PG_DUMP_FILE must be set}"

echo "==> Stopping Authelia container(s): ${stop_containers}"
docker stop ${stop_containers}

pg_dump_dir="$(dirname "${pg_dump_file}")"
mkdir -p "${pg_dump_dir}"
find "${pg_dump_dir}" -maxdepth 1 -type f -name "$(basename "${pg_dump_file}").tmp.*" -delete
pg_tmp_dump="$(mktemp "${pg_dump_file}.tmp.XXXXXX")"
cleanup_pg_tmp_dump() {
  rm -f -- "${pg_tmp_dump}"
}
trap cleanup_pg_tmp_dump EXIT HUP INT TERM

echo "==> Creating Authelia PostgreSQL custom-format dump from ${pg_container}/${pg_db_name}: ${pg_dump_file}"
if ! docker exec "${pg_container}" \
  sh -eu -c 'exec pg_dump --format=custom --compress=0 --username="${POSTGRES_USER:?POSTGRES_USER is not set}" --dbname="$1"' \
  sh "${pg_db_name}" > "${pg_tmp_dump}"; then
  echo "PostgreSQL dump failed; removing incomplete temporary file ${pg_tmp_dump}" >&2
  exit 74
fi

if [ ! -s "${pg_tmp_dump}" ]; then
  echo "PostgreSQL dump is empty; removing temporary file ${pg_tmp_dump}" >&2
  exit 74
fi

if ! docker exec -i "${pg_container}" pg_restore --list < "${pg_tmp_dump}" >/dev/null; then
  echo "PostgreSQL dump validation failed; removing temporary file ${pg_tmp_dump}" >&2
  exit 74
fi

chmod 0640 "${pg_tmp_dump}"
mv "${pg_tmp_dump}" "${pg_dump_file}"
trap - EXIT HUP INT TERM
echo "==> Authelia PostgreSQL dump ready: ${pg_dump_file}"
