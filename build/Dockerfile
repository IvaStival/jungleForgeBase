# syntax=docker/dockerfile:1.7
#
# THE common project image — ONE Dockerfile shared by every project. Projects do NOT carry
# their own; jungleforge's compose points build.dockerfile here while build.context stays the
# project root (so the COPY deploy/* lines pull each project's own config). Build targets:
#   dev  -> FROM the prebuilt jungleforge base (fast; no extension compiling)
#   app  -> self-contained prod build (vendor + assets baked, multi-arch-portable)
#
# Written to tolerate project variation: an absent package-lock.json (npm install vs ci) and
# API-only projects with no frontend at all (the assets stage no-ops). Each container is
# self-contained: nginx + php-fpm (+ horizon + scheduler) under supervisord; nginx -> php-fpm
# over 127.0.0.1:9000. php config is MOUNTED by compose (defaults overridable per project).

ARG PHP_VERSION=8.4

# ---------- DEV runtime: thin layer on the shared jungleforge base (no compiling) ----------
# Requires the base built once: `make base`. jungleforge/php:<v>-dev already has php + extensions
# + nginx + supervisor + xdebug + composer/node + zsh. Code is volume-mounted at runtime.
FROM jungleforge/php:${PHP_VERSION}-dev AS dev
COPY deploy/supervisor/supervisord.dev.conf /etc/supervisor/supervisord.conf
COPY deploy/nginx/default.conf.template /etc/nginx/http.d/default.conf.template
COPY deploy/entrypoint.dev.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint
WORKDIR /var/www
EXPOSE 8080
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint"]
CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]

# ---------- composer dependencies (prod) ----------
# --platform=$BUILDPLATFORM keeps composer on the build host's native arch during cross-arch
# builds. composer.json is always present; composer.lock is optional (the [k] glob matches it
# if it exists, nothing otherwise).
#
# --ignore-platform-reqs: the composer:2 image bundles its OWN PHP (tracks latest — currently
# 8.5) and only a minimal extension set, which is NOT the runtime. The app actually runs on the
# php-base stage below (PHP ${PHP_VERSION} + intl/gd/pgsql/redis/...). Without this flag composer
# validates the lock against the builder's PHP and fails on both the version (lock may cap at
# 8.4) and missing exts (e.g. ext-intl for filament). We resolve from the lock file (no update)
# and let the runtime image be the source of truth for platform compatibility.
FROM --platform=$BUILDPLATFORM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.loc[k] ./
RUN composer install --no-dev --no-scripts --no-autoloader \
        --prefer-dist --no-interaction --no-progress --ignore-platform-reqs
COPY . .
RUN composer dump-autoload --optimize --classmap-authoritative --no-dev --no-scripts

# ---------- frontend assets (prod) ----------
# Optional: API-only projects have no package.json — the whole stage then just ensures an empty
# public/build exists so the app stage's COPY succeeds. composer.json guarantees the first COPY
# matches at least one file so the optional package globs may match zero.
FROM --platform=$BUILDPLATFORM node:20-alpine AS assets
WORKDIR /app
COPY composer.json package.jso[n] package-lock.jso[n] ./
RUN if [ -f package.json ]; then npm ci --no-audit --no-fund || npm install --no-audit --no-fund; fi
COPY . .
RUN if [ -f package.json ] && npm run 2>/dev/null | grep -qiE '^[[:space:]]+build'; then \
        npm run build; \
    fi; \
    mkdir -p public/build

# ---------- prod extension layer (self-contained for multi-arch) ----------
# Mirrors base/Dockerfile's `fpm` stage. Kept here (not FROM the base) so prod images don't
# depend on the locally-built base and stay portable for multi-arch `make push`.
FROM php:${PHP_VERSION}-fpm-alpine AS php-base
RUN apk add --no-cache \
        bash tini su-exec nginx supervisor gettext \
        icu-libs libpng libjpeg-turbo libwebp freetype libzip \
        postgresql-libs oniguruma \
    && apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS icu-dev libpng-dev libjpeg-turbo-dev libwebp-dev \
        freetype-dev libzip-dev postgresql-dev oniguruma-dev linux-headers \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
        bcmath gd intl mbstring opcache pcntl pdo_pgsql pgsql sockets zip \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del .build-deps \
    && sed -i 's/^user .*/user www-data;/' /etc/nginx/nginx.conf \
    && rm -rf /tmp/* /var/cache/apk/*

# ---------- prod runtime (baked code + assets, nginx + php-fpm under supervisord) ----------
FROM php-base AS app
# Pre-configured zsh (oh-my-zsh + powerlevel10k + plugins) so `docker exec … zsh` and
# `make sh <project> env=prod` land in the same shell as dev. Config is single-sourced from
# jungleforge's base/zsh/* via the `jungleforge` named build context (docker-compose.prod.yml
# additional_contexts) — that repo is outside the project build context, so it can't be a
# plain COPY. Placed before the vendor/assets COPY so the layer caches across projects.
RUN apk add --no-cache zsh git \
    && git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git                  /root/.oh-my-zsh \
    && git clone --depth=1 https://github.com/romkatv/powerlevel10k.git            /root/.oh-my-zsh/custom/themes/powerlevel10k \
    && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git    /root/.oh-my-zsh/custom/plugins/zsh-autosuggestions \
    && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git /root/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting \
    && find /root/.oh-my-zsh -name '.git' -prune -exec rm -rf {} +
COPY --from=jungleforge base/zsh/zshrc    /root/.zshrc
COPY --from=jungleforge base/zsh/p10k.zsh /root/.p10k.zsh
COPY deploy/supervisor/supervisord.conf /etc/supervisor/supervisord.conf
COPY deploy/nginx/default.conf.template /etc/nginx/http.d/default.conf.template
COPY deploy/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint
WORKDIR /var/www
# Code & vendor are root-owned (world-readable) so the runtime user (www-data) can READ but
# not REWRITE the application's own source — a PHP-level RCE can't persist by editing code.
# Only the dirs Laravel must write to (storage/, bootstrap/cache) are owned by www-data; the
# entrypoint's `artisan optimize`/`package:discover` write only there.
COPY --chown=root:root --from=vendor /app              /var/www
COPY --chown=root:root --from=assets /app/public/build /var/www/public/build
RUN mkdir -p storage/framework/cache storage/framework/sessions \
        storage/framework/views storage/logs bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R ug+rwX storage bootstrap/cache
EXPOSE 8080
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint"]
CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
