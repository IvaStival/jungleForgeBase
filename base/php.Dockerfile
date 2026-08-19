# syntax=docker/dockerfile:1.7
#
# Shared, project-AGNOSTIC base images for jungleforge. Built once by `make base [version]`:
#   jungleforge/php:<v>-fpm   php-fpm + extensions + nginx + supervisor   (prod-shaped runtime)
#   jungleforge/php:<v>-dev   ^ + xdebug + git + node + npm + composer     (dev runtime)
#
# Project images FROM the `-dev` tag for DEV builds, so a freshly-registered project comes up
# in seconds with no extension compiling. Production project images do NOT use these — they
# self-compile (templates/deploy/Dockerfile `php-base` stage) so prod stays portable for
# multi-arch builds. Keep the extension list below IN SYNC with that `php-base` stage.

ARG PHP_VERSION=8.4

# ---------- fpm base: php + extensions + nginx + supervisor ----------
# Extension list mirrors ~/Projects/phpdocker's php/Dockerfile (this control plane's Debian-
# based predecessor), translated to apk/pecl on Alpine, so every company app's known needs
# (MySQL, AMQP, image processing, etc.) are covered without revisiting this file per project.
# Excluded: sqlsrv/pdo_sqlsrv (Microsoft's ODBC driver isn't musl/Alpine-compatible) and the
# optional swoole build — neither is used by any current app.
FROM php:${PHP_VERSION}-fpm-alpine AS fpm
RUN apk add --no-cache \
        bash tini su-exec nginx supervisor gettext \
        icu-libs libpng libjpeg-turbo libwebp freetype libzip \
        postgresql-libs oniguruma \
        curl libxml2 libxslt gmp bzip2 libffi imagemagick rabbitmq-c gettext \
    && apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS icu-dev libpng-dev libjpeg-turbo-dev libwebp-dev \
        freetype-dev libzip-dev postgresql-dev oniguruma-dev linux-headers \
        curl-dev libxml2-dev libxslt-dev gmp-dev bzip2-dev libffi-dev \
        imagemagick-dev rabbitmq-c-dev gettext-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
        bcmath bz2 calendar curl exif ffi ftp gd gettext gmp intl mbstring \
        mysqli opcache pcntl pdo_mysql pdo_pgsql pgsql soap sockets xsl zip \
    && pecl install redis amqp mongodb apcu imagick \
    && docker-php-ext-enable redis amqp mongodb apcu imagick \
    && apk del .build-deps \
    && sed -i 's/^user .*/user www-data;/' /etc/nginx/nginx.conf \
    && rm -rf /tmp/* /var/cache/apk/*
WORKDIR /var/www

# ---------- dev base: + xdebug + tooling + composer + pre-configured zsh ----------
FROM fpm AS dev
RUN apk add --no-cache git unzip nodejs npm zsh \
    && apk add --no-cache --virtual .xdebug-deps $PHPIZE_DEPS linux-headers \
    && pecl install xdebug \
    && docker-php-ext-enable xdebug \
    && apk del .xdebug-deps \
    && rm -rf /tmp/* /var/cache/apk/*
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Pre-configured zsh: oh-my-zsh + powerlevel10k + autosuggestions + syntax-highlighting.
# Cloned (shallow) rather than via the curl|sh installer; .git dirs stripped to keep it small.
# Config is shipped (base/zsh/*) so there is NO `p10k configure` wizard on first shell.
RUN git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git                  /root/.oh-my-zsh \
    && git clone --depth=1 https://github.com/romkatv/powerlevel10k.git         /root/.oh-my-zsh/custom/themes/powerlevel10k \
    && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git /root/.oh-my-zsh/custom/plugins/zsh-autosuggestions \
    && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git /root/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting \
    && find /root/.oh-my-zsh -name '.git' -prune -exec rm -rf {} + \
    && rm -rf /tmp/* /var/cache/apk/*
COPY base/zsh/zshrc    /root/.zshrc
COPY base/zsh/p10k.zsh /root/.p10k.zsh
