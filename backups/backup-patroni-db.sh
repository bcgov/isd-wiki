#!/bin/bash

##############################################################################
# Patroni PostgreSQL Database Backup Script (Minimal)
#
# Usage:
#   NAMESPACE=aebbdd-test ./backup-patroni-db.sh
#
# Requirements:
#   - oc CLI tool installed
#   - Valid kubeconfig at $HOME/.kube/backup-bot-kubeconfig
##############################################################################

set -euo pipefail

# Configuration - Edit these or pass as environment variables
export KUBECONFIG="$HOME/.kube/backup-bot-kubeconfig"
NAMESPACE="${NAMESPACE:-aebbdd-dev}"
APP_NAME="${APP_NAME:-patroni}"
DB_NAME="${DB_NAME:-mediawiki}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"

# Generate timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "=== Patroni Database Backup ==="
echo "Namespace: $NAMESPACE"
echo "Database: $DB_NAME"
echo ""

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Find Patroni pod
echo "Finding Patroni pod..."
LEADER_POD=$(oc get pods -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=${APP_NAME}" \
  -o jsonpath='{.items[?(@.metadata.labels.role=="master")].metadata.name}')

if [ -z "$LEADER_POD" ]; then
    echo "ERROR: No Patroni pod found"
    exit 1
fi

echo "Using pod: $LEADER_POD"

# Get database password
echo "Retrieving credentials..."
DB_PASSWORD=$(oc get secret -n "$NAMESPACE" "${APP_NAME}" -o jsonpath='{.data.superuser-password}' | base64 -d)

# Backup database globals (roles, tablespaces)
echo ""
echo "Backing up database globals..."
GLOBALS_FILE="${BACKUP_DIR}/patroni-globals-${TIMESTAMP}.sql"
oc exec -n "$NAMESPACE" "$LEADER_POD" -- bash -c \
    "PGPASSWORD='$DB_PASSWORD' pg_dumpall -U postgres --globals-only" > "$GLOBALS_FILE"

GLOBALS_SIZE=$(du -h "$GLOBALS_FILE" | cut -f1)
echo "Globals backup: $GLOBALS_FILE ($GLOBALS_SIZE)"

# Backup the database
echo ""
echo "Backing up database: $DB_NAME..."
DB_FILE="${BACKUP_DIR}/patroni-${DB_NAME}-${TIMESTAMP}.sql"
oc exec -n "$NAMESPACE" "$LEADER_POD" -- bash -c \
    "PGPASSWORD='$DB_PASSWORD' pg_dump -U postgres -d '$DB_NAME' --clean --if-exists" > "$DB_FILE"

DB_SIZE=$(du -h "$DB_FILE" | cut -f1)
echo "Database backup: $DB_FILE ($DB_SIZE)"

# Compress backups
echo ""
echo "Compressing backups..."
gzip "$GLOBALS_FILE"
gzip "$DB_FILE"

echo ""
echo "=== Backup Complete ==="
echo "Files:"
echo "  - ${GLOBALS_FILE}.gz"
echo "  - ${DB_FILE}.gz"