# MediaWiki Production Backup

Complete backup solution for MediaWiki production environment, deployed in `<NS>` namespace.

## What is Backed Up

1. PostgreSQL Database
- **Database**: `<DB>` (app database in <Namespace>)
- **Schedule**: Daily at 1:00 AM
- **Retention**: 12 daily, 8 weekly, 2 monthly
- **Method**: pg_dump via backup-container

2. MediaWiki Files

### Storage
- All backups stored in `mediawiki-backup-prod-backup-storage-backup-pvc` (8Gi)
- Located in tools namespace
- Path structure: `/backups/daily/YYYY-MM-DD/`

## Deployment Steps


### 1. Create Database Secret
Get the prod database credentials and create secret in tools namespace:

```bash
# Get prod credentials
POSTGRES_USER=$(oc get secret <db> -n <NS> -o jsonpath='{.data.<secret user key>}' | base64 -d)
POSTGRES_PASS=$(oc get secret db> -n <NS> -o jsonpath='{.data.<secret pw key>}' | base64 -d)

# Create secret in tools namespace
oc create secret generic <secret> \
  --from-literal=superuser-username=$POSTGRES_USER \
  --from-literal=superuser-password=$POSTGRES_PASS \
  -n <NS>
```

### 2. Create Network Resources

```bash
# Create network policy in prod to allow backup access
oc apply -f network-policy.yaml

# Create ExternalName service in tools to resolve prod database
oc apply -f external-name-service.yaml
```

### 3. Deploy Database Backup

Leverages BC government backup container solution: https://github.com/bcgov/backup-container
```bash
# Add BCGov Helm repo if not already added
helm repo add bcgov https://bcgov.github.io/helm-charts
helm repo update

# Install the backup chart
helm install mediawiki-backup-prod bcgov/backup-storage \
  --version 0.1.18 \
  -f values-prod.yaml \
  -n <NS>

# Verify deployment
oc get pods -n <NS> | grep mediawiki-backup-prod
```

### 4. Deploy File Backup CronJob

```bash
oc apply -f mediawiki-files-backup-cronjob.yaml

# Verify CronJob
oc get cronjob mediawiki-files-backup-prod -n <NS>
```

### 5. Test Backups

**Test Database Backup:**
```bash
oc rsh deployment/mediawiki-backup-prod-backup-storage -n <NS>
./backup.sh -s
exit
```

**Test File Backup:**
```bash
oc create job --from=cronjob/mediawiki-files-backup-prod test-file-backup -n <NS>
oc logs -f job/test-file-backup -n <NS>
oc delete job test-file-backup -n <NS>
```

## How to Restore

### 1. Restore Database

```bash
# List available backups
oc exec deployment/<pod> -n <NS> -- ls -lh /backups/daily/

# Restore from a specific backup file
oc exec deployment/<pod> -n <NS> -- bash -c \
  "gunzip < /backups/daily/YYYY-MM-DD/<backup>_TIMESTAMP.sql.gz | \
   psql -h <DB service> -U postgres -d <DB>"
```

### 2. Restore Files

```bash
# Get the MediaWiki pod name
POD=$(oc get pod -n <NS> -l app.kubernetes.io/name=<wiki label> -o jsonpath='{.items[0].metadata.name}')

# Restore /var/www/data
oc exec deployment/<POD> -n <NS> -- \
  cat /backups/daily/YYYY-MM-DD/mediawiki-data-prod_TIMESTAMP.tar.gz | \
  oc exec -n <NS> $POD -c mediawiki -i -- tar -xzf - -C /<PVC mount 1>

# Restore /var/www/html
oc exec deployment/<POD> -n <NS> -- \
  cat /backups/daily/YYYY-MM-DD/mediawiki-html-prod_TIMESTAMP.tar.gz | \
  oc exec -n <NS> $POD -c mediawiki -i -- tar -xzf - -C <PVC mount 2>
```
## Backup Schedule

- **Database Backup**: 1:00 AM daily
- **Database Verification**: 2:00 AM daily
- **File Backup**: 1:35 AM daily
