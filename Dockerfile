# Use the official MediaWiki FPM image based on Alpine.
# This image is designed to run non-root and is suitable for OpenShift.
#
# Pinned to the 1.46 series rather than the floating "stable" tag. "stable"
# silently moved this image from MediaWiki 1.44 to 1.46 while the extensions
# below stayed pinned to REL1_44, which is what produced the deprecation
# warnings from PageForms' special pages. The 1.46 tag still tracks patch
# releases (1.46.x), so security fixes arrive without jumping a minor version
# out from under the extension pins. Bump this and the REL branch below
# together.
FROM mediawiki:1.46-fpm-alpine

# --- System dependencies ---
# Add necessary system packages not included in the base image,
# including git (for extensions), imagemagick, librsvg2-bin (for SVG rendering),
# python3 (for SyntaxHighlighting), unzip (for some extensions), and jq (for Vault secret processing).
RUN set -eux; \
    apk add --no-cache \
    git \
    imagemagick \
    librsvg \
    python3 \
    unzip \
    jq \
    netcat-openbsd \
    postgresql-client \
    ;

# --- Install additional PHP extensions ---
# The base `mediawiki:fpm-stable-alpine` image already includes many common PHP extensions
# (like intl, mbstring, mysqli, opcache, calendar).
# We only need to add those specifically requested in your original Dockerfile that might be missing,
# or are typically installed via PECL (APCu, LuaSandbox).
# Also adding ldap, pcntl, zip, imagick, redis, memcached as per your original Dockerfile,
# ensuring their build dependencies are handled.
RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
    $PHPIZE_DEPS \
    icu-dev \
    lua5.1-dev \
    oniguruma-dev \
    openldap-dev \
    libzip-dev \
    imagemagick-dev \
    hiredis-dev \
    libmemcached-dev \
    postgresql-dev \
    ; \
    docker-php-ext-install -j "$(nproc)" \
    ldap \
    pgsql \
    pcntl \
    zip \
    # imagick is installed via pecl, not docker-php-ext-install for ImageMagick
    ; \
    pecl install imagick redis memcached; \
    docker-php-ext-enable \
    imagick \
    redis \
    memcached \
    ; \
    rm -r /tmp/pear; \
    runDeps="$( \
    scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
    | tr ',' '\n' \
    | sort -u \
    | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-network --virtual .mediawiki-phpext-rundeps $runDeps; \
    apk del --no-network .build-deps; \
    # Clean up any remaining build artifacts if necessary
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# --- MediaWiki Version (for extension compatibility) ---
# The base image already contains MediaWiki core. These ENVs are for extension logic.
ENV MEDIAWIKI_MAJOR_VERSION=1.46
ENV MEDIAWIKI_VERSION=1.46.0
ENV MEDIAWIKI_VERSION_STR=1_46

# --- MediaWiki core workaround: ZIP magic number misdetection ---
# MediaWiki 1.46.0 adds "PK\x03\x04" => 'application/epub+zip' to
# MimeAnalyzer::MAGIC_NUMBERS. Every ZIP-based format opens with that magic
# number, so the MAGIC_NUMBERS loop matches first and returns early, and
# detectZipTypeFromFile() - the function that actually tells docx from xlsx
# from ODF - is never reached. improveTypeFromExtension() only rescues
# 'application/x-opc+zip' and the OpenDocument types, so 'application/epub+zip'
# survives to the extension check and every OOXML/ODF upload is rejected with
# "File extension .docx does not match the detected MIME type of the file
# (application/epub+zip)". This hits docx, xlsx, pptx, dotx, xltx, ppsx and ODF
# alike. The mapping is not even usable as written: 'epub' is absent from
# $wgFileExtensions, so nothing can be uploaded as an epub either way.
#
# It also silently disables the 'application/java' ZIP-applet check, because
# detectZipTypeFromFile() is that type's only producer and it is listed in
# $wgMimeTypeExclusions.
#
# This ships in the official docker.io/library/mediawiki image, not in anything
# we build - verified byte-identical between mediawiki:1.46-fpm-alpine and our
# own image. 1.46.0 is the only 1.46 release published, so there is no patch
# version to bump to.
#
# Removing the two lines restores the previous behaviour: guessMimeType()
# returns 'application/x-opc+zip' and improveTypeFromExtension() resolves that
# to the real wordprocessingml/spreadsheetml type. Verified in aebbdd-test.
#
# Deliberately a targeted sed rather than a patches/ overlay: MimeAnalyzer.php
# is core and changes between releases, so a whole-file COPY would pin it to
# 1.46.0 and mask later fixes to it, including security fixes. The guards below
# fail the build if upstream changes or fixes these lines, so the next version
# bump surfaces this rather than silently no-opping. Remove this block once a
# MediaWiki release ships without the epub mapping.
RUN set -eux; \
    F=/var/www/html/includes/libs/Mime/MimeAnalyzer.php; \
    if ! grep -q 'epub+zip' "$F"; then \
        echo "MimeAnalyzer.php no longer maps ZIP to epub+zip - drop this workaround" >&2; \
        exit 1; \
    fi; \
    sed -i -e '/^[[:space:]]*\/\/ archive$/d' -e '/application\/epub+zip.,$/d' "$F"; \
    if grep -q 'epub+zip' "$F"; then \
        echo "failed to remove the epub+zip mapping from MimeAnalyzer.php" >&2; \
        exit 1; \
    fi; \
    php -l "$F"

# --- Install Composer ---
# The official image already has /var/www/html/extensions.
# We'll clone and install specific extensions here.
ENV COMPOSER_ALLOW_SUPERUSER=1
WORKDIR /var/www/html
RUN curl -sS https://getcomposer.org/installer | php && \
    mv composer.phar /usr/local/bin/composer

# --- Install MediaWiki Extensions ---
RUN set -eux; \
    extensions="PageForms CategoryTree TitleKey TemplateData VEForAll Lingo"; \
    for ext in $extensions; do \
        target_dir="extensions/$ext"; \
        if [ -d "$target_dir" ]; then \
            echo "Skipping $ext: already exists."; \
        else \
            git clone --depth 1 --branch REL1_46 \
              "https://gerrit.wikimedia.org/r/mediawiki/extensions/$ext" "$target_dir"; \
        fi; \
    done; \
    cd extensions/PageForms && composer install --no-dev --no-interaction || true; \
    cd /var/www/html;

# NOTE: the former patches/PageForms-PF_ValuesUtils.php overlay is gone as of
# the REL1_46 bump. It existed because PageForms' getCategoriesForPage() queried
# the pre-normalization "cl_to" column on categorylinks, which MediaWiki 1.46
# replaced with a "linktarget" join keyed by cl_target_id. REL1_46 handles this
# upstream by probing $db->fieldExists( 'categorylinks', 'cl_to' ) and choosing
# the query shape at runtime, so the overlay is redundant.
#
# Keeping it would have been actively harmful rather than merely redundant:
# REL1_46 renames every PF_*.php file (includes/PF_ValuesUtils.php is now
# includes/PFValuesUtils.php), so the COPY would have written a file at a path
# nothing autoloads - a silent no-op that still builds cleanly.

# Lingo's shouldParse() guards with "if ( !$parser->getOutput() ... )", a null
# check written for the days when Parser::$mOutput was untyped. MediaWiki 1.46
# made it a typed property, so reading it before a parse has begun raises
# "Typed property MediaWiki\Parser\Parser::$mOutput must not be accessed before
# initialization" instead of returning null - the guard meant to detect "no
# output yet" is what throws. Every request reaching this hook with a Parser
# that has not started parsing dies, which took out editing and previewing in
# production while ordinary page views (which always parse) looked fine.
#
# This overlay catches the Error and returns false, preserving the original
# intent: no parser output means nothing to annotate. Upstream master carries
# the same bug as of 2026-08-11, so no version bump fixes it - re-check if
# Lingo is ever bumped past REL1_46 / 3.3.0.
COPY patches/Lingo-LingoParser.php extensions/Lingo/src/LingoParser.php

# --- Install EmbedVideo (for embedding YouTube/Vimeo/etc. video in pages) ---
# Not hosted on gerrit.wikimedia.org, so cloned separately and pinned to a
# release tag (upstream publishes no REL branches; v4.1.0 is the current
# release and declares "MediaWiki": ">= 1.43.0", so it covers our 1.46 core).
RUN set -eux; \
    target_dir="extensions/EmbedVideo"; \
    if [ -d "$target_dir" ]; then \
        echo "Skipping EmbedVideo: already exists."; \
    else \
        git clone --depth 1 --branch v4.1.0 \
          "https://github.com/StarCitizenWiki/mediawiki-extensions-EmbedVideo.git" "$target_dir"; \
    fi;

# EmbedVideo's upstream SharePoint service only matches direct file links
# ending in a file extension (e.g. ".../video.mp4"). Our SharePoint tenant's
# "Embed" share action instead generates Stream player links in the form
# ".../_layouts/15/embed.aspx?UniqueId=...", which don't end in an extension
# and so are rejected outright. This overlay relaxes that regex to accept
# any URL under /sites/ on a sharepoint.com host. Re-apply if EmbedVideo is
# ever bumped past v4.1.0, since upstream may not have fixed this.
COPY patches/EmbedVideo-SharePoint.php extensions/EmbedVideo/includes/EmbedService/SharePoint.php

# EmbedVideo's RefreshEmbedVideoMetadata special page passes its permission to
# the parent constructor as the $restriction argument, which MediaWiki 1.46
# deprecated; every instantiation emits a deprecation warning. This overlay
# moves the permission to a getRestriction() override, which is exactly what
# UnlistedSpecialPage's own docblock prescribes ("override the method
# getRestriction() instead"). Core calls getRestriction() from isRestricted(),
# userCanExecute(), checkPermissions() and displayRestrictionError(), so the
# permission check is unchanged - the argument is not simply dropped.
#
# Only visible once the PageForms REL1_46 bump landed: MWDebug::deprecatedMsg
# keys its warning table on the message text, so with the debug toolbar off
# only the *first* caller of a given deprecation ever emits. PageForms was
# masking this one. Re-check for a newly unmasked warning whenever one of
# these is fixed. Drop this overlay if EmbedVideo is bumped past v4.1.0 and
# upstream has fixed it.
COPY patches/EmbedVideo-SpecialRefreshEmbedVideoMetadata.php extensions/EmbedVideo/includes/Specials/SpecialRefreshEmbedVideoMetadata.php

# --- OpenShift Specific Configuration for Non-Root Execution ---
# The official MediaWiki image typically runs as 'www-data' (UID 33).
# OpenShift runs containers with an arbitrary user ID, but ensures it has group write access
# to volumes. We explicitly ensure our added/modified directories are group-writable.
# The base image's entrypoint will handle permissions for core MediaWiki files.
RUN set -eux; \
    # Ensure images directory is writable for user uploads.
    # The base image might already handle this, but explicit is safer.
    mkdir -p /var/www/html/images; \
    chmod 775 /var/www/html/images; \
    chown -R www-data:www-data /var/www/html/images; \
    mkdir -p /var/www/html/extensions; \
    mkdir -p /var/www/html/skins; \
    chmod 775 /var/www/html/extensions /var/www/html/skins; \
    chown -R www-data:www-data /var/www/html/extensions /var/www/html/skins;

# --- php-fpm process manager tuning ---
# Raises the pool off the stock pm.max_children = 5. Named to sort last in the
# php-fpm.d/*.conf glob so it overrides www.conf. See the file for sizing notes.
COPY php-fpm-pool.conf /usr/local/etc/php-fpm.d/zzz-isd-wiki.conf

# --- Final Permissions and Volume ---
RUN mkdir -p /var/www/data
VOLUME /var/www/data

EXPOSE 9000

# --- Entrypoint and Command ---
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["php-fpm"]

# --- Labels ---
LABEL org.opencontainers.image.source="https://github.com/bcgov/isd-wiki" \
    org.opencontainers.image.description="MediaWiki with extensions for OpenShift" \
    org.opencontainers.image.licenses="GPL-2.0-only"
