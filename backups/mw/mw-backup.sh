#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# MediaWiki Backup Script - Task Scheduler Friendly (Windows Git Bash)
##############################################################################

##########################
# CONFIGURATION
##########################

# Absolute backup root directory
BACKUP_ROOT="${BACKUP_ROOT:-/c/Users/chridodd/backups/mw/mediawiki-backups}"

# Kubernetes/OpenShift
export KUBECONFIG="${KUBECONFIG:-/c/Users/chridodd/.kube/backup-bot-kubeconfig}"
SA_NAME="${SA_NAME:-backup-bot}"
NAMESPACE="${NAMESPACE:-aebbdd-test}"
SERVER="${SERVER:-https://api.silver.devops.gov.bc.ca:6443}"

# Pod info
MW_LABEL="${MW_LABEL:-app.kubernetes.io/name=isd-wiki}"
MW_CONTAINER="${MW_CONTAINER:-mediawiki}"

# Timestamp & backup directory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
mkdir -p "$BACKUP_DIR"

echo "==================================="
echo " MediaWiki Backup Script"
echo " Timestamp: $TIMESTAMP"
echo " Backup directory: $BACKUP_DIR"
echo "==================================="

##########################
# REFRESH SERVICE ACCOUNT TOKEN
##########################
echo "Refreshing service account token..."
SA_TOKEN=$(oc create token "$SA_NAME" --duration=8760h -n "$NAMESPACE")
oc login --token="$SA_TOKEN" --server="$SERVER" --namespace="$NAMESPACE" --kubeconfig="$KUBECONFIG"
echo "✓ Token refreshed and kubeconfig updated"
echo ""

##########################
# CHECK OPENSHIFT AUTH
##########################
echo "Checking OpenShift authentication..."
oc_whoami=$(oc whoami)
if [ -z "$oc_whoami" ]; then
    echo "ERROR: Cannot authenticate with OpenShift using kubeconfig: $KUBECONFIG"
    exit 1
fi
echo "Authenticated as: $oc_whoami"
echo ""

##########################
# FIND MEDIAWIKI POD
##########################
echo "Finding MediaWiki pod..."
POD_NAME=$(oc get pods -n "$NAMESPACE" -l "$MW_LABEL" \
    -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}')

if [ -z "$POD_NAME" ]; then
    echo "ERROR: No running MediaWiki pod found!"
    exit 1
fi
echo "Found pod: $POD_NAME"
echo ""

##########################
# BACKUP /var/www/data
##########################
DATA_TAR="$BACKUP_DIR/mediawiki-data-${TIMESTAMP}.tar.gz"
echo "Backing up /var/www/data to $DATA_TAR ..."
oc exec -n "$NAMESPACE" "$POD_NAME" -c "$MW_CONTAINER" -- sh -c 'tar czf - -C /var/www data' > "$DATA_TAR"
echo "✓ Data backup complete"
echo ""

##########################
# BACKUP /var/www/html
##########################
HTML_TAR="$BACKUP_DIR/mediawiki-html-${TIMESTAMP}.tar.gz"
echo "Backing up /var/www/html to $HTML_TAR ..."
oc exec -n "$NAMESPACE" "$POD_NAME" -c "$MW_CONTAINER" -- sh -c 'tar czf - -C /var/www html' > "$HTML_TAR"
echo "✓ HTML backup complete"
echo ""

##########################
# BACKUP SUMMARY
##########################
echo "==================================="
echo "Backup Summary"
echo "==================================="
ls -lh "$BACKUP_DIR"
echo "Total size:"
du -sh "$BACKUP_DIR"
echo ""
echo "✓ Backup completed successfully!"
echo ""
