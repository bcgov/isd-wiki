#!/bin/sh
set -eo pipefail

# This script is designed to handle both fresh installs and upgrades
# for a MediaWiki application in an OpenShift/Kubernetes environment.

# The first argument is a command to run, for example "php-fpm".
cmd="$@"

# Check if the database is up before proceeding, using a simple loop.
echo "Waiting for database to be ready..."

i=0
while [ $i -lt 60 ]
do
    # Use PGPASSWORD environment variable to authenticate the `psql` connection check.
    # The `-c '\q'` command will run silently and check the connection.
    if PGPASSWORD="$MEDIAWIKI_DB_PASSWORD" psql -h "$MEDIAWIKI_DB_HOST" -U "$MEDIAWIKI_DB_USER" -d "$MEDIAWIKI_DB_NAME" -c '\q' >/dev/null 2>&1; then
        echo "Database is up."
        break
    fi
    echo -n "."
    sleep 1
    i=$((i+1))
done

# Check if the database is up or timed out
if [ $i -eq 60 ]; then
    echo "Database connection timed out."
    exit 1
fi

# The persistent volume is mounted at /var/www/html
cd /var/www/html
LOCALSETTINGS_FILE="/var/www/html/LocalSettings.php"

if [ ! -f "$LOCALSETTINGS_FILE" ]; then
    echo "LocalSettings.php not found. This is a fresh install."
    # Ensure the "w" directory exists and has correct permissions.
    mkdir -p /var/www/html
    cd /var/www/html
    
    # Check if the database is empty before running install.php.
    # Use PGPASSWORD to authenticate the `psql` check for a fresh database.
    if PGPASSWORD="$MEDIAWIKI_DB_PASSWORD" psql -h "$MEDIAWIKI_DB_HOST" -U "$MEDIAWIKI_DB_USER" -d "$MEDIAWIKI_DB_NAME" -c '\dt' | grep -q "public"; then
        echo "Database is not empty but LocalSettings.php is missing. This is an invalid state."
        exit 1
    else
        echo "Database is empty. Running install.php to create the schema and initial config."
        
        # Use install.php to set up the new wiki, passing all database details as arguments
        # to ensure it does not default to a local socket.
        php maintenance/install.php \
            --dbserver="$MEDIAWIKI_DB_HOST" \
            --dbport="$MEDIAWIKI_DB_PORT" \
            --dbtype="postgres" \
            --dbname="$MEDIAWIKI_DB_NAME" \
            --dbuser="$MEDIAWIKI_DB_USER" \
            --dbpass="$MEDIAWIKI_DB_PASSWORD" \
            --server="$MEDIAWIKI_SITE_SERVER" \
            --scriptpath="/w" \
            --lang="$MEDIAWIKI_SITE_LANG" \
            --pass="$MEDIAWIKI_ADMIN_PASS" \
            "$MEDIAWIKI_SITE_NAME" "$MEDIAWIKI_ADMIN_USER"
        
        echo "Installation complete. LocalSettings.php and database schema created."

#         # === APPEND CUSTOM SETTINGS ===


cat << EOF >> LocalSettings.php

# --- START OF CUSTOM SETTINGS ---
# These settings were appended to the auto-generated file.

# Short URL configuration
\$wgArticlePath = "/wiki/\$1";
\$wgUsePathInfo = true;

# # --- Debugging and Environment ---
error_reporting(E_ALL);
ini_set('display_errors', 1);
\$wgShowExceptionDetails = true;
\$wgDevelopmentWarnings = false;
\$wgShowDBErrorBacktrace = true;

# # --- Custom Extensions ---
# # Load VisualEditor and its dependencies
# wfLoadExtension( 'VisualEditor' );
# $wgDefaultUserOptions['visualeditor-enable'] = 1;
# $wgVisualEditorEnableWikitext = true;
# $wgHiddenPrefs[] = 'visualeditor-enable-mw-nitro';

# # Load SyntaxHighlight_GeSHi
# # wfLoadExtension( 'SyntaxHighlight_GeSHi' );

# # --- Environment and Paths ---
# $wgTmpDirectory = "/tmp";
# $wgUseImageMagick = true;
# $wgImageMagickConvertCommand = "/usr/bin/convert";
# $wgSVGFileRenderer = 'rsvg';
# $wgSVGFileRendererPath = '/usr/bin/rsvg-convert';

# --- END OF CUSTOM SETTINGS ---
EOF

echo "Appended custom settings to LocalSettings.php."

    fi

else
    echo "LocalSettings.php found. This is an existing installation."
    echo "Running update.php to migrate the database schema."
    php maintenance/update.php
fi

# Ensure images folder exists and has correct permissions.
if [ ! -d "images" ]; then
    mkdir -p images
fi

# Execute the main container command, e.g., php-fpm.
exec "$@"