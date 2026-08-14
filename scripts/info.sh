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

# rows: group<TAB>slug<TAB>container_name
rows=""

if [ -z "$group" ] || [ "$group" = "services" ]; then
    for core in mariadb postgres redis rabbitmq; do
        matches_filter "$core" || continue
        rows="$rows
services	$core	${services_prefix}${core}"
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
$item_group	$slug	$container"
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

# Enrich each row with status/image/published-ports, still tab-separated, then hand the whole
# table to awk for two-pass column-width computation + colored rendering (color is wrapped
# around each field AFTER padding so escape codes never throw off alignment).
enriched=""
while IFS= read -r row; do
    [ -n "$row" ] || continue
    item_group=$(printf '%s' "$row" | cut -f1)
    slug=$(printf '%s' "$row" | cut -f2)
    container=$(printf '%s' "$row" | cut -f3)

    if docker inspect "$container" >/dev/null 2>&1; then
        status=$(docker ps -a --filter "name=^${container}\$" --format '{{.Status}}' | head -1)
        image=$(docker inspect "$container" --format '{{.Config.Image}}')
        ports=$(docker inspect "$container" --format \
            '{{range $p, $c := .NetworkSettings.Ports}}{{if $c}}{{(index $c 0).HostPort}}->{{$p}} {{end}}{{end}}' \
            | sed -E 's#/tcp##g; s/ $//')
        [ -n "$ports" ] || ports="-"
    else
        status="not created"
        image="-"
        ports="-"
    fi

    enriched="$enriched
$item_group	$slug	$status	$image	$ports"
done <<EOF
$rows
EOF
enriched=$(printf '%s\n' "$enriched" | sed '/^$/d')

printf '%s\n' "$enriched" | awk -F'\t' '
{
    grp[NR] = $1; name[NR] = $2; status[NR] = $3; image[NR] = $4; ports[NR] = $5
    if (length($2) > wname)   wname   = length($2)
    if (length($3) > wstatus) wstatus = length($3)
    if (length($4) > wimage)  wimage  = length($4)
    n = NR
}
END {
    if (wname   < 4) wname   = 4
    if (wstatus < 6) wstatus = 6
    if (wimage  < 5) wimage  = 5
    lastgrp = ""
    for (i = 1; i <= n; i++) {
        if (grp[i] != lastgrp) {
            if (lastgrp != "") printf "\n"
            hdr = toupper(substr(grp[i],1,1)) substr(grp[i],2)
            printf "\033[1m%s\033[0m\n", hdr
            lastgrp = grp[i]
        }
        color = (status[i] ~ /^Up/) ? "32" : "90"
        pad = wstatus - length(status[i])
        printf "  %-*s  \033[%sm%s\033[0m%*s  %-*s  %s\n", \
            wname, name[i], color, status[i], pad, "", wimage, image[i], ports[i]
    }
}'
