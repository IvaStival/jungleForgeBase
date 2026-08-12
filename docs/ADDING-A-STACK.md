# Adding a stack

jungleforgebase drives every registered project through one `Makefile`, but a project isn't
locked into PHP-with-nginx. The `STACK` variable in a project's `deploy/.docker-env` picks
which build/runtime pipeline the Makefile uses — `php` (nginx + php-fpm, the default when
`STACK` is unset), `node` (Vite dev server / built + served in prod), and `frankenphp`
(Symfony or any PHP app served directly by FrankenPHP's bundled Caddy, no nginx/php-fpm split).

This doc walks through what a **4th stack** needs, using `frankenphp` as the worked example
since it's the most recently added one.

## How the Makefile reads `STACK`

```makefile
# Makefile, around line 31-35
STACK := $(strip $(shell sed -n 's/^STACK=//p' $(DEPLOY)/.docker-env 2>/dev/null | awk '{print $$1}'))
STACK := $(or $(STACK),php)
```

It's a plain string read out of the project's own `deploy/.docker-env` — no registry, no
plugin system. Everything downstream branches on that string with `ifeq`.

## The four things a new stack needs

### 1. `build/<stack>.Dockerfile`

One Dockerfile shared by every project on that stack (projects never carry their own
Dockerfile — only their `deploy/` config). Mirror `build/php.Dockerfile`'s `dev`/`app` split:

- `dev` — thin, fast-building layer for local development. Code is volume-mounted from the
  host; you run the language's dependency install yourself (`composer install`, `npm install`,
  etc.) rather than baking it into the dev image.
- `app` (prod) — self-contained: dependencies installed in a builder stage, code + built
  artifacts baked in, so the image is portable for multi-arch push and doesn't depend on any
  locally-built base image.

`build/frankenphp.Dockerfile` is the worked example: it skips the nginx/php-fpm split
entirely (FrankenPHP bundles its own web server) and its `dev` stage is a thin layer on top of
the official `dunglas/frankenphp` image, exactly like `build/php.Dockerfile`'s `dev` stage layers
on top of jungleforgebase's own prebuilt `jungleforge/php:<v>-dev` base.

### 2. `docker-compose.<stack>.{dev,prod}.yml`

A dev/prod pair, following the existing naming convention (`docker-compose.node.dev.yml`,
`docker-compose.frankenphp.prod.yml`, …). Both need:

- `build.dockerfile: ${APP_DOCKERFILE}` (see point 3) and `build.context: ${PROJECT_PATH}`.
- The project joins the external `lion-network` with an alias equal to its project name
  (`APP_HOST`), so other projects can reach it at `http://<project>:8080`.
- Dev bind-mounts the project's own config file(s) live where the runtime expects them (e.g.
  frankenphp's dev compose mounts `${PROJECT_PATH}/deploy/Caddyfile` read-only into the
  container), so editing config doesn't require a rebuild.
- Prod publishes only `APP_HTTP_PORT` (bound to `127.0.0.1`, front it with the host's system
  nginx/Caddy for TLS) — the container's own port is always `8080` internally.

### 3. Wire it into the `Makefile`'s `ifeq` branches

Three spots currently branch on `STACK`:

```makefile
# Compose file selection (~line 37-43)
COMPOSE_FILE := docker-compose.$(env).yml
ifeq ($(STACK),node)
COMPOSE_FILE := docker-compose.node.$(env).yml
endif
ifeq ($(STACK),frankenphp)
COMPOSE_FILE := docker-compose.frankenphp.$(env).yml
endif

# The shared Dockerfile to build with (~line 80-89)
APP_DOCKERFILE := $(CURDIR)/build/php.Dockerfile
ifeq ($(STACK),node)
APP_DOCKERFILE := $(CURDIR)/build/node.Dockerfile
endif
ifeq ($(STACK),frankenphp)
APP_DOCKERFILE := $(CURDIR)/build/frankenphp.Dockerfile
endif

# Migration command stack default (~line 45-54) — optional, only if your stack has an
# obvious default migration command; projects can always override with MIGRATE_CMD=... in
# their own deploy/.docker-env regardless.
MIGRATE_CMD := ...
ifeq ($(STACK),frankenphp)
MIGRATE_CMD := php bin/console app:db:setup
endif
```

Add a matching `ifeq ($(STACK),<yourstack>)` block to each. That's the entire integration
surface — `build`, `up`, `down`, `logs`, `sh`, `ps`, `migrate`, `push`, `pull` all key off
`COMPOSE_FILE`/`APP_DOCKERFILE`/`MIGRATE_CMD` and need no further changes.

### 4. `templates/deploy-<stack>/`

The drop-in scaffold a new project copies into its own `deploy/` folder. Mirror
`templates/deploy-frankenphp/`'s shape:

- `entrypoint.dev.sh` / `entrypoint.sh` — minimal boot scripts (ensure writable runtime dirs,
  `exec "$@"`). Keep these generic; project-specific bootstrapping (database provisioning,
  cache warming) belongs in the *project's own* `deploy/`, not the shared template — see how
  `templates/deploy/entrypoint.sh` stays minimal while individual PHP projects add their own
  `db:setup`-style commands on top.
- Any stack-specific runtime config the Dockerfile/compose files expect to find under
  `deploy/` (frankenphp's is `Caddyfile`; the `php` stack's is `nginx/default.conf` +
  `supervisor/*.conf`).
- `.docker-env.example` — `STACK=<yourstack>` plus whatever orchestration vars the compose
  files reference (`IMAGE_NAME`, `PHP_CONTAINER`/`APP_CONTAINER`, `PHP_VERSION`,
  `APP_HTTP_PORT`, …).
- `dockerignore.example` — mirror `templates/deploy/dockerignore.example`, adjusted for the
  stack's own dependency/cache directories.

## Registering a project on the new stack

No different from any other project: add `<NAME>_PATH=/abs/path` to `.env`, scaffold
`deploy/` from the new template, set `STACK=<yourstack>` in `deploy/.docker-env`, and
`make up <name>`.
