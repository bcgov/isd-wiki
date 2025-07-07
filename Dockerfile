# Use the official MediaWiki image as base.
# We're choosing a specific stable version (e.g., 1.39.6) and the FPM variant
# which is suitable for use with web servers like Nginx or Apache in separate containers
# or for running PHP-FPM directly.
# Always pin to a specific version for stability.
FROM mediawiki:1.41.1-fpm

# --- System Dependencies for Extensions and OpenShift Compatibility ---
# Install system packages required for typical MediaWiki extensions
# and ensure nonroot operations.
# apt-get update and clean up are crucial for efficient image layers.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        git \
        librsvg2-bin \
        imagemagick \
        # php-gd might be needed for image manipulation if not bundled, check base image
        # and other common tools often used by extensions
        unzip \
        rsync \
    ; \
    rm -rf /var/lib/apt/lists/*

# --- OpenShift Specific Configuration for Non-Root Execution ---
# The official MediaWiki image often runs as 'www-data' (UID 33) which is a non-root user.
# OpenShift typically runs containers with an arbitrary user ID.
# This part ensures that the necessary directories are writable by the assigned UID.
# MediaWiki's entrypoint often handles permissions, but it's good to be explicit for
# common writable directories.

# Ensure /var/www/html/images is writable for uploads.
# The official image usually sets appropriate permissions for /var/www/html itself.
# We'll rely on the official image's setup for the main /var/www/html and entrypoint.
# The `images` directory is where user uploads go.
RUN set -eux; \
    mkdir -p /var/www/html/images; \
    chmod 775 /var/www/html/images; \
    chown -R www-data:www-data /var/www/html/images; \
    # Also ensure extensions and skins directories are writable if you plan to
    # dynamically add them or update them post-deployment (though generally not recommended).
    # For a build-time Dockerfile, these are often copied in directly.
    mkdir -p /var/www/html/extensions; \
    mkdir -p /var/www/html/skins; \
    chmod 775 /var/www/html/extensions /var/www/html/skins; \
    chown -R www-data:www-data /var/www/html/extensions /var/www/html/skins

# --- Install MediaWiki Extensions ---
# This section demonstrates how to add extensions.
# You can add more `RUN` commands for each extension or consolidate.
# It's recommended to install extensions at build time for stable deployments.

# Install VisualEditor
# See: https://www.mediawiki.org/wiki/Extension:VisualEditor
RUN cd /var/www/html/extensions/
RUN set -eux; \
    git clone --recurse-submodules https://gerrit.wikimedia.org/r/mediawiki/extensions/VisualEditor; \
    # Try to checkout the specific release branch first
    # If that fails (e.g., branch doesn't exist), fall back to master.
    # It's better to confirm the branch beforehand to avoid failures.
    # git checkout REL1_41 || echo "REL1_41 branch not found, falling back to master" && git checkout master; \
    # composer install --no-dev; \
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

# --- Customize MediaWiki Configuration (Optional but Recommended) ---
# It's common to provide a custom LocalSettings.php, often using environment variables
# or a config map in Kubernetes. For this Dockerfile, we'll assume the configuration
# will primarily come from environment variables passed at runtime or a mounted ConfigMap.
# However, you might want to bake in some defaults or common settings here.

# Example: Pre-enable extensions in a dummy LocalSettings.php.
# This file will likely be overwritten by a mounted ConfigMap in Kubernetes.
# This serves as a placeholder or a default if no config map is used.
COPY LocalSettings.php /var/www/html/LocalSettings.php

# --- User and Permissions (Handled by Base Image & OpenShift) ---
# The official MediaWiki image's entrypoint usually sets up permissions correctly
# and switches to the 'www-data' user (UID 33).
# OpenShift will run the container with an arbitrary user ID, but it ensures
# that this ID has write access to volumes mounted.
# The base image's entrypoint is responsible for handling the `www-data` user and group setup.
# We explicitly set ownership for our added directories and files to `www-data`.
USER www-data

# --- Expose Port ---
# MediaWiki (PHP-FPM) typically listens on port 9000 for FPM.
# The web server (e.g., Nginx or Apache) would then communicate with this port.
EXPOSE 9000

# --- Entrypoint and Command ---
# Use the default entrypoint and command from the official image,
# as it's designed to correctly initialize MediaWiki.
CMD ["php-fpm"]
ENTRYPOINT ["/entrypoint.sh"]

# Final permissions check (optional, for debugging)
RUN ls -la /var/www/html/images /var/www/html/extensions

# Best practice: Add labels for maintainability
LABEL org.opencontainers.image.source="https://github.com/bcgov/isd-wiki" \
      org.opencontainers.image.description="MediaWiki custom image with extensions." \
      org.opencontainers.image.licenses="GPL-2.0-only"