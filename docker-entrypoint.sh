#!/bin/sh
set -eo pipefail

# This script is designed to handle both fresh installs and upgrades
# for a MediaWiki application in an OpenShift/Kubernetes environment.

# Two modes, because startup work that mutates shared state cannot run once
# per pod when there is more than one replica:
#
#   init   - run by the Helm pre-upgrade hook Job, exactly once per release.
#            Performs every mutation of shared state: update.php against the
#            database, and the idempotent LocalSettings.php appends on the
#            shared RWX volume. Exits when finished; never starts php-fpm.
#   serve  - the default, used by the application pods. Waits for the database
#            and starts php-fpm. Touches no shared state on an existing
#            install, so any number of replicas can start concurrently.
#
# update.php has no internal locking: it records applied updates in the
# updatelog table, but two concurrent runs can both see an update as pending
# and both apply it. The LocalSettings.php appends have the same problem on
# the shared volume. Hence one writer, not one per pod.
MODE="serve"
if [ "$1" = "init" ]; then
    MODE="init"
    shift
fi

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
            --scriptpath="/html" \
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

# Upload path configuration
# Set upload path to /html/images to match nginx configuration
# (nginx root is /var/www, so /var/www/html/images maps to /html/images URL)
\$wgUploadPath = "/html/images";

# # --- Debugging and Environment ---
error_reporting(E_ALL);
ini_set('display_errors', 1);
\$wgShowExceptionDetails = true;
\$wgDevelopmentWarnings = false;
\$wgShowDBErrorBacktrace = true;
\$wgLanguageCode = "en";

# # --- MediaWiki SMTP Settings ---
\$wgSMTP = [
    'host'      => "$MEDIAWIKI_SMTP_HOST",
    'IDHost'    => "$MEDIAWIKI_SMTP_ID_HOST",
    'localhost' => "$MEDIAWIKI_SMTP_LOCALHOST",
    'port'      => "$MEDIAWIKI_SMTP_PORT",
    'auth'      => "$MEDIAWIKI_SMTP_AUTH"
];

## To enable image uploads, make sure the 'images' directory
## is writable, then set this to true:
\$wgEnableUploads = true;
\$wgFileExtensions = array('png', 'jpg', 'jpeg', 'gif', 'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx');
\$wgStrictFileExtensions = true;
\$wgMaxUploadSize = 10 * 1024 * 1024; // 10 MB max
\$wgUploadSizeWarning = 5 * 1024 * 1024; // Warn at 5 MB


# Prevent anonymous users from editing

\$wgGroupPermissions['*']['edit'] = false;
\$wgGroupPermissions['*']['createaccount'] = false;
\$wgGroupPermissions['*']['createtalk'] = false;

# Allow registered users to edit and upload
\$wgGroupPermissions['user']['edit'] = true;
\$wgGroupPermissions['user']['upload'] = true;


# # --- Custom Extensions ---
# # Load VisualEditor and its dependencies
wfLoadExtension( 'VisualEditor' );
\$wgDefaultUserOptions['visualeditor-enable'] = 1;
# $wgVisualEditorEnableWikitext = true;
# $wgHiddenPrefs[] = 'visualeditor-enable-mw-nitro';

# # Load SyntaxHighlight_GeSHi
wfLoadExtension( 'SyntaxHighlight_GeSHi' );

# # --- Environment and Paths ---
# \$wgTmpDirectory = "/tmp";
# \$wgUseImageMagick = true;
# \$wgImageMagickConvertCommand = "/usr/bin/convert";
# \$wgSVGFileRenderer = 'rsvg';
# \$wgSVGFileRendererPath = '/usr/bin/rsvg-convert';



# # Load TitleKey here
wfLoadExtension( 'TitleKey' );


# # Load VEforALL
wfLoadExtension( 'VEForAll' );

# # Load TemplateData
wfLoadExtension( 'TemplateData' );

# Ensure VisualEditor works in Help namespace
\$wgVisualEditorNamespaces[NS_HELP] = true;

# # CategoryTree
wfLoadExtension( 'CategoryTree' );

# # Load PageForms
wfLoadExtension( 'PageForms' );

# --- Scribunto Extension ---
wfLoadExtension( 'Scribunto' );

# Use LuaSandbox (since it is already installed)
\$wgScribuntoDefaultEngine = 'luasandbox';
# --- END OF CUSTOM SETTINGS ---

# # Load EmbedVideo (embed YouTube/Vimeo/etc. videos in pages)
wfLoadExtension( 'EmbedVideo' );
# Local file-based video/audio handling needs ffmpeg, which this image
# doesn't ship. We only need embedding of externally-hosted videos.
\$wgEmbedVideoEnableVideoHandler = false;
\$wgEmbedVideoEnableAudioHandler = false;

# # Load Lingo (glossary term tooltips)
wfLoadExtension( 'Lingo' );
# Use the bolder WCAG-contrast underline style so glossary terms are
# more obviously interactive (default style is a very subtle 1px dotted
# underline that's easy to miss).
\$wgexLingoWCAGStyle = true;

# --- END OF CUSTOM SETTINGS ---
EOF

echo "Appended custom settings to LocalSettings.php."

    fi

elif [ "$MODE" = "init" ]; then
    echo "LocalSettings.php found. This is an existing installation."
    echo "Running update.php to migrate the database schema."
    php maintenance/update.php

    # === APPEND SETTINGS ADDED SINCE INITIAL INSTALL ===
    # LocalSettings.php is created once and persisted on a volume, so settings
    # added to the block above after a wiki's first install never reach it.
    # Idempotently patch those in here, keyed on a marker already in the file.
    #
    # A marker only counts as present if it appears on a line that is not
    # commented out. A plain substring match also hits lines an operator has
    # disabled by prefixing "#", which reads as "already applied" and skips
    # the append on every future start, so the setting can never come back.
    # (This is exactly how prod ended up stuck with SyntaxHighlight_GeSHi
    # commented out and no way for the entrypoint to restore it.)
    setting_active() {
        grep -v '^[[:space:]]*#' "$LOCALSETTINGS_FILE" | grep -qF "$1"
    }

    if ! setting_active "wfLoadExtension( 'EmbedVideo' )"; then
        echo "Adding EmbedVideo extension to existing LocalSettings.php."
        cat << 'EOF' >> "$LOCALSETTINGS_FILE"

# # Load EmbedVideo (embed YouTube/Vimeo/etc. videos in pages)
wfLoadExtension( 'EmbedVideo' );
# Local file-based video/audio handling needs ffmpeg, which this image
# doesn't ship. We only need embedding of externally-hosted videos.
$wgEmbedVideoEnableVideoHandler = false;
$wgEmbedVideoEnableAudioHandler = false;
EOF
    fi

    if ! setting_active "wfLoadExtension( 'SyntaxHighlight_GeSHi' )"; then
        echo "Adding SyntaxHighlight_GeSHi extension to existing LocalSettings.php."
        cat << 'EOF' >> "$LOCALSETTINGS_FILE"

# # Load SyntaxHighlight_GeSHi
wfLoadExtension( 'SyntaxHighlight_GeSHi' );
EOF
    fi

    # Scribunto is in the fresh-install block above but was never back-filled
    # here, so wikis installed before it was added (prod) have the extension
    # present in the image but never loaded.
    if ! setting_active "wfLoadExtension( 'Scribunto' )"; then
        echo "Adding Scribunto extension to existing LocalSettings.php."
        cat << 'EOF' >> "$LOCALSETTINGS_FILE"

# --- Scribunto Extension ---
wfLoadExtension( 'Scribunto' );

# Use LuaSandbox (since it is already installed)
$wgScribuntoDefaultEngine = 'luasandbox';
EOF
    fi

    if ! setting_active '$wgVisualEditorNamespaces[NS_HELP]'; then
        echo "Adding VisualEditor Help namespace setting to existing LocalSettings.php."
        cat << 'EOF' >> "$LOCALSETTINGS_FILE"

# Ensure VisualEditor works in Help namespace
$wgVisualEditorNamespaces[NS_HELP] = true;
EOF
    fi

    if ! setting_active "wfLoadExtension( 'Lingo' )"; then
        echo "Adding Lingo extension to existing LocalSettings.php."
        cat << 'EOF' >> "$LOCALSETTINGS_FILE"

# # Load Lingo (glossary term tooltips)
wfLoadExtension( 'Lingo' );
EOF
    fi

    if ! setting_active '$wgexLingoWCAGStyle'; then
        echo "Adding Lingo WCAG style setting to existing LocalSettings.php."
        cat << 'EOF' >> "$LOCALSETTINGS_FILE"

# Use the bolder WCAG-contrast underline style so glossary terms are
# more obviously interactive (default style is a very subtle 1px dotted
# underline that's easy to miss).
$wgexLingoWCAGStyle = true;
EOF
    fi

    # Sessions must be shared across replicas. $wgMainCacheType is CACHE_ACCEL
    # (APCu), which lives in one pod's memory, and $wgSessionCacheType inherits
    # from it when unset - so with more than one replica a user's session only
    # exists on whichever pod happened to create it, and they appear randomly
    # logged out as requests land elsewhere. CACHE_DB keeps sessions in the
    # objectcache table, shared by every pod, with no extra infrastructure to
    # run. Applying this invalidates existing sessions once, so everyone signs
    # in again on the deploy that introduces it.
    if ! setting_active '$wgSessionCacheType'; then
        echo "Adding shared session storage to existing LocalSettings.php."
        cat << 'EOF' >> "$LOCALSETTINGS_FILE"

# Store sessions in the database so they are shared across replicas.
$wgSessionCacheType = CACHE_DB;
EOF
    fi

    # The main cache must be shared for the same reason sessions must be.
    # install.php writes $wgMainCacheType = CACHE_ACCEL, which is APCu - memory
    # local to a single php-fpm pod. MediaWiki uses this cache for WANObjectCache
    # purges and tombstones, rate limit counters, the message cache and similar,
    # all of which assume every application server sees the same store. With two
    # replicas and APCu, an edit served by one pod does not invalidate the other
    # pod's copy, so users get stale content depending on which pod they land on,
    # and rate limits are counted per pod.
    #
    # CACHE_DB uses the objectcache table, which already exists. It is slower
    # than APCu but correct across replicas, and this wiki is small. Redis or
    # memcached would be the faster option - the php extensions for both are
    # already in the image - but that means running another service.
    #
    # Appending re-assigns the variable; the later assignment in LocalSettings.php
    # wins. The guard therefore has to match the value, not just the name, since
    # $wgMainCacheType is always present from the original install.
    if ! setting_active '$wgMainCacheType = CACHE_DB'; then
        echo "Switching main cache to shared database storage in LocalSettings.php."
        cat << 'EOF' >> "$LOCALSETTINGS_FILE"

# Shared across replicas; overrides the CACHE_ACCEL (APCu, per-pod) default
# written by install.php.
$wgMainCacheType = CACHE_DB;
EOF
    fi
else
    echo "Existing installation. Startup mutations run in the init Job, not here."
fi

# Ensure images folder exists and has correct permissions.
if [ ! -d "images" ]; then
    mkdir -p images
fi

# The init Job's work is done; it must not become a php-fpm process.
if [ "$MODE" = "init" ]; then
    echo "Init complete."
    exit 0
fi

# Execute the main container command, e.g., php-fpm.
exec "$@"