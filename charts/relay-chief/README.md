# relay-chief

Runs [Relay Chief](https://github.com/AgentWorkforce/relay-chief) on Kubernetes.
Each CronJob firing runs one bounded `run-once` cycle against a SQLite database
on a persistent volume. Cycles never overlap, because the database has one writer.

**Status: not qualified.** There is no published image yet, and the runtime's own
[readiness document](https://github.com/AgentWorkforce/relay-chief/blob/main/docs/readiness.md)
lists what must exist before customer use. The chart has only been rendered, not
run. The control-plane routes Relay Chief calls are contracts defined by that
repository, not routes confirmed to exist in relaycontrol.

## Required values

| Value | Purpose |
| --- | --- |
| `image.digest` | Immutable image digest (`sha256:...`) |
| `relay.baseUrl` | Rendered as `RELAY_BASE_URL`. Required, because the runtime otherwise uses the hosted Relay |
| `controlPlane.url` | Rendered as `CHIEF_CONTROL_PLANE_URL` |
| `existingSecret` | Secret holding the three credentials below |
| `config` | Relay Chief configuration, identifiers only |

## Secret keys

| Value (default key) | Environment variable |
| --- | --- |
| `secretKeys.relayAgentToken` (`relay-agent-token`) | `RELAY_AGENT_TOKEN`, a pre-provisioned chief identity and not a workspace admin key |
| `secretKeys.typesafeApiKey` (`typesafe-api-key`) | `TYPESAFE_API_KEY` |
| `secretKeys.controlPlaneToken` (`control-plane-token`) | `CHIEF_CONTROL_PLANE_TOKEN` |

## Behavior to know

- `dispatch` is `false` by default, so a cycle sends no Relay assignments. Set it
  to `true` only after the execution side is integrated.
- The schedule defaults to one minute, the finest Kubernetes cron allows. The
  repository's reference systemd timer runs every 30 seconds.
- A failed cycle is not retried by Kubernetes. The next firing resumes from
  durable state.
- The volume defaults to `ReadWriteOncePod` and is kept on uninstall. Back it up:
  it holds the durable claims and task state.
- The image must run as a non-root user with a read-only root filesystem, and
  must provide `node` and `/opt/relay-chief/dist/cli.js` unless `command` is set.
