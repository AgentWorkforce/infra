// The agent host: runs the per-thread agents. An agent is a relay identity
// with its own workdir and Claude session on the host's volume. Nothing runs
// between messages; a message addressed to an agent wakes it (joins the relay
// under its own name and resumes its session), the host runs one Claude turn,
// and the agent answers in the relay thread as itself. After `idleMs` without
// work it leaves the relay (shows offline) until the next message wakes it.
//
// Each turn gets the roster from the ledger (who else is working on what) and
// a Relaycast MCP server bound to the agent's own token, so it can see and
// message the other agents on the relay.
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { dataOf, inboundOf, type InboundData, type RelayEventLike, type RelayMessageLike, type ReplyData } from "./protocol.ts";

export interface HostAgentClient {
  reply(id: string, text: string, opts?: { data?: Record<string, unknown> }): Promise<{ id: string }>;
  disconnect?(): Promise<void>;
}

export interface AgentSession {
  client: HostAgentClient;
  token: string;
}

export interface TurnInput {
  agent: string;
  workdir: string;
  sessionId: string;
  resume: boolean;
  prompt: string;
  system: string;
  mcpConfigPath: string | null;
}

export interface TurnResult {
  text: string;
  sessionId: string;
  error: boolean;
}

export type RunTurn = (t: TurnInput) => Promise<TurnResult>;

export interface HostOptions {
  routerName: string;
  channel: string;
  dataDir: string;
  /** Joins the relay as `name` (register or recover). */
  connect: (name: string) => Promise<AgentSession>;
  runTurn: RunTurn;
  /** Reads a relay message by id: thread.reply events carry no `data`. */
  getMessage?: (id: string) => Promise<RelayMessageLike>;
  /** Builds the MCP config for an agent's turn, or null for none. */
  mcpConfig?: (agent: string, token: string) => Record<string, unknown> | null;
  persona?: string;
  idleMs?: number;
  log?: (m: string) => void;
}

type HostConfig = Required<Omit<HostOptions, "mcpConfig" | "getMessage">> & Pick<HostOptions, "mcpConfig" | "getMessage">;

interface Live {
  session: AgentSession;
  queue: Promise<unknown>;
  lastUsed: number;
  busy: number;
}

export class AgentHost {
  readonly #o: HostConfig;
  readonly #live = new Map<string, Live>();
  readonly #connecting = new Map<string, Promise<Live>>();
  readonly #seen = new Set<string>();

  constructor(o: HostOptions) {
    this.#o = {
      persona: DEFAULT_PERSONA,
      idleMs: 15 * 60_000,
      log: () => {},
      ...o,
    } as HostConfig;
  }

  get liveAgents(): string[] {
    return [...this.#live.keys()];
  }

  /** Handles one relay event; resolves when the agent has answered (or was skipped). */
  async onEvent(ev: RelayEventLike): Promise<string | null> {
    const msg = ev.message;
    if (!msg?.id || msg.agentName !== this.#o.routerName) return null;
    if (ev.channel && ev.channel.replace(/^#/, "") !== this.#o.channel.replace(/^#/, "")) return null;
    if (this.#seen.has(msg.id)) return null;
    let inbound = inboundOf(dataOf(msg));
    if (!inbound && ev.type === "thread.reply" && this.#o.getMessage) {
      inbound = inboundOf(dataOf(await this.#o.getMessage(msg.id)));
    }
    if (!inbound) return null;
    if (this.#seen.has(msg.id)) return null;
    this.#seen.add(msg.id);
    if (this.#seen.size > 20_000) this.#seen.clear();

    const parentId = ev.type === "thread.reply" && ev.parentId ? ev.parentId : msg.id;
    const live = await this.#wake(inbound.target);
    const run = live.queue.catch(() => undefined).then(() => this.#turn(live, inbound, msg.text ?? "", parentId));
    live.queue = run;
    return run;
  }

  /** Releases agents idle longer than `idleMs`: they leave the relay until woken. */
  async releaseIdle(now = Date.now()): Promise<string[]> {
    const released: string[] = [];
    for (const [name, live] of this.#live) {
      if (live.busy > 0 || now - live.lastUsed < this.#o.idleMs) continue;
      this.#live.delete(name);
      released.push(name);
      await live.session.client.disconnect?.().catch(() => undefined);
      this.#o.log(`released ${name} (idle)`);
    }
    return released;
  }

  async #wake(name: string): Promise<Live> {
    const existing = this.#live.get(name);
    if (existing) return existing;
    const pending = this.#connecting.get(name);
    if (pending) return pending;
    const p = (async () => {
      const session = await this.#o.connect(name);
      const live: Live = { session, queue: Promise.resolve(), lastUsed: Date.now(), busy: 0 };
      this.#live.set(name, live);
      this.#o.log(`woke ${name}`);
      return live;
    })();
    this.#connecting.set(name, p);
    try {
      return await p;
    } finally {
      this.#connecting.delete(name);
    }
  }

  async #turn(live: Live, inbound: InboundData, text: string, parentId: string): Promise<string> {
    live.busy++;
    try {
      const name = inbound.target;
      const workdir = join(this.#o.dataDir, "agents", name);
      mkdirSync(workdir, { recursive: true });
      // The session already exists on disk if any earlier turn ran, whatever the router believes.
      const started = existsSync(join(workdir, ".session-started"));
      const mcp = this.#o.mcpConfig?.(name, live.session.token) ?? null;
      let mcpConfigPath: string | null = null;
      if (mcp) {
        mcpConfigPath = join(workdir, ".mcp.json");
        writeFileSync(mcpConfigPath, JSON.stringify(mcp), { mode: 0o600 });
      }
      const result = await this.#o.runTurn({
        agent: name,
        workdir,
        sessionId: inbound.session.id,
        resume: started,
        prompt: promptFor(inbound, text),
        system: systemFor(name, this.#o.persona, inbound),
        mcpConfigPath,
      });
      if (!result.error) writeFileSync(join(workdir, ".session-started"), result.sessionId);
      const data: ReplyData = {
        kind: "agent.reply",
        session_id: result.sessionId,
        summary: summarize(text),
        ...(result.error ? { error: true } : {}),
      };
      const reply = await live.session.client.reply(parentId, result.text, { data: data as unknown as Record<string, unknown> });
      this.#o.log(`${name} answered in ${parentId}${started ? " (resumed)" : ""}`);
      return reply.id;
    } finally {
      live.busy--;
      live.lastUsed = Date.now();
    }
  }
}

const DEFAULT_PERSONA = "You are a helpful generalist working for the team. Be accurate and concise.";

export function systemFor(name: string, persona: string, inbound: InboundData): string {
  const others = inbound.roster.length
    ? inbound.roster.map((r) => `- ${r.name} (${r.status}): ${r.summary ?? "no summary yet"}; ${r.threads} thread(s)`).join("\n")
    : "- none yet";
  return [
    `You are ${name}, an agent on Agent Relay. You own one Slack thread and answer the people in it.`,
    persona,
    `Your reply is posted to the Slack thread as-is: write Slack-ready text (short paragraphs, *bold*, \`code\`), no preamble.`,
    `Other agents on the relay right now (from the routing ledger):\n${others}`,
    `You can see and message them with the relaycast tools when another agent's work is relevant; never paste another thread's private content into this one.`,
    inbound.brief ? `Orchestrator brief for this thread: ${inbound.brief}` : "",
  ]
    .filter(Boolean)
    .join("\n\n");
}

export function promptFor(inbound: InboundData, text: string): string {
  const said = text.replace(/^@\S+\s+/, "");
  return `${said}\n\n(slack channel ${inbound.slack.channel}, thread ${inbound.slack.thread_ts}; people in the thread: ${inbound.slack.participants.map((p) => `<@${p}>`).join(", ")})`;
}

function summarize(text: string): string {
  return text.replace(/^@\S+\s+/, "").replace(/^\[slack [^\]]*\]\s*/, "").replace(/\s+/g, " ").slice(0, 140);
}

const ERROR_REPLY = "Sorry, I hit an error working on this. Try again in a moment; the details are in the agent host's logs.";

/**
 * Runs one headless Claude Code turn: start the agent's session, or resume it.
 * A session that already exists on disk (an earlier turn failed after Claude
 * created it) is resumed instead of started. CLI errors go to the log, never
 * to Slack.
 */
export function claudeTurn(opts: { bin?: string; model: string; env: NodeJS.ProcessEnv; timeoutMs: number; permissionMode?: string; allowedTools?: string[] }): RunTurn {
  const once = (t: TurnInput, resume: boolean) =>
    new Promise<TurnResult & { inUse?: boolean }>((resolve) => {
      const args = [
        "-p",
        t.prompt,
        "--output-format",
        "json",
        "--model",
        opts.model,
        "--append-system-prompt",
        t.system,
        "--permission-mode",
        opts.permissionMode ?? "dontAsk",
        ...(resume ? ["--resume", t.sessionId] : ["--session-id", t.sessionId]),
        ...(t.mcpConfigPath ? ["--mcp-config", t.mcpConfigPath, "--strict-mcp-config"] : []),
        ...(opts.allowedTools?.length ? ["--allowedTools", ...opts.allowedTools] : []),
      ];
      const fail = (detail: string) => {
        process.stderr.write(`[claude ${t.agent}] ${detail.slice(-2000)}\n`);
        resolve({ text: ERROR_REPLY, sessionId: t.sessionId, error: true, inUse: /already in use/i.test(detail) });
      };
      let child: ReturnType<typeof spawn>;
      try {
        child = spawn(opts.bin ?? "claude", args, { cwd: t.workdir, env: opts.env, stdio: ["ignore", "pipe", "pipe"] });
      } catch (e) {
        return fail(`spawn failed: ${(e as Error).message}`);
      }
      let out = "";
      let err = "";
      child.stdout!.on("data", (d) => (out += d));
      child.stderr!.on("data", (d) => (err += d));
      const timer = setTimeout(() => child.kill("SIGTERM"), opts.timeoutMs);
      child.on("error", (e) => {
        clearTimeout(timer);
        fail(`spawn failed: ${e.message}`);
      });
      child.on("close", (code) => {
        clearTimeout(timer);
        let j: { result?: string; session_id?: string; is_error?: boolean } | null = null;
        try {
          j = JSON.parse(out);
        } catch {
          return fail(`exit ${code ?? "timeout"}: ${err || out}`);
        }
        if (j!.is_error || code !== 0) return fail(`exit ${code}: ${j!.result ?? ""} ${err}`);
        resolve({ text: j!.result?.trim() || "(no reply)", sessionId: j!.session_id ?? t.sessionId, error: false });
      });
    });
  return async (t) => {
    const first = await once(t, t.resume);
    if (first.error && first.inUse && !t.resume) return once(t, true);
    return first;
  };
}
