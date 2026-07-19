#!/bin/sh
# Dev entrypoint: install node_modules on first start (the anonymous /app/node_modules volume is
# empty until then), then hand off to the CMD (supervisord -> vite dev).
set -e
cd /app

if [ ! -d node_modules ] || [ -z "$(ls -A node_modules 2>/dev/null)" ]; then
    echo ">> installing node_modules (first run)…"
    npm ci --no-audit --no-fund || npm install --no-audit --no-fund
fi

exec "$@"
