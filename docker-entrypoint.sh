#!/bin/bash
set -eo pipefail

# This script is designed to handle both fresh installs and upgrades
# for a MediaWiki application in an OpenShift/Kubernetes environment.

# The first argument is a command to run, for example "php-fpm".
cmd="$@"

# Simple `while` loop to wait for the database to be ready, using `psql` with credentials.

echo "Waiting for database to be ready..."

i=0
while [ $i -lt 60 ]
do
    # Use `PGPASSWORD` environment variable to authenticate the `psql` connection check.
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
    
    # Check if the database is empty before running install.php.
    if ! psql -h "$MEDIAWIKI_DB_HOST" -U "$MEDIAWIKI_DB_USER" -d "$MEDIAWIKI_DB_NAME" -c '\dt' | grep -q "public"; then
        echo "Database is empty. Running install.php to create the schema and initial config."
        
		# Use install.php to set up the new wiki, passing database details as arguments
        # to ensure it does not default to a local socket.
        php maintenance/install.php \
            --dbserver "$MEDIAWIKI_DB_HOST" \
            --dbname "$MEDIAWIKI_DB_NAME" \
            --dbuser "$MEDIAWIKI_DB_USER" \
            --dbpass "$MEDIAWIKI_DB_PASSWORD" \
            --server "$MEDIAWIKI_SITE_SERVER" \
            --lang "$MEDIAWIKI_SITE_LANG" \
            --pass "$MEDIAWIKI_ADMIN_PASS" \
            "$MEDIAWIKI_SITE_NAME" "$MEDIAWIKI_ADMIN_USER"
        
        echo "Installation complete. LocalSettings.php and database schema created."

        # === APPEND CUSTOM SETTINGS ===
        # Add your custom settings from the original LocalSettings.php to the newly generated one.
        cat >> LocalSettings.php <<EOF
$(cat LocalSettings.php)

# -----------------------------------------------------------------------
# START OF CUSTOM SETTINGS
# These settings were appended to the auto-generated file.
# -----------------------------------------------------------------------

# --- Database settings (already configured, but for reference) ---
# $wgDBserver = "patroni-isd-wiki-db";
# $wgDBuser = getenv('MEDIAWIKI_DB_USER');
# $wgDBpassword = getenv('MEDIAWIKI_DB_PASSWORD');

# --- Custom Extensions ---
# Load VisualEditor and its dependencies
wfLoadExtension( 'VisualEditor' );
$wgDefaultUserOptions['visualeditor-enable'] = 1;
$wgVisualEditorEnableWikitext = true;
$wgHiddenPrefs[] = 'visualeditor-enable-mw-nitro';

# Load SyntaxHighlight_GeSHi
wfLoadExtension( 'SyntaxHighlight_GeSHi' );

# --- Debugging and Environment ---
error_reporting(E_ALL);
ini_set('display_errors', 1);
$wgShowExceptionDetails = true;
$wgDevelopmentWarnings = true;
$wgShowDBErrorBacktrace = true;

# --- Environment and Paths ---
$wgTmpDirectory = "/tmp";
$wgUseImageMagick = true;
$wgImageMagickConvertCommand = "/usr/bin/convert";
$wgSVGFileRenderer = 'rsvg';
$wgSVGFileRendererPath = '/usr/bin/rsvg-convert';
$wgServerName = getenv('MEDIAWIKI_SERVER_NAME');
$wgServer = getenv('MEDIAWIKI_SERVER_URL');

# -----------------------------------------------------------------------
# END OF CUSTOM SETTINGS
# -----------------------------------------------------------------------
EOF
        echo "Appended custom settings to LocalSettings.php."

    else
        echo "Database is not empty but LocalSettings.php is missing. This is an invalid state."
        exit 1
    fi

else
    echo "LocalSettings.php found. This is an existing installation."
    echo "Running update.php to migrate the database schema."
    php maintenance/update.php
fi

exec "$cmd"