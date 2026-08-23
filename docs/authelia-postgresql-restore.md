# Authelia PostgreSQL restore

The `authelia` job stores an internally uncompressed PostgreSQL custom-format
dump as `/source/2/authelia/postgres/latest.dump`. The dump is created before
Restic runs and is validated with `pg_restore --list`.

Restore a snapshot into the configured restore directory (replace
`SNAPSHOT_ID`):

```sh
docker compose run --rm restic-job \
  -c '. /jobs/authelia.env && export RESTIC_REPOSITORY RESTIC_CACHE_DIR=/cache && restic restore SNAPSHOT_ID --target /restore/authelia-SNAPSHOT_ID --include /source/2/authelia/postgres/latest.dump'
```

The resulting dump can be inspected with the matching PostgreSQL client:

```sh
dump=/opt/docker/restic/restore/authelia-SNAPSHOT_ID/source/2/authelia/postgres/latest.dump
docker exec -i authelia-postgresql-1 pg_restore --list < "${dump}"
```

Restore into a newly named database first, validate Authelia, and only then
switch the application configuration. Do not overwrite the active database
without a tested rollback plan.
