# Shared Node base image for jungleforge frontend (Vite/Node) projects.
# Mirrors base/php.Dockerfile (the PHP base): two targets — `prod` (minimal long-lived runtime) and
# `dev` (+ git/zsh tooling). Project DEV builds layer thinly FROM jungleforge/node:<v>-dev.
# Build both with: make base-node   (or `make base-node 22` for another major version).
ARG NODE_VERSION=20

# --- prod base: minimal long-lived runtime (tini reaps, supervisor runs the node process) ---
FROM node:${NODE_VERSION}-alpine AS prod
RUN apk add --no-cache bash tini supervisor
WORKDIR /app

# --- dev base: + git/zsh tooling, reusing base/zsh/ (same shell setup as the PHP dev base) ---
FROM prod AS dev
RUN apk add --no-cache git zsh \
 && git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git                  /root/.oh-my-zsh \
 && git clone --depth=1 https://github.com/romkatv/powerlevel10k.git            /root/.oh-my-zsh/custom/themes/powerlevel10k \
 && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git    /root/.oh-my-zsh/custom/plugins/zsh-autosuggestions \
 && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git /root/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting \
 && find /root/.oh-my-zsh -name '.git' -prune -exec rm -rf {} + \
 && rm -rf /tmp/* /var/cache/apk/*
COPY base/zsh/zshrc    /root/.zshrc
COPY base/zsh/p10k.zsh /root/.p10k.zsh
