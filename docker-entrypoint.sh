#!/bin/sh

set -e

# This is a simplified entrypoint script for a Kubernetes environment.
# It assumes:
# 1. The LocalSettings.php is mounted via a ConfigMap.
# 2. Composer dependencies are installed during the Dockerfile build.
# 3. Database credentials are provided via environment variables.

# Exit if a required environment variable is not set.
if [ -z "$MEDIAWIKI_DB_HOST" ]; then
    echo >&2 'error: missing MEDIAWIKI_DB_HOST environment variable'
    exit 1
fi
if [ -z "$MEDIAWIKI_DB_PASSWORD" ]; then
    echo >&2 'error: missing MEDIAWIKI_DB_PASSWORD environment variable'
    exit 1
fi

# Wait for the database to be available before proceeding.
while ! nc -w 1 "$MEDIAWIKI_DB_HOST" "$MEDIAWIKI_DB_PORT" </dev/null; do
    echo "Waiting for database at $MEDIAWIKI_DB_HOST:$MEDIAWIKI_DB_PORT..."
    sleep 1
done
echo "Database is up."

cd /var/www/html

# Run MediaWiki database update script on container startup.
# This ensures the database schema is up-to-date.
echo "Running MediaWiki update script..."
php maintenance/update.php --quick

# Ensure images folder exists and has correct permissions.
# This is a good practice for file uploads.
if [ ! -d "images" ]; then
    mkdir -p images
    chown www-data:www-data images
fi
chown -R www-data:www-data /var/www/html/cache

# If no command is passed, default to php-fpm.
if [ "$1" = 'php-fpm' ]; then
    exec "$@"
fi

exec "$@"