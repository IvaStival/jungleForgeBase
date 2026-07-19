# THE one shared Node/Vite project image (frontend counterpart of build/Dockerfile).
# Stages: dev (thin layer on the prebuilt base, code volume-mounted) | deps (locked install) |
# build (vite build) | app (prod runtime: `vite preview` under supervisord).
# compose points build.dockerfile here while build.context stays the project root, so `COPY deploy/*`
# and `COPY .` pull each project's own config/source.
ARG NODE_VERSION=20

# === DEV: thin layer on the prebuilt base. Code is volume-mounted; node_modules installed at
# === first start by the entrypoint (lands on the anonymous /app/node_modules volume).
FROM jungleforge/node:${NODE_VERSION}-dev AS dev
COPY deploy/supervisor/supervisord.dev.conf /etc/supervisor/supervisord.conf
COPY deploy/entrypoint.dev.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint
WORKDIR /app
EXPOSE 5173
ENTRYPOINT ["/sbin/tini","--","/usr/local/bin/entrypoint"]
CMD ["supervisord","-c","/etc/supervisor/supervisord.conf"]

# === DEPS: locked install, kept on the build host's native arch during cross-arch builds.
FROM --platform=$BUILDPLATFORM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
COPY package.json package-lock.jso[n] ./
RUN npm ci --no-audit --no-fund || npm install --no-audit --no-fund

# === BUILD: compile the SPA. Public VITE_* vars are inlined here (build-time for an SPA), forwarded
# === from the project's .docker-env via compose build.args.
FROM deps AS build
ARG VITE_BACKEND_URL
ENV VITE_BACKEND_URL=${VITE_BACKEND_URL}
COPY . .
RUN npm run build

# === APP (prod): long-lived `vite preview` under supervisord. Carries dist/ + node_modules (vite
# === itself is needed to run `preview`) + config from the build stage.
FROM jungleforge/node:${NODE_VERSION}-prod AS app
COPY deploy/supervisor/supervisord.conf /etc/supervisor/supervisord.conf
COPY deploy/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint
COPY --from=build /app /app
WORKDIR /app
EXPOSE 5173
ENTRYPOINT ["/sbin/tini","--","/usr/local/bin/entrypoint"]
CMD ["supervisord","-c","/etc/supervisor/supervisord.conf"]
