# Development only: uses the dashboard's existing, immutable Node build base.
FROM node:22-bookworm-slim@sha256:4b150b48b4116e2a22f2c39cc27025fbf4f153e2078fd3b14d159fdb5c7279da
WORKDIR /seed
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
ENV DASHBOARD_BASE_PATH=/ DASHBOARD_RUNTIME_CONFIG_URL=/runtime-config.js
# /devsrc is a bounded emptyDir; /seed and node_modules stay read-only.
USER 101:101
EXPOSE 8080
CMD ["node", "/seed/__kind_dev/frontend.mjs"]
