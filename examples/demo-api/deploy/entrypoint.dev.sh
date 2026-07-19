#!/bin/sh
# Dev entrypoint: ensure runtime-writable dirs exist on the mounted code, then hand off to
# the CMD (supervisord). No config caching — config stays live for editing.
set -e
cd /var/www

mkdir -p storage/framework/cache storage/framework/sessions \
         storage/framework/views storage/logs bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true

exec "$@"
