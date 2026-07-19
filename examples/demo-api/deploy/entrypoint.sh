#!/bin/sh
# Production entrypoint: warm Laravel caches with the real runtime env (the project's .env
# is bind-mounted), then hand off to the CMD (supervisord). Runs artisan as www-data.
set -e
cd /var/www

su-exec www-data php artisan package:discover --ansi || true
su-exec www-data php artisan optimize

exec "$@"
