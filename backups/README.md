# MediaWiki Production Backup

Backup solution for the MediaWiki production environment, deployed in the `<NS>`
(tools) namespace and protecting the `<Pod NS>` (prod) namespace.

It is deliberately split in two, because no single mechanism can cover both
halves: PVCs are namespace-scoped, so the backup container in tools cannot mount
the wiki's volumes in prod.

| | Mechanism | Runs | Retention |
|---|---|---|---|
| Database | `backup-storage` Helm release (bcgov/backup-container) | 01:00 daily | 14 daily, 8 weekly, 6 monthly |
| Files | `mediawiki-files-backup-cronjob.yaml` (`oc exec` + tar) | 01:35 daily | 14 daily, 6 monthly |

Both write into the same PVC, `mediawiki-backup-prod-backup-storage-backup-pvc`
(12Gi, RWX, `netapp-file-backup`), under `/backups/{daily,weekly,monthly}/YYYY-MM-DD/`.

## Strategy

Two tiers, with different jobs.

| Tier | Holds | Window | Recovery |
|---|---|---|---|
| This project's backups, on the PVC | Database dumps and content archives | 14 daily, 8 weekly, 6 monthly | Self-service, minutes |
| OCIO platform backup of that PVC | The whole volume as it stood | 90 days, geographically separate | Request to OCIO, slow |

The first tier is what anyone recovering a deleted page or a bad migration will
actually use, and is entirely under this project's control. The second is the
off-site floor underneath it — it is the reason the PVC sits on
`netapp-file-backup` rather than `netapp-file-standard`, and it holds copies of
files that tier-one pruning has already deleted.

Note what the platform tier does **not** cover: it protects the backup volume,
not the wiki. The production database and html volumes are on
`netapp-file-standard` with no equivalent guarantee. Keeping backups on separate
storage from the thing they protect is the point.

Retention depth is set by how long damage can go unnoticed, not by capacity —
database dumps are ~10Mi each, so depth is nearly free and is the only defence
against a problem discovered weeks later.

## What is backed up

**1. PostgreSQL database** — `<DB>`, dumped with `pg_dump` by the backup
container. About 10Mi per dump, so the whole 28-dump retention set costs roughly
280Mi. Every night at 02:00 the newest dump is restored into a throwaway local
postgres and test-queried; the run reports how many tables came back. Only the
newest dump is checked, which is part of why retention runs deep.

That check requires two settings that are easy to get wrong and fail in
confusing ways — a non-superuser database role and `TABLE_SCHEMA` — both
explained in `values-prod.yaml`.

**2. Wiki content** — `/var/www/html/images` and `/var/www/html/LocalSettings.php`,
about 123Mi per day.

Nothing else on the html volume is backed up, and that is intentional. The rest
of it — `extensions`, `includes`, `vendor`, `languages`, `skins`, `resources`,
`tests`, and MediaWiki core — is copied onto the volume from the container image
by the `copy-mediawiki-files` initContainer. It is a cache of the image, not
primary data, and is restored by redeploying the image. Backing it up cost an
extra ~128Mi every night and protected nothing.

`/var/www/data` is also not backed up. The PVC mounted there has been empty since
it was created and produced a 104-byte tarball every night.

### Retention and pruning

The backup container prunes by matching the core filename of dumps **it** wrote.
Anything it did not write is invisible to it, so the file tarballs are pruned by
the CronJob itself. Both prunes are scoped by filename, so a database dump can
never become a deletion candidate for the file job or vice versa.

File pruning is count-based rather than age-based on purpose: a run of failed
jobs must not be able to age out the backups that are still on disk.

> **Sizing constraint.** `netapp-file-backup` is capped at 12Gi for this
> namespace (`requests.storage 12Gi/12Gi`), so the backup PVC cannot be grown
> without a platform quota increase. Current retention lands at roughly 2.8Gi.

## Deployment steps

> **Every file here is anonymised and none of them deploy as-is.** This is a
> public repository, so the real namespaces, service accounts and secret names
> are placeholders. They are not valid Kubernetes identifiers, so applying them
> unmodified fails.
>
> - `values-prod.yaml` — layer a private overlay on top. Helm merges values
>   files in order, so pass the committed file first and the overlay second. The
>   overlay needs only `backupConfig`, the three `db.*` keys and
>   `env.DATABASE_SERVICE_NAME`; everything else stays here.
> - `mediawiki-files-backup-cronjob.yaml`,
>   `mediawiki-backup-healthcheck-cronjob.yaml`, `network-policy.yaml`,
>   `external-name-service.yaml` — no overlay mechanism exists for raw
>   manifests, so substitute the placeholders into a private rendered copy and
>   apply that. Regenerate it whenever the committed file changes, or the two
>   will drift.
>
> Failures are loud rather than silent: the API server rejects `<SA>` and
> `<DB Secret>` as invalid names. But a rejected Helm upgrade can still leave a
> valid-looking ConfigMap behind, so always deploy with `--rollback-on-failure`
> (`--atomic` on older Helm).

### 1. Create database secret

The secret needs **two** sets of credentials. Backups and verification run as the
non-superuser application role; restores need the superuser. Creating only the
superuser pair is what breaks the nightly verification — see `values-prod.yaml`.

```bash
# Application role - used for backups and verification
APP_USER=$(oc get secret <db> -n <Pod NS> -o jsonpath='{.data.app-db-username}' | base64 -d)
APP_PASS=$(oc get secret <db> -n <Pod NS> -o jsonpath='{.data.app-db-password}' | base64 -d)

# Superuser - used for restores
SU_USER=$(oc get secret <db> -n <Pod NS> -o jsonpath='{.data.superuser-username}' | base64 -d)
SU_PASS=$(oc get secret <db> -n <Pod NS> -o jsonpath='{.data.superuser-password}' | base64 -d)

oc create secret generic <secret> \
  --from-literal=app-username=$APP_USER \
  --from-literal=app-password=$APP_PASS \
  --from-literal=superuser-username=$SU_USER \
  --from-literal=superuser-password=$SU_PASS \
  -n <NS>
```

`db.usernameKey` / `db.passwordKey` in the values must point at the **app** keys.

### 2. Create network resources

```bash
# Network policy in prod to allow backup access
oc apply -f network-policy.yaml

# ExternalName service in tools to resolve the prod database
oc apply -f external-name-service.yaml
```

### 3. Deploy database backup

Leverages the BC Government backup container: https://github.com/bcgov/backup-container

```bash
helm repo add bcgov https://bcgov.github.io/helm-charts
helm repo update

helm upgrade --install mediawiki-backup-prod bcgov/backup-storage \
  --version 0.1.18 --rollback-on-failure \
  -f values-prod.yaml \
  -f <private>/values-prod.local.yaml \
  -n <NS>

oc get pods -n <NS> | grep mediawiki-backup-prod
```

> Always deploy this release through Helm with `values-prod.yaml`. Settings
> changed directly on the live Deployment or ConfigMap are silently reverted by
> the next `helm upgrade`, because Helm still holds the values from the previous
> release.

Confirm the settings the container actually resolved:

```bash
oc exec -n <NS> deployment/mediawiki-backup-prod-backup-storage -- ./backup.sh -c
```

### 4. Deploy file backup CronJob

Creates the ServiceAccount in tools, plus a Role and RoleBinding in prod
granting only `pods` get/list and `pods/exec` create.

```bash
oc apply -f mediawiki-files-backup-cronjob.yaml

oc get cronjob mediawiki-files-backup-prod -n <NS>
```

### 5. Test backups

**Database:**

```bash
oc exec -n <NS> deployment/mediawiki-backup-prod-backup-storage -- ./backup.sh -1
```

**Files:**

```bash
oc create job --from=cronjob/mediawiki-files-backup-prod test-file-backup -n <NS>
oc logs -f job/test-file-backup -n <NS>
oc delete job test-file-backup -n <NS>
```

### 6. Deploy the health check

```bash
oc apply -f mediawiki-backup-healthcheck-cronjob.yaml

# Run it once to confirm it passes against the backups already on disk
oc create job --from=cronjob/mediawiki-backup-healthcheck healthcheck-test -n <NS>
oc logs -f job/healthcheck-test -n <NS>
oc delete job healthcheck-test -n <NS>
```

Needs no ServiceAccount or RBAC — it only mounts the backup volume read-only.

## How to restore

### 1. Restore the database

> ## Always pass `-I`
>
> **A restore without `-I` destroys the target and restores nothing.**
>
> The backup container ships `pg_dump` 18.x while the database servers run
> PostgreSQL 12.4, so every dump contains `SET transaction_timeout = 0;` on line
> 4 — a parameter 12.4 does not recognise. The restore runs `DROP DATABASE`,
> then `CREATE DATABASE`, then dies on that line and stops, because errors are
> fatal by default. The target is left empty and the data is not loaded.
>
> `-I` continues past errors. Verified twice against real backups: with `-I` the
> restore is complete and correct; without it, it is destructive.
>
> Restoring into a cluster that already has the `app` and `replication` roles
> also raises "role already exists". Harmless, and `-I` covers it too.

`backup.sh -r` drops and recreates the target database, prompts for the admin
password, and shows the settings it will use for confirmation first. Have the
superuser password from `<DB Secret>` ready.

```bash
POD=$(oc get pod -n <NS> -l app.kubernetes.io/name=backup-storage -o name)

# List what is available
oc exec -n <NS> $POD -- ./backup.sh -l

# Most recent backup, restored over prod - destructive
oc exec -it -n <NS> $POD -- ./backup.sh -I -r postgres=<DB service:port/db>

# A specific backup file
oc exec -it -n <NS> $POD -- \
  ./backup.sh -I -r postgres=<DB service:port/db> \
    -f <backup>_YYYY-MM-DD_HH-MM-SS.sql.gz
```

Expect these three errors even on a successful restore. Anything beyond them
deserves a closer look:

```
ERROR:  unrecognized configuration parameter "transaction_timeout"
ERROR:  role "app" already exists
ERROR:  role "replication" already exists
```

To rehearse a restore without touching production, point `-r` at a different
host or database name and pass `-f` explicitly — the script supports restoring
elsewhere precisely so backups can be tested.

### 2. Restore files

The tarballs are plain `tar -czf` streams and go back the way they came. Note
the archive is extracted into `/var/www/html`, and contains the `images`
directory and `LocalSettings.php`.

```bash
# Copy the archive out of the backup volume first
oc cp <NS>/<backup pod>:/backups/daily/YYYY-MM-DD/mediawiki-content-prod_TIMESTAMP.tar.gz \
  ./restore.tar.gz

# Stream it into the wiki pod
POD=$(oc get pod -n <Pod NS> -l app.kubernetes.io/name=<wiki label> -o jsonpath='{.items[0].metadata.name}')

oc exec -i -n <Pod NS> $POD -c mediawiki -- \
  tar -xzf - -C /var/www/html < ./restore.tar.gz
```

Archives written before this was narrowed are named `mediawiki-html-prod_*` and
contain the entire html volume. They extract to the same place, but will also
overwrite the MediaWiki tree with the version from that date — redeploy the
intended image afterwards.

Quiesce the wiki first if the restore is broad rather than a single recovered
file. If only uploads are being recovered, extract to a scratch directory and
copy the individual files across instead.

### 3. Full rebuild

What is backed up, and what is not:

| | Where it comes from |
|---|---|
| Database | the dump |
| Uploads and `LocalSettings.php` | the content archive |
| MediaWiki core, extensions, skins | the container image, redeployed |
| **Secrets** | **not backed up — recreate by hand** |

Verified 2026-08-19: the only files on the html volume that are not in the image
are `images/` (1,632 of 1,632 present in the archive) and `LocalSettings.php`.
Everything else on that volume is a copy of the image, or a leftover from an
older MediaWiki that a rebuild does not need.

```bash
# 1. Secrets first - nothing else works without them. Not in any backup.
#    Recreate: isd-wiki-credentials, patroni-instance, sso-client-conf,
#    dev-sso-client-conf, gchr-isd-wiki-pull-secret
oc get secret -n <Pod NS>

# 2. Database and app, from the chart
helm upgrade --install patroni ... -n <Pod NS>
helm upgrade --install isd-wiki ... -n <Pod NS>

# 3. Restore the database - note -I, see the warning above
POD=$(oc get pod -n <NS> -l app.kubernetes.io/name=backup-storage -o name)
oc exec -n <NS> $POD -- ./backup.sh -l
oc exec -it -n <NS> $POD -- \
  ./backup.sh -I -r postgres=<DB service:port/db> \
    -f <backup>_YYYY-MM-DD_HH-MM-SS.sql.gz

# 4. Restore uploads and LocalSettings.php
oc cp <NS>/<backup pod>:/backups/daily/YYYY-MM-DD/mediawiki-content-prod_TIMESTAMP.tar.gz \
  ./restore.tar.gz
WIKI=$(oc get pod -n <Pod NS> -l app.kubernetes.io/name=<wiki label> \
  -o jsonpath='{.items[0].metadata.name}')
oc exec -i -n <Pod NS> $WIKI -c mediawiki -- \
  tar -xzf - -C /var/www/html < ./restore.tar.gz

# 5. Confirm
oc exec -n <Pod NS> <patroni pod> -- psql -U postgres -d <DB> -t -c \
  "SELECT count(*) FROM mediawiki.page;"
```

If the database was restored into a **rebuilt** Patroni, its roles carry the old
passwords from the dump while the new secret holds freshly generated ones. Reset
the app role to match the secret, or the wiki cannot connect.

## Rehearsing a restore

Nothing else here proves the wiki can be rebuilt from a backup. That needs a
real restore into a real database, which `backup.sh -r` supports: point `-r` at
a different host and database name and pass `-f` explicitly, and it restores
there instead of over production.

Pick a lower environment as the target and restore into a **scratch database
name**, not the one that environment's own wiki uses — `-r` drops and recreates
whatever it is pointed at.

The scratch database must **already exist**. The restore's first action is
`DROP DATABASE`; if it is not there that fails, and every step after it —
create, grant, load — is skipped.

```bash
oc exec -n <Target NS> <patroni pod> -- psql -U postgres -c 'CREATE DATABASE <scratch db>;'
```

A target environment needs two things before the backup pod can reach it. Both
already exist for the environment that was set up first; a second target needs
them added:

1. An `ExternalName` service in the tools namespace resolving to that
   environment's Patroni service — see `external-name-service.yaml`.
2. A `NetworkPolicy` in the target namespace allowing ingress on 5432 from the
   tools namespace — see `network-policy.yaml`. The `podSelector` must match
   that environment's Patroni master labels, which differ per environment
   (`cluster-name` in particular is not the same everywhere).

Then:

```bash
POD=$(oc get pod -n <NS> -l app.kubernetes.io/name=backup-storage -o name)

oc exec -it -n <NS> $POD -- \
  ./backup.sh -I -r postgres=<target service>:5432/<scratch db> \
    -f <backup>_YYYY-MM-DD_HH-MM-SS.sql.gz
```

The script prompts for the target's superuser password and shows its settings
for confirmation before doing anything. **Read the database name on that screen
before accepting it.**

Verify the restore against the source. MediaWiki's tables live in a `mediawiki`
schema, not `public`, so they need qualifying — an unqualified `FROM page` just
errors:

```bash
oc exec -n <Target NS> <patroni pod> -- psql -U postgres -d <scratch db> -t -A -F'|' -c "
SELECT
  (SELECT count(*) FROM information_schema.tables WHERE table_schema='mediawiki'),
  (SELECT count(*) FROM pg_indexes WHERE schemaname='mediawiki'),
  (SELECT count(*) FROM mediawiki.page),
  (SELECT count(*) FROM mediawiki.revision),
  (SELECT max(rev_timestamp) FROM mediawiki.revision);"
```

Table and index counts should match production **exactly** — those catch a
restore that stopped partway, which row counts alone can miss. Page and revision
counts should be at or just below production, and the newest revision timestamp
should predate the backup. Drop the scratch database when finished.

Rehearsed 2026-08-18 against two separate backups: 65/65 tables, 197/197
indexes, content readable, and an MD5 of page titles identical to production.

## Backup schedule

All times `America/Vancouver`.

- **Database backup**: 01:00 daily
- **File backup and prune**: 01:35 daily
- **Database verification**: 02:00 daily (newest dump only)
- **Health check**: 03:00 daily

> Both CronJobs set `spec.timeZone`. Kubernetes schedules CronJobs in **UTC** by
> default while the backup container's `go-crond` uses pod local time, so without
> it the two halves run seven hours apart in the wrong order. Any new CronJob
> here needs the same field.

## Monitoring

`mediawiki-backup-healthcheck-cronjob.yaml` checks, every morning at 03:00, that
the backups that should exist actually do: a database dump over 1Mi and a content
archive over 50Mi both written in the last 25 hours, and the volume under 85%
full. If any check fails the Job exits non-zero, and OpenShift emails the repo
owners.

This is a pull check rather than the container's own `WEBHOOK_URL`, on purpose.
The backup container runs `go-crond` in a long-lived pod: when `backup.sh`
fails, that pod stays `1/1 Running`, nothing restarts, no Job object appears and
no metric moves. Infrastructure monitoring sees a perfectly healthy container.
That is exactly how the nightly verification stayed broken unnoticed.

A webhook only fires when the thing that is broken still works well enough to
send it, so it cannot report a pod that never started or a cron that never ran.
Checking the artefacts on disk has no such blind spot, needs no receiver, no
credentials and no external service.

It does not replace reading the verification result — it reports that a backup
exists and is a plausible size, not that it restores. Rehearse a restore
periodically; see [Rehearsing a restore](#rehearsing-a-restore).

## Known issues

### `WEBHOOK_URL` is unconfigured

Every run ends with `Missing PagerDuty service key`, so the container itself
reports nothing. This is deliberate rather than outstanding — see
[Monitoring](#monitoring) for why the health check covers it better.

### Dumps are not restorable without `-I`

See the warning under [Restore the database](#1-restore-the-database). The
`pg_dump` in the container is several major versions ahead of the servers. The
durable fix is to align them — which ultimately means confronting that
PostgreSQL 12.4 has been end-of-life since November 2024.
