# Slack app for self-hosted Agent Relay (optional)

`slack-relay` lets people talk to agents running in your Agent Relay install
from Slack. It is optional: install it next to an existing `agent-relay`
release, or turn it on in the umbrella chart with `components.slackRelay`.

- Someone @mentions the app in a channel, or DMs it if you allow DMs. An agent
  picks up the thread.
- Follow-ups in that thread go to the same agent, with its context, however
  long the gap. Several people can talk in one thread at once.
- Each thread gets its own agent. The agents live on your relay and can see
  each other, so they can ask one another for help.
- Agents, sessions and the routing record stay inside your cluster. Slack only
  receives what an agent posts back into its thread.

## How it works

```text
Slack ──(Socket Mode, outbound WSS)──▶ router ──▶ ledger (SQLite: thread → agent)
                                         │  unowned thread? ask the orchestrator (Claude) once
                                         ▼
                                  relay channel #slack  (one relay thread per Slack thread)
                                         ▼
                                  agent host ──▶ wakes the owning agent, resumes its Claude session,
                                         │       runs one turn, answers as that agent
                                         ▼
Slack ◀──── router posts the answer into the Slack thread the ledger maps it to
```

| Piece | Kind | What it does |
| --- | --- | --- |
| Router | Deployment, 1 replica, PVC | Holds the Slack connection. Records every message in the **ledger**: threads, the people in them, agents, and an append-only event log. Routes by ledger lookup and asks the orchestrator only about threads nobody owns yet. It is the only component with Slack credentials. |
| Orchestrator | in the router | A Claude model (default `claude-fable-5-2`) that sees every agent, its status, what it's working on and whose threads it holds. For a new thread it either assigns an existing or pinned agent, or starts a new agent with a brief. Set `router.orchestrator: deterministic` to start one agent per thread with no model call. |
| Agent host | StatefulSet, 1 replica, PVC | Runs the per-thread agents with headless Claude Code (default `claude-opus-5-5`). Each agent is its own relay identity with its own workdir and Claude session on the volume. It runs no process between messages: a message wakes it and resumes its session, and it leaves the relay after `host.idleReleaseMinutes`. It has no Slack credentials. |

Restarts are safe. The ledger and the sessions live on volumes. Agents
re-register on the relay under the same name with a recovery proof derived
from a stable secret, so no agent tokens are stored.

## Requirements

- An `agent-relay` install with Relaycast reachable from the namespace, for
  example `http://relaycast:8787`.
- A Relaycast workspace key (`rk_live_...`) for the workspace the agents join.
- An Anthropic API key. Agents run Claude Code, and the default orchestrator is
  a Claude model.
- A Slack workspace where you can create apps.
- Outbound HTTPS from the namespace to `slack.com`, `wss-*.slack.com` (Socket
  Mode) and `api.anthropic.com`. No inbound traffic is needed in Socket Mode.

## 1. Create the Slack app

You create the app in your own Slack workspace from our manifest. The tokens
never leave your control.

1. Render the manifest. You can give the app your own name:
   ```sh
   components/slack-relay/manifest/render-manifest.py --name "Acme Agents" > manifest.json
   ```
2. In <https://api.slack.com/apps>, choose **Create New App**, then **From a
   manifest**. Pick your workspace and paste `manifest.json`.
3. In **Basic Information**, under **App-Level Tokens**, choose **Generate Token
   and Scopes**. Add the scope `connections:write` and copy the `xapp-...`
   token. Socket Mode uses this token.
4. In **Install App**, choose **Install to Workspace** and copy the **Bot User
   OAuth Token** (`xoxb-...`).
5. Invite the app to the channel(s) it should answer in (`/invite @Acme Agents`)
   and note each channel's ID (`C...`, under the channel name, then **About**).
   For a first rollout, start with a single channel and list only that one in
   `slack.allowedChannels`.

Bot scopes the manifest requests: `app_mentions:read`, `channels:history`,
`groups:history`, `im:history` (to read the threads it is in) and `chat:write`
(to answer). Events: `app_mention`, `message.channels`, `message.groups` and
`message.im`. The router ignores channel messages unless they mention the app
or are in a thread it already holds. It ignores DMs unless `slack.allowDms` is
set.

To receive events over HTTPS instead of Socket Mode, render the manifest with
`--mode http --url https://<host>/slack/events`. Then set `slack.mode: http`,
`ingress.*` and `secrets.slackSigningSecret`. In http mode only
`/slack/events` is exposed.

## 2. Create the Secrets

The chart only references Secrets, so create them however you manage secrets
(External Secrets, Secret Manager CSI, `kubectl`):

```sh
kubectl -n agent-relay create secret generic slack-relay-relaycast --from-literal=workspace-key="$RELAYCAST_WORKSPACE_KEY"
kubectl -n agent-relay create secret generic slack-relay-slack \
  --from-literal=bot-token="$SLACK_BOT_TOKEN" --from-literal=app-token="$SLACK_APP_TOKEN"
kubectl -n agent-relay create secret generic slack-relay-anthropic --from-literal=api-key="$ANTHROPIC_API_KEY"
```

## 3. Install

```yaml
# slack-relay-values.yaml
image:
  digest: sha256:<published digest>
relaycast:
  baseUrl: http://relaycast:8787
secrets:
  relaycastWorkspaceKey: { name: slack-relay-relaycast, key: workspace-key }
  slackBotToken: { name: slack-relay-slack, key: bot-token }
  slackAppToken: { name: slack-relay-slack, key: app-token }
  anthropicApiKey: { name: slack-relay-anthropic, key: api-key }
slack:
  allowedChannels: [C0123456789]
```

```sh
helm upgrade --install slack-relay charts/slack-relay -n agent-relay -f slack-relay-values.yaml
```

To install through the umbrella chart instead, set `components.slackRelay: true`
and put the same values under `slack-relay:`.

## 4. Check it

```sh
kubectl -n agent-relay logs deploy/slack-relay-router      # "socket mode connected"
kubectl -n agent-relay logs statefulset/slack-relay-host   # "registered relay agent slack-agent-host"
```

@mention the app in the allowed channel. The router logs `assigned <channel>:<ts>
-> slack-<channel>-<ts>`, the host logs `woke …` and `… answered`, and the
answer appears in the thread. Reply in the thread and the same agent answers
(`(resumed)` in the host log).

The ledger can be read from inside the cluster:

```sh
kubectl -n agent-relay port-forward deploy/slack-relay-router 8080
curl -s localhost:8080/ledger/roster   # agents, status, what they're doing, their threads and people
curl -s localhost:8080/ledger/events   # append-only routing log: inbound, assign, agent.*, outbound
```

## Data boundaries and audit

- **What leaves the cluster:** Slack API calls from the router only, and
  Anthropic API calls from the router (orchestrator) and the host (agents).
  Agents have no Slack credentials and post only through the relay.
- **Agent tools:** by default `Read`, `Glob`, `Grep` and the relay tools only.
  No shell, no web fetch/search, and `permissionMode: dontAsk`, so any other
  tool call is refused. Widen `host.allowedTools` deliberately. Each tool you
  add is a new way for data to leave.
- **Audit trail:** the ledger's `events` table records every inbound Slack
  message (who, where, when, truncated text), every routing decision (who
  decided: `orchestrator:<model>` or `deterministic`) and every outbound post.
  The agents' full Claude sessions are JSONL files on the host volume
  (`/data/home/.claude/projects/...`).
- For a hard egress boundary, add a NetworkPolicy or a firewall egress rule
  that allows only Relaycast, Slack and Anthropic from this namespace.

## Values reference

See `charts/slack-relay/values.yaml`. The ones you're most likely to change:

| Value | Default | |
| --- | --- | --- |
| `slack.allowedChannels` | `[]` (any channel the bot is in) | Channel IDs the app answers in. |
| `slack.allowDms` | `false` | Answer DMs to the bot. |
| `router.orchestrator` | `claude` | `deterministic` to skip the model and start one agent per thread. |
| `router.orchestratorModel` | `claude-fable-5-2` | |
| `router.knownAgents` | `[]` | Pinned agents the orchestrator may route to, e.g. a company knowledge agent. |
| `host.agentModel` | `claude-opus-5-5` | |
| `host.persona` | generalist | Appended to each agent's system prompt. |
| `host.allowedTools` | `[Read, Glob, Grep, mcp__relaycast]` | |
| `host.idleReleaseMinutes` | `15` | |

## Limits of this version

- One router and one host replica. The ledger is single-writer SQLite and the
  sessions live on one volume, so this scales by machine size, not replica
  count.
- Each agent's turns run one at a time. Different threads run in parallel.
- An agent's awareness of other agents comes from the ledger roster in its
  prompt. Its relay tools are scoped to its own token, so it can message and
  read channels but not administer the workspace.
