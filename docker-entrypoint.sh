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

# Run MediaWiki database install/update script on container startup.

# Check if the database is empty.
if ! psql -h "$WG_DB_SERVER" -U "$WG_DB_USER" -d "$WG_DB_NAME" -c '\dt' | grep -q "public"; then
    echo "Database is empty. Running install.php to create the schema."
    # Run the installation script.
    php /var/www/html/maintenance/install.php --dbname "$WG_DB_NAME" --dbuser "$WG_DB_USER" --dbpass "$WG_DB_PASSWORD" ...
else
    echo "Database already exists. Running update.php to migrate the schema."
    # Run the update script.
    php /var/www/html/maintenance/update.php --conf /var/www/html/LocalSettings.php
fi

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