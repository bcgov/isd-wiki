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


LOCALSETTINGS_FILE="/var/www/html/LocalSettings.php"

if [ ! -f "$LOCALSETTINGS_FILE" ]; then
  echo "LocalSettings.php not found. This is a fresh install."
  
  # The 'psql' command is now available due to the Dockerfile change
  if ! psql -h "$MEDIAWIKI_DB_HOST" -U "$MEDIAWIKI_DB_USER" -d "$MEDIAWIKI_DB_NAME" -c '\dt' | grep -q "public"; then
    echo "Database is empty. Running install.php to create the schema and initial config."

    php maintenance/install.php \
      --dbname "$MEDIAWIKI_DB_NAME" \
      --dbuser "$MEDIAWIKI_DB_USER" \
      --dbpass "$MEDIAWIKI_DB_PASSWORD" \
      --server "$MEDIAWIKI_SITE_SERVER" \
      --lang "$MEDIAWIKI_SITE_LANG" \
      --pass "$MEDIAWIKI_ADMIN_PASS" \
      "$MEDIAWIKI_SITE_NAME" "$MEDIAWIKI_ADMIN_USER"
    echo "Installation complete. LocalSettings.php and database schema created."
  else
    echo "Database is not empty but LocalSettings.php is missing. This is an invalid state."
    exit 1
  fi
 else
    echo "Found LocalSettings.php in persistent volume. Running update.php to migrate the schema."
    php maintenance/update.php
  fi
 fi

# Ensure images folder exists and has correct permissions.
# This is a good practice for file uploads.
if [ ! -d "images" ]; then
    mkdir -p images
    chown www-data:www-data images
fi
chown -R www-data:www-data /var/www/html/cache

if [ "$#" -eq 0 ]; then
    # This is for when the entrypoint is used without a command.
    # For your deployment, the CMD should be set to 'php-fpm'.
    exec php-fpm
else
    # This allows the entrypoint to be used to run other commands if needed.
    exec "$@"
fi

exec "$@"