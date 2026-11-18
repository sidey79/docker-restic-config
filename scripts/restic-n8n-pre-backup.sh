#!/bin/sh
set -eu

pg_container="${N8N_PG_CONTAINER:?N8N_PG_CONTAINER must be set}"
pg_dump_file="${N8N_PG_DUMP_FILE:?N8N_PG_DUMP_FILE must be set}"
pg_db_name="${N8N_PG_DB_NAME:-}"

# The n8n encryption key is needed to decrypt the credentials stored in the
# dump. Set N8N_KEY_FILE to an empty value to skip the key snapshot.
key_file="${N8N_KEY_FILE-}"
n8n_container="${N8N_CONTAINER:-}"
n8n_config_file="${N8N_CONFIG_FILE:-/home/node/.n8n/config}"

key_tmp=""
dump_tmp=""
cleanup_tmp_files() {
  if [ -n "${key_tmp}" ]; then
    rm -f -- "${key_tmp}"
  fi
  if [ -n "${dump_tmp}" ]; then
    rm -f -- "${dump_tmp}"
  fi
}
# A trap handler for a signal returns to the interrupted script, so the signal
# traps must exit explicitly. The EXIT trap then removes the temporary files.
trap cleanup_tmp_files EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Only one run may use the temporary files at a time: a second run would
# delete the first run's in-progress file as "stale".
lock_file="${N8N_LOCK_FILE:-/run/lock/restic-n8n-pre-backup.lock}"
if [ ! -d "$(dirname "${lock_file}")" ]; then
  lock_file="${TMPDIR:-/tmp}/restic-n8n-pre-backup.lock"
fi
if command -v flock >/dev/null 2>&1; then
  exec 9>"${lock_file}"
  if ! flock -n 9; then
    echo "Another n8n pre-backup run holds ${lock_file}; aborting" >&2
    exit 75
  fi
else
  echo "==> WARNING: flock not found; running without a lock" >&2
fi

# Removes leftovers of an earlier killed run next to ${1}.
remove_stale_tmp_files() {
  find "$(dirname "${1}")" -maxdepth 1 -type f -name "$(basename "${1}").tmp.*" -delete
}

if [ -n "${key_file}" ]; then
  : "${n8n_container:?N8N_CONTAINER must be set when N8N_KEY_FILE is set}"

  echo "==> Saving n8n encryption key from ${n8n_container}:${n8n_config_file}"
  key_value="$(
    docker exec "${n8n_container}" cat "${n8n_config_file}" 2>/dev/null |
      grep -oE '"encryptionKey"[[:space:]]*:[[:space:]]*"[^"]+"' |
      head -n 1 |
      sed -E 's/.*"encryptionKey"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
  )" || key_value=""
  if [ -z "${key_value}" ]; then
    echo "n8n encryption key not found in ${n8n_container}:${n8n_config_file}; refusing to run a backup that cannot restore credentials" >&2
    exit 78
  fi

  key_dir="$(dirname "${key_file}")"
  mkdir -p "${key_dir}"
  # The key decrypts the credentials in the dump: keep its directory closed to
  # other users, like the key file itself (0600).
  chmod "${N8N_KEY_DIR_MODE:-0750}" "${key_dir}"
  remove_stale_tmp_files "${key_file}"
  key_tmp="$(mktemp "${key_file}.tmp.XXXXXX")"
  printf 'N8N_ENCRYPTION_KEY=%s\n' "${key_value}" > "${key_tmp}"
  chmod 0600 "${key_tmp}"
  mv "${key_tmp}" "${key_file}"
  key_tmp=""
  echo "==> n8n encryption key saved: ${key_file}"
fi

dump_dir="$(dirname "${pg_dump_file}")"
mkdir -p "${dump_dir}"
# The dump contains workflows, credentials and execution data: keep the
# directory closed to other users, like the dump file itself (0640).
chmod "${N8N_PG_DUMP_DIR_MODE:-0750}" "${dump_dir}"
remove_stale_tmp_files "${pg_dump_file}"
dump_tmp="$(mktemp "${pg_dump_file}.tmp.XXXXXX")"

echo "==> Creating n8n PostgreSQL plain SQL dump from ${pg_container}: ${pg_dump_file}"
if ! docker exec -e N8N_PG_DB="${pg_db_name}" "${pg_container}" \
  sh -eu -c '
    db="${N8N_PG_DB:-${POSTGRES_DB:-}}"
    : "${db:?Neither N8N_PG_DB_NAME nor POSTGRES_DB is set}"
    : "${POSTGRES_USER:?POSTGRES_USER is not set}"
    if [ -n "${POSTGRES_PASSWORD:-}" ]; then
      export PGPASSWORD="${POSTGRES_PASSWORD}"
    fi
    exec pg_dump --no-owner --no-privileges --username="${POSTGRES_USER}" --dbname="${db}"
  ' > "${dump_tmp}"; then
  echo "PostgreSQL dump failed; removing incomplete temporary file ${dump_tmp}" >&2
  exit 74
fi

if [ ! -s "${dump_tmp}" ]; then
  echo "PostgreSQL dump is empty; removing temporary file ${dump_tmp}" >&2
  exit 74
fi

if ! tail -n 20 "${dump_tmp}" | grep -q 'PostgreSQL database dump complete'; then
  echo "PostgreSQL dump looks incomplete; removing temporary file ${dump_tmp}" >&2
  exit 74
fi

chmod 0640 "${dump_tmp}"
mv "${dump_tmp}" "${pg_dump_file}"
dump_tmp=""
echo "==> n8n PostgreSQL dump ready: ${pg_dump_file}"
