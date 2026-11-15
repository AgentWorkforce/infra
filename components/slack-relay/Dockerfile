# syntax=docker/dockerfile:1
# Slack relay: one image, two roles (ROLE=router | ROLE=host).
# The host role runs Claude Code headless, installed from the pinned npm package.
FROM node:24-bookworm-slim@sha256:dc26ae92c9fb15cf6b1d63e20f0944b2efe0f115b20e00be48fb23fceb061c54

ENV NODE_ENV=production \
    CLAUDE_BIN=/app/node_modules/.bin/claude \
    DATA_DIR=/data \
    LEDGER_PATH=/data/ledger.sqlite

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git ripgrep tini \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY src ./src

# Non-root; /data is the volume (ledger for the router, agent sessions for the host).
RUN mkdir -p /data && chown node:node /data
USER node
VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "node", "--disable-warning=ExperimentalWarning", "src/main.ts"]
