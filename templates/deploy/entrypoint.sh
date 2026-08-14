#!/bin/sh
# Production entrypoint: render nginx's config from its template (APP_HTTP_PORT is only known at
# runtime, not at image build time), warm Laravel caches with the real runtime env (the project's
# .env is bind-mounted), then hand off to the CMD (supervisord). Runs artisan as www-data.
set -e
cd /var/www

envsubst '${APP_HTTP_PORT}' < /etc/nginx/http.d/default.conf.template > /etc/nginx/http.d/default.conf

su-exec www-data php artisan package:discover --ansi || true
su-exec www-data php artisan optimize

exec "$@"
