# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker control plane** for running many projects from one place, across three stacks: `php`
(nginx + php-fpm + Horizon + scheduler under supervisord, the default), `node` (Vite), and
`frankenphp` (FrankenPHP's bundled Caddy + PHP, e.g. Symfony). This repo holds no application
code — it is the Makefile + compose files + shared base images + config defaults + project
templates that drive *other* projects living elsewhere on disk. Each project runs as a
**single self-contained container**, in `dev` (code volume-mounted, Xdebug) or `prod`
(code/assets baked into the image). A single shared stack of MariaDB + Postgres + Redis + RabbitMQ backs
every project. See `docs/ADDING-A-STACK.md` for how the `STACK` discriminator works and what a
new stack needs.

## Common commands

```bash
make base                       # build shared jungleforge/php:8.4-{fpm,dev} base (once; `make base 8.3` for another version)
make base force=true            # rebuild the base without cache
make services-logs              # tail the shared mariadb/postgres/redis/rabbitmq stack

# Interactive picker — services (mariadb/postgres/redis/rabbitmq + BASE_SERVICE=true projects) and apps
# (everything else), running/stopped shown. Enter toggles + advances; land on the pinned
# "Continue" row and press Enter to execute; ctrl-a selects everything shown. env=dev default.
make up                         # picker: everything
make up fantastica               # picker: filtered to matches("fantastica")
make up group=services           # picker: services section only
make up force=true               # confirmed selections rebuild without cache first
make up fantastica env=prod      # picker still applies; env just changes what gets started
make build                      # same picker, verb=build (core services listed but no-op — no build step)
make down                       # same picker, verb=down (core services get `stop`, apps get real `down`)

# Per-project, unaffected by the picker — project name is the word after the target; env=dev default.
make restart|logs|ps|migrate <project> [env=prod]
make sh <project>               # shell into app container (zsh in dev, sh in prod)

# Multi-arch build & push (needs REGISTRY in .env; uses docker buildx bake)
make push <project> env=prod                # multi-arch via TARGET_PLATFORMS
make push <project> env=prod arch=armv7     # single-arch armv7 + low-mem PHP tuning (auto-reverted)
make pull <project> env=prod

make help                       # full help + list of registered projects
```

`make migrate` runs a stack default (`php artisan migrate --force` for php/node,
`php bin/console app:db:setup` for frankenphp) or `MIGRATE_CMD` from the project's
`deploy/.docker-env` if set. There is no test suite or linter in this repo (it ships
infrastructure, not code) — tests/lint belong to the individual projects.

## How the Makefile resolves a project

`make restart fantastica` → `PROJECT=fantastica` (2nd word of the goal) → looks up
`FANTASTICA_PATH` in `.env` (uppercased, dashes→underscores). That path's `deploy/` folder
supplies the per-project config, and `deploy/.docker-env` supplies orchestration vars
(`IMAGE_NAME`, `PHP_CONTAINER`, `PHP_VERSION`, `APP_HTTP_PORT`, etc.). The trailing `%: @:` rule
swallows the project-name word so make doesn't treat it as a target. `guard` validates the
project is registered, env is dev/prod, and `.docker-env` exists — used directly by
`restart`/`logs`/`sh`/`ps`/`migrate`/`push`/`pull`, and by `_build`/`_up`/`_down` (the internal
targets `scripts/pick.sh` calls once it's resolved an exact project from the picker). `build`/
`up`/`down` themselves don't call `guard` — the 2nd word is only a *filter* into the picker there
(see Common commands above), not necessarily an exact registered slug.

**To register a project:** add `<NAME>_PATH=/abs/path` to `.env`, and ensure the project has a
`deploy/` folder (scaffold from `templates/deploy/`, `-node`, or `-frankenphp`) + a
`.docker-env` with the right `STACK=`.

## Frontend (Node/Vite) projects

A project's `deploy/.docker-env` picks its stack via `STACK=php|node|frankenphp` — the Makefile
reads it and auto-selects the Dockerfile + compose files, so `make build|up|down <project>` is
identical across stacks. `STACK` unset ⇒ `php`.

- **Build the Node base once:** `make base-node` builds `jungleforge/node:20-{prod,dev}` (mirrors
  `make base`; `make base-node 22` for another major, `make base-node force=true` to rebuild
  without cache). Frontend DEV builds layer thinly FROM `jungleforge/node:20-dev`.
- **Register a frontend:** add `<NAME>_PATH=/abs/path` to `.env`, scaffold its `deploy/` from
  `templates/deploy-node/`, and set `STACK=node` (plus `NODE_VERSION`, `IMAGE_NAME`, `APP_CONTAINER`,
  `VITE_PORT`, `VITE_BACKEND_URL`) in `deploy/.docker-env`.
- **Dev:** vite dev server (HMR) under supervisord; code volume-mounted, `node_modules` installed on
  first start by `entrypoint.dev.sh` onto an anonymous volume. Published on host `VITE_PORT`.
- **Prod:** `vite build` then `vite preview` under supervisord, bound to `127.0.0.1:APP_HTTP_PORT`
  (front with the host's nginx, same as PHP prod). Public `VITE_*` vars are **build-time** — passed
  as build args from `.docker-env` so `vite build` inlines them.
- **API calls:** on `lion-network` the SPA reaches its backend container-to-container at
  `http://<backend>:<backend's own APP_HTTP_PORT>` (set `VITE_BACKEND_URL` to that; it's the vite
  proxy target in dev and the inlined origin in prod — the backend's in-container port matches
  its own `APP_HTTP_PORT`, not a fixed `8080`, unless it's a `frankenphp` backend, see below).
- `make migrate` is PHP-only (artisan) and does not apply to Node projects.

## FrankenPHP projects

`STACK=frankenphp` selects `build/frankenphp.Dockerfile` and `docker-compose.frankenphp.
{dev,prod}.yml`. No nginx/php-fpm split and no supervisord — a single `frankenphp run` process
serves the app on `:8080`, configured via the project's `deploy/Caddyfile` (mounted live in dev,
baked in prod). Scaffold from `templates/deploy-frankenphp/`. Composer deps are volume-mounted
in dev (run `composer install` on the host yourself) and baked into a builder stage in prod,
mirroring the php stack's `vendor`/`assets` convention.

## Architecture essentials

- **One container per project.** In the `php` stack, nginx serves `public/` and proxies PHP to
  php-fpm at `127.0.0.1:9000` *inside the same container*; supervisord keeps nginx + php-fpm
  (+ Horizon + scheduler) running. `frankenphp`-stack projects run one process instead (no
  supervisord); `node`-stack projects run Vite under supervisord.
- **In-container port matches the host-published `APP_HTTP_PORT`** (`php`; `node`'s dev/prod use
  `VITE_PORT`/`APP_HTTP_PORT` the same way) — not a fixed `8080` for every project. nginx's
  config is a template (`deploy/nginx/default.conf.template`, `listen ${APP_HTTP_PORT}`)
  rendered by the entrypoint at container start via `envsubst`, since the value is only known at
  runtime; node's supervisord command lines use their own native
  `%(ENV_VITE_PORT)s`/`%(ENV_APP_HTTP_PORT)s` interpolation instead, no envsubst needed there.
  **`frankenphp` keeps a fixed internal port** — its Caddyfile is hand-owned per project (no
  shared jungleforge template), so it isn't part of this templating.
- **Shared `lion-network` (external, name configurable via `NETWORK_NAME` in `.env`, default
  `lion-network`).** Every container is aliased to its project name, so projects call each other
  at `http://<project>:<that project's own APP_HTTP_PORT>` (the in-container port — never assume
  the host port, and never assume a fixed `8080`/`5173` either, except for `frankenphp` projects
  which still use their own hand-set port). `make network`/`ensure-network` create the network
  (under whatever `NETWORK_NAME` resolves to) if it doesn't exist.
- **`SERVICES_PREFIX` (empty by default, in `.env`)** prefixes `docker-compose.services.yml`'s
  compose project name and its mariadb/postgres/redis/rabbitmq container names — unset, they're just
  `services`/`postgres`/`redis`/`rabbitmq`. Only needs setting if running more than one instance
  of this control plane on the same host, and include your own trailing separator when you do
  (e.g. `SERVICES_PREFIX=myinstance-`).
- **Config resolution (in the Makefile):** for each of `php.ini`, `php.dev.ini`, `opcache.ini`,
  `www.conf` → use the project's `deploy/php/<file>` if present, else `defaults/php/<file>`. These
  are *mounted* (not baked) so they're editable without a rebuild. The php-stack nginx vhost and
  frankenphp's Caddyfile are baked into the image and also mounted live in dev.
- **dev reuses the base; prod self-compiles.** Dev (`target: dev`) is a thin layer `FROM
  jungleforge/php:<v>-dev` — no extension compiling, builds in seconds. Prod (`target: app`)
  compiles its own extension layer (`php-base` stage) so production images are portable for
  multi-arch push and don't depend on the locally-built base.
- **One `fzf` picker, two groups.** `make build`/`make up`/`make down` (`scripts/pick.sh`) all
  open the same picker: a **services** section (mariadb/postgres/redis/rabbitmq + any project opted in
  via `BASE_SERVICE=true` in its `deploy/.docker-env` — set that flag when a project is shared
  infra other projects depend on, e.g. a websocket bridge other projects reach over RabbitMQ, not
  a standalone app) and an **apps** section (every other registered project). The groups are a
  strict partition — a `BASE_SERVICE=true` project shows only under services, never both. Every
  row shows live running/stopped status. Nothing is pre-selected; Enter toggles the highlighted
  row and advances to the next one, and the pinned `>>> Continue: <verb> selected` row at the
  bottom is what you land on and press Enter on to actually execute (`ctrl-a` selects everything
  currently listed). The positional word (if any) filters by substring match against the slug;
  `group=services`/`group=apps` filters by section; both combine. All 4 core services are listed
  under every verb, including `verb=build` — selecting one there is a no-op (pulled images, no
  build step). `verb=down` runs `stop` (not `down`) on confirmed core
  services — scoped to just the ones selected, since `down` isn't — and a real `docker compose
  down` on confirmed apps. Requires `fzf` (`brew install fzf`); there is no non-fzf fallback.
  Confirmed selections are dispatched to the internal `_build`/`_up`/`_down` targets (per-project)
  or a direct `docker compose` call (core services) — don't call `_build`/`_up`/`_down` by hand,
  they skip the picker entirely and assume `guard` will resolve their argument to a real
  registered project.

## Key files

- `Makefile` — the entire control plane (path resolution, compose invocation, arch tuning).
- `build/Dockerfile` — THE one shared `php`-stack project image. Stages: `dev`, `vendor`
  (composer), `assets` (npm), `php-base` (prod extensions), `app` (prod runtime). Compose points
  `build.dockerfile` here while `build.context` stays the project root, so `COPY deploy/*` pulls
  each project's own config. Written to tolerate variation: missing `composer.lock`, API-only
  projects with no `package.json`.
- `base/Dockerfile` — the prebuilt dev base (`fpm` + `dev` targets). Its `fpm` extension list
  **must stay in sync** with `build/Dockerfile`'s `php-base` stage — update both when adding a
  PHP extension.
- `docker-compose.{dev,prod,services}.yml` — per-project dev, per-project prod, shared services.
  `docker-compose.yml` is the legacy single-project setup, kept for reference; the Makefile does
  not use it.
- `build/node.Dockerfile` — the Node/Vite counterpart of `build/Dockerfile`. Stages: `dev` (thin,
  FROM `jungleforge/node:<v>-dev`), `deps` (npm ci), `build` (`vite build`), `app` (prod: `vite
  preview` under supervisord).
- `base/node.Dockerfile` — prebuilt Node base (`prod` + `dev` targets); built by `make base-node`.
- `docker-compose.node.{dev,prod}.yml` — per-project dev/prod for Node projects (selected when
  `STACK=node`).
- `build/frankenphp.Dockerfile` — the FrankenPHP counterpart. Stages: `dev` (thin, FROM the
  official `dunglas/frankenphp` image), `vendor` (composer, prod only), `app` (prod runtime).
- `docker-compose.frankenphp.{dev,prod}.yml` — per-project dev/prod for FrankenPHP projects.
- `templates/deploy-node/` — drop-in scaffold for a Node project's `deploy/` (entrypoints,
  supervisor configs running vite, `.docker-env.example`).
- `templates/deploy-frankenphp/` — drop-in scaffold for a FrankenPHP project's `deploy/`
  (entrypoints, `Caddyfile`, `.docker-env.example`).
- `defaults/php/` — fallback php.ini / php.dev.ini / opcache.ini / www.conf.
- `templates/deploy/` — drop-in scaffold copied into a `php`-stack project's `deploy/`
  (entrypoints, nginx vhost, supervisor configs, `.docker-env.example`).
- `base/zsh/` — zsh config baked into both dev bases; edit then re-run `make base` / `make base-node`.
- `scripts/pick.sh` — the unified `fzf` picker behind `build`/`up`/`down` (see Architecture
  essentials above).
- `docs/ADDING-A-STACK.md` — how to add a 4th stack beyond php/node/frankenphp.
- `examples/demo-api/` — a runnable minimal project proving the whole loop works out of the box.

## Gotchas

- **`make build`/`make up` auto-build the shared base if it's missing** (dev env, php/node
  stacks only — prod self-compiles and frankenphp bases off the public `dunglas/frankenphp`
  image directly, so neither needs this). The version comes from the project's own
  `deploy/.docker-env` (`PHP_VERSION`/`NODE_VERSION`); on a hit it's a silent no-op, on a miss it
  prints `>> jungleforge/php:X-dev not built yet — building it first (make base X)` and runs the
  equivalent of `make base X`/`make base-node X` before continuing. This is what a fresh clone or
  a project pinning a not-yet-built version hits automatically — no need to remember to run
  `make base` by hand first. See `ensure-base` in the Makefile.
- **`arch=armv7` tuning** mutates `defaults/php/*` via `sed -i.bak`. `make push … arch=armv7`
  auto-reverts via an EXIT/INT/TERM trap; `apply-arch`/`revert-arch` are the persistent
  (no auto-revert) variants. `apply-arch` refuses to run if `.bak` snapshots already exist —
  run `revert-arch` first if it errors.
- **Horizon/scheduler are off by default in dev** (php stack only, so a fresh project doesn't
  crash-loop before `composer require laravel/horizon`). Enable inside the container:
  `make sh <project>` then `supervisorctl start horizon scheduler`.
- **Prod web servers bind `127.0.0.1` only** (php stack's nginx also trusts `X-Forwarded-For`)
  — front them with the host's system nginx/Caddy for TLS.
- A project's own `.env` must point at the shared services: `DB_HOST=postgres`,
  `REDIS_HOST=redis`, `RABBITMQ_HOST=rabbitmq` (adjust var names to your framework's convention).
