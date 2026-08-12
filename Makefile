# JungleForge control plane.
#
# Shared backing services (postgres + redis + rabbitmq) — run once:
#   make services-up | services-down | services-logs
#
# Per-project (project name = the word after the target; env=dev is the default):
#   make build|up|down|restart|logs|sh|ps|migrate <project> [env=prod]
# e.g.
#   make up fantastica            # dev
#   make up fantastica env=prod   # prod

-include .env

env ?= dev
force ?= false

# Prefix for the shared services' compose project + container names (jf-services,
# jf-postgres, ...). Override in .env if running more than one instance of this
# control plane on the same host, to avoid colliding container/project names.
SERVICES_PREFIX ?= jf

SERVICES := docker compose -p $(SERVICES_PREFIX)-services -f docker-compose.services.yml

# Shared external network every project + the backing services attach to (see comment at
# APP_HOST). Declared `external: true` in every compose file, so Docker won't auto-create it —
# the `network` target (and the silent `ensure-network` prereq) create it on a fresh host.
NETWORK := lion-network

# Project name = second word on the command line (`make up fantastica` -> fantastica)
PROJECT := $(word 2,$(MAKECMDGOALS))

# Registry lookup: fantastica -> FANTASTICA_PATH ; my-app -> MY_APP_PATH
PREFIX       := $(shell printf '%s' '$(PROJECT)' | tr 'a-z-' 'A-Z_')
PROJECT_PATH := $($(PREFIX)_PATH)
DEPLOY       := $(PROJECT_PATH)/deploy

# Stack discriminator: read STACK from the project's .docker-env (php default). Selects which
# Dockerfile + compose files drive the project — `node` for Vite/Node frontends, `frankenphp`
# for FrankenPHP-served PHP apps (e.g. Symfony), else PHP/Laravel (nginx + php-fpm).
STACK := $(strip $(shell sed -n 's/^STACK=//p' $(DEPLOY)/.docker-env 2>/dev/null | awk '{print $$1}'))
STACK := $(or $(STACK),php)

COMPOSE_FILE := docker-compose.$(env).yml
ifeq ($(STACK),node)
COMPOSE_FILE := docker-compose.node.$(env).yml
endif
ifeq ($(STACK),frankenphp)
COMPOSE_FILE := docker-compose.frankenphp.$(env).yml
endif

# Migration command: project override (deploy/.docker-env MIGRATE_CMD=...) else a stack default
# (artisan for php/node-fronted Laravel APIs; the Doctrine-backed bootstrap command for
# frankenphp/Symfony projects — override with e.g. `php bin/console app:db:setup`).
MIGRATE_CMD := $(strip $(shell sed -n 's/^MIGRATE_CMD=//p' $(DEPLOY)/.docker-env 2>/dev/null))
ifeq ($(MIGRATE_CMD),)
MIGRATE_CMD := php artisan migrate --force
ifeq ($(STACK),frankenphp)
MIGRATE_CMD := php bin/console app:db:setup
endif
endif

# Shared base image version this project's DEV build needs (php/node stacks only — frankenphp
# has no local base, see ensure-base) — read from the project's own .docker-env, the same var
# docker compose interpolates for the build arg. Defaults mirror base/base-node's own defaults.
PROJECT_PHP_VERSION  := $(strip $(shell sed -n 's/^PHP_VERSION=//p' $(DEPLOY)/.docker-env 2>/dev/null | awk '{print $$1}'))
PROJECT_PHP_VERSION  := $(or $(PROJECT_PHP_VERSION),8.4)
PROJECT_NODE_VERSION := $(strip $(shell sed -n 's/^NODE_VERSION=//p' $(DEPLOY)/.docker-env 2>/dev/null | awk '{print $$1}'))
PROJECT_NODE_VERSION := $(or $(PROJECT_NODE_VERSION),20)

# php config: project override (deploy/php/<file>) else jungleforge default (defaults/php/<file>)
PHP_INI     := $(or $(wildcard $(DEPLOY)/php/php.ini),$(CURDIR)/defaults/php/php.ini)
PHP_DEV_INI := $(or $(wildcard $(DEPLOY)/php/php.dev.ini),$(CURDIR)/defaults/php/php.dev.ini)
OPCACHE_INI := $(or $(wildcard $(DEPLOY)/php/opcache.ini),$(CURDIR)/defaults/php/opcache.ini)
FPM_POOL    := $(or $(wildcard $(DEPLOY)/php/www.conf),$(CURDIR)/defaults/php/www.conf)

# Cross-arch build flag (used by `push`): arch=armv7 builds single-arch ARM v7 and also
# applies sed deltas to defaults/php/* (auto-reverted on exit via trap). Default empty =
# multi-arch build using TARGET_PLATFORMS from .env.
arch ?=
arch_platforms = $(if $(filter armv7,$(arch)),linux/arm/v7,$(TARGET_PLATFORMS))

# Shared base image version: 2nd word on the line, default 8.4 (`make base` | `make base 8.3`).
BASE_VERSION := $(or $(word 2,$(MAKECMDGOALS)),8.4)

# Shared Node base version: 2nd word on the line, default 20 (`make base-node` | `make base-node 22`).
NODE_BASE_VERSION := $(or $(word 2,$(MAKECMDGOALS)),20)

# All projects share the external lion-network; each container gets a DNS alias = its project
# name, so one project reaches another at http://<project>:8080 (the in-container nginx port —
# inter-project traffic does NOT use the host-published port). APP_HOST feeds that alias.
# The host-published port (APP_HTTP_PORT) is set per project in its own deploy/.docker-env.
export APP_HOST := $(PROJECT)

# THE one common project Dockerfile (php), or its Node/FrankenPHP counterpart, chosen by STACK.
# compose points build.dockerfile here (outside the project build context) so projects don't
# each carry their own — they keep only their deploy/ config.
APP_DOCKERFILE := $(CURDIR)/build/Dockerfile
ifeq ($(STACK),node)
APP_DOCKERFILE := $(CURDIR)/build/node.Dockerfile
endif
ifeq ($(STACK),frankenphp)
APP_DOCKERFILE := $(CURDIR)/build/frankenphp.Dockerfile
endif
export APP_DOCKERFILE

# Exported so docker compose / docker buildx bake can interpolate them. Node projects' vars
# (NODE_VERSION, IMAGE_NAME, APP_CONTAINER, VITE_BACKEND_URL) come from the project's .docker-env
# via compose --env-file — NOT exported here, so an empty make value never shadows the file.
# jungleforge repo root — exposed to prod builds as the `jungleforge` named build context so the
# shared Dockerfile can COPY base/zsh/* (that repo is outside the project build context).
export PHPDOCKER_ROOT := $(CURDIR)

export PROJECT_PATH PHP_INI PHP_DEV_INI OPCACHE_INI FPM_POOL REGISTRY TARGET_PLATFORMS

COMPOSE = docker compose -p $(PROJECT) --env-file $(DEPLOY)/.docker-env -f $(COMPOSE_FILE)

.DEFAULT_GOAL := help
.PHONY: help guard network ensure-network ensure-base base base-node services-up services-down services-logs \
        apps apps-down \
        build up down restart logs sh ps migrate \
        push pull apply-arch revert-arch

help:
	@echo "JungleForge — central control plane"
	@echo ""
	@echo "  Shared base images (build once; project DEV builds reuse them):"
	@echo "    make base                                   build jungleforge/php:8.4-{fpm,dev}"
	@echo "    make base 8.3                               build for a specific PHP version"
	@echo "    make base force=true                        rebuild without cache"
	@echo "    make base-node                              build jungleforge/node:20-{prod,dev} (Vite/Node projects)"
	@echo "    make base-node 22                           build for a specific Node version"
	@echo "    make base-node force=true                   rebuild without cache"
	@echo ""
	@echo "  Shared network + services (run once on a fresh host):"
	@echo "    make network                                create the external lion-network if missing"
	@echo "    make services-up                            interactive fzf checklist (postgres/redis/rabbitmq"
	@echo "                                                 + any project with BASE_SERVICE=true), pre-checked"
	@echo "    make services-down                          same checklist, but only what's currently running"
	@echo "    make services-logs"
	@echo ""
	@echo "  Per-project (env=dev default; env=prod for production):"
	@echo "    make apps                                   interactive fzf checklist of every registered"
	@echo "                                                 project (shows running/stopped), none pre-checked"
	@echo "    make apps-down                               same idea, reversed — only currently-running"
	@echo "                                                 projects, pre-checked"
	@echo "    make build|up|down|restart|logs|sh|ps|migrate <project> [env=prod]"
	@echo "    (php/node/frankenphp is auto-selected from the project's .docker-env STACK;"
	@echo "     migrate runs a stack default, or MIGRATE_CMD from .docker-env if set;"
	@echo "     build/up auto-build the shared base first if it's missing, dev only)"
	@echo ""
	@echo "  Cross-arch build + push (requires REGISTRY in .env; uses 'docker buildx bake'):"
	@echo "    make push <project> env=prod                multi-arch (TARGET_PLATFORMS)"
	@echo "    make push <project> env=prod arch=armv7     single-arch armv7 + sed deltas (auto-reverted)"
	@echo "    make pull <project> env=prod                pull matching arch on the target host"
	@echo ""
	@echo "  Per-host arch tuning (persistent — no auto-revert):"
	@echo "    make apply-arch arch=armv7                  apply sed deltas to defaults/php/*"
	@echo "    make revert-arch arch=armv7                 git restore defaults/php/"
	@echo ""
	@echo "Registered projects:"
	@grep -oE '^[A-Z0-9_]+_PATH' .env 2>/dev/null | sed 's/_PATH$$//' | tr 'A-Z_' 'a-z-' | sed 's/^/  - /' || true

guard:
	@if [ -z "$(PROJECT)" ]; then echo "ERROR: name a project, e.g. 'make $(firstword $(MAKECMDGOALS)) fantastica'"; exit 1; fi
	@if [ -z "$(PROJECT_PATH)" ]; then echo "ERROR: $(PREFIX)_PATH is not set in .env (unknown project '$(PROJECT)')"; exit 1; fi
	@if [ "$(env)" != "dev" ] && [ "$(env)" != "prod" ]; then echo "ERROR: env must be 'dev' or 'prod' (got '$(env)')"; exit 1; fi
	@if [ ! -f "$(DEPLOY)/.docker-env" ]; then echo "ERROR: missing $(DEPLOY)/.docker-env"; exit 1; fi

# Build the shared base images ONCE (project DEV builds FROM jungleforge/php:<v>-dev).
# Re-run when you bump PHP versions or want fresh extensions. Default version 8.4.
base:
	docker build $(if $(filter true,$(force)),--no-cache) -f base/Dockerfile --target fpm --build-arg PHP_VERSION=$(BASE_VERSION) -t jungleforge/php:$(BASE_VERSION)-fpm .
	docker build $(if $(filter true,$(force)),--no-cache) -f base/Dockerfile --target dev --build-arg PHP_VERSION=$(BASE_VERSION) -t jungleforge/php:$(BASE_VERSION)-dev .
	@echo ">> built jungleforge/php:$(BASE_VERSION)-fpm and jungleforge/php:$(BASE_VERSION)-dev"

# Build the shared Node base images ONCE (frontend project DEV builds FROM jungleforge/node:<v>-dev).
# Re-run when you bump the Node major version. Default version 20.
base-node:
	docker build $(if $(filter true,$(force)),--no-cache) -f base/node.Dockerfile --target prod --build-arg NODE_VERSION=$(NODE_BASE_VERSION) -t jungleforge/node:$(NODE_BASE_VERSION)-prod .
	docker build $(if $(filter true,$(force)),--no-cache) -f base/node.Dockerfile --target dev  --build-arg NODE_VERSION=$(NODE_BASE_VERSION) -t jungleforge/node:$(NODE_BASE_VERSION)-dev .
	@echo ">> built jungleforge/node:$(NODE_BASE_VERSION)-prod and jungleforge/node:$(NODE_BASE_VERSION)-dev"

# Create the shared external lion-network if it doesn't exist (idempotent, verbose).
network:
	@if docker network inspect $(NETWORK) >/dev/null 2>&1; then \
	   echo ">> network $(NETWORK) already exists"; \
	 else \
	   docker network create $(NETWORK) >/dev/null && echo ">> created network $(NETWORK)"; \
	 fi

# Silent ensure-the-network-exists prerequisite, run before anything attaches to it.
ensure-network:
	@docker network inspect $(NETWORK) >/dev/null 2>&1 || \
	 { docker network create $(NETWORK) >/dev/null && echo ">> created network $(NETWORK)"; }

# DEV builds FROM the shared jungleforge/php|node base — build it first if missing, so a
# freshly-registered project doesn't just fail with a bare "pull access denied". No-op for
# env=prod (self-compiles) and STACK=frankenphp (bases FROM the public dunglas/frankenphp image
# directly, no local base to check).
ensure-base:
	@if [ "$(env)" != "dev" ]; then exit 0; fi
	@case "$(STACK)" in \
	   php) \
	     if ! docker image inspect jungleforge/php:$(PROJECT_PHP_VERSION)-dev >/dev/null 2>&1; then \
	       echo ">> jungleforge/php:$(PROJECT_PHP_VERSION)-dev not built yet — building it first (make base $(PROJECT_PHP_VERSION))"; \
	       $(MAKE) --no-print-directory base BASE_VERSION=$(PROJECT_PHP_VERSION); \
	     fi ;; \
	   node) \
	     if ! docker image inspect jungleforge/node:$(PROJECT_NODE_VERSION)-dev >/dev/null 2>&1; then \
	       echo ">> jungleforge/node:$(PROJECT_NODE_VERSION)-dev not built yet — building it first (make base-node $(PROJECT_NODE_VERSION))"; \
	       $(MAKE) --no-print-directory base-node NODE_BASE_VERSION=$(PROJECT_NODE_VERSION); \
	     fi ;; \
	 esac

services-up: ensure-network
	@env=$(env) ./scripts/services-up.sh
services-down:
	@env=$(env) ./scripts/services-down.sh
services-logs:
	$(SERVICES) logs -f

# Interactive pickers over EVERY registered project (contrast with services-up/down, which are
# scoped to the core stack + BASE_SERVICE=true projects only). See scripts/apps*.sh.
apps: ensure-network
	@env=$(env) ./scripts/apps.sh
apps-down:
	@env=$(env) ./scripts/apps-down.sh

build: guard ensure-network ensure-base
	$(COMPOSE) build $(if $(filter true,$(force)),--no-cache)
up: guard ensure-network ensure-base
	$(COMPOSE) up -d
down: guard
	$(COMPOSE) down
restart: guard
	$(COMPOSE) restart
logs: guard
	$(COMPOSE) logs -f
sh: guard
	$(COMPOSE) exec app sh -c 'command -v zsh >/dev/null 2>&1 && exec zsh || exec sh'
ps: guard
	$(COMPOSE) ps
migrate: guard
	$(COMPOSE) run --rm app $(MIGRATE_CMD)

# Cross-arch build + push via docker buildx bake. Sources .docker-env so bake interpolates
# IMAGE_NAME / PHP_VERSION / etc. the same way `docker compose` does. If `arch=` is set,
# applies the matching sed deltas to defaults/php/* first and reverts via trap on exit
# (success, failure, or Ctrl-C). Requires REGISTRY in .env to actually publish.
push: guard
	@if [ -n "$(arch)" ]; then $(MAKE) --no-print-directory apply-arch arch=$(arch); fi
	@set -e; \
	 set -a; . $(DEPLOY)/.docker-env; set +a; \
	 trap '[ -n "$(arch)" ] && $(MAKE) --no-print-directory revert-arch arch=$(arch) >/dev/null 2>&1 || true' EXIT INT TERM; \
	 docker buildx bake -f $(COMPOSE_FILE) --set "*.platform=$(arch_platforms)" --push

# Pull the matching-arch image from the registry on the target host.
pull: guard
	$(COMPOSE) pull

# Apply arch-specific sed deltas to defaults/php/*. No-op if arch= is empty.
# `sed -i.bak` saves each original to <file>.bak alongside; revert-arch restores from those.
# Refuses to run if .bak snapshots already exist (would mean a previous apply wasn't reverted).
apply-arch:
	@if [ -z "$(arch)" ]; then exit 0; fi
	@if ls defaults/php/*.bak >/dev/null 2>&1; then \
	   echo "ERROR: snapshot files (.bak) already exist in defaults/php/ — refusing to clobber."; \
	   echo "       Run 'make revert-arch arch=$(arch)' first."; \
	   exit 1; \
	 fi
	@case "$(arch)" in \
	   armv7) \
	     echo ">> applying armv7 deltas to defaults/php/* (originals snapshotted to *.bak)"; \
	     sed -i.bak -E \
	       -e 's/^opcache\.jit *=.*/opcache.jit = off/' \
	       -e 's/^opcache\.jit_buffer_size *=.*/opcache.jit_buffer_size = 0/' \
	       -e 's/^opcache\.memory_consumption *=.*/opcache.memory_consumption = 48/' \
	       -e 's/^opcache\.max_accelerated_files *=.*/opcache.max_accelerated_files = 4000/' \
	       defaults/php/opcache.ini; \
	     sed -i.bak -E \
	       -e 's/^pm\.max_children *=.*/pm.max_children = 2/' \
	       -e 's/^pm\.start_servers *=.*/pm.start_servers = 1/' \
	       -e 's/^pm\.min_spare_servers *=.*/pm.min_spare_servers = 1/' \
	       -e 's/^pm\.max_spare_servers *=.*/pm.max_spare_servers = 2/' \
	       defaults/php/www.conf; \
	     sed -i.bak -E \
	       -e 's/^memory_limit *=.*/memory_limit = 128M/' \
	       defaults/php/php.ini; \
	     ;; \
	   *) echo "ERROR: unknown arch '$(arch)' (supported: armv7)"; exit 1 ;; \
	 esac

# Restore defaults/php/ from .bak snapshots created by apply-arch (no-op if arch= empty
# or no snapshots present).
revert-arch:
	@if [ -z "$(arch)" ]; then exit 0; fi
	@found=0; for f in defaults/php/*.bak; do \
	   [ -e "$$f" ] || continue; \
	   mv "$$f" "$${f%.bak}"; \
	   echo ">> restored $${f%.bak}"; \
	   found=1; \
	 done; \
	 if [ "$$found" = "0" ]; then echo ">> no .bak snapshots to restore"; fi

# Swallow the project-name word so make doesn't try to build it as a target.
%:
	@:
