#!/bin/sh
set -eu

export RESTIC_CACHE_DIR=/cache

keep_daily="${RESTIC_KEEP_DAILY:-14}"
keep_weekly="${RESTIC_KEEP_WEEKLY:-8}"
keep_monthly="${RESTIC_KEEP_MONTHLY:-12}"

run_backup() {
  name="$1"
  shift

  echo "==> Backing up ${name}"
  restic backup \
    --host zeus \
    --tag "${name}" \
    "$@"
}

echo "==> Checking repository availability"
if ! restic snapshots >/dev/null 2>&1; then
  echo "Repository is not initialized or not reachable. Running restic init..."
  restic init
fi

# Large mostly-static file sources. Avoid adding /source/zeus here because it
# overlaps with the more specific service dump directories below.
run_backup data \
  /source/pictures \
  /source/ecodms

# Service state, app dumps and host configuration. Database dump producers should
# write stable, atomically-renamed files into these directories before this runs.
run_backup services \
  /source/etc \
  /source/fhem \
  /source/wordpress \
  /source/bitwarden \
  /source/z2m \
  /source/n8n \
  /source/portainer

echo "==> Applying retention policy"
restic forget \
  --keep-daily "${keep_daily}" \
  --keep-weekly "${keep_weekly}" \
  --keep-monthly "${keep_monthly}" \
  --prune

echo "==> Running repository check"
restic check
