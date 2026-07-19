# jungleforgebase

A small **Docker control plane** for running many backend + frontend projects from one place —
PHP/Laravel (nginx + php-fpm), FrankenPHP (e.g. Symfony), and Node/Vite, side by side, sharing
one Postgres + Redis + RabbitMQ stack.

One `make` command spins up any registered project as a **single self-contained container** in
**dev** (live, volume-mounted code + Xdebug) or **prod** (code & assets baked into the image).
PHP config falls back to sensible defaults but can be overridden per project, and prod images
can be built and pushed **multi-arch** (amd64 / arm64 / armv7).

This repo is the **engine only** — it holds no application code. You consume it by forking,
registering your own projects (each living elsewhere on disk), and periodically pulling engine
updates from this upstream. See [Consuming this repo](#consuming-this-repo) below.

---

## Features

- **Central registry, one command per project** — register a project once (`<NAME>_PATH` in
  `.env`) and drive it with `make up <project>`, `make build <project>`, `make sh <project>`,
  etc. No per-project compose files to maintain.
- **Three built-in stacks** — `php` (nginx + php-fpm + supervisord, the default), `node`
  (Vite dev server in dev, built + served in prod), and `frankenphp` (Symfony or any PHP app
  served directly by FrankenPHP's bundled Caddy, no nginx/php-fpm split). A project opts in via
  `STACK=` in its `deploy/.docker-env`. See [docs/ADDING-A-STACK.md](docs/ADDING-A-STACK.md) to
  add a 5th.
- **Prebuilt shared base image** — `make base` compiles the PHP extension layer **once** into
  `jungleforge/php:<v>-fpm` / `jungleforge/php:<v>-dev`. Every project's **dev** build then just
  `FROM`s it and layers config, so a freshly-registered project comes up in **seconds** instead
  of recompiling gd/intl/redis/xdebug each time. Prod builds stay self-contained (see below).
- **One self-contained container per project** — nginx and php-fpm (or FrankenPHP alone) live
  in the **same** image; no separate nginx container, no project-scoped network — just `app`.
- **Shared network for inter-project calls** — every project joins the external `lion-network`
  and gets a DNS alias equal to its name, so projects call each other at `http://<project>:8080`
  (the in-container port). Each project's **host** port (`APP_HTTP_PORT`) is set in its own
  `deploy/.docker-env` — give each a distinct value so they don't collide on the host.
- **Dev / prod from the same Dockerfile** — the shared `build/Dockerfile` (or its `node.`/
  `frankenphp.` counterpart) builds a `dev` target (volume-mounted code, Xdebug, composer, node)
  or an `app` target (code and built assets baked in), selected automatically by `env=dev`
  (default) or `env=prod`.
- **Shared backing services** — Postgres, Redis and RabbitMQ run **once** as
  `jungleforge-services` and every project reaches them by hostname (`postgres`, `redis`,
  `rabbitmq`) over the external `lion-network`. Healthchecks and persistent volumes included.
- **Interactive service picker** — `make services-up`/`services-down` are `fzf` checklists
  scoped to postgres, redis, rabbitmq, plus any registered project marked as shared infra
  (`BASE_SERVICE=true` in its `deploy/.docker-env`, e.g. a websocket server other projects
  depend on). Everything is pre-selected, so pressing Enter reproduces the old
  "bring everything up" / "stop everything" behavior; deselect what you don't need.
- **Interactive app picker** — `make apps`/`apps-down` are the same idea for **every**
  registered project, not just shared infra. `apps` shows each project's live running/stopped
  status and starts with nothing pre-selected (bringing up every app at once is expensive);
  `apps-down` lists only what's currently running, pre-selected.
- **Layered PHP & nginx config** — `php.ini`, `opcache.ini` and the FPM pool (`www.conf`) are
  *mounted*, not baked. Each is resolved as **project override** (`deploy/php/<file>`) **else
  jungleforgebase default** (`defaults/php/<file>`). The nginx vhost (`deploy/nginx/default.conf`)
  is baked into the image and additionally mounted live in dev for editing without a rebuild.
- **Supervisor-managed runtime (php stack)** — one image runs nginx **and** php-fpm **plus**
  Laravel Horizon and the scheduler under `supervisord` (no separate worker containers). In dev,
  Horizon/scheduler are opt-in so a fresh project doesn't crash-loop before
  `composer require laravel/horizon`.
- **Multi-arch build & push** — `make push <project> env=prod` builds for
  `TARGET_PLATFORMS` via `docker buildx bake`. An `arch=armv7` mode applies low-memory PHP
  tuning deltas (JIT off, fewer FPM children, lower memory limit) for constrained hosts and
  auto-reverts them afterwards.
- **Prod is reverse-proxy ready** — each container's web server publishes on `127.0.0.1` only
  (php stack additionally trusts `X-Forwarded-For`), so you terminate TLS with the host's system
  nginx/Caddy and proxy to it.
- **One shared Dockerfile per stack, no per-project Dockerfile** — every project builds with
  jungleforgebase's shared `build/<stack>.Dockerfile`; compose points `build.dockerfile` at it
  while the build context stays the project root. A project's `deploy/` is just config (web
  server vhost/Caddyfile, supervisor, entrypoints, `.docker-env`) — nothing to keep in sync
  across projects.
- **Drop-in project templates** — `templates/deploy/`, `templates/deploy-node/`,
  `templates/deploy-frankenphp/` are everything a project on that stack needs; copy the matching
  one to the project's `deploy/` and fill in `.docker-env`.

---

## Architecture

```
                       ┌──────────────────────────────────────────┐
   make ... <project>  │  jungleforgebase (this repo) — control plane │
  ───────────────────► │                                           │
                       │  .env        project registry + creds     │
                       │  Makefile    resolves paths, runs compose │
                       │  defaults/   fallback php.ini/opcache/pool │
                       │  templates/  deploy/ scaffold per stack   │
                       └──────────────────────────────────────────┘
                                          │
                 ┌────────────────────────┼─────────────────────────┐
                 │                         │                         │
   ┌─────────────▼──────────────┐         │        ┌────────────────▼───────────┐
   │ project: fantastica        │         │        │ project: demo-api          │
   │  ONE container (supervisord)│        │        │  ONE container (supervisord)│
   │  ┌───────┐   ┌───────────┐ │         │        │  ┌───────┐   ┌───────────┐ │
   │  │ nginx │──►│  php-fpm   │ │         │        │  │ nginx │──►│  php-fpm   │ │
   │  └───────┘   │ + horizon  │ │         │        │  └───────┘   │ + horizon  │ │
   │   :8080      │ + scheduler│ │         │        │   :8080      │ + scheduler│ │
   │              └─────┬──────┘ │         │        │              └─────┬──────┘ │
   └────────────────────┼────────┘        │        └────────────────────┼────────┘
                        │                 │                             │
                        └─────────────────┴─────────────────────────────┘
                                          │  lion-network (external, shared)
                       ┌──────────────────▼──────────────────┐
                       │  jungleforge-services (run once)        │
                       │   postgres   redis   rabbitmq         │
                       └───────────────────────────────────────┘
```

Inside a `php`-stack project container, nginx (`:8080`) serves static files from `public/` and
proxies PHP requests to php-fpm on `127.0.0.1:9000`; supervisord keeps nginx, php-fpm, Horizon
and the scheduler running. A `frankenphp`-stack project instead runs a single `frankenphp`
process (Caddy + PHP) on `:8080`, configured via `deploy/Caddyfile` — no supervisord needed. A
`node`-stack project runs the Vite dev server (dev) or `vite preview` (prod) on `:8080`.

All projects share the external `lion-network` and each container is aliased to its project
name, so projects talk to **each other** at `http://<project>:8080` and to shared services at
`postgres` / `redis` / `rabbitmq`. The container port is always `8080`; only the **host**-
published port (`APP_HTTP_PORT`, set per project in `deploy/.docker-env`) must be unique per
project — inside the network, identical `8080` ports never collide because each container has
its own IP.

**Compose files**

| File                                              | Scope        | What it runs                                         |
| -------------------------------------------------- | ------------ | ----------------------------------------------------- |
| `docker-compose.services.yml`                     | global       | Shared Postgres + Redis + RabbitMQ on `lion-network`  |
| `docker-compose.dev.yml` / `.prod.yml`             | per project  | `php` stack — nginx + php-fpm                         |
| `docker-compose.node.dev.yml` / `.prod.yml`        | per project  | `node` stack — Vite                                   |
| `docker-compose.frankenphp.dev.yml` / `.prod.yml`  | per project  | `frankenphp` stack — FrankenPHP (Caddy + PHP)         |

**Per-project `deploy/` folder** (scaffolded from `templates/deploy*/`)

A project carries **no Dockerfile** — every project builds with jungleforgebase's shared
`build/<stack>.Dockerfile` (compose points `build.dockerfile` at it; the build context stays the
project root, so the `COPY deploy/*` lines pull each project's own config). A `php`-stack
project's `deploy/` looks like:

```
deploy/
├── .docker-env           # orchestration vars (image name, container name, host port APP_HTTP_PORT)
├── entrypoint.sh         # prod: artisan optimize, then hand off to supervisord
├── entrypoint.dev.sh     # dev: ensure writable storage dirs, then supervisord
├── nginx/default.conf    # serves public/, fastcgi to 127.0.0.1:9000 (same container)
├── supervisor/
│   ├── supervisord.conf      # prod: nginx + php-fpm + horizon + scheduler
│   └── supervisord.dev.conf  # dev:  nginx + php-fpm (horizon/scheduler opt-in)
└── php/                  # OPTIONAL overrides (php.ini, opcache.ini, www.conf)
```

A `frankenphp`-stack project's `deploy/` is simpler — `.docker-env`, `entrypoint.sh`,
`entrypoint.dev.sh`, `Caddyfile`, no supervisor/nginx config needed.

**Config resolution** (in the Makefile): for each of `php.ini`, `php.dev.ini`, `opcache.ini`,
`www.conf` → use `deploy/php/<file>` if it exists, otherwise `defaults/php/<file>`.

**Build strategy: dev reuses the base, prod self-compiles**

- **Dev** (`target: dev`) is a thin layer: `FROM jungleforge/php:<v>-dev` (built by `make base`,
  already has php + extensions + nginx + supervisor + xdebug + composer/node + a pre-configured
  zsh) then just COPYs the supervisor/nginx/entrypoint config. No compiling → builds in seconds.
- **Prod** (`target: app`) is **self-contained** — it compiles its own extension layer
  (`php-base` stage below) so production images don't depend on the locally-built base and stay
  portable for multi-arch `make push`.

**Shared Dockerfile stages** (`build/Dockerfile` — one file, every `php`-stack project)

- `dev` — `FROM` the prebuilt `jungleforge/php:<v>-dev` base; COPY config only.
- `vendor` — `composer install --no-dev` + optimized autoloader (runs on the build host's
  native arch even during cross-arch builds; `composer.lock` optional).
- `assets` — `npm ci`/`npm install` + `npm run build` (native; optional — API-only projects
  with no `package.json` no-op and just emit an empty `public/build`).
- `php-base` — PHP-FPM Alpine + extensions (`bcmath gd intl mbstring opcache pcntl pdo_pgsql
  pgsql sockets zip` + `redis`); the prod-only self-contained extension layer.
- `app` — prod runtime: baked vendor + built assets, plus **nginx** + supervisor; supervisord
  runs nginx + php-fpm + Horizon + scheduler. This is the only image shipped to production.

> The dev base (`base/Dockerfile`, `fpm` stage) mirrors the `php-base` extension list — keep the
> two in sync when adding extensions. The Dockerfile is written to tolerate project variation
> (missing lockfile, no frontend), so one file serves every `php`-stack project.

`build/node.Dockerfile` and `build/frankenphp.Dockerfile` follow the same dev-reuses-base /
prod-self-compiles shape for their own stacks — see
[docs/ADDING-A-STACK.md](docs/ADDING-A-STACK.md) for the full breakdown of what each stack needs.

---

## Consuming this repo

jungleforgebase is a **living upstream**, not a template you copy once. Fork it, then:

```bash
git remote add upstream https://github.com/<original-owner>/jungleforgebase.git
git pull upstream main    # whenever you want engine updates
```

This stays conflict-free because your fork only ever touches two things this repo doesn't ship:
your own gitignored `.env` (project registry + credentials) and your projects' own `deploy/`
folders, which live in *their* repos, not here. The engine (`Makefile`, Dockerfiles, compose
files, `defaults/`, `templates/`) is the only thing this repo tracks — pull updates whenever you
want them, with nothing of yours in the way.

---

## Quickstart

```bash
git clone <your-fork-url> jungleforgebase && cd jungleforgebase
cp .env.example .env
make base                                              # build the shared PHP base image (once)
make services-up                                       # postgres + redis + rabbitmq
echo 'DEMO_API_PATH='"$PWD"'/examples/demo-api' >> .env
make up demo-api                                       # build + start the included demo
curl localhost:8090/                                   # → confirms the whole loop works
```

`examples/demo-api` is a minimal Laravel app with its own `deploy/`, included so you can prove
the control plane works end-to-end before registering your own project. Once it's running, swap
it for your own: register your project's path in `.env`, scaffold its `deploy/` from
`templates/deploy/` (or `-node`/`-frankenphp`), and `make up <your-project>`.

---

## Usage

### Prerequisites

- Docker + Docker Compose v2 (`docker compose`), and `docker buildx` for multi-arch push.
- [`fzf`](https://github.com/junegunn/fzf) — drives the `make services-up`/`services-down`/
  `apps`/`apps-down` pickers (`brew install fzf`); there's no non-interactive fallback.
- Each project must contain a `deploy/` folder (copy the template matching its stack) and its
  own `.env` pointing at the shared services: `DB_HOST=postgres`, `REDIS_HOST=redis`,
  `RABBITMQ_HOST=rabbitmq` (php/frankenphp — adjust var names to your framework's convention).

### 1. One-time setup

```bash
cp .env.example .env          # then edit: register projects + set service credentials
make base                     # build the shared PHP base image (once; `make base 8.3` for 8.3)
make services-up              # interactive fzf checklist: postgres + redis + rabbitmq (+ any
                               # project with BASE_SERVICE=true), all pre-selected — Enter to start
```

`make base` produces `jungleforge/php:8.4-fpm` and `jungleforge/php:8.4-dev`; project **dev** builds
reuse them. Re-run it when you bump PHP versions or want fresh extensions. If a project pins a
different `PHP_VERSION` in its `deploy/.docker-env`, build that version too (`make base 8.3`).

Register a project by adding its absolute path to `.env` (name uppercased, dashes → underscores):

```dotenv
FANTASTICA_PATH=/Users/you/Projects/fantastica
DEMO_API_PATH=/Users/you/Projects/jungleforgebase/examples/demo-api
```

Each project's host port is set in its own `deploy/.docker-env` (`APP_HTTP_PORT`) — give each a
distinct value so they don't collide. Regardless of host port, projects reach **each other**
over the shared `lion-network` at `http://<project>:8080` (e.g. fantastica calls demo-api at
`http://demo-api:8080`).

`make help` lists every command and every registered project.

### 2. Scaffold a project

```bash
cp -r templates/deploy /path/to/fantastica/deploy        # or templates/deploy-node, templates/deploy-frankenphp
cp /path/to/fantastica/deploy/.docker-env.example /path/to/fantastica/deploy/.docker-env
# edit deploy/.docker-env: IMAGE_NAME, PHP_CONTAINER, PHP_VERSION, APP_HTTP_PORT (distinct per project)
```

Then register the project's path in jungleforgebase's `.env` (`FANTASTICA_PATH=...`).

### 3. Day-to-day (dev is the default `env`)

```bash
make up fantastica            # build if needed + start dev (code mounted, Xdebug on)
make logs fantastica          # tail logs
make sh fantastica            # shell into the app container (pre-configured zsh)
make migrate fantastica       # php artisan migrate --force
make ps fantastica            # container status
make restart fantastica
make down fantastica          # stop & remove this project's containers
```

App is reachable on the host at `http://localhost:<APP_HTTP_PORT>` (the project's
`deploy/.docker-env` value); from other projects on `lion-network` at `http://fantastica:8080`.
Vite/HMR on `VITE_PORT` (default `5173`); Xdebug connects back to your IDE on `9003`.

`make sh` opens a **pre-configured zsh** (oh-my-zsh + powerlevel10k + autosuggestions + syntax-
highlighting, with `a`/`art` → `php artisan` aliases) baked into the dev base — no setup wizard.
It lives only in the dev image; prod stays lean (`make sh … env=prod` falls back to `sh`). The
shell config is in `base/zsh/` — edit and re-run `make base` to change it.

Horizon and the scheduler are off by default in dev (php stack) — enable them inside the
container:

```bash
make sh fantastica
supervisorctl start horizon scheduler
```

### 4. Production

```bash
make build fantastica env=prod    # bake code + built assets into the image
make up    fantastica env=prod    # run the container (web server bound to 127.0.0.1:8080)
make migrate fantastica env=prod
```

Then point the host's system nginx/Caddy at `127.0.0.1:8080` and terminate TLS there.

### 5. Multi-arch build & push

Set `REGISTRY` (and optionally `TARGET_PLATFORMS`) in `.env`, then:

```bash
make push fantastica env=prod                 # multi-arch (TARGET_PLATFORMS) → registry
make push fantastica env=prod arch=armv7      # single-arch armv7 + low-mem PHP tuning (auto-reverted)
make pull fantastica env=prod                 # on the target host, pull the matching arch
```

To tune the **defaults** on a constrained host persistently (no auto-revert):

```bash
make apply-arch  arch=armv7       # apply low-mem deltas to defaults/php/*
make revert-arch arch=armv7       # restore them
```

### Shared services management

```bash
make services-up        # fzf checklist: postgres/redis/rabbitmq + BASE_SERVICE=true projects
make services-down      # same checklist, scoped to what's currently running
make services-logs      # tail the core stack's logs
```

`make services-up` (`scripts/services-up.sh`) lists the three core services plus any registered
project whose `deploy/.docker-env` sets `BASE_SERVICE=true` — for infra-like projects other
projects depend on (e.g. a websocket server other apps reach over RabbitMQ), not one-off apps.
Everything starts pre-selected (Space to toggle, Enter to confirm), so hitting Enter with no
changes brings up the same set as before this existed.

`make services-down` (`scripts/services-down.sh`) mirrors it in reverse: the checklist only
shows items that are **currently running**, still pre-selected, so Enter alone stops everything
running (and if nothing's running, it says so and exits — nothing to select). Core services are
stopped with `docker compose ... stop` (not `down`, which isn't scoped to individual services);
`BASE_SERVICE` projects are stopped via `make down <project>`. `services-logs` is unaffected —
it still tails the full `docker-compose.services.yml` stack.

Running more than one instance of this control plane on the same host? Set `SERVICES_PREFIX`
in `.env` (default `jungleforge`) — it prefixes the compose project name and every core
container name (`<prefix>-postgres`, etc.), so two instances don't collide.

### Browsing & bringing up registered apps

```bash
make apps        # fzf checklist of EVERY registered project, with live running/stopped status
make apps-down    # same idea reversed — only currently-running projects
```

`make apps` (`scripts/apps.sh`) is the app-level counterpart to `services-up`, but scoped to
**every** project in `.env` (not just `BASE_SERVICE=true` ones) and annotated with each
project's live status, e.g.:

```
fantastica           stopped
demo-api             running
```

Unlike the services pickers, nothing starts pre-selected — bringing up every registered app at
once is expensive, so you pick exactly what you want (Space to toggle, Enter to confirm; Enter
with nothing picked is a no-op). Selected projects are brought up via `make up <project>`,
identical to running that command directly.

`make apps-down` mirrors `services-down`: only currently-running projects are listed, all
pre-selected (stopping is cheap), and selections are torn down via `make down <project>`. Both
`make up <project>` / `make down <project>` keep working exactly as before, independent of
these pickers.

### Command summary

| Command                                  | Effect                                                    |
| ---------------------------------------- | --------------------------------------------------------- |
| `make base [version]`                    | Build shared `jungleforge/php:<v>-{fpm,dev}` base (once)     |
| `make services-up`                       | Interactive `fzf` checklist: Postgres/Redis/RabbitMQ + `BASE_SERVICE=true` projects |
| `make services-down`                     | Same checklist, scoped to what's currently running        |
| `make services-logs`                     | Tail the full shared services stack                        |
| `make apps`                               | Interactive `fzf` checklist: every registered project, live status shown |
| `make apps-down`                          | Same checklist, scoped to what's currently running        |
| `make build <p> [env=prod]`              | Build the project image                                   |
| `make up <p> [env=prod]`                 | Start the project (dev default)                           |
| `make down \| restart <p> [env=prod]`    | Stop / restart the project                                |
| `make logs \| ps <p> [env=prod]`         | Logs / status                                             |
| `make sh <p> [env=prod]`                 | Shell into the `app` container                            |
| `make migrate <p> [env=prod]`            | Stack-default migration command (`MIGRATE_CMD` overrides)  |
| `make push <p> env=prod [arch=armv7]`    | Multi-arch (or armv7) build & push to `REGISTRY`          |
| `make pull <p> env=prod`                 | Pull the matching-arch image on the target host           |
| `make apply-arch \| revert-arch arch=armv7` | Apply / revert low-mem tuning to `defaults/php/*`      |
| `make help`                              | Full help + list of registered projects                  |

See [docs/ADDING-A-STACK.md](docs/ADDING-A-STACK.md) for how to add a stack beyond the three
built in.
