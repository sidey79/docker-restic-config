# Restic backup stack

Central Restic stack for host and Docker application backups.

The stack replaces the central Duplicati container model with one Restic runner.
Application stacks are still responsible for producing consistent database dumps
or app exports. This stack only backs up files that already exist on disk.

## Layout

- `docker-compose.yml`: central Restic service
- `scripts/restic-backup.sh`: backup, retention and check workflow
- `.env.example`: source paths, repository target and retention settings
- `renovate.json`: dependency update configuration

## Setup

Create the runtime env file and password file:

```sh
cp .env.example .env
mkdir -p /opt/docker/restic/secrets /opt/docker/restic/cache /opt/docker/restic/restore /opt/docker/restic/repository
chmod 700 /opt/docker/restic/secrets
printf '%s\n' 'change-this-password' > /opt/docker/restic/secrets/restic-password
chmod 600 /opt/docker/restic/secrets/restic-password
```

Adjust `RESTIC_REPOSITORY` in `.env` to the real backend.

Run one backup manually:

```sh
docker compose run --rm restic
```

Run the Paperless-specific backup after a fresh Paperless DB dump exists:

```sh
docker compose run --rm --entrypoint /bin/sh restic /scripts/restic-paperless-backup.sh
```

List snapshots:

```sh
docker compose run --rm --entrypoint restic restic snapshots
```

Restore into the configured restore directory:

```sh
docker compose run --rm --entrypoint restic restic restore latest --target /restore
```

## Data source policy

The stack intentionally backs up the more specific Zeus subdirectories instead
of the broad `/srv/backup/zeus` tree. This avoids overlapping snapshots for
`ecodms`, `paperless-ngx`, `n8n` and `portainer`.

Database dumps should be written uncompressed where practical, then atomically
renamed from `*.tmp` to their final filename. Restic can then deduplicate stable
SQL dumps more effectively.

## Scheduling

Prefer a host-level systemd timer that first starts the app-specific dump
containers and then runs this stack:

```sh
docker compose -f /opt/docker/wordpress/docker-compose.yml run --rm wordpress-db-dump
docker compose -f /opt/docker/n8n/docker-compose.yml run --rm n8n-db-dump
docker compose -f /opt/docker/restic/docker-compose.yml run --rm restic
```

This keeps database credentials in the application stacks while Restic only
needs filesystem access to the dump directories.
