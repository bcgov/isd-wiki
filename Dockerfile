# Use the official MediaWiki FPM stable image based on Alpine.
# This image is designed to run non-root and is suitable for OpenShift.
FROM mediawiki:stable-fpm-alpine

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
ENV MEDIAWIKI_MAJOR_VERSION=1.44
ENV MEDIAWIKI_VERSION=1.44.0
ENV MEDIAWIKI_VERSION_STR=1_44

# --- Install Composer ---
# The official image already has /var/www/html/extensions.
# We'll clone and install specific extensions here.
ENV COMPOSER_ALLOW_SUPERUSER=1
WORKDIR /var/www/html
RUN curl -sS https://getcomposer.org/installer | php && \
    mv composer.phar /usr/local/bin/composer

# --- Install MediaWiki Extensions ---
RUN set -eux; \
    extensions="PageForms CategoryTree TitleKey TemplateData VEForAll"; \
    for ext in $extensions; do \
        target_dir="extensions/$ext"; \
        if [ -d "$target_dir" ]; then \
            echo "Skipping $ext: already exists."; \
        else \
            git clone --depth 1 --branch REL1_44 \
              "https://gerrit.wikimedia.org/r/mediawiki/extensions/$ext" "$target_dir"; \
        fi; \
    done; \
    cd extensions/PageForms && composer install --no-dev --no-interaction || true; \
    cd /var/www/html;

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
