#!/bin/sh
set -eu

backup_dir="${PORTAINER_BACKUP_DIR:-/srv/backup/zeus/portainer}"
backup_file="${PORTAINER_BACKUP_FILE:-${backup_dir}/latest.tar.gz}"
portainer_url="${PORTAINER_URL:-https://127.0.0.1:9443}"
portainer_api_key="${PORTAINER_API_KEY:?PORTAINER_API_KEY must be set}"
portainer_backup_password="${PORTAINER_BACKUP_PASSWORD:-}"
curl_timeout="${PORTAINER_BACKUP_TIMEOUT:-120}"
curl_insecure="${PORTAINER_BACKUP_INSECURE:-0}"

case "${portainer_backup_password}" in
  *"
"*)
    echo "PORTAINER_BACKUP_PASSWORD must not contain newline characters" >&2
    exit 64
    ;;
esac

mkdir -p "${backup_dir}"
tmp_file="$(mktemp "${backup_dir}/latest.tar.gz.tmp.XXXXXX")"
request_file="${tmp_file}.request"
trap 'rm -f "${tmp_file}" "${request_file}"' EXIT HUP INT TERM

curl_tls_args=""
if [ "${curl_insecure}" = "1" ]; then
  curl_tls_args="--insecure"
fi

json_password="$(printf '%s' "${portainer_backup_password}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '{"Password":"%s"}' "${json_password}" > "${request_file}"

echo "==> Creating Portainer backup through ${portainer_url}/api/backup"
curl \
  --fail \
  --show-error \
  --silent \
  --location \
  --max-time "${curl_timeout}" \
  ${curl_tls_args} \
  --request POST \
  --url "${portainer_url%/}/api/backup" \
  --header "X-API-Key: ${portainer_api_key}" \
  --header "Content-Type: application/json" \
  --data-binary "@${request_file}" \
  --output "${tmp_file}"

if [ ! -s "${tmp_file}" ]; then
  echo "Portainer backup response was empty" >&2
  exit 1
fi

chmod 0600 "${tmp_file}"
mv "${tmp_file}" "${backup_file}"
trap - EXIT HUP INT TERM
rm -f "${request_file}"

echo "==> Portainer backup ready: ${backup_file}"
