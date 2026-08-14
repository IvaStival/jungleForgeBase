#!/bin/sh
# Dev entrypoint: ensure runtime-writable dirs exist on the mounted code, render nginx's config
# from its template (APP_HTTP_PORT is only known at runtime), then hand off to the CMD
# (supervisord). No config caching — config stays live for editing.
set -e
cd /var/www

mkdir -p storage/framework/cache storage/framework/sessions \
         storage/framework/views storage/logs bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true

envsubst '${APP_HTTP_PORT}' < /etc/nginx/http.d/default.conf.template > /etc/nginx/http.d/default.conf

exec "$@"
