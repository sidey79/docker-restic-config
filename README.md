# Restic backup stack

Central Restic stack for host and Docker application backups.

The stack replaces the central Duplicati container model with one generic Restic
one-shot runner. Each backup source is configured as its own job in `jobs/*.env`,
including its own repository, tag and timer, and is started with
`docker compose run --rm` from centrally installed host-level systemd timers.

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
mkdir -p /opt/docker/restic/cache /opt/docker/restic/restore /opt/docker/restic/repository /opt/docker/restic/output
```

Configure the variables from `.env` in Portainer's stack environment and set
`RESTIC_PASSWORD` there. The stack does not mount a password file so that
Portainer can deploy it without pre-existing sidecar secret files.

When jobs are started through the host-level systemd units, Portainer's
internal stack environment is not available to systemd. Put secrets needed by
Compose, especially `RESTIC_PASSWORD`, into `/etc/docker-restic-config/secrets.env`
on the host. Non-secret runtime settings such as `N8N_BACKUP_WEBHOOK_URL` are
written to `/etc/docker-restic-config/systemd.env`; the default webhook URL is
`https://127.0.0.1:5678/webhook/restic/status`. The installer creates
`secrets.env` as root-only placeholder if it does not exist.

Service-specific job files set their own repository target. Current jobs are
`bitwarden`, `ecodms`, `etc`, `fhem`, `n8n`, `paperless`, `pictures`,
`portainer`, `wordpress` and `z2m`. Paperless is configured in
`jobs/paperless.env` and additionally defines host-side pre/post commands.

`RESTIC_SSH_DIR` is configured in the stack environment and mounted read-only to
`/root/.ssh` inside the Restic container. The stack provides `/etc/ssh/ssh_config.d/tiffy.conf` as an inline Compose config
for `tiffy` on port `2222` with user `sbackupftp` and key
`/root/.ssh/id.key`. The mounted SSH directory must contain that private key and
the stack pins the ED25519 host key through `/etc/restic/known_hosts` with
`StrictHostKeyChecking yes`.

Run one backup manually:

```sh
set -a
. jobs/paperless.env
set +a
docker compose run --rm restic-job /scripts/restic-job.sh paperless
```

List snapshots for a specific repository:

```sh
set -a
. jobs/paperless.env
set +a
docker compose run --rm restic-job -c '. /jobs/paperless.env && export RESTIC_REPOSITORY RESTIC_CACHE_DIR=/cache && restic snapshots'
```

Restore into the configured restore directory:

```sh
set -a
. jobs/paperless.env
set +a
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

Set `ENABLE_TIMERS=0` to install timer unit files without enabling them:

```sh
sudo ENABLE_TIMERS=0 ./scripts/install-systemd-units.sh
```

Use `JOBS` to render only selected job timers. This installs only the Paperless
timer unit file and leaves it disabled:

```sh
sudo JOBS=paperless ENABLE_TIMERS=0 ./scripts/install-systemd-units.sh
```

If the deployed Portainer stack lives somewhere else, pass its path explicitly:

```sh
sudo STACK_DIR=/opt/docker/portainer-compose-unpacker/stacks/restic/docker-restic-config \
  ./scripts/install-systemd-units.sh
```

## Updating existing timers after repository updates

If your host already has `restic-backup@*.timer` units from an older checkout,
update only those existing timers after pulling a new repository version:

```sh
cd /opt/docker/portainer-compose-unpacker/stacks/restic/docker-restic-config
git pull --ff-only
sudo UPDATE_EXISTING_ONLY=1 ./scripts/install-systemd-units.sh
```

If your stack checkout lives somewhere else, pass it explicitly so
`/etc/docker-restic-config/systemd.env` points to the correct Compose project:

```sh
sudo STACK_DIR=/your/stack/path ./scripts/install-systemd-units.sh
```

If you only want a subset of jobs enabled on this host, rerun with `JOBS`:

```sh
sudo JOBS="paperless n8n" ./scripts/install-systemd-units.sh
```

`UPDATE_EXISTING_ONLY=1` can be combined with `JOBS` to update the intersection
of both selectors (only listed jobs that already have timer unit files):

```sh
sudo UPDATE_EXISTING_ONLY=1 JOBS="paperless n8n" ./scripts/install-systemd-units.sh
```

If you only want to create timer files without enabling them, use `ENABLE_TIMERS=0`:

```sh
sudo JOBS="paperless n8n" ENABLE_TIMERS=0 ./scripts/install-systemd-units.sh
```

The installer creates or updates matching unit files and enables selected
timers, but it does not remove stale timer units from jobs that no longer
exist or should no longer run. Disable and remove obsolete timers manually:

```sh
sudo systemctl disable --now restic-backup@oldjob.timer
sudo rm -f /etc/systemd/system/restic-backup@oldjob.timer
sudo systemctl daemon-reload
```

Verify the final state:

```sh
systemctl list-timers 'restic-backup@*.timer'
systemctl status restic-backup@paperless.timer
```

## Data source policy

The stack intentionally backs up each source through its own job instead of a
broad `/srv/backup/zeus` snapshot. This avoids overlapping snapshots for
`ecodms`, `paperless-ngx`, `n8n` and `portainer` and keeps retention, tags and
repository paths independent per backup source.

Each job declares the host paths that should be mounted into the Restic container
with `RESTIC_CONTAINER_BACKUP_SOURCE_1`, `RESTIC_CONTAINER_BACKUP_SOURCE_2` and
`RESTIC_CONTAINER_BACKUP_SOURCE_3`. The names are intentionally container-scoped:
Compose mounts them as `/source/1`, `/source/2` and `/source/3`, and the job's
`BACKUP_PATHS` selects the directories or files to include.

Database dumps should be written uncompressed where practical, then atomically
renamed from a temporary file to their final filename. Restic can then deduplicate
stable SQL dumps more effectively.

Jobs can define `PRE_BACKUP_COMMAND` and `POST_BACKUP_COMMAND` in `jobs/<name>.env`.
The systemd service runs a host-side orchestrator that executes the pre-backup
command, then the Restic container, then the post-backup command. The post-backup
command is also attempted when the pre-backup command or Restic fails, so stopped
applications can be started again.

Generic systemd job flow:

```text
systemd on host
  -> scripts/systemd-backup-job.sh <job> on host
     -> scripts/notify-backup-job.sh <job> started on host
     -> scripts/pre-backup-job.sh <job> on host
        -> optional PRE_BACKUP_COMMAND from jobs/<job>.env
     -> docker compose run restic-job /scripts/restic-job.sh <job>
        -> scripts/restic-job.sh inside the Restic container
        -> restic backup --json writes /output/<job>-backup.jsonl
     -> scripts/post-backup-job.sh <job> on host
        -> optional POST_BACKUP_COMMAND from jobs/<job>.env
     -> scripts/notify-backup-job.sh <job> success|failure on host
```

The orchestrator keeps Docker control, application stop/start commands and n8n
notifications on the host. Only the Restic repository operations run inside the
`restic-job` container.

The Paperless job stops the webserver container while leaving Postgres and helper services running,
creates `/srv/backup/zeus/paperless-ngx/db/latest.sql` with `pg_dump`, runs Restic,
and starts the webserver container again afterwards.

The Portainer job does not need a local Portainer stack file. Before Restic runs,
it calls Portainer's backup API and writes the archive atomically to
`/srv/backup/zeus/portainer/latest.tar.gz`; Restic backs up that generated file.
Portainer documents that this backup includes the Portainer database and stack
files deployed through Portainer, but not the managed containers, images,
volumes or application data. Create an administrator API key in Portainer and put
it into `/etc/docker-restic-config/secrets.env`:

```sh
PORTAINER_API_KEY=ptr_...
PORTAINER_BACKUP_PASSWORD=change-this-encryption-password
```

`PORTAINER_BACKUP_PASSWORD` is optional for the API request, but using it is
recommended because the generated archive contains sensitive Portainer
configuration and credentials.

The FHEM job starts at 00:16 and waits until `LoggingDB.reduce2:current_job`
and `FHEM.Backup:Backupnow` both have a current-day finished timestamp. It then
creates an uncompressed MariaDB dump as `/backup/latest.sql` inside the MariaDB
container. That path is backed by `/srv/backup/zeus/fhem` on the host and is
backed up via `/source/2/fhem/latest.sql`; FHEM app data is backed up
separately from `/opt/docker/fhem/app`. By default the dump uses
`MYSQL_ROOT_PASSWORD` from the MariaDB container environment. Set
`FHEM_DB_PASSWORD` in `/etc/docker-restic-config/secrets.env` only when an
explicit override is needed.

The z2m job backs up the live Zigbee2MQTT data directory
`/opt/docker/fhem/zigbee2mqtt/data` without stopping the container. This includes
`configuration.yaml`, `coordinator_backup.json`, `database.db`, `state.json`,
device icons and logs. The Zigbee network key is covered by the backup because
it is stored in `configuration.yaml` and also present in the coordinator backup.

If `N8N_BACKUP_WEBHOOK_URL` is set, the orchestrator sends JSON `started`,
`success` and `failure` events to n8n. Notification delivery failures are logged
but do not change the backup result. The payload contains `source`, `event`,
`job`, `status`, `host`, `exitCode`, `timestamp`, `startedAt`, `finishedAt`,
`durationSeconds` and `restic`. The `restic` field is the raw Restic
`backup --json` summary object. The complete Restic JSONL output is also
written to `${RESTIC_OUTPUT_DIR:-/opt/docker/restic/output}/<job>-backup.jsonl`.

## Scheduling

Prefer host-level systemd timers from this repository. Every `jobs/*.env` file
with `SYSTEMD_ON_CALENDAR` is installed as a sibling `restic-backup@<job>.timer`
next to the Paperless timer. The timers prepare or require consistent
application dumps and then execute the relevant Restic one-shot job:

```sh
docker compose \
  --project-directory /opt/docker/portainer-compose-unpacker/stacks/restic/docker-restic-config \
  -f /opt/docker/portainer-compose-unpacker/stacks/restic/docker-restic-config/docker-compose.yml \
  run --rm restic-job /scripts/restic-job.sh paperless
```

This keeps database credentials in the application stacks while Restic only
needs filesystem access to the dump directories.
