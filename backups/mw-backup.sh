#!/usr/bin/env bash
set -e

# =========================================
# MediaWiki Backup Script (Windows Git Bash)
# Using oc exec + tar (reliable)
# =========================================

# Timestamp
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Backup directories
BACKUP_ROOT="$HOME/backups/mw/mediawiki-backups"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
mkdir -p "$BACKUP_DIR"

echo "==================================="
echo " MediaWiki Local Backup Script"
echo " Timestamp: $TIMESTAMP"
echo " Backup directory: $BACKUP_DIR"
echo "==================================="

# -----------------------
# Kubeconfig & Service Account
# -----------------------
KUBECONFIG="$HOME/.kube/backup-bot-kubeconfig"
SA_NAME="backup-bot"
NAMESPACE="aebbdd-test"
SERVER="https://api.silver.devops.gov.bc.ca:6443"
export KUBECONFIG

# -----------------------
# Refresh service account token (long-lived)
# -----------------------
echo "Refreshing service account token..."
SA_TOKEN=$(oc create token "$SA_NAME" --duration=8760h -n "$NAMESPACE")
oc login --token="$SA_TOKEN" --server="$SERVER" --namespace="$NAMESPACE" --kubeconfig="$KUBECONFIG"
echo "✓ Token refreshed and kubeconfig updated"
echo ""

# -----------------------
# Check OpenShift authentication
# -----------------------
echo "Checking OpenShift authentication..."
oc_whoami=$(oc whoami)
if [ -z "$oc_whoami" ]; then
    echo "ERROR: Cannot authenticate with OpenShift using kubeconfig: $KUBECONFIG"
    exit 1
fi
echo "Authenticated as: $oc_whoami"
echo ""

# -----------------------
# Find MediaWiki pod
# -----------------------
echo "Finding MediaWiki pod..."
POD_NAME=$(oc get pods -l app.kubernetes.io/name=isd-wiki \
    -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}')

if [ -z "$POD_NAME" ]; then
    echo "ERROR: No running MediaWiki pod found!"
    exit 1
fi
echo "Found pod: $POD_NAME"
echo ""

# -----------------------
# Backup /var/www/data
# -----------------------
DATA_TAR="$BACKUP_DIR/mediawiki-data.tar.gz"
echo "Backing up /var/www/data (user uploads) to $DATA_TAR ..."
oc exec "$POD_NAME" -c mediawiki -- sh -c 'tar czf - -C /var/www data' > "$DATA_TAR"
echo "✓ Data backup complete"
echo ""

# -----------------------
# Backup /var/www/html
# -----------------------
HTML_TAR="$BACKUP_DIR/mediawiki-html.tar.gz"
echo "Backing up /var/www/html (MediaWiki files) to $HTML_TAR ..."
oc exec "$POD_NAME" -c mediawiki -- sh -c 'tar czf - -C /var/www html' > "$HTML_TAR"
echo "✓ HTML backup complete"
echo ""

# -----------------------
# Backup summary
# -----------------------
echo "==================================="
echo "Backup Summary"
echo "==================================="
ls -lh "$BACKUP_DIR"
echo "Total size:"
du -sh "$BACKUP_DIR"
echo ""
echo "✓ Backup completed successfully!"
echo ""