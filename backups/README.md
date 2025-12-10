# MediaWiki Production Backup

Complete backup solution for MediaWiki production environment, deployed in `aebbdd-tools` namespace.

## What is Backed Up

### 1. PostgreSQL Database
- **Database**: `patroni-instance` (app database in aebbdd-prod)
- **Schedule**: Daily at 1:00 AM
- **Retention**: 12 daily, 8 weekly, 2 monthly
- **Method**: pg_dump via backup-container

### 2. MediaWiki Files
- **Data volume**: `/var/www/data` from prod MediaWiki pod
- **HTML volume**: `/var/www/html` from prod MediaWiki pod
- **Schedule**: Daily at 1:35 AM
- **Method**: Tar archives streamed via oc exec

### Storage
- All backups stored in `mediawiki-backup-prod-backup-storage-backup-pvc` (8Gi)
- Located in `aebbdd-tools` namespace
- Path structure: `/backups/daily/YYYY-MM-DD/`

## Deployment Steps

### Prerequisites
```bash
oc login --token=<your-token> --server=https://api.silver.devops.gov.bc.ca:6443
oc project aebbdd-tools
```

### 1. Create Database Secret
Get the prod database credentials and create secret in tools namespace:

```bash
# Get prod credentials
POSTGRES_USER=$(oc get secret patroni-instance -n aebbdd-prod -o jsonpath='{.data.superuser-username}' | base64 -d)
POSTGRES_PASS=$(oc get secret patroni-instance -n aebbdd-prod -o jsonpath='{.data.superuser-password}' | base64 -d)

# Create secret in tools namespace
oc create secret generic patroni-isd-wiki-db-prod-secret \
  --from-literal=superuser-username=$POSTGRES_USER \
  --from-literal=superuser-password=$POSTGRES_PASS \
  -n aebbdd-tools
```

### 2. Create Network Resources

```bash
# Create network policy in prod to allow backup access
oc apply -f network-policy.yaml

# Create ExternalName service in tools to resolve prod database
oc apply -f external-name-service.yaml
```

### 3. Deploy Database Backup

```bash
# Add BCGov Helm repo if not already added
helm repo add bcgov https://bcgov.github.io/helm-charts
helm repo update

# Install the backup chart
helm install mediawiki-backup-prod bcgov/backup-storage \
  --version 0.1.18 \
  -f values-prod.yaml \
  -n aebbdd-tools

# Verify deployment
oc get pods -n aebbdd-tools | grep mediawiki-backup-prod
```

### 4. Deploy File Backup CronJob

```bash
oc apply -f mediawiki-files-backup-cronjob.yaml

# Verify CronJob
oc get cronjob mediawiki-files-backup-prod -n aebbdd-tools
```

### 5. Test Backups

**Test Database Backup:**
```bash
oc rsh deployment/mediawiki-backup-prod-backup-storage -n aebbdd-tools
./backup.sh -s
exit
```

**Test File Backup:**
```bash
oc create job --from=cronjob/mediawiki-files-backup-prod test-file-backup -n aebbdd-tools
oc logs -f job/test-file-backup -n aebbdd-tools
oc delete job test-file-backup -n aebbdd-tools
```

## How to Restore

### 1. Restore Database

```bash
# List available backups
oc exec deployment/mediawiki-backup-prod-backup-storage -n aebbdd-tools -- ls -lh /backups/daily/

# Restore from a specific backup file
oc exec deployment/mediawiki-backup-prod-backup-storage -n aebbdd-tools -- bash -c \
  "gunzip < /backups/daily/YYYY-MM-DD/patroni-isd-wiki-db-prod-app_TIMESTAMP.sql.gz | \
   psql -h patroni-isd-wiki-db-prod -U postgres -d app"
```

### 2. Restore Files

```bash
# Get the MediaWiki pod name
POD=$(oc get pod -n aebbdd-prod -l app.kubernetes.io/name=isd-wiki -o jsonpath='{.items[0].metadata.name}')

# Restore /var/www/data
oc exec deployment/mediawiki-backup-prod-backup-storage -n aebbdd-tools -- \
  cat /backups/daily/YYYY-MM-DD/mediawiki-data-prod_TIMESTAMP.tar.gz | \
  oc exec -n aebbdd-prod $POD -c mediawiki -i -- tar -xzf - -C /var/www/data

# Restore /var/www/html
oc exec deployment/mediawiki-backup-prod-backup-storage -n aebbdd-tools -- \
  cat /backups/daily/YYYY-MM-DD/mediawiki-html-prod_TIMESTAMP.tar.gz | \
  oc exec -n aebbdd-prod $POD -c mediawiki -i -- tar -xzf - -C /var/www/html
```

## Monitoring

**Check backup status:**
```bash
# View database backup pod logs
oc logs -f deployment/mediawiki-backup-prod-backup-storage -n aebbdd-tools

# List all backups
oc exec deployment/mediawiki-backup-prod-backup-storage -n aebbdd-tools -- ./backup.sh -l
```

**Check CronJob history:**
```bash
# View recent jobs
oc get jobs -n aebbdd-tools | grep mediawiki-files-backup-prod

# View logs from last run
LAST_JOB=$(oc get jobs -n aebbdd-tools --sort-by=.metadata.creationTimestamp -o name | grep mediawiki-files-backup-prod | tail -1)
oc logs $LAST_JOB -n aebbdd-tools
```

## Backup Schedule

- **Database Backup**: 1:00 AM daily
- **Database Verification**: 2:00 AM daily
- **File Backup**: 1:35 AM daily

## Storage Usage

```bash
# Check PVC usage
oc exec deployment/mediawiki-backup-prod-backup-storage -n aebbdd-tools -- df -h /backups

# Check backup sizes
oc exec deployment/mediawiki-backup-prod-backup-storage -n aebbdd-tools -- du -sh /backups/daily/*
```

## Troubleshooting

**Database backup fails with authentication error:**
- Verify secret exists: `oc get secret patroni-isd-wiki-db-prod-secret -n aebbdd-tools`
- Check password matches prod: Compare with `oc get secret patroni-instance -n aebbdd-prod`

**Database backup fails with connection timeout:**
- Verify network policy exists: `oc get networkpolicy allow-patroni-instance-backup-from-tools -n aebbdd-prod`
- Test connectivity: `oc exec deployment/mediawiki-backup-prod-backup-storage -n aebbdd-tools -- nc -zv patroni-isd-wiki-db-prod 5432`

**File backup fails to find pod:**
- Check MediaWiki pod is running: `oc get pods -n aebbdd-prod -l app.kubernetes.io/name=isd-wiki`
- Verify service account has permissions: `oc get rolebinding mediawiki-files-backup-prod -n aebbdd-prod`
