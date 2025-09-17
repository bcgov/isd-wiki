# Use the official MediaWiki FPM stable image based on Alpine.
FROM mediawiki:stable-fpm-alpine

# --- System dependencies ---
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
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# --- MediaWiki Version (for extension compatibility) ---
ENV MEDIAWIKI_MAJOR_VERSION=1.44
ENV MEDIAWIKI_VERSION=1.44.0
ENV MEDIAWIKI_VERSION_STR=1_44

# --- Install Composer ---
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
RUN set -eux; \
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
