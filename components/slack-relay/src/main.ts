// Entrypoint. ROLE=router runs the Slack app + ledger + orchestrator;
// ROLE=host runs the per-thread agents. Both are long-running relay agents.
import { readFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { dirname, join } from "node:path";
import { mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { AgentHost, claudeTurn } from "./host.ts";
import { Ledger } from "./ledger.ts";
import { ClaudeOrchestrator, DeterministicOrchestrator, ThreadPolicy, type KnownAgent, type Orchestrator } from "./orchestrator.ts";
import type { RelayEventLike } from "./protocol.ts";
import { connectAgent, ensureChannel } from "./relay.ts";
import { Router } from "./router.ts";
import { checkWithRetry, kbStreamId, RelaygateClient, slackStreamId } from "./gate.ts";
import { McpClient, oauthServersFromEnv, TokenSource } from "./mcp.ts";
import { SlackIngest, type SourceRule } from "./ingest.ts";
import { channelMessageOf, ChannelDirectory, normalizeSlackEvent, SlackWeb, SocketModeClient, verifySlackSignature, type SlackEventEnvelope } from "./slack.ts";

const env = process.env;
const log = (m: string) => console.log(`${new Date().toISOString()} [${env.ROLE ?? "?"}] ${m}`);

function secret(name: string, required = true): string {
  const file = env[`${name}_FILE`];
  const v = file ? readFileSync(file, "utf8").trim() : (env[name] ?? "").trim();
  if (!v && required) throw new Error(`${name} (or ${name}_FILE) is required`);
  return v;
}

function int(name: string, dflt: number): number {
  const v = Number(env[name] ?? "");
  return Number.isFinite(v) && v > 0 ? v : dflt;
}

// relaygate (opt-in): agents register through it and every Relaycast call goes
// through it; the workspace key is then never needed (or present).
const gateUrl = (env.RELAYGATE_URL ?? "").trim();
const relayBase = gateUrl || (env.RELAYCAST_BASE_URL ?? "");
function relaygate(): RelaygateClient | undefined {
  return gateUrl ? new RelaygateClient({ url: gateUrl, enrollmentKey: secret("RELAYGATE_ENROLLMENT_KEY") }) : undefined;
}
/** The workspace key (direct mode) and the stable secret agent identities are recovered with. */
function identity(): { workspaceKey: string; proofSecret: string } {
  if (gateUrl) return { workspaceKey: "", proofSecret: secret("AGENT_IDENTITY_SECRET") };
  const workspaceKey = secret("RELAYCAST_WORKSPACE_KEY");
  return { workspaceKey, proofSecret: secret("AGENT_IDENTITY_SECRET", false) || workspaceKey };
}
const channel = (env.RELAY_CHANNEL ?? "slack").replace(/^#/, "");
const routerName = env.ROUTER_AGENT_NAME ?? "slack-router";

/** SDK events arrive camelized; older engines send snake_case. Accept both. */
export function toEvent(raw: Record<string, unknown>): RelayEventLike {
  const m = (raw.message ?? {}) as Record<string, unknown>;
  return {
    type: String(raw.type ?? ""),
    channel: (raw.channel as string | undefined) ?? undefined,
    parentId: (raw.parentId ?? raw.parent_id) as string | undefined,
    message: {
      id: String(m.id ?? ""),
      agentName: (m.agentName ?? m.agent_name) as string | undefined,
      text: m.text as string | undefined,
      metadata: m.metadata as Record<string, unknown> | undefined,
      data: m.data as Record<string, unknown> | undefined,
    },
  };
}

type Health = { ready: () => boolean; extra?: (req: IncomingMessage, res: ServerResponse) => boolean };

function serve(port: number, h: Health): void {
  createServer((req, res) => {
    if (h.extra?.(req, res)) return;
    if (req.url === "/healthz") return void res.writeHead(200).end("ok");
    if (req.url === "/readyz") return void res.writeHead(h.ready() ? 200 : 503).end(h.ready() ? "ready" : "not ready");
    res.writeHead(404).end();
  }).listen(port, () => log(`listening on :${port}`));
}

async function runRouter(): Promise<void> {
  const { workspaceKey, proofSecret } = identity();
  const gate = relaygate();
  if (gate) log(`relaygate: on (${gate.url})`);
  const botToken = secret("SLACK_BOT_TOKEN");
  const mode = (env.SLACK_MODE ?? "socket") as "socket" | "http";
  const allowed = new Set((env.SLACK_ALLOWED_CHANNELS ?? "").split(",").map((s) => s.trim()).filter(Boolean));
  const allowDms = env.SLACK_ALLOW_DMS === "true";

  const ledgerPath = env.LEDGER_PATH ?? "/data/ledger.sqlite";
  mkdirSync(dirname(ledgerPath), { recursive: true });
  const ledger = new Ledger(ledgerPath);
  const slack = new SlackWeb(botToken, env.SLACK_API_URL);
  const me = await slack.authTest();
  log(`slack bot ${me.userId} in team ${me.teamId}; mode ${mode}; channels ${allowed.size ? [...allowed].join(",") : "(any the bot is in)"}`);

  const { agent, token: routerToken } = await connectAgent({ baseUrl: relayBase, workspaceKey, name: routerName, persona: "Slack router", proofSecret, log, gate });
  await ensureChannel(agent, channel, "Slack threads routed to agents");

  const known: KnownAgent[] = env.KNOWN_AGENTS_JSON ? (JSON.parse(env.KNOWN_AGENTS_JSON) as KnownAgent[]) : [];
  const anthropicKey = secret("ANTHROPIC_API_KEY", false);
  const prefix = env.AGENT_PREFIX ?? "slack";
  const model: Orchestrator = anthropicKey && env.ORCHESTRATOR !== "deterministic"
    ? new ClaudeOrchestrator({ apiKey: anthropicKey, model: env.ORCHESTRATOR_MODEL ?? "claude-fable-5-2", known, prefix, log })
    : new DeterministicOrchestrator(prefix);
  const allowReuse = env.ALLOW_AGENT_REUSE === "true";
  const orchestrator = new ThreadPolicy({ inner: model, known, allowReuse, prefix, log });
  log(`routing: one agent per thread${allowReuse ? " (reuse allowed)" : ""}; pinned agents: ${known.map((k) => k.name).join(", ") || "none"}`);

  const router = new Router({
    ledger,
    relay: agent,
    slack,
    orchestrator,
    channel,
    selfName: routerName,
    log,
    // Slack posts don't pass through relaygate, so each one is asked about first.
    egress: gate ? (ref, text) => checkWithRetry(gate, routerToken, { op: "w", resource: { kind: "stream", id: slackStreamId(ref) }, content: text }) : undefined,
  });

  agent.subscribe([channel], (raw: unknown) => {
    void router.fromRelay(toEvent(raw as Record<string, unknown>)).catch((err) => log(`relay -> slack failed: ${(err as Error).message}`));
  });

  const refuseShared = env.SLACK_REFUSE_SHARED_CHANNELS !== "false";
  // Continuous ingest of channel messages into a knowledge base over MCP.
  const servers = oauthServersFromEnv(env);
  const ingestServer = env.INGEST_MCP_SERVER ? servers.find((s) => s.name === env.INGEST_MCP_SERVER) : undefined;
  if (env.INGEST_MCP_SERVER && !ingestServer) throw new Error(`INGEST_MCP_SERVER ${env.INGEST_MCP_SERVER} is not in MCP_OAUTH_SERVERS_JSON`);
  const ingest = ingestServer
    ? new SlackIngest({
        brain: new McpClient(ingestServer),
        sourceId: env.INGEST_SOURCE_ID,
        privateSourceId: env.INGEST_PRIVATE_SOURCE_ID,
        rules: env.INGEST_SOURCE_RULES ? (JSON.parse(env.INGEST_SOURCE_RULES) as SourceRule[]) : [],
        prefix: env.INGEST_PAGE_PREFIX ?? "slack",
        log,
        // Knowledge-base writes are egress relaygate can't see either.
        beforeWrite: gate
          ? (slug, text) => checkWithRetry(gate, routerToken, { op: "w", resource: { kind: "stream", id: kbStreamId(ingestServer.name, slug) }, content: text })
          : undefined,
      })
    : null;
  const ingestPrivate = env.INGEST_PRIVATE_CHANNELS === "true";
  log(`ingest: ${ingest ? `on -> ${ingestServer!.name}${env.INGEST_SOURCE_ID ? ` (source ${env.INGEST_SOURCE_ID})` : ""}${ingestPrivate ? ", private channels too" : ", public channels"}` : "off"}; shared channels ${refuseShared ? "refused" : "allowed"}`);

  // Channels shared outside the workspace are refused for answers and ingest
  // (needs channels:read / groups:read). Fail closed when Slack can't say.
  const directory = new ChannelDirectory(slack);
  const channelOk = async (id: string): Promise<{ ok: boolean; name: string; isPrivate: boolean; known: boolean }> => {
    if (allowed.size > 0 && !allowed.has(id)) return { ok: false, name: id, isPrivate: true, known: false };
    // Ingest needs the channel's real name and privacy to pick its source, so
    // look it up whenever ingest is on, not only to refuse shared channels.
    if (!refuseShared && ingest === null) return { ok: true, name: id, isPrivate: true, known: false };
    try {
      const info = await directory.get(id);
      return { ok: !refuseShared || !info.isShared, name: info.name, isPrivate: info.isPrivate, known: true };
    } catch (err) {
      log(`channel ${id}: info unavailable (${(err as Error).message}); ${refuseShared ? "refusing" : "answering without ingest"}`);
      return { ok: !refuseShared, name: id, isPrivate: true, known: false };
    }
  };

  const onEnvelope = (p: SlackEventEnvelope) => {
    void (async () => {
      const team = p.team_id ?? me.teamId;
      const cm = ingest ? channelMessageOf(p.event, me.userId) : null;
      const m = normalizeSlackEvent(p.event, {
        botUserId: me.userId,
        teamId: team,
        isTrackedThread: (ch, ts) => router.isTrackedThread(team, ch, ts),
      });
      if (!m && !cm) return;
      if (m?.kind === "dm") {
        if (!allowDms) return void log(`ignored dm (DMs off)`);
        return void (await router.fromSlack({ ...m, team }));
      }
      const id = (m ?? cm)!.channel;
      const gate = await channelOk(id);
      if (!gate.ok) return void log(`ignored message in ${id} (not allowed or shared)`);
      // Ingest only with real channel details: its source depends on them.
      if (cm && ingest && gate.known && (!gate.isPrivate || ingestPrivate)) {
        void ingest.add({ ...cm, channelName: gate.name, isPrivate: gate.isPrivate }).catch((err) => log(`ingest failed in #${gate.name}: ${(err as Error).message}`));
      }
      if (m) await router.fromSlack({ ...m, team });
    })().catch((err) => log(`slack -> relay failed: ${(err as Error).message}`));
  };

  let socket: SocketModeClient | null = null;
  if (mode === "socket") {
    socket = new SocketModeClient({ web: slack, appToken: secret("SLACK_APP_TOKEN"), onEnvelope, log });
    await socket.start();
  }
  const signingSecret = mode === "http" ? secret("SLACK_SIGNING_SECRET") : "";

  const idleMs = int("IDLE_RELEASE_MINUTES", 30) * 60_000;
  setInterval(() => {
    const released = router.sweepIdle(idleMs);
    if (released.length) log(`ledger: released ${released.join(", ")}`);
  }, 60_000).unref();

  serve(int("PORT", 8080), {
    ready: () => (socket ? socket.connected : true),
    extra: (req, res) => {
      if (req.method === "GET" && req.url === "/ledger/roster") {
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(ledger.roster(), null, 2));
        return true;
      }
      if (req.method === "GET" && req.url?.startsWith("/ledger/events")) {
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(ledger.events(200), null, 2));
        return true;
      }
      if (mode === "http" && req.method === "POST" && req.url === "/slack/events") {
        // Bounded before the signature check: an unsigned caller can't make
        // the router buffer an arbitrarily large body.
        const MAX_BODY = 1024 * 1024;
        const chunks: Buffer[] = [];
        let size = 0;
        let tooLarge = false;
        req.on("data", (c: Buffer) => {
          if (tooLarge) return;
          size += c.length;
          if (size > MAX_BODY) {
            tooLarge = true;
            res.writeHead(413, { connection: "close" }).end();
            req.destroy();
            return;
          }
          chunks.push(c);
        });
        req.on("end", () => {
          if (tooLarge) return;
          // Decoded once, whole: a multibyte character split across chunks stays intact for the signature.
          const body = Buffer.concat(chunks).toString("utf8");
          const ok = verifySlackSignature({
            signingSecret,
            timestamp: req.headers["x-slack-request-timestamp"] as string | undefined,
            signature: req.headers["x-slack-signature"] as string | undefined,
            rawBody: body,
          });
          if (!ok) return void res.writeHead(401).end();
          let p: SlackEventEnvelope;
          try {
            p = JSON.parse(body) as SlackEventEnvelope;
          } catch {
            return void res.writeHead(400).end();
          }
          if (p.type === "url_verification") return void res.writeHead(200, { "content-type": "text/plain" }).end(p.challenge ?? "");
          res.writeHead(200).end();
          if (p.type === "event_callback") onEnvelope(p);
        });
        return true;
      }
      return false;
    },
  });
}

async function runHost(): Promise<void> {
  const { workspaceKey, proofSecret } = identity();
  const gate = relaygate();
  if (gate) log(`relaygate: on (${gate.url})`);
  const anthropicKey = secret("ANTHROPIC_API_KEY");
  const dataDir = env.DATA_DIR ?? "/data";
  const hostName = env.HOST_AGENT_NAME ?? "slack-agent-host";
  mkdirSync(join(dataDir, "agents"), { recursive: true });

  const { agent: hostAgent } = await connectAgent({ baseUrl: relayBase, workspaceKey, name: hostName, persona: "Hosts Slack thread agents", proofSecret, log, gate });
  await ensureChannel(hostAgent, channel, "Slack threads routed to agents");

  const agentServers = oauthServersFromEnv(env)
    .filter((s) => !env.AGENT_MCP_SERVERS || env.AGENT_MCP_SERVERS.split(",").includes(s.name))
    .map((s) => [s, new TokenSource(s)] as const);
  if (agentServers.length) log(`agent MCP servers: ${agentServers.map(([s]) => s.name).join(", ")}`);
  const mcpEntry = env.RELAYCAST_MCP_ENTRY ?? join(dirname(fileURLToPath(import.meta.url)), "..", "node_modules", "@relaycast", "mcp", "dist", "stdio.js");
  // Path-scoped: an agent reads only its own workdir (./**). With dontAsk,
  // anything else (other agents' workdirs, /proc, env) is refused.
  const tools = (env.AGENT_ALLOWED_TOOLS ?? "Read(./**) Glob(./**) Grep(./**) mcp__relaycast").split(/[\s,]+/).filter(Boolean);
  const denied = (env.AGENT_DISALLOWED_TOOLS ?? "Bash WebFetch WebSearch Read(//proc/**)").split(/[\s,]+/).filter(Boolean);
  const host = new AgentHost({
    routerName,
    channel,
    dataDir,
    persona: env.AGENT_PERSONA,
    idleMs: int("IDLE_RELEASE_MINUTES", 15) * 60_000,
    log,
    getMessage: (id) => hostAgent.message(id) as never,
    connect: async (name) => {
      const { agent, token } = await connectAgent({ baseUrl: relayBase, workspaceKey, name, persona: "Slack thread agent", proofSecret, log, gate });
      await ensureChannel(agent, channel, "Slack threads routed to agents");
      return { client: agent, token };
    },
    // Relay tools bound to the agent's own token, plus any OAuth MCP servers
    // (e.g. a company brain), each with a fresh bearer token per turn.
    mcpConfig: async (name, token) => {
      const mcpServers: Record<string, unknown> = {};
      if (env.RELAYCAST_MCP !== "false") {
        mcpServers.relaycast = {
          command: process.execPath,
          args: [mcpEntry],
          env: { RELAY_BASE_URL: relayBase, RELAY_AGENT_TOKEN: token, RELAY_AGENT_NAME: name, RELAY_SKIP_BOOTSTRAP: "1", RELAYCAST_TELEMETRY_DISABLED: "1" },
        };
      }
      for (const [s, tokens] of agentServers) {
        try {
          mcpServers[s.name] = { type: "http", url: s.url, headers: { Authorization: `Bearer ${await tokens.get()}` } };
        } catch (err) {
          // The agent still answers, without this server, rather than not at all.
          log(`${name}: ${s.name} unavailable this turn (${(err as Error).message})`);
        }
      }
      return Object.keys(mcpServers).length ? { mcpServers } : null;
    },
    runTurn: claudeTurn({
      bin: env.CLAUDE_BIN,
      model: env.AGENT_MODEL ?? "claude-opus-5-5",
      timeoutMs: int("TURN_TIMEOUT_SECONDS", 600) * 1000,
      permissionMode: env.AGENT_PERMISSION_MODE ?? "dontAsk",
      allowedTools: tools,
      disallowedTools: denied,
      env: {
        PATH: env.PATH,
        HOME: join(dataDir, "home"),
        ANTHROPIC_API_KEY: anthropicKey,
        DISABLE_TELEMETRY: "1",
        DISABLE_AUTOUPDATER: "1",
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
      },
    }),
  });

  hostAgent.subscribe([channel], (raw: unknown) => {
    void host.onEvent(toEvent(raw as Record<string, unknown>)).catch((err) => log(`agent turn failed: ${(err as Error).message}`));
  });
  // Health first, then re-join known agents in the background (retrying the
  // ones that fail), so a slow relay can't hold the pod unready.
  void host.rejoinKnown().then((names) => names.length && log(`rejoined ${names.length} agent(s): ${names.join(", ")}`));
  serve(int("PORT", 8080), {
    ready: () => true,
    extra: (req, res) => {
      if (req.method === "GET" && req.url === "/agents") {
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ live: host.liveAgents }));
        return true;
      }
      return false;
    },
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const role = env.ROLE;
  const run = role === "router" ? runRouter : role === "host" ? runHost : null;
  if (!run) {
    console.error("ROLE must be router or host");
    process.exit(2);
  }
  if (!relayBase) {
    console.error("RELAYCAST_BASE_URL (or RELAYGATE_URL) is required");
    process.exit(2);
  }
  run().catch((err) => {
    console.error(err);
    process.exit(1);
  });
  for (const sig of ["SIGTERM", "SIGINT"] as const) process.on(sig, () => process.exit(0));
}
