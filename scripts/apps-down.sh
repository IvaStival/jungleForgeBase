#!/bin/sh
# Interactive picker for `make apps-down`, symmetric to apps.sh. Lists only registered
# projects that are CURRENTLY RUNNING (any project, not just BASE_SERVICE=true ones — see
# services-down.sh for that narrower picker), pre-selected so Enter alone stops everything
# running. Stopped projects are omitted entirely.
set -e

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v fzf >/dev/null 2>&1; then
    echo "ERROR: fzf is required for the interactive service picker. Install it with: brew install fzf" >&2
    exit 1
fi

items=""
for name in $(grep -oE '^[A-Z0-9_]+_PATH' .env 2>/dev/null | sed 's/_PATH$//'); do
    path=$(sed -n "s/^${name}_PATH=//p" .env)
    [ -n "$path" ] || continue
    docker_env="$path/deploy/.docker-env"
    [ -f "$docker_env" ] || continue

    # Container-name var differs by stack: PHP_CONTAINER (php/frankenphp stacks) or
    # APP_CONTAINER (node stacks) — see templates/deploy/.docker-env.example vs
    # templates/deploy-node/.docker-env.example.
    container=$(sed -n 's/^PHP_CONTAINER=//p' "$docker_env" | head -1)
    [ -n "$container" ] || container=$(sed -n 's/^APP_CONTAINER=//p' "$docker_env" | head -1)
    [ -n "$container" ] || continue

    if [ -n "$(docker ps --filter "name=^${container}\$" --filter status=running -q)" ]; then
        slug=$(printf '%s' "$name" | tr 'A-Z_' 'a-z-')
        items="$items
$slug"
    fi
done
items=$(printf '%s\n' "$items" | sed '/^$/d')

if [ -z "$items" ]; then
    echo ">> nothing currently running"
    exit 0
fi

selected=$(printf '%s\n' "$items" | fzf --multi --bind 'load:select-all,space:toggle' \
    --header 'Space: toggle  Enter: confirm bring-down  (all pre-selected)' \
    --prompt 'apps-down> ' \
    --height='~40%' --layout=reverse --border=rounded) || true

if [ -z "$selected" ]; then
    echo ">> nothing selected"
    exit 0
fi

while IFS= read -r project; do
    [ -n "$project" ] || continue
    echo ">> stopping project: $project"
    make down "$project" env="${env:-dev}"
done <<EOF
$selected
EOF
