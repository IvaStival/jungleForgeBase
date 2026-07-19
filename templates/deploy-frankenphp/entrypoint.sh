#!/bin/sh
# Production entrypoint: hand off to the CMD (frankenphp run). var/cache and var/log are
# already created and chowned at build time (see build/frankenphp.Dockerfile's app stage) —
# add cache-warming or migration commands here if your framework needs them before boot.
set -e
cd /app

exec "$@"
