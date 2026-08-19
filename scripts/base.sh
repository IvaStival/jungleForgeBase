#!/bin/sh
# Interactive picker for `make base`. Lists stack:version combos this control plane can build
# as shared base images (php/node — frankenphp has no local base, it runs FROM the official
# dunglas/frankenphp image) and builds whatever's selected. Nothing pre-selected: unlike
# services-up.sh's "cheap to act on all of it", building every version variant here is wasteful,
# so you opt in — the default versions are just marked for convenience. `force=true` (forwarded
# via the Makefile's `base` target) rebuilds whatever's selected without cache. For a version
# not listed, skip the picker and call `make base-php <version>` / `make base-node <version>`
# directly (also accepts `force=true`).
set -e

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v fzf >/dev/null 2>&1; then
    echo "ERROR: fzf is required for the interactive base picker. Install it with: brew install fzf" >&2
    exit 1
fi

items="php:8.4  (default)
php:8.3
php:8.2
node:20  (default)
node:22
node:18"

selected=$(printf '%s\n' "$items" | fzf --multi --bind 'space:toggle' \
    --header 'Space: toggle  Enter: confirm build  (nothing pre-selected)' \
    --prompt 'base> ' \
    --height='~40%' --layout=reverse --border=rounded) || true

if [ -z "$selected" ]; then
    echo ">> nothing selected"
    exit 0
fi

while IFS= read -r line; do
    [ -n "$line" ] || continue
    stack=$(printf '%s' "$line" | cut -d: -f1)
    version=$(printf '%s' "$line" | cut -d: -f2 | awk '{print $1}')
    case "$stack" in
        php)  echo ">> building php base $version"; make base-php "$version" force="${force:-false}" ;;
        node) echo ">> building node base $version"; make base-node "$version" force="${force:-false}" ;;
    esac
done <<EOF
$selected
EOF
