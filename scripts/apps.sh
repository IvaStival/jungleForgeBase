#!/bin/sh
# Interactive picker for `make apps`. Lists EVERY project registered in .env (not just
# BASE_SERVICE=true ones — see services-up.sh for that narrower picker), annotated with its
# live running/stopped status, and runs `make up` on whatever's selected. Nothing is
# pre-selected: bringing up every registered app at once is expensive, so you opt in.
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
    slug=$(printf '%s' "$name" | tr 'A-Z_' 'a-z-')

    status="stopped"
    if [ -f "$docker_env" ]; then
        # Container-name var differs by stack: PHP_CONTAINER (php/frankenphp stacks) or
        # APP_CONTAINER (node stacks) — see templates/deploy/.docker-env.example vs
        # templates/deploy-node/.docker-env.example.
        container=$(sed -n 's/^PHP_CONTAINER=//p' "$docker_env" | head -1)
        [ -n "$container" ] || container=$(sed -n 's/^APP_CONTAINER=//p' "$docker_env" | head -1)
        if [ -n "$container" ] && [ -n "$(docker ps --filter "name=^${container}\$" --filter status=running -q)" ]; then
            status="running"
        fi
    fi

    # Green for running, red for stopped — fzf renders these via --ansi below. The color codes
    # only wrap the status word, so the awk-based slug extraction on selection is unaffected.
    if [ "$status" = "running" ]; then
        status_colored=$(printf '\033[32m%s\033[0m' "$status")
    else
        status_colored=$(printf '\033[31m%s\033[0m' "$status")
    fi
    line=$(printf '%-20s %s' "$slug" "$status_colored")
    items="$items
$line"
done
items=$(printf '%s\n' "$items" | sed '/^$/d')

if [ -z "$items" ]; then
    echo ">> no projects registered in .env"
    exit 0
fi

selected=$(printf '%s\n' "$items" | fzf --multi --ansi --bind 'space:toggle' \
    --header 'Space: toggle  Enter: confirm bring-up  (nothing pre-selected)' \
    --prompt 'apps> ' \
    --height='~40%' --layout=reverse --border=rounded) || true

if [ -z "$selected" ]; then
    echo ">> nothing selected"
    exit 0
fi

while IFS= read -r line; do
    [ -n "$line" ] || continue
    project=$(printf '%s' "$line" | awk '{print $1}')
    echo ">> starting project: $project"
    make up "$project" env="${env:-dev}"
done <<EOF
$selected
EOF
