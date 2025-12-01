#!/bin/bash
set -euo pipefail

##############################################################################
# Patroni PostgreSQL Database Backup Script - Task Scheduler Friendly
##############################################################################

##########################
# CONFIGURATION
##########################

# Kubernetes namespace and app
NAMESPACE="${NAMESPACE:-aebbdd-test}"
APP_NAME="${APP_NAME:-patroni}"
DB_NAME="${DB_NAME:-mediawiki}"

# Absolute backup path
BACKUP_ROOT="${BACKUP_ROOT:-/c/Users/chridodd/backups/db/backups}"

# Path to kubeconfig
export KUBECONFIG="${KUBECONFIG:-/c/Users/chridodd/.kube/backup-bot-kubeconfig}"

# Optional: service account for automatic token refresh (recommended)
SA_NAME="${SA_NAME:-backup-bot}"
SERVER="${SERVER:-https://api.silver.devops.gov.bc.ca:6443}"

# Timestamp & backup directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

echo "=== Patroni Database Backup ==="
echo "Namespace: $NAMESPACE"
echo "Database: $DB_NAME"
echo "Backup directory: $BACKUP_DIR"
echo ""

##########################
# REFRESH SERVICE ACCOUNT TOKEN
##########################
if command -v oc >/dev/null 2>&1; then
    echo "Refreshing service account token..."
    SA_TOKEN=$(oc create token "$SA_NAME" --duration=8760h -n "$NAMESPACE")
    oc login --token="$SA_TOKEN" --server="$SERVER" --namespace="$NAMESPACE" --kubeconfig="$KUBECONFIG"
    echo "✓ Token refreshed and kubeconfig updated"
    echo ""
else
    echo "ERROR: oc CLI not found"
    exit 1
fi

##########################
# FIND LEADER POD
##########################
echo "Finding Patroni pod..."
LEADER_POD=$(oc get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=${APP_NAME}" \
  -o jsonpath='{.items[?(@.metadata.labels.role=="master")].metadata.name}')

if [ -z "$LEADER_POD" ]; then
    echo "ERROR: No Patroni pod found"
    exit 1
fi
echo "Using pod: $LEADER_POD"

##########################
# RETRIEVE DATABASE PASSWORD
##########################
echo "Retrieving credentials..."
DB_PASSWORD=$(oc get secret -n "$NAMESPACE" "${APP_NAME}" -o jsonpath='{.data.superuser-password}' | base64 -d)

##########################
# BACKUP DATABASE GLOBALS
##########################
GLOBALS_FILE="${BACKUP_DIR}/patroni-globals-${TIMESTAMP}.sql"
echo "Backing up database globals..."
oc exec -n "$NAMESPACE" "$LEADER_POD" -- bash -c \
    "PGPASSWORD='$DB_PASSWORD' pg_dumpall -U postgres --globals-only" > "$GLOBALS_FILE"
gzip "$GLOBALS_FILE"
echo "Globals backup: ${GLOBALS_FILE}.gz"

##########################
# BACKUP DATABASE
##########################
DB_FILE="${BACKUP_DIR}/patroni-${DB_NAME}-${TIMESTAMP}.sql"
echo "Backing up database: $DB_NAME..."
oc exec -n "$NAMESPACE" "$LEADER_POD" -- bash -c \
    "PGPASSWORD='$DB_PASSWORD' pg_dump -U postgres -d '$DB_NAME' --clean --if-exists" > "$DB_FILE"
gzip "$DB_FILE"
echo "Database backup: ${DB_FILE}.gz"

echo ""
echo "=== Backup Complete ==="
echo "Files saved in: $BACKUP_DIR"
