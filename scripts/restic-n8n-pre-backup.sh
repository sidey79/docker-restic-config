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

tmp_files=""
cleanup_tmp_files() {
  for tmp_file in ${tmp_files}; do
    rm -f -- "${tmp_file}"
  done
}
trap cleanup_tmp_files EXIT HUP INT TERM

# Sets ${new_tmp} (no command substitution, so the cleanup trap sees the file).
new_tmp_file() {
  target="$1"
  mkdir -p "$(dirname "${target}")"
  find "$(dirname "${target}")" -maxdepth 1 -type f -name "$(basename "${target}").tmp.*" -delete
  new_tmp="$(mktemp "${target}.tmp.XXXXXX")"
  tmp_files="${tmp_files} ${new_tmp}"
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

  new_tmp_file "${key_file}"
  key_tmp="${new_tmp}"
  printf 'N8N_ENCRYPTION_KEY=%s\n' "${key_value}" > "${key_tmp}"
  chmod 0600 "${key_tmp}"
  mv "${key_tmp}" "${key_file}"
  echo "==> n8n encryption key saved: ${key_file}"
fi

new_tmp_file "${pg_dump_file}"
dump_tmp="${new_tmp}"
# The dump contains workflows, credentials and execution data: keep the
# directory closed to other users, like the dump file itself (0640).
chmod "${N8N_PG_DUMP_DIR_MODE:-0750}" "$(dirname "${pg_dump_file}")"

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
echo "==> n8n PostgreSQL dump ready: ${pg_dump_file}"
