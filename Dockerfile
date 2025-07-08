# Use the official MediaWiki FPM stable image based on Alpine.
# This image is designed to run non-root and is suitable for OpenShift.
# It includes PHP-FPM, MediaWiki core, and many common PHP extensions.
FROM mediawiki:stable-fpm-alpine

# --- System dependencies ---
# Add necessary system packages not included in the base image,
# including git (for extensions), imagemagick, librsvg2-bin (for SVG rendering),
# python3 (for SyntaxHighlighting), unzip (for some extensions), and jq (for Vault secret processing).
RUN set -eux; \
    \
    apk add --no-cache \
    git \
    imagemagick \
    librsvg2-bin \
    python3 \
    unzip \
    # jq is crucial for parsing Vault secrets in your custom entrypoint script
    jq \
    ;

# --- Install additional PHP extensions ---
# The base `mediawiki:fpm-stable-alpine` image already includes many common PHP extensions
# (like intl, mbstring, mysqli, opcache, calendar).
# We only need to add those specifically requested in your original Dockerfile that might be missing,
# or are typically installed via PECL (APCu, LuaSandbox).
# Also adding ldap, pcntl, zip, imagick, redis, memcached as per your original Dockerfile,
# ensuring their build dependencies are handled.
RUN set -eux; \
    \
    apk add --no-cache --virtual .build-deps \
    $PHPIZE_DEPS \
    icu-dev \
    lua5.1-dev \
    oniguruma-dev \
    # For ldap, pcntl, zip, imagick, redis, memcached
    # Check if these are already in base, but safer to include build deps
    openldap-dev \
    libzip-dev \
    imagemagick-dev \
    hiredis-dev \
    libmemcached-dev \
    ; \
    \
    docker-php-ext-install -j "$(nproc)" \
    ldap \
    pcntl \
    zip \
    # imagick is installed via pecl, not docker-php-ext-install for ImageMagick
    ; \
    \
    pecl install APCu-5.1.24; \
    pecl install LuaSandbox-4.1.2; \
    pecl install imagick redis memcached; \
    docker-php-ext-enable \
    apcu \
    luasandbox \
    imagick \
    redis \
    memcached \
    ; \
    rm -r /tmp/pear; \
    \
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
ENV MEDIAWIKI_MAJOR_VERSION=1.44
ENV MEDIAWIKI_VERSION=1.44.0
ENV MEDIAWIKI_VERSION_STR=1_44

# --- Install MediaWiki Extensions ---
# The official image already has /var/www/html/extensions.
# We'll clone and install specific extensions here.
WORKDIR /var/www/html
# The base image already includes Composer.
ENV COMPOSER_ALLOW_SUPERUSER=1

# Install VisualEditor
# See: https://www.mediawiki.org/wiki/Extension:VisualEditor
RUN cd /var/www/html/extensions/
RUN set -eux; \
    git clone --recurse-submodules https://gerrit.wikimedia.org/r/mediawiki/extensions/VisualEditor; \
    cd VisualEditor; \
    rm -rf .git; \
    chown -R www-data:www-data /var/www/html/extensions/VisualEditor;

# # Install SyntaxHighlight_GeSHi
# RUN set -eux; \
#     git clone https://gerrit.wikimedia.org/r/mediawiki/extensions/SyntaxHighlight_GeSHi.git /var/www/html/extensions/SyntaxHighlight_GeSHi; \
#     cd /var/www/html/extensions/SyntaxHighlight_GeSHi; \
#     git checkout REL1_41; \
#     rm -rf .git; \
#     chown -R www-data:www-data /var/www/html/extensions/SyntaxHighlight_GeSHi;


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
    \
    # Ensure extensions and skins directories are writable if you dynamically add/update them.
    # For build-time installs, this ensures the arbitrary UID can write if needed.
    mkdir -p /var/www/html/extensions; \
    mkdir -p /var/www/html/skins; \
    chmod 775 /var/www/html/extensions /var/www/html/skins; \
    chown -R www-data:www-data /var/www/html/extensions /var/www/html/skins;

# --- Copy custom configuration files ---
# These files will be part of the image.
# Your LocalSettings.php will likely be overridden by a mounted ConfigMap in Kubernetes.
# Your custom entrypoint and startup tasks will be used.
COPY php.ini /usr/local/etc/php/
# If you have mediawiki.conf for Apache, ensure you're using an Apache base image.
# If using FPM, this file is irrelevant.
# COPY mediawiki.conf /etc/apache2/
COPY docker-entrypoint.sh /entrypoint.sh
COPY docker-startuptasks.sh /startuptasks.sh
COPY LocalSettings.php /var/www/html/LocalSettings.php
COPY CustomHooks.php /var/www/html/CustomHooks.php

# --- Final Permissions and Volume ---
# /var/www/data is for SQLite or other data. The base image might use /var/www/html/data.
# Ensure this aligns with your LocalSettings.php and volume mounts.
# The `images` directory is typically where user uploads go.
RUN mkdir -p /data \
    && chmod a+rw /var/www/html/extensions/Widgets/compiled_templates

VOLUME /data

EXPOSE 9000

# --- Entrypoint and Command ---
# Stick to the official image's default ENTRYPOINT/CMD for PHP-FPM.
# Your custom entrypoint wrapper will override this in Kubernetes.
# The official image's ENTRYPOINT is usually 'docker-entrypoint.sh'
# and its CMD is 'php-fpm'.
# We keep these here as defaults, but your Helm chart will override them.
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]

# Best practice: Add labels for maintainability
LABEL org.opencontainers.image.source="https://github.com/bcgov/isd-wiki" \
    org.opencontainers.image.description="MediaWiki with extensions for OpenShift" \
    org.opencontainers.image.licenses="GPL-2.0-only"

