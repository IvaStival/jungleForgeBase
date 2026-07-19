#!/bin/sh
# Prod entrypoint: the SPA is already built and node_modules baked into the image — nothing to
# prepare. Hand off to the CMD (supervisord -> vite preview).
set -e
cd /app
exec "$@"
