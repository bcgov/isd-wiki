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

## What is backed up

**1. PostgreSQL database** — `<DB>`, dumped with `pg_dump` by the backup
container. About 10Mi per dump, so the whole 28-dump retention set costs roughly
280Mi. The newest dump is restored into a throwaway local postgres and
test-queried every night at 02:00; older dumps are *not* verified, which is part
of why retention runs deep.

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

### 1. Create database secret

Get the prod database credentials and create the secret in the tools namespace:

```bash
# Get prod credentials
POSTGRES_USER=$(oc get secret <db> -n <Pod NS> -o jsonpath='{.data.<secret user key>}' | base64 -d)
POSTGRES_PASS=$(oc get secret <db> -n <Pod NS> -o jsonpath='{.data.<secret pw key>}' | base64 -d)

# Create secret in tools namespace
oc create secret generic <secret> \
  --from-literal=superuser-username=$POSTGRES_USER \
  --from-literal=superuser-password=$POSTGRES_PASS \
  -n <NS>
```

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
  --version 0.1.18 \
  -f values-prod.yaml \
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

## How to restore

### 1. Restore the database

Prefer `backup.sh -r`. It drops and recreates the target database, prompts for
the admin password, and shows the settings it will use for confirmation first.
Have the superuser password from `<DB Secret>` ready.

```bash
POD=$(oc get pod -n <NS> -l app.kubernetes.io/name=backup-storage -o name)

# List what is available
oc exec -n <NS> $POD -- ./backup.sh -l

# Most recent backup, restored over prod - destructive
oc exec -it -n <NS> $POD -- ./backup.sh -r postgres=<DB service:port/db>

# A specific backup file
oc exec -it -n <NS> $POD -- \
  ./backup.sh -r postgres=<DB service:port/db> \
    -f <backup>_YYYY-MM-DD_HH-MM-SS.sql.gz
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

## Backup schedule

- **Database backup**: 01:00 daily
- **Database verification**: 02:00 daily (newest dump only)
- **File backup and prune**: 01:35 daily
