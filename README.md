# Restic backup stack

Central Restic stack for host and Docker application backups.

The stack replaces the central Duplicati container model with one Restic runner.
The container stays idle when Portainer starts the stack. Backup jobs are
started explicitly with `docker compose exec`, usually from host-level systemd
services that prepare consistent application data first.

## Layout

- `docker-compose.yml`: central Restic service
- `scripts/restic-backup.sh`: backup, retention and check workflow
- `.env.example`: source paths, repository target and retention settings
- `renovate.json`: dependency update configuration

## Setup

Create the local directories used by the stack:

```sh
mkdir -p /opt/docker/restic/cache /opt/docker/restic/restore /opt/docker/restic/repository
```

Configure the variables from `.env` in Portainer's stack environment and set
`RESTIC_PASSWORD` there. The stack does not mount a password file so that
Portainer can deploy it without pre-existing sidecar secret files.

For SFTP repositories, set `RESTIC_REPOSITORY` to the service-specific target,
for example:

```text
RESTIC_REPOSITORY=sftp:tiffy:/data/zeus/restic/paperless
RESTIC_SSH_DIR=/opt/docker/duplicati/config/.ssh
```

`RESTIC_SSH_DIR` is mounted read-only to `/root/.ssh` inside the Restic
container. The stack provides `/root/.ssh/config` as an inline Compose config
for `tiffy` on port `2222` with user `sbackupftp` and key
`/root/.ssh/id.key`. The mounted SSH directory must contain that private key and
the required host key trust material.

Run one backup manually:

```sh
docker compose exec restic /bin/sh /scripts/restic-backup.sh
```

Run the Paperless-specific backup after a fresh Paperless DB dump exists:

```sh
docker compose exec restic /bin/sh /scripts/restic-paperless-backup.sh
```

List snapshots:

```sh
docker compose exec restic restic snapshots
```

Restore into the configured restore directory:

```sh
docker compose exec restic restic restore latest --target /restore
```

## Data source policy

The stack intentionally backs up the more specific Zeus subdirectories instead
of the broad `/srv/backup/zeus` tree. This avoids overlapping snapshots for
`ecodms`, `paperless-ngx`, `n8n` and `portainer`.

Database dumps should be written uncompressed where practical, then atomically
renamed from `*.tmp` to their final filename. Restic can then deduplicate stable
SQL dumps more effectively.

## Scheduling

Prefer host-level systemd timers that prepare app-specific dumps and then
execute the relevant Restic job inside the already-running Restic container:

```sh
docker compose \
  --project-directory /opt/docker/portainer-compose-unpacker/stacks/docker-restic-config \
  -f /opt/docker/portainer-compose-unpacker/stacks/docker-restic-config/docker-compose.yml \
  exec restic /bin/sh /scripts/restic-backup.sh
```

This keeps database credentials in the application stacks while Restic only
needs filesystem access to the dump directories.
