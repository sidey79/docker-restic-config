#!/bin/sh
set -u

job_name="${1:-}"
event_status="${2:-}"
exit_code="${3:-0}"
started_at="${4:-}"
finished_at="${5:-}"
duration_seconds="${6:-0}"
restic_json_file="${7:-}"

if [ -z "${job_name}" ] || [ -z "${event_status}" ]; then
  echo "Usage: $0 <job-name> <started|success|failure> [exit-code] [started-at] [finished-at] [duration-seconds] [restic-json-file]" >&2
  exit 64
fi

webhook_url="${N8N_BACKUP_WEBHOOK_URL:-${BACKUP_WEBHOOK_URL:-}}"
if [ -z "${webhook_url}" ]; then
  echo "==> No n8n backup webhook configured; skipping ${event_status} notification for ${job_name}"
  exit 0
fi

json_escape() {
  printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

restic_summary_json="null"
if [ -n "${restic_json_file}" ] && [ -r "${restic_json_file}" ]; then
  restic_summary_json="$(sed -n '/"message_type":"summary"/p; /"message_type": "summary"/p' "${restic_json_file}" | tail -n 1)"
  if [ -z "${restic_summary_json}" ]; then
    restic_summary_json="null"
  fi
fi

host_name="$(hostname 2>/dev/null || printf unknown)"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

job_json="$(json_escape "${job_name}")"
status_json="$(json_escape "${event_status}")"
host_json="$(json_escape "${host_name}")"
timestamp_json="$(json_escape "${timestamp}")"
started_json="$(json_escape "${started_at}")"
finished_json="$(json_escape "${finished_at}")"

payload=$(printf '{"source":"restic","event":"backup","job":"%s","status":"%s","host":"%s","exitCode":%s,"timestamp":"%s","startedAt":"%s","finishedAt":"%s","durationSeconds":%s,"restic":%s}' \
  "${job_json}" \
  "${status_json}" \
  "${host_json}" \
  "${exit_code}" \
  "${timestamp_json}" \
  "${started_json}" \
  "${finished_json}" \
  "${duration_seconds}" \
  "${restic_summary_json}")

echo "==> Sending n8n backup notification: job=${job_name} status=${event_status} exitCode=${exit_code}"
if ! curl --fail --silent --show-error --max-time "${N8N_BACKUP_WEBHOOK_TIMEOUT:-10}" \
  --header "Content-Type: application/json" \
  --data "${payload}" \
  "${webhook_url}" >/dev/null; then
  echo "==> n8n backup notification failed for ${job_name} status=${event_status}" >&2
fi
