#!/bin/sh
set -eu

export RESTIC_CACHE_DIR=/cache

keep_daily="${RESTIC_KEEP_DAILY:-14}"
keep_weekly="${RESTIC_KEEP_WEEKLY:-8}"
keep_monthly="${RESTIC_KEEP_MONTHLY:-12}"

echo "==> Checking repository availability"
if ! restic snapshots >/dev/null 2>&1; then
  echo "Repository is not initialized or not reachable. Running restic init..."
  restic init
fi

echo "==> Backing up Paperless"
restic backup \
  --host zeus \
  --tag paperless \
  /source/paperless-ngx/db/latest.sql \
  /source/paperless-data \
  /source/paperless-media

echo "==> Applying Paperless retention policy"
restic forget \
  --tag paperless \
  --keep-daily "${keep_daily}" \
  --keep-weekly "${keep_weekly}" \
  --keep-monthly "${keep_monthly}" \
  --prune

echo "==> Running repository check"
restic check
