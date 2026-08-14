#!/bin/sh
# `make info` — table of every registered container (services + apps), running or not. Same
# services/apps grouping and filter/group semantics as scripts/pick.sh, but read-only (no fzf,
# no action taken).
set -e

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

filter="${filter:-}"
group="${group:-}"

matches_filter() {
    [ -n "$filter" ] || return 0
    printf '%s' "$1" | grep -qi -- "$filter"
}

services_prefix=$(sed -n 's/^SERVICES_PREFIX=//p' .env 2>/dev/null | head -1)

# rows: slug<TAB>container_name<TAB>group
rows=""

if [ -z "$group" ] || [ "$group" = "services" ]; then
    for core in mariadb postgres redis rabbitmq; do
        matches_filter "$core" || continue
        rows="$rows
$core	${services_prefix}${core}	services"
    done
fi

for name in $(grep -oE '^[A-Z0-9_]+_PATH' .env 2>/dev/null | sed 's/_PATH$//'); do
    path=$(sed -n "s/^${name}_PATH=//p" .env)
    [ -n "$path" ] || continue
    docker_env="$path/deploy/.docker-env"
    slug=$(printf '%s' "$name" | tr 'A-Z_' 'a-z-')
    matches_filter "$slug" || continue
    [ -f "$docker_env" ] || continue

    is_base_service=false
    grep -q '^BASE_SERVICE=true' "$docker_env" && is_base_service=true
    # Container-name var differs by stack: PHP_CONTAINER (php/frankenphp) or APP_CONTAINER
    # (node) — see e.g. PhiPlanner/web vs tormenta_app/backend.
    container=$(sed -n 's/^PHP_CONTAINER=//p' "$docker_env" | head -1)
    [ -n "$container" ] || container=$(sed -n 's/^APP_CONTAINER=//p' "$docker_env" | head -1)
    [ -n "$container" ] || continue

    item_group="apps"
    [ "$is_base_service" = "true" ] && item_group="services"
    [ -z "$group" ] || [ "$group" = "$item_group" ] || continue

    rows="$rows
$slug	$container	$item_group"
done

rows=$(printf '%s\n' "$rows" | sed '/^$/d')

if [ -z "$rows" ]; then
    if [ -n "$filter" ]; then
        echo ">> no services/apps match '$filter'"
    else
        echo ">> nothing registered"
    fi
    exit 0
fi

printf '%-22s %-9s %-10s %-24s %-28s %s\n' "NAME" "GROUP" "STATUS" "CONTAINER" "IMAGE" "PORTS"
while IFS= read -r row; do
    [ -n "$row" ] || continue
    slug=$(printf '%s' "$row" | cut -f1)
    container=$(printf '%s' "$row" | cut -f2)
    item_group=$(printf '%s' "$row" | cut -f3)

    info=$(docker ps -a --filter "name=^${container}\$" --format '{{.Status}}	{{.Image}}	{{.Ports}}' | head -1)
    if [ -z "$info" ]; then
        status="not created"
        image="-"
        ports="-"
    else
        status=$(printf '%s' "$info" | cut -f1)
        image=$(printf '%s' "$info" | cut -f2)
        ports=$(printf '%s' "$info" | cut -f3)
        [ -n "$ports" ] || ports="-"
    fi
    printf '%-22s %-9s %-10s %-24s %-28s %s\n' "$slug" "$item_group" "$status" "$container" "$image" "$ports"
done <<EOF
$rows
EOF
