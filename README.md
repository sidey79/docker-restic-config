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
`https://127.0.0.1:5678/webhook/backup-wf/backup-status`. The installer creates
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

The stack intentionally backs up each source through its own job instead of a
broad `/srv/backup/zeus` snapshot. This avoids overlapping snapshots for
`ecodms`, `paperless-ngx`, `n8n` and `portainer` and keeps retention, tags and
repository paths independent per backup source.

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
creates `/opt/docker/paperless-ngx/db/latest.sql` with `pg_dump`, runs Restic,
and starts the webserver container again afterwards.

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
