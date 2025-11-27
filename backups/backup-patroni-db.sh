#!/bin/bash

##############################################################################
# Patroni PostgreSQL Database Backup Script (Minimal)
#
# Usage:
#   ./backup-patroni-db.sh
#
# Requirements:
#   - oc CLI tool installed and in PATH
#   - Git Bash (Windows) or bash (Linux)
#   - Valid kubeconfig at $KUBECONFIG
#
# Configuration: Set environment variables below or override before running
##############################################################################

set -euo pipefail

##########################
# CONFIGURATION
##########################

# Kubernetes namespace and app
NAMESPACE="${NAMESPACE:-aebbdd-test}"       # e.g., aebbdd-test
APP_NAME="${APP_NAME:-patroni}"             # e.g., patroni
DB_NAME="${DB_NAME:-mediawiki}"             # database name

# FULL PATH backup directory (must exist or script will create)
# Example: /c/Users/YourUser/backups/db
BACKUP_ROOT="${BACKUP_ROOT:-./backups}"

# Generate timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

##########################
# PREPARE BACKUP DIR
##########################
BACKUP_DIR="${BACKUP_ROOT}/backup-${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"

echo "=== Patroni Database Backup ==="
echo "Namespace: $NAMESPACE"
echo "Database: $DB_NAME"
echo "Backup directory: $BACKUP_DIR"
echo ""

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
