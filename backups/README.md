## Overview

This setup performs:

MediaWiki backup: application files and user-uploaded content.

PostgreSQL/Patroni backup: database globals (roles, tablespaces) and database content.

Backups are timestamped and stored in a local folder.

## Requirements

1. Git Bash (Windows) or Linux bash shell
1. oc CLI installed and in PATH
1. Access to a service account with sufficient permissions in OpenShift/Kubernetes pods (kubeconfig file)
1. PostgreSQL superuser credentials in a Kubernetes secret
1. Sufficient disk space for compressed backups
## Set up

Each folder contains:
1. backup script
1. task schedule .bat
1. task scheduler xml template

Review the short shell and .bat scripts to set any absolute paths then import the xml template in task scheduler. After a test run any logging should be available.
## Backup Scripts
### 1. PostgreSQL / Patroni

Script: backup-patroni-db.sh

#### Features:

1. Dumps globals (patroni-globals-YYYYMMDD_HHMMSS.sql.gz)
1. Dumps database (patroni-DBNAME-YYYYMMDD_HHMMSS.sql.gz)

Uses Kubernetes secrets for superuser password

Output directory is timestamped in seperate folder

### 2. MediaWiki

Script: backup-mediawiki.sh

#### Features:

1. Backs up /var/www/html and /var/www/data from the running MediaWiki pod
1. Compresses backups to mediawiki-html.tar.gz and mediawiki-data.tar.gz
1. Uses service account for authentication

# Configuration

Set environment variables before running the scripts. Example:

### Windows Git Bash or Linux
```bash
export BACKUP_ROOT="$HOME/backups"
export PATRONI_BACKUP_DIR="$BACKUP_ROOT/patroni"
export MEDIAWIKI_BACKUP_DIR="$BACKUP_ROOT/mw/mediawiki-backups"
export KUBECONFIG="$HOME/.kube/backup-bot-kubeconfig"
```
### PostgreSQL / Patroni
```bash
export NAMESPACE="aebbdd-test"
export APP_NAME="patroni"
export DB_NAME="mediawiki"
```
### MediaWiki
```bash
export MW_NAMESPACE="aebbdd-test"
export MW_APP_NAME="isd-wiki"
export SA_NAME="backup-bot"
export SERVER="https://api.silver.devops.gov.bc.ca:6443"
```

You can change BACKUP_ROOT to any path accessible to you or your team.

## Running Backups
### PostgreSQL / Patroni
```bash
./backup-patroni-db.sh
```

This will create a timestamped backup folder in $PATRONI_BACKUP_DIR containing:

patroni-globals-YYYYMMDD_HHMMSS.sql.gz
patroni-mediawiki-YYYYMMDD_HHMMSS.sql.gz

### MediaWiki
```bash
./backup-mediawiki.sh
```

This will create a timestamped backup folder in $MEDIAWIKI_BACKUP_DIR containing:

mediawiki-html.tar.gz
mediawiki-data.tar.gz

## Restoring Backups
### PostgreSQL / Patroni

#### Copy backup files to Patroni pod:
```bash
oc cp patroni-globals-YYYYMMDD_HHMMSS.sql.gz <pod>:/tmp/globals.sql.gz
oc cp patroni-mediawiki-YYYYMMDD_HHMMSS.sql.gz <pod>:/tmp/mediawiki.sql.gz
```

#### Gunzip files:
```bash
oc exec <pod> -- bash -c "gunzip -f /tmp/globals.sql.gz"
oc exec <pod> -- bash -c "gunzip -f /tmp/mediawiki.sql.gz"

```
#### Restore globals and database:
```bash
oc exec <pod> -- psql -U postgres -f /tmp/globals.sql
oc exec <pod> -- psql -U postgres -d mediawiki -f /tmp/mediawiki.sql
```
### MediaWiki

#### Copy backup tars to MediaWiki pod:
```bash
oc cp mediawiki-html.tar.gz <pod>:/tmp/
oc cp mediawiki-data.tar.gz <pod>:/tmp/
```

#### Restore:
```bash
oc exec <pod> -- bash -c "tar xzf /tmp/mediawiki-html.tar.gz -C /var/www"
oc exec <pod> -- bash -c "tar xzf /tmp/mediawiki-data.tar.gz -C /var/www"
```

# TODO
1. schedule
1. delete backups after retention policy
1. enable on local machine 
1. discuss enabling on other local machine