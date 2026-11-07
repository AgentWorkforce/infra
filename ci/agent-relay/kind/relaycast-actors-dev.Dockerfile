# syntax=docker/dockerfile:1.7
# kind/CI proof ONLY: the relaycast Workspace actor on a single-process
# `durable-actors dev` runtime, run as a sidecar next to the relaycast actors
# gateway (charts/relaycast runtime.durableActors.devRuntime). Build from a
# checkout of the relaycast repo (branch selfhost/terse-actors-relaycast):
#
#   docker build -f <infra>/ci/agent-relay/kind/relaycast-actors-dev.Dockerfile \
#     -t relaycast-actors-dev:kind <relaycast checkout>
#
# Kept here until the relaycast repo ships its own dev-runtime image.
# node:22.23.2-bookworm-slim (multi-arch index), pinned so rebuilds are reproducible.
ARG NODE_IMAGE=node:22.23.2-bookworm-slim@sha256:48e4b67d85f87bd551df43704e24d252f56cc5f8e9718841aace50f19948f0f9
ARG DURABLE_ACTORS_TYPESCRIPT_IMAGE=us-central1-docker.pkg.dev/fluid-analogy-473415-c2/public/durable-actors@sha256:d5ad5fe0ade42e97670446666fa86f1c1dfcaaf1ef31246781642b7372ef5925

FROM ${NODE_IMAGE} AS build
WORKDIR /workspace
COPY package.json package-lock.json tsconfig.base.json ./
COPY packages/a2a/package.json packages/a2a/tsconfig.json ./packages/a2a/
COPY packages/a2a/src ./packages/a2a/src
COPY packages/types/package.json packages/types/tsconfig.json ./packages/types/
COPY packages/types/src ./packages/types/src
COPY packages/engine/package.json packages/engine/tsconfig.json ./packages/engine/
COPY packages/engine/src ./packages/engine/src
COPY packages/actors-workspace/package.json packages/actors-workspace/tsconfig.json ./packages/actors-workspace/
COPY packages/actors-workspace/src ./packages/actors-workspace/src
RUN npm ci --ignore-scripts --no-audit --no-fund \
  && npm run --workspace @relaycast/a2a build \
  && npm run --workspace @relaycast/types build \
  && npm run --workspace @relaycast/engine build

FROM ${NODE_IMAGE} AS install
WORKDIR /workspace
COPY --from=build /workspace/package.json /workspace/package-lock.json ./
COPY --from=build /workspace/packages/a2a/package.json ./packages/a2a/
COPY --from=build /workspace/packages/a2a/dist ./packages/a2a/dist
COPY --from=build /workspace/packages/types/package.json ./packages/types/
COPY --from=build /workspace/packages/types/dist ./packages/types/dist
COPY --from=build /workspace/packages/engine/package.json ./packages/engine/
COPY --from=build /workspace/packages/engine/dist ./packages/engine/dist
COPY --from=build /workspace/packages/actors-workspace ./packages/actors-workspace
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
      --workspace @relaycast/actors-workspace --include-workspace-root=false \
  && mkdir -p /app/node_modules/@relaycast \
  && cp -R node_modules/. /app/node_modules/ \
  && for pkg in a2a types engine; do \
       rm -rf "/app/node_modules/@relaycast/$pkg" && cp -R "packages/$pkg" "/app/node_modules/@relaycast/$pkg"; \
     done \
  && rm -rf /app/node_modules/@relaycast/actors-workspace \
  && mkdir -p /app/actor && cp -R packages/actors-workspace/src packages/actors-workspace/package.json packages/actors-workspace/tsconfig.json /app/actor/

FROM ${DURABLE_ACTORS_TYPESCRIPT_IMAGE}
COPY --from=install --chown=10000:10000 /app /app
USER 0
RUN mkdir -p /data && chown -R 10000:10000 /data
USER 10000:10000
WORKDIR /app/actor
ENV DURABLE_ACTORS_SDK_HOST=/app/node_modules/durable-actors/dist/host.js \
    DURABLE_ACTORS_DATA_DIR=/data \
    DURABLE_ACTORS_PROJECT_ID=local \
    DURABLE_ACTORS_PORT=7100
ENTRYPOINT ["/usr/local/bin/durable-actors", "dev", "--sdk-host", "/app/node_modules/durable-actors/dist/host.js"]
