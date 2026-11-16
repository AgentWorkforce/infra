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
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { isGateDenial } from "./gate.ts";
import { sessionIdFor } from "./session-id.ts";
import { dataOf, inboundOf, type InboundData, type RelayEventLike, type RelayMessageLike, type ReplyData } from "./protocol.ts";

export interface HostAgentClient {
  reply(id: string, text: string, opts?: { data?: Record<string, unknown> }): Promise<{ id: string }>;
  dm?(to: string, text: string, opts?: { data?: Record<string, unknown> }): Promise<unknown>;
  /** Reads a message the agent can see: DM events carry no `data`. */
  message?(id: string): Promise<RelayMessageLike>;
  /** Realtime for the agent's own DMs ("@self"). */
  subscribe?(channels: string[], handler: (raw: unknown) => void): unknown;
  disconnect?(): Promise<void>;
}

/** A DM to a hosted agent, normalized from the SDK's camelized or the engine's snake_case event. */
export interface DmEvent {
  id: string;
  from: string;
  text: string;
  data?: Record<string, unknown>;
}

export function dmOf(raw: unknown): DmEvent | null {
  const e = raw as Record<string, unknown> | null;
  if (!e || e.type !== "dm.received") return null;
  const m = (e.message ?? {}) as Record<string, unknown>;
  const from = (m.agentName ?? m.agent_name) as string | undefined;
  if (typeof m.id !== "string" || !from || typeof m.text !== "string") return null;
  return { id: m.id, from, text: m.text, data: dataOf({ id: m.id, metadata: m.metadata as Record<string, unknown> | undefined, data: m.data as Record<string, unknown> | undefined }) };
}

/** Marks an agent's automatic DM answer, so the answer itself doesn't trigger another one. */
const DM_REPLY = "agent.dm.reply";

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
  mcpConfig?: (agent: string, token: string) => Record<string, unknown> | null | Promise<Record<string, unknown> | null>;
  persona?: string;
  idleMs?: number;
  /** Behind relaygate: a 403 on a reply is the gate's final denial, never retried. */
  gated?: boolean;
  /**
   * Called after each turn (and for every known agent on rejoin) so the agent's Claude session can be uploaded
   * as the agent. Fire and forget: it never delays or fails a turn.
   */
  sessionUpload?: (u: { agent: string; token: string; sessionId: string; workdir: string; slack?: { channel: string; thread_ts: string } }) => Promise<unknown>;
  log?: (m: string) => void;
}

type HostConfig = Required<Omit<HostOptions, "mcpConfig" | "getMessage" | "sessionUpload">> & Pick<HostOptions, "mcpConfig" | "getMessage" | "sessionUpload">;

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
  /** Message ids being handled or answered; a failed one is forgotten so a redelivery retries it. */
  readonly #handled = new BoundedIds(20_000);

  constructor(o: HostOptions) {
    this.#o = {
      persona: DEFAULT_PERSONA,
      idleMs: 15 * 60_000,
      gated: false,
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
    if (this.#handled.has(msg.id)) return null;
    let inbound = inboundOf(dataOf(msg));
    if (!inbound && ev.type === "thread.reply" && this.#o.getMessage) {
      inbound = inboundOf(dataOf(await this.#o.getMessage(msg.id)));
    }
    if (!inbound) return null;
    if (this.#handled.has(msg.id)) return null;
    this.#handled.add(msg.id);
    try {
      const parentId = ev.type === "thread.reply" && ev.parentId ? ev.parentId : msg.id;
      const live = await this.#wake(inbound.target);
      const run = live.queue.catch(() => undefined).then(() => this.#turn(live, inbound, msg.text ?? "", parentId));
      live.queue = run;
      return await run;
    } catch (err) {
      this.#handled.delete(msg.id);
      throw err;
    }
  }

  /**
   * Agents idle longer than `idleMs`. No process runs for an idle agent; the
   * host keeps only its relay connection, so a DM or a routed Slack message
   * can wake it, as a node keeps its agents reachable.
   */
  idleAgents(now = Date.now()): string[] {
    return [...this.#live].filter(([, l]) => l.busy === 0 && now - l.lastUsed >= this.#o.idleMs).map(([n]) => n);
  }

  /** Re-joins every agent this host has hosted (after a restart), so their DMs reach them. */
  async rejoinKnown(): Promise<string[]> {
    const dir = join(this.#o.dataDir, "agents");
    const names = existsSync(dir) ? readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name) : [];
    const failed: string[] = [];
    for (const name of names) {
      await this.#wake(name)
        .then((live) => this.#uploadStarted(name, live))
        .catch((err) => {
          failed.push(name);
          this.#o.log(`rejoin ${name} failed: ${(err as Error).message}; retrying`);
        });
    }
    // Keep retrying the ones that failed, so their DMs reach them eventually.
    for (let delay = 30_000; failed.length; delay = Math.min(delay * 2, 30 * 60_000)) {
      await new Promise((r) => setTimeout(r, delay).unref());
      for (const name of [...failed]) {
        try {
          this.#uploadStarted(name, await this.#wake(name));
          failed.splice(failed.indexOf(name), 1);
        } catch {
          // next round
        }
      }
    }
    return names.filter((n) => !failed.includes(n));
  }

  /** Leaves the relay for every agent (shutdown and tests). */
  async disconnectAll(): Promise<void> {
    for (const [name, live] of this.#live) {
      this.#live.delete(name);
      await live.session.client.disconnect?.().catch(() => undefined);
    }
  }

  /**
   * A DM to a hosted agent: one turn in the agent's own session. A normal DM
   * is answered by DM; an automatic answer from another agent is taken in
   * without replying, so two agents can't ping-pong forever.
   */
  async onDm(name: string, dm: DmEvent): Promise<string | null> {
    if (dm.from === name || dm.from === this.#o.routerName) return null;
    if (this.#handled.has(dm.id)) return null;
    this.#handled.add(dm.id);
    try {
      return await this.#dmTurn(name, dm);
    } catch (err) {
      if (this.#o.gated && isGateDenial(err)) {
        // relaygate refused the reply (e.g. a pit agent answering an outside agent): final, never retried.
        this.#o.log(`${name}: reply to ${dm.from} denied by relaygate`);
        return null;
      }
      this.#handled.delete(dm.id);
      throw err;
    }
  }

  async #dmTurn(name: string, dm: DmEvent): Promise<string | null> {
    const live = await this.#wake(name);
    let data = dm.data;
    let unknownKind = false;
    if (!data && live.session.client.message) {
      try {
        data = dataOf(await live.session.client.message(dm.id));
      } catch {
        unknownKind = true; // the read failed; a DM with no data at all is an ordinary one
      }
    }
    // If it can't be told whether this is another agent's automatic answer,
    // take it in without replying: a missed reply beats an endless loop.
    const isAnswer = data?.kind === DM_REPLY || unknownKind;
    const run = live.queue.catch(() => undefined).then(async () => {
      live.busy++;
      try {
        const workdir = join(this.#o.dataDir, "agents", name);
        mkdirSync(workdir, { recursive: true });
        const marker = join(workdir, ".session-started");
        const started = existsSync(marker);
        const sessionId = started ? readFileSync(marker, "utf8").trim() : sessionIdFor(name);
        const result = await this.#o.runTurn({
          agent: name,
          workdir,
          sessionId,
          resume: started,
          prompt: isAnswer
            ? `${dm.from} answered your direct message on the relay:\n\n${dm.text}\n\n(Take this into account; no reply is sent for this turn.)`
            : `Direct message on the relay from ${dm.from}:\n\n${dm.text}\n\n(Your answer is sent back to ${dm.from} as a direct message.)`,
          system: [`You are ${name}, an agent on Agent Relay.`, this.#o.persona].join("\n\n"),
          mcpConfigPath: await this.#mcpPath(name, workdir, live),
        });
        if (!result.error) writeFileSync(marker, result.sessionId);
        this.#upload({ agent: name, token: live.session.token, sessionId: result.sessionId, workdir });
        if (isAnswer || !live.session.client.dm) return null;
        await live.session.client.dm(dm.from, result.text, { data: { kind: DM_REPLY, session_id: result.sessionId } });
        this.#o.log(`${name} answered a DM from ${dm.from}`);
        return dm.from;
      } finally {
        live.busy--;
        live.lastUsed = Date.now();
      }
    });
    live.queue = run;
    return run;
  }

  /** Uploads what an agent's session has past its cursor (after a restart), if it has one. */
  #uploadStarted(name: string, live: Live): void {
    const workdir = join(this.#o.dataDir, "agents", name);
    const marker = join(workdir, ".session-started");
    if (!this.#o.sessionUpload || !existsSync(marker)) return;
    const sessionId = readFileSync(marker, "utf8").trim();
    if (sessionId) this.#upload({ agent: name, token: live.session.token, sessionId, workdir });
  }

  #upload(u: Parameters<NonNullable<HostOptions["sessionUpload"]>>[0]): void {
    const up = this.#o.sessionUpload;
    if (!up) return;
    void Promise.resolve()
      .then(() => up(u))
      .catch((err) => this.#o.log(`${u.agent}: session upload failed: ${(err as Error).message}`));
  }

  async #mcpPath(name: string, workdir: string, live: Live): Promise<string | null> {
    const mcp = (await this.#o.mcpConfig?.(name, live.session.token)) ?? null;
    if (!mcp) return null;
    const p = join(workdir, ".mcp.json");
    writeFileSync(p, JSON.stringify(mcp), { mode: 0o600 });
    return p;
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
      // DMs wake the agent too: from people, or from other agents on the relay.
      session.client.subscribe?.(["@self"], (raw) => {
        const dm = dmOf(raw);
        if (dm) void this.onDm(name, dm).catch((err) => this.#o.log(`${name} DM turn failed: ${(err as Error).message}`));
      });
      this.#o.log(`${name} joined the relay`);
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
      const mcpConfigPath = await this.#mcpPath(name, workdir, live);
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
      this.#upload({ agent: name, token: live.session.token, sessionId: result.sessionId, workdir, slack: { channel: inbound.slack.channel, thread_ts: inbound.slack.thread_ts } });
      const data: ReplyData = {
        kind: "agent.reply",
        session_id: result.sessionId,
        // What the agent is on, without the thread's words: the roster is
        // shown to other agents, and a thread may be private.
        summary: `Slack thread in ${inbound.slack.channel} with ${inbound.slack.participants.length} ${inbound.slack.participants.length === 1 ? "person" : "people"}`,
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


const ERROR_REPLY = "Sorry, I hit an error working on this. Try again in a moment; the details are in the agent host's logs.";

/**
 * Runs one headless Claude Code turn: start the agent's session, or resume it.
 * A session that already exists on disk (an earlier turn failed after Claude
 * created it) is resumed instead of started. CLI errors go to the log, never
 * to Slack.
 */
export function claudeTurn(opts: { bin?: string; model: string; env: NodeJS.ProcessEnv; timeoutMs: number; permissionMode?: string; allowedTools?: string[]; disallowedTools?: string[] }): RunTurn {
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
        ...(opts.disallowedTools?.length ? ["--disallowedTools", ...opts.disallowedTools] : []),
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
      let settled = false;
      const done = resolve;
      resolve = ((r: TurnResult & { inUse?: boolean }) => {
        if (settled) return;
        settled = true;
        done(r);
      }) as typeof resolve;
      // Past the deadline: SIGTERM, then SIGKILL, and the turn settles either
      // way, so the agent's queue never waits on a stuck process.
      const timer = setTimeout(() => {
        child.kill("SIGTERM");
        setTimeout(() => {
          if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
          fail(`turn timed out after ${opts.timeoutMs} ms`);
        }, 10_000).unref();
      }, opts.timeoutMs);
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

/** A set of ids that keeps the most recent `max`, evicting the oldest. */
class BoundedIds {
  readonly #max: number;
  readonly #ids = new Map<string, true>();
  constructor(max: number) {
    this.#max = max;
  }
  has(id: string): boolean {
    return this.#ids.has(id);
  }
  add(id: string): void {
    this.#ids.set(id, true);
    while (this.#ids.size > this.#max) this.#ids.delete(this.#ids.keys().next().value as string);
  }
  delete(id: string): void {
    this.#ids.delete(id);
  }
}
