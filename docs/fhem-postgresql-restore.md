# FHEM PostgreSQL restore

The `fhem` job stores the PostgreSQL custom-format dump as
`/source/2/fhem/postgres/latest.dump`. The existing MariaDB dump
`/source/2/fhem/latest.sql` remains an unchanged rollback backup.

## Run or inspect the backup

The complete workflow, including both database dumps, runs via:

```sh
sudo systemctl start restic-backup@fhem.service
sudo journalctl -u restic-backup@fhem.service -n 200 --no-pager
```

Do not call `scripts/restic-job.sh` alone when a fresh dump is required because
only the host-side pre-backup hook creates the dumps.

## Restore a dump from Restic

List snapshots and select an explicit, reviewed snapshot ID:

```sh
set -a
. jobs/fhem.env
set +a
docker compose run --rm restic-job -c \
  '. /jobs/fhem.env && export RESTIC_REPOSITORY RESTIC_CACHE_DIR=/cache && restic snapshots --tag fhem'
```

Restore only the PostgreSQL dump into a new directory (replace `SNAPSHOT_ID`):

```sh
docker compose run --rm restic-job -c \
  '. /jobs/fhem.env && export RESTIC_REPOSITORY RESTIC_CACHE_DIR=/cache && restic restore SNAPSHOT_ID --target /restore/fhem-pg-SNAPSHOT_ID --include /source/2/fhem/postgres/latest.dump'
```

With the default `RESTIC_RESTORE_DIR`, validate the resulting archive using the
matching client in `postgres-fhem`:

```sh
dump=/opt/docker/restic/restore/fhem-pg-SNAPSHOT_ID/source/2/fhem/postgres/latest.dump
test -s "${dump}"
docker exec -i postgres-fhem pg_restore --list < "${dump}" > /tmp/fhem-pg-SNAPSHOT_ID.list
```

Review the archive list, including recorded role names, before restoring.

## Safe restore test

Use a unique database name. The existence check aborts on collision and no
password is copied from the container or written to a command line:

```sh
test_db=fhem_restore_test_YYYYMMDDHHMMSS
docker exec postgres-fhem sh -eu -c \
  'exists="$(psql --username="$POSTGRES_USER" --dbname=postgres --tuples-only --no-align --command="SELECT 1 FROM pg_database WHERE datname = '\''$1'\''")"; [ -z "$exists" ] || { echo "Target database already exists: $1" >&2; exit 73; }; createdb --username="$POSTGRES_USER" --owner="$POSTGRES_USER" --template=template0 "$1"' \
  sh "${test_db}"
docker exec -i postgres-fhem sh -eu -c \
  'exec pg_restore --exit-on-error --no-owner --no-privileges --username="$POSTGRES_USER" --role="$POSTGRES_USER" --dbname="$1"' \
  sh "${test_db}" < "${dump}"
```

Inspect tables and estimated row counts in test and source databases:

```sh
docker exec postgres-fhem sh -eu -c \
  'psql --username="$POSTGRES_USER" --dbname="$1" --command="\\dt+" --command="SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY 1,2;"' \
  sh "${test_db}"
docker exec postgres-fhem sh -eu -c \
  'psql --username="$POSTGRES_USER" --dbname=fhem --command="SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY 1,2;"' sh
```

After confirming the actual history table name, compare exact `COUNT(*)` and
recent timestamps in both databases. Leave the test database for review;
deleting it is a separate, explicitly approved action.

## Controlled production restore

A production restore is destructive and requires a maintenance window and
explicit approval. Never use `fhem` as the target of the test commands.

1. Stop or isolate FHEM writes. Record the database owner, roles, grants,
   extensions, encoding and locale.
2. Prefer restoring into a newly named database and switching FHEM deliberately.
   Keep the old PostgreSQL database and MariaDB rollback dump until acceptance.
3. Create the target from `template0` with the intended FHEM role as owner.
4. Restore with `pg_restore --exit-on-error`. For controlled ownership, use
   `--no-owner --no-privileges --role=<FHEM role>` and then explicitly apply and
   verify `CONNECT`, schema, table, sequence and default privileges. For exact
   source ownership/ACLs, prepare all source roles and omit those options.
5. Verify tables, exact history-row counts, recent timestamps, sequences and
   extensions. Then check `LoggingDB_PG` connectivity and FHEM read/write access.

MariaDB may be removed only after the agreed rollback period, multiple successful
PostgreSQL snapshots, a documented restore test, verified FHEM access and
explicit operational approval. Existing snapshots remain under the unchanged
Restic retention; this migration deletes none manually.
