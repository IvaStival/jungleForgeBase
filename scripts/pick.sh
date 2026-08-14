#!/bin/sh
# Unified interactive picker for `make build`/`make up`/`make down`. Lists two groups —
# "services" (mariadb/postgres/redis/rabbitmq + any project with BASE_SERVICE=true) and "apps" (every
# other registered project) — each annotated with live running/stopped status. Enter toggles the
# highlighted row and advances to the next one; the pinned "Continue" row at the bottom is what you
# land on and press Enter on to actually execute against everything toggled. ctrl-a selects
# everything currently listed.
#
# Inputs (env vars, set by the Makefile): verb (build|up|down), env, force, filter (optional
# positional project-name substring), group (services|apps|empty=both).
set -e

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

verb="${verb:?pick.sh requires verb=build|up|down}"
env="${env:-dev}"
force="${force:-false}"
filter="${filter:-}"
group="${group:-}"

if ! command -v fzf >/dev/null 2>&1; then
    echo "ERROR: fzf is required for the interactive picker. Install it with: brew install fzf" >&2
    exit 1
fi

services_prefix=$(sed -n 's/^SERVICES_PREFIX=//p' .env 2>/dev/null | head -1)
SERVICES_COMPOSE="docker compose -p ${services_prefix}services -f docker-compose.services.yml"

# Green for running, red for stopped — fzf renders these via --ansi. Color codes only wrap the
# status word, so `awk '{print $1}'` on a selected line always gets a clean slug.
colorize_status() {
    if [ "$1" = "running" ]; then
        printf '\033[32m%s\033[0m' "$1"
    else
        printf '\033[31m%s\033[0m' "$1"
    fi
}

status_for_container() {
    container="$1"
    [ -n "$container" ] || { echo "stopped"; return; }
    if [ -n "$(docker ps --filter "name=^${container}\$" --filter status=running -q)" ]; then
        echo "running"
    else
        echo "stopped"
    fi
}

matches_filter() {
    [ -n "$filter" ] || return 0
    printf '%s' "$1" | grep -qi -- "$filter"
}

services_items=""
apps_items=""

# Core services always listed, all three verbs — build simply has nothing to do for them
# (pulled images, no build step) and silently skips any that get selected there anyway.
for core in mariadb postgres redis rabbitmq; do
    matches_filter "$core" || continue
    status=$(status_for_container "${services_prefix}${core}")
    line=$(printf '%-24s %s' "$core" "$(colorize_status "$status")")
    services_items="$services_items
$line"
done

for name in $(grep -oE '^[A-Z0-9_]+_PATH' .env 2>/dev/null | sed 's/_PATH$//'); do
    path=$(sed -n "s/^${name}_PATH=//p" .env)
    [ -n "$path" ] || continue
    docker_env="$path/deploy/.docker-env"
    slug=$(printf '%s' "$name" | tr 'A-Z_' 'a-z-')
    matches_filter "$slug" || continue

    is_base_service=false
    container=""
    if [ -f "$docker_env" ]; then
        grep -q '^BASE_SERVICE=true' "$docker_env" && is_base_service=true
        # Container-name var differs by stack: PHP_CONTAINER (php/frankenphp) or APP_CONTAINER
        # (node) — see e.g. PhiPlanner/web vs tormenta_app/backend.
        container=$(sed -n 's/^PHP_CONTAINER=//p' "$docker_env" | head -1)
        [ -n "$container" ] || container=$(sed -n 's/^APP_CONTAINER=//p' "$docker_env" | head -1)
    fi

    status=$(status_for_container "$container")
    line=$(printf '%-24s %s' "$slug" "$(colorize_status "$status")")
    if [ "$is_base_service" = "true" ]; then
        services_items="$services_items
$line"
    else
        apps_items="$apps_items
$line"
    fi
done

[ -n "$group" ] && [ "$group" != "services" ] && services_items=""
[ -n "$group" ] && [ "$group" != "apps" ] && apps_items=""

services_items=$(printf '%s\n' "$services_items" | sed '/^$/d')
apps_items=$(printf '%s\n' "$apps_items" | sed '/^$/d')

if [ -z "$services_items" ] && [ -z "$apps_items" ]; then
    if [ -n "$filter" ]; then
        echo ">> no services/apps match '$filter'" >&2
    else
        echo ">> nothing to $verb" >&2
    fi
    exit 1
fi

HEADER_SERVICES="── services ──"
HEADER_APPS="── apps ──"
CONTINUE_LABEL=">>> Continue: $verb selected"

items=""
if [ -n "$services_items" ]; then
    items="$items
$HEADER_SERVICES
$services_items"
fi
if [ -n "$apps_items" ]; then
    items="$items
$HEADER_APPS
$apps_items"
fi
items="$items
$CONTINUE_LABEL"
items=$(printf '%s\n' "$items" | sed '/^$/d')

selected=$(printf '%s\n' "$items" | fzf --multi --ansi \
    --header "Enter: toggle + advance   land on \"Continue\" + Enter: execute   ctrl-a: select all" \
    --bind "enter:transform:case {} in \"$CONTINUE_LABEL\") echo accept ;; *) echo toggle+down ;; esac" \
    --bind 'ctrl-a:select-all' \
    --prompt "$verb> " \
    --height='~70%' --layout=reverse --border=rounded) || true

if [ -z "$selected" ]; then
    echo ">> nothing selected"
    exit 0
fi

core=""
projects=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
        "$CONTINUE_LABEL"|"$HEADER_SERVICES"|"$HEADER_APPS") continue ;;
    esac
    slug=$(printf '%s' "$line" | awk '{print $1}')
    case "$slug" in
        mariadb|postgres|redis|rabbitmq) core="$core $slug" ;;
        *) projects="$projects $slug" ;;
    esac
done <<EOF
$selected
EOF

if [ -n "$core" ]; then
    case "$verb" in
        up)
            echo ">> starting shared services:$core"
            # shellcheck disable=SC2086
            $SERVICES_COMPOSE up -d $core
            ;;
        down)
            # `stop`, not `down` — scoped to the selected services only. `down` operates on the
            # whole compose project regardless of arguments, which would tear down services you
            # didn't select.
            echo ">> stopping shared services:$core"
            # shellcheck disable=SC2086
            $SERVICES_COMPOSE stop $core
            ;;
    esac
fi

for project in $projects; do
    case "$verb" in
        build)
            echo ">> building project: $project"
            make _build "$project" env="$env" force="$force"
            ;;
        up)
            if [ "$force" = "true" ]; then
                echo ">> force rebuilding project: $project"
                make _build "$project" env="$env" force=true
            fi
            echo ">> starting project: $project"
            make _up "$project" env="$env"
            ;;
        down)
            echo ">> stopping project: $project"
            make _down "$project" env="$env"
            ;;
    esac
done
