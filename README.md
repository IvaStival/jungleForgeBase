# jungleforgebase

A small **Docker control plane** for running many backend + frontend projects from one place —
PHP/Laravel, FrankenPHP (e.g. Symfony), and Node/Vite — sharing one MariaDB + Postgres + Redis + RabbitMQ
stack.

One `make` command spins up any registered project as a **single self-contained container**, in
**dev** (live code + Xdebug) or **prod** (baked image), and can build/push it **multi-arch**.

This repo holds no application code — it's the engine (Makefile, Dockerfiles, compose files,
templates) that drives *other* projects living elsewhere on disk. Fork it, register your
projects, and pull engine updates whenever you want — see
[Consuming this repo](#consuming-this-repo).

---

## Quickstart

```bash
git clone <your-fork-url> jungleforgebase && cd jungleforgebase
cp .env.example .env
make base                                              # build the shared PHP base image (once)
make up group=services                                 # picker: mariadb + postgres + redis + rabbitmq —
                                                        # ctrl-a to select all, Continue + Enter
echo 'DEMO_API_PATH='"$PWD"'/examples/demo-api' >> .env
make up demo-api                                       # picker filtered to "demo-api" — Enter, Enter
curl localhost:8090/                                   # → confirms the whole loop works
```

`examples/demo-api` is a minimal Laravel app with its own `deploy/`, included so you can prove
the control plane works end-to-end before registering your own project. Once it's running, swap
it for your own: register your project's path in `.env`, scaffold its `deploy/` from
`templates/deploy/` (or `-node`/`-frankenphp`), and `make up <your-project>`.

---

## How it works

```
                        ┌───────────────────────────────────────────────┐
make <cmd> <project>    │ jungleforgebase (this repo) — control plane   │
───────────────────────▶│                                               │
                        │ .env        project registry + credentials    │
                        │ Makefile    resolves paths, runs compose      │
                        │ defaults/   fallback php.ini / opcache / pool │
                        │ templates/  deploy/ scaffold per stack        │
                        └───────────────────────────────────────────────┘
                                               │
                                               │
                     ┬─────────────────────────┴─────────────────────────┬
                     │                                                   │
 ┌────────────────────────────────────────┐          ┌────────────────────────────────────────┐
 │ project: your-app                      │          │ project: demo-api                      │
 │ nginx -> php-fpm + horizon + scheduler │          │ nginx -> php-fpm + horizon + scheduler │
 │ under supervisord, on :‹port›          │          │ under supervisord, on :‹port›          │
 └───────────────────│────────────────────┘          └───────────────────│────────────────────┘
                     │                                                   │
                     ┴─────────────────────────┬─────────────────────────┴
                                               │ lion-network (external, shared)
                               ┌───────────────────────────────────────┐
                               │ services (run once)                   │
                               │ mariadb · postgres · redis · rabbitmq │
                               └───────────────────────────────────────┘
```

- **Each project runs as one container.** A `php`-stack project runs nginx + php-fpm + Laravel
  Horizon + the scheduler under `supervisord`; `frankenphp` runs a single FrankenPHP process
  (Caddy + PHP); `node` runs Vite. Pick the stack with `STACK=` in the project's
  `deploy/.docker-env` (`php` is the default).
- **Every project shares the `lion-network`** (name configurable via `NETWORK_NAME` in `.env`,
  default `lion-network`) and is reachable by other projects at `http://<project>:<that
  project's own APP_HTTP_PORT>` (the in-container port matches the host-published one — no fixed
  `8080`/`5173` — except `frankenphp` projects, which keep a fixed port set in their own
  hand-owned Caddyfile), and reaches MariaDB/Postgres/Redis/RabbitMQ at their hostnames. Only each
  project's **host** port (`APP_HTTP_PORT`) needs to be unique.
- **A project carries no Dockerfile of its own** — it builds from jungleforgebase's shared
  `build/<stack>.Dockerfile`. Its `deploy/` folder (scaffolded from `templates/deploy*/`) is
  just config: web server vhost/Caddyfile, supervisor, entrypoints, `.docker-env`.
- **`make base`/`make base-node` build the shared PHP/Node images once** (`force=true` rebuilds
  without cache); every project's dev build reuses them, so a freshly-registered project comes up
  in seconds. Prod builds stay self-contained and portable for multi-arch push. If a project's
  dev build needs a base image that isn't built yet, `make build`/`make up` build it
  automatically first — you don't have to remember to run `make base` by hand.

For the full breakdown of build stages, config resolution, and how to add a new stack, see
[docs/ADDING-A-STACK.md](docs/ADDING-A-STACK.md) and `CLAUDE.md`.

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

## Usage

### Prerequisites

- Docker + Docker Compose v2 (`docker compose`), and `docker buildx` for multi-arch push.
- [`fzf`](https://github.com/junegunn/fzf) — drives the `make build`/`up`/`down` picker
  (`brew install fzf`); there's no non-interactive fallback.
- Each project must contain a `deploy/` folder (copy the template matching its stack) and its
  own `.env` pointing at the shared services: `DB_HOST=postgres`, `REDIS_HOST=redis`,
  `RABBITMQ_HOST=rabbitmq` (php/frankenphp — adjust var names to your framework's convention).

### 1. One-time setup

```bash
cp .env.example .env          # then edit: register projects + set service credentials
make base                     # build the shared PHP base image (once; `make base 8.3` for 8.3,
                               # `make base force=true` to rebuild without cache)
make up group=services        # picker: mariadb + postgres + redis + rabbitmq (+ any project with
                               # BASE_SERVICE=true) — ctrl-a to select all, then Continue + Enter
```

Register a project by adding its absolute path to `.env` (name uppercased, dashes → underscores):

```dotenv
YOUR_APP_PATH=/Users/you/Projects/your-app
DEMO_API_PATH=/Users/you/Projects/jungleforgebase/examples/demo-api
```

Each project's host port is set in its own `deploy/.docker-env` (`APP_HTTP_PORT`) — give each a
distinct value so they don't collide. `make help` lists every command and every registered
project.

### 2. Scaffold a project

```bash
cp -r templates/deploy /path/to/your-app/deploy        # or templates/deploy-node, templates/deploy-frankenphp
cp /path/to/your-app/deploy/.docker-env.example /path/to/your-app/deploy/.docker-env
# edit deploy/.docker-env: IMAGE_NAME, PHP_CONTAINER, PHP_VERSION, APP_HTTP_PORT (distinct per project)
```

Then register the project's path in jungleforgebase's `.env` (`YOUR_APP_PATH=...`).

### 3. Day-to-day (dev is the default `env`)

```bash
make up your-app          # picker filtered to "your-app" + Continue row — Enter, Enter
make logs your-app        # tail logs (no picker — direct)
make sh your-app          # shell into the app container (pre-configured zsh)
make migrate your-app     # php artisan migrate --force
make ps your-app          # container status
make restart your-app
make down your-app        # picker filtered to "your-app" — stop & remove its containers
```

App is reachable on the host at `http://localhost:<APP_HTTP_PORT>`; from other projects on
`lion-network` at `http://your-app:<same APP_HTTP_PORT>` (the in-container port now matches it).
Vite/HMR on `VITE_PORT` (default `5173`); Xdebug connects back to your IDE on `9003`.

Horizon and the scheduler are off by default in dev (php stack) — enable them inside the
container:

```bash
make sh your-app
supervisorctl start horizon scheduler
```

### 4. Production

```bash
make build your-app env=prod    # picker filtered to "your-app" — bakes code + built assets
make up    your-app env=prod    # picker filtered to "your-app" — runs it (web server on 127.0.0.1:8080)
make migrate your-app env=prod
```

Then point the host's system nginx/Caddy at `127.0.0.1:8080` and terminate TLS there.

### 5. Multi-arch build & push

Set `REGISTRY` (and optionally `TARGET_PLATFORMS`) in `.env`, then:

```bash
make push your-app env=prod                 # multi-arch (TARGET_PLATFORMS) → registry
make push your-app env=prod arch=armv7      # single-arch armv7 + low-mem PHP tuning (auto-reverted)
make pull your-app env=prod                 # on the target host, pull the matching arch
```

### The build/up/down picker

```bash
make up                       # picker: services + apps, running/stopped shown, nothing pre-picked
make up your-app                # picker: filtered to matches("your-app")
make up group=services          # picker: services section only
make build force=true          # same picker; confirmed selections build with --no-cache first
make down                      # same picker; confirmed core services get `stop`, confirmed apps get `down`
```

`make build`/`make up`/`make down` (`scripts/pick.sh`) all open the same picker: a **services**
section (mariadb/postgres/redis/rabbitmq + any project with `BASE_SERVICE=true`) and an **apps** section
(everything else registered), both showing live running/stopped status. Nothing starts
pre-selected. **Enter** toggles the highlighted row and advances to the next one; a pinned
`>>> Continue: <verb> selected` row is what you land on and press Enter on to execute against
everything toggled (`ctrl-a` selects everything listed). The positional word (if given) filters
by substring match; `group=services`/`group=apps` filters by section — both combine.
All 4 core services are listed under every verb, including `verb=build` — selecting one there is
a no-op (no build step); `verb=down` runs `stop` (not `down`) on confirmed core services and a
real `down` on confirmed apps.

Running more than one instance of this control plane on the same host? Set `SERVICES_PREFIX` in
`.env` (empty by default — bare `postgres`/`redis`/`rabbitmq`/`services` names), including your
own trailing separator (e.g. `SERVICES_PREFIX=myinstance-`), so container/project names don't
collide between instances.

### Command summary

| Command                                  | Effect                                                    |
| ----------------------------------------- | --------------------------------------------------------- |
| `make base [version] [force=true]`       | Build shared `jungleforge/php:<v>-{fpm,dev}` base (once; `force=true` = no cache) |
| `make base-node [version] [force=true]`  | Build shared `jungleforge/node:<v>-{prod,dev}` base (once; `force=true` = no cache) |
| `make services-logs`                     | Tail the full shared services stack                        |
| `make build [name] [group=] [force=true]` | Picker (services+apps); confirmed selections build (dev: auto-builds the missing base first) |
| `make up [name] [group=] [force=true]`   | Picker; confirmed selections start (dev: same base auto-build) |
| `make down [name] [group=]`              | Picker; confirmed core services `stop`, confirmed apps `down` |
| `make restart <p> [env=prod]`            | Restart the project directly, no picker                    |
| `make logs \| ps <p> [env=prod]`         | Logs / status                                               |
| `make sh <p> [env=prod]`                 | Shell into the `app` container                            |
| `make migrate <p> [env=prod]`            | Stack-default migration command (`MIGRATE_CMD` overrides)  |
| `make push <p> env=prod [arch=armv7]`    | Multi-arch (or armv7) build & push to `REGISTRY`          |
| `make pull <p> env=prod`                 | Pull the matching-arch image on the target host           |
| `make apply-arch \| revert-arch arch=armv7` | Apply / revert low-mem tuning to `defaults/php/*`      |
| `make help`                              | Full help + list of registered projects                  |

See [docs/ADDING-A-STACK.md](docs/ADDING-A-STACK.md) for how to add a stack beyond the three
built in.
