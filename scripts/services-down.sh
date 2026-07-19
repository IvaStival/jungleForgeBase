#!/bin/sh
# Interactive teardown picker, symmetric to services-up.sh. Lists only what's CURRENTLY
# RUNNING among postgres/redis/rabbitmq and any project with BASE_SERVICE=true, pre-selected
# so Enter alone stops everything (matching the old unconditional `services-down` behavior).
# Stopped items are skipped entirely — nothing to select means nothing to do.
set -e

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v fzf >/dev/null 2>&1; then
    echo "ERROR: fzf is required for the interactive service picker. Install it with: brew install fzf" >&2
    exit 1
fi

items=$(docker compose -p jungleforge-services -f docker-compose.services.yml \
    ps --services --filter status=running 2>/dev/null) || items=""

for name in $(grep -oE '^[A-Z0-9_]+_PATH' .env 2>/dev/null | sed 's/_PATH$//'); do
    path=$(sed -n "s/^${name}_PATH=//p" .env)
    [ -n "$path" ] || continue
    docker_env="$path/deploy/.docker-env"
    [ -f "$docker_env" ] || continue
    grep -q '^BASE_SERVICE=true' "$docker_env" || continue
    container=$(sed -n 's/^PHP_CONTAINER=//p' "$docker_env" | head -1)
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
    --prompt 'services-down> ' \
    --height='~40%' --layout=reverse --border=rounded) || true

if [ -z "$selected" ]; then
    echo ">> nothing selected"
    exit 0
fi

core=""
projects=""
while IFS= read -r item; do
    [ -n "$item" ] || continue
    case "$item" in
        postgres|redis|rabbitmq) core="$core $item" ;;
        *) projects="$projects $item" ;;
    esac
done <<EOF
$selected
EOF

if [ -n "$core" ]; then
    echo ">> stopping shared services:$core"
    # `stop`, not `down` — scoped to the selected services only. `down` operates on the whole
    # compose project regardless of arguments, which would tear down services you didn't select.
    # shellcheck disable=SC2086
    docker compose -p jungleforge-services -f docker-compose.services.yml stop $core
fi

for project in $projects; do
    echo ">> stopping project: $project"
    make down "$project" env="${env:-dev}"
done
