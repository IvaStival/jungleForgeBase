# syntax=docker/dockerfile:1.7
#
# THE common project image for the "frankenphp" stack (a project opts in with STACK=frankenphp
# in its deploy/.docker-env) — one Dockerfile shared by every FrankenPHP-based project (e.g.
# Symfony). Mirrors build/php.Dockerfile's dev/app split, but FrankenPHP bundles its own web server
# (Caddy) + PHP: there is no separate nginx/php-fpm pair and no supervisord — a single
# `frankenphp run` process serves the app on :8080 (configured via the project's
# deploy/Caddyfile).
#
# Composer dependencies are NOT installed at build time for `dev` — like build/php.Dockerfile's dev
# stage, code (including vendor/) is volume-mounted from the host, where you run `composer
# install` yourself. `app` (prod) installs them in a builder stage and bakes the result in.

ARG PHP_VERSION=8.4

# ---------- DEV runtime ----------
# The official FrankenPHP image already bundles PHP + Caddy + common extensions.
FROM dunglas/frankenphp:1-php${PHP_VERSION}-alpine AS dev
# The base image ships PHP + pdo_sqlite only — add pdo_pgsql for projects using Postgres
# (the jungleforge shared services stack).
RUN apk add --no-cache postgresql-libs \
    && apk add --no-cache --virtual .build-deps postgresql-dev \
    && docker-php-ext-install pdo_pgsql pgsql \
    && apk del .build-deps
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
WORKDIR /app
COPY deploy/entrypoint.dev.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint
EXPOSE 8080
# Override the base image's default healthcheck (it probes Caddy's admin API on :2019, which
# our Caddyfile disables with `admin off`) — probe the actual app port instead. Any valid HTTP
# response (including a 404 for an unmatched route) proves FrankenPHP is serving.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -sS -o /dev/null http://127.0.0.1:8080/ || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["frankenphp", "run", "--config", "/etc/frankenphp/Caddyfile"]

# ---------- composer dependencies (prod) ----------
# --platform=$BUILDPLATFORM keeps composer on the build host's native arch during cross-arch
# builds (mirrors build/php.Dockerfile's vendor stage). composer.json is always present;
# composer.lock is optional (the [k] glob matches it if it exists, nothing otherwise).
FROM --platform=$BUILDPLATFORM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.loc[k] ./
RUN composer install --no-dev --no-scripts --no-autoloader \
        --prefer-dist --no-interaction --no-progress --ignore-platform-reqs
COPY . .
RUN composer dump-autoload --optimize --classmap-authoritative --no-dev --no-scripts

# ---------- prod runtime (self-contained, multi-arch-portable) ----------
FROM dunglas/frankenphp:1-php${PHP_VERSION}-alpine AS app
RUN apk add --no-cache postgresql-libs \
    && apk add --no-cache --virtual .build-deps postgresql-dev \
    && docker-php-ext-install pdo_pgsql pgsql \
    && apk del .build-deps
WORKDIR /app
COPY --chown=root:root --from=vendor /app /app
COPY deploy/Caddyfile /etc/frankenphp/Caddyfile
COPY deploy/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint \
    && mkdir -p var/cache var/log \
    && chown -R www-data:www-data var
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -sS -o /dev/null http://127.0.0.1:8080/ || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["frankenphp", "run", "--config", "/etc/frankenphp/Caddyfile"]
