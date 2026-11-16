# slack-relay

Source of the `ghcr.io/agentworkforce/slack-relay` image used by
[`charts/slack-relay`](../../charts/slack-relay). Install and Slack app setup:
[docs/self-hosted-slack-relay.md](../../docs/self-hosted-slack-relay.md).

One image, two roles:

| `ROLE` | Module | |
| --- | --- | --- |
| `router` | `src/router.ts`, `src/ledger.ts`, `src/orchestrator.ts`, `src/slack.ts` | Slack app (Socket Mode or HTTP Events), the routing ledger, and the orchestrator for unowned threads. |
| `host` | `src/host.ts` | Runs per-thread agents as headless Claude Code on the relay. |

`src/protocol.ts` is the contract between them: the `data` carried on relay
messages in the Slack relay channel. `src/relay.ts` handles relay identity.
An agent registers once with a recovery-proof verifier and recovers the same
identity on every restart.

The router is deliberately flow-shaped: fixed steps (record, route, decide
once, deliver, return), with the model asked only to make the one decision
the ledger can't. When Relayflows gains cross-run state and resumable named
agents, the same steps can move into a `.flow.ts`.

## Develop

```sh
npm ci
npm run typecheck
npm test                       # unit tests; the e2e test is skipped
# e2e against a real Relaycast engine (Slack and Claude are faked):
npx @relaycast/engine@12.8.0 & # http://localhost:8787
KEY=$(curl -s -XPOST localhost:8787/v1/workspaces -H 'content-type: application/json' -d '{"name":"dev"}' | jq -r .data.api_key)
RELAYCAST_E2E_URL=http://localhost:8787 RELAYCAST_E2E_KEY=$KEY npm test
```

`manifest/` holds the Slack app manifest the customer creates the app from,
and `render-manifest.py` to name it and pick socket or http mode.
It also holds the read-only GitHub App manifest for `repos.app` and
`register-github-app.mts`, which registers the app from it, stores the app ID,
private key and installation ID (Kubernetes Secret, Secret Manager or files)
and verifies them (docs/self-hosted-slack-relay.md, "GitHub repos").

## Publish

A merge to main publishes `:sha-<short>` and `:main` through
`.github/workflows/slack-relay.yml` on GitHub-hosted runners. When that queue
is too slow, the infra fast path runs the same tests and image build on
Blacksmith, after Khaliq approves the `fast-path` environment:

```sh
gh workflow run fast-path.yml -R AgentWorkforce/infra \
  -f stage=slack-relay-image -f ref=main -f reason="<why>"
```

`ref` may be any branch or commit. It pushes `:fast-<sha>` and
`:sha-<short sha>` with the same provenance and SBOM, never `:main`, and prints
the digest to pin (`image.digest`) in the run summary.
