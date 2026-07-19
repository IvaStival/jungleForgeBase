#!/bin/sh
# Interactive picker for `make services-up`. Lists the static shared services
# (postgres/redis/rabbitmq, from docker-compose.services.yml) plus any registered project that
# opted in via `BASE_SERVICE=true` in its deploy/.docker-env (see CLAUDE.md), and starts
# whatever's selected. All items are pre-selected so Enter alone reproduces the old
# "bring everything up" behavior.
set -e

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v fzf >/dev/null 2>&1; then
    echo "ERROR: fzf is required for the interactive service picker. Install it with: brew install fzf" >&2
    exit 1
fi

items="postgres
redis
rabbitmq"

for name in $(grep -oE '^[A-Z0-9_]+_PATH' .env 2>/dev/null | sed 's/_PATH$//'); do
    path=$(sed -n "s/^${name}_PATH=//p" .env)
    [ -n "$path" ] || continue
    docker_env="$path/deploy/.docker-env"
    [ -f "$docker_env" ] || continue
    if grep -q '^BASE_SERVICE=true' "$docker_env"; then
        slug=$(printf '%s' "$name" | tr 'A-Z_' 'a-z-')
        items="$items
$slug"
    fi
done

selected=$(printf '%s\n' "$items" | fzf --multi --bind 'load:select-all,space:toggle' \
    --header 'Space: toggle  Enter: confirm bring-up  (all pre-selected)' \
    --prompt 'services-up> ' \
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
    echo ">> starting shared services:$core"
    # shellcheck disable=SC2086
    docker compose -p jungleforge-services -f docker-compose.services.yml up -d $core
fi

for project in $projects; do
    echo ">> starting project: $project"
    make up "$project" env="${env:-dev}"
done
