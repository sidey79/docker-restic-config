# Restic backup stack

Central Restic stack for host and Docker application backups.

The stack replaces the central Duplicati container model with one Restic
one-shot runner. Backup jobs are started with `docker compose run --rm`, usually
from centrally installed host-level systemd timers.

## Layout

- `docker-compose.yml`: central Restic service
- `scripts/restic-job.sh`: generic backup, retention and check workflow
- `jobs/*.env`: per-job repository, source and retention settings
- `systemd/`: central systemd service and timer template
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

When jobs are started through the host-level systemd units, Portainer's
internal stack environment is not available to systemd. Put secrets needed by
Compose, especially `RESTIC_PASSWORD`, into `/etc/docker-restic-config/secrets.env`
on the host. The installer creates this file as root-only placeholder if it does
not exist.

Service-specific job files set their own repository target. Paperless is
configured in `jobs/paperless.env`. `RESTIC_SSH_DIR` is still configured in the
stack environment and mounted read-only to `/root/.ssh` inside the Restic
container.

`RESTIC_SSH_DIR` is mounted read-only to `/root/.ssh` inside the Restic
container. The stack provides `/etc/ssh/ssh_config.d/tiffy.conf` as an inline Compose config
for `tiffy` on port `2222` with user `sbackupftp` and key
`/root/.ssh/id.key`. The mounted SSH directory must contain that private key and
the stack pins the ED25519 host key through `/etc/restic/known_hosts` with
`StrictHostKeyChecking yes`.

Run one backup manually:

```sh
docker compose run --rm restic-job /scripts/restic-job.sh paperless
```

List snapshots for a specific repository:

```sh
docker compose run --rm restic-job -c '. /jobs/paperless.env && export RESTIC_REPOSITORY RESTIC_CACHE_DIR=/cache && restic snapshots'
```

Restore into the configured restore directory:

```sh
docker compose run --rm restic-job -c '. /jobs/paperless.env && export RESTIC_REPOSITORY RESTIC_CACHE_DIR=/cache && restic restore latest --target /restore'
```

## systemd installation

Backup timers are maintained centrally in this repository. Job files that define
`SYSTEMD_ON_CALENDAR` get a matching `restic-backup@<job>.timer` during
installation.

Install or update the central service and timers:

```sh
sudo ./scripts/install-systemd-units.sh
```

By default the installer writes:

- `/etc/systemd/system/restic-backup@.service`
- `/etc/systemd/system/restic-backup@<job>.timer`
- `/etc/docker-restic-config/systemd.env`

The generated `systemd.env` pins `COMPOSE_PROJECT_NAME=restic` so host-level
manual runs and timer runs reuse the existing `restic_default` Docker network.

`CONFIG_DIR` changes the location of `systemd.env`; the installer also renders
the matching `EnvironmentFile=` path into `restic-backup@.service`.

Set `ENABLE_TIMERS=0` to install without enabling timers:

```sh
sudo ENABLE_TIMERS=0 ./scripts/install-systemd-units.sh
```

If the deployed Portainer stack lives somewhere else, pass its path explicitly:

```sh
sudo STACK_DIR=/opt/docker/portainer-compose-unpacker/stacks/restic/docker-restic-config \
  ./scripts/install-systemd-units.sh
```

## Data source policy

The stack intentionally backs up the more specific Zeus subdirectories instead
of the broad `/srv/backup/zeus` tree. This avoids overlapping snapshots for
`ecodms`, `paperless-ngx`, `n8n` and `portainer`.

Database dumps should be written uncompressed where practical, then atomically
renamed from `*.tmp` to their final filename. Restic can then deduplicate stable
SQL dumps more effectively.

## Scheduling

Prefer host-level systemd timers from this repository. They prepare or require
consistent application dumps and then execute the relevant Restic one-shot job:

```sh
docker compose \
  --project-directory /opt/docker/portainer-compose-unpacker/stacks/restic/docker-restic-config \
  -f /opt/docker/portainer-compose-unpacker/stacks/restic/docker-restic-config/docker-compose.yml \
  run --rm restic-job /scripts/restic-job.sh paperless
```

This keeps database credentials in the application stacks while Restic only
needs filesystem access to the dump directories.
