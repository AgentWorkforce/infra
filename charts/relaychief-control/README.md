# relaychief-control

Packaging for [relaychief-control](https://github.com/AgentWorkforce/relaychief-control),
the optional Relay Chief registry and slot-binding add-on. It is not part of the
`agent-relay` umbrella, and an installation without it is complete. It runs one
replica and makes no HA claim. `image.digest` defaults to the published 0.1.0
image.

## Install inputs

| Value | Renders | Notes |
| --- | --- | --- |
| `image.digest` | image reference | Pinned to 0.1.0 by default; must be `sha256:<64 hex>`, tags are not accepted |
| `config.relaycontrolUrl` | `RELAYCONTROL_URL` | Required bare http(s) origin |
| `config.publicOrigin` | `RELAYCHIEF_CONTROL_PUBLIC_ORIGIN` | Required bare http(s) origin; register it in relay-control's accepted audiences |
| `config.browserOrigins` | `RELAYCHIEF_CONTROL_BROWSER_ORIGINS` | Optional, comma separated |
| `config.nangoHost` | `NANGO_HOST` | Optional; refused without `secretKeys.nangoSecretKey` |
| `existingSecret` | all Secret env | Required; the chart creates no Secret and takes no Secret values |

`existingSecret` holds these data keys, renamed through `secretKeys.*`:

| Key | Env | Requirement |
| --- | --- | --- |
| `DATABASE_URL` | `DATABASE_URL` | Required; also used by the migrate Job |
| `RELAYCONTROL_INTROSPECT_SECRET` | same | Required, 32+ characters |
| `RELAYCHIEF_CONTROL_ADMIN_TOKEN` | same | Required, 32+ characters |
| set `secretKeys.nangoSecretKey` | `NANGO_SECRET_KEY` | Optional; unset leaves Nango off and creating a chief answers 503 |

A render cannot see Secret contents. A missing key stops the pod with
`CreateContainerConfigError`, and a short token stops the server at startup.
Rotating the Secret needs a pod restart.

`postgresCa` mounts a private Postgres CA bundle for `sslmode=verify-full`, as in
the `relayhistory` chart.

## Admin listener

The operator routes listen on `127.0.0.1:3201` in the pod. The chart renders
`ADMIN_HOST=127.0.0.1` itself, refuses `ADMIN_HOST` and `ADMIN_PORT` in `extraEnv`,
and adds the port to neither the Service nor the container ports. Use a
port-forward to the pod:

```sh
kubectl -n <ns> port-forward pod/<pod> 3201:3201
```

## Ingress and NetworkPolicy

`ingress.enabled` is off, and no ingress class, host or annotation is a chart
default. When enabled the Ingress routes only `/chief/v1` (Prefix). The tenant
routes under `/api/v1` (also served as `/cloud/api/v1`) stay cluster-internal
unless `ingress.extraPaths` adds them; a `/` rule is refused because it would
expose every route.

`networkPolicy.enabled` defaults to true with restricted egress, so
`networkPolicy.additionalEgress` must admit the database (and relay-control or
Nango when outside the namespace), or the render fails. `allowAllEgress: true`
is the alternative.

With `ingress.enabled` the render also requires `networkPolicy.ingressFrom`. An
AWS ALB in IP target mode connects from its subnets, so list those subnets as
`ipBlock` peers (instance mode would connect from the nodes instead, which the
pod policy does not admit). The ALB's default health check path is `/`, which
this service answers with 404, so set
`alb.ingress.kubernetes.io/healthcheck-path` to `/healthz`. `ingressFrom`
replaces the same-namespace default, so add a `podSelector` or `namespaceSelector`
peer for cluster-internal callers of `/api/v1`. See
[`ci/alb-values.yaml`](ci/alb-values.yaml) for the shape.

## Migration

The migration is a plain Job named by a hash of its pod template, not a Helm
hook, so it is present under `--no-hooks`. It is idempotent and takes an advisory
lock. The server can start before it finishes, so wait for it (the command is in
the release notes `helm install` prints). `/readyz` checks only that the
database answers.

```sh
helm lint --strict charts/relaychief-control \
  -f charts/relaychief-control/ci/default-values.yaml
```
