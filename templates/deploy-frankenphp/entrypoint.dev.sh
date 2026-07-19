#!/bin/sh
# Dev entrypoint: ensure runtime-writable dirs exist on the mounted code, then hand off to the
# CMD (frankenphp run). No cache warming — config/cache stay live for editing. Code (including
# vendor/) is volume-mounted; run `composer install` on the host yourself before `make up`.
set -e
cd /app

mkdir -p var/cache var/log

exec "$@"
