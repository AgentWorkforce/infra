// The routing ledger: the deterministic record of which agent owns which Slack
// thread, who has spoken in it, and every routing decision made. The flow
// reads it to route a message without asking a model; only a thread with no
// owner goes to the orchestrator, and its decision is written back here.
//
// SQLite (node:sqlite, no native dependency). Append-only `events` is the
// audit trail; `threads`, `participants` and `agents` are its current state.
import { createHash } from "node:crypto";
import { DatabaseSync } from "node:sqlite";

export type AgentStatus = "spawning" | "active" | "idle" | "released" | "failed";

export interface ThreadKey {
  team: string;
  channel: string;
  threadTs: string;
}

export interface ThreadRow extends ThreadKey {
  agentName: string | null;
  relayParentId: string | null;
  status: "open" | "closed";
  createdAt: number;
  lastActivityAt: number;
}

export interface AgentRow {
  agentName: string;
  status: AgentStatus;
  sessionId: string | null;
  cli: string | null;
  model: string | null;
  summary: string | null;
  lastWakeAt: number | null;
  lastActivityAt: number;
  releasedAt: number | null;
}

export type RouteDecision =
  | { kind: "owned"; thread: ThreadRow; agent: AgentRow; wake: boolean }
  | { kind: "unowned"; thread: ThreadRow };

const SCHEMA = `
CREATE TABLE IF NOT EXISTS threads (
  team TEXT NOT NULL, channel TEXT NOT NULL, thread_ts TEXT NOT NULL,
  agent_name TEXT, relay_parent_id TEXT,
  status TEXT NOT NULL DEFAULT 'open',
  created_at INTEGER NOT NULL, last_activity_at INTEGER NOT NULL,
  PRIMARY KEY (team, channel, thread_ts)
);
CREATE INDEX IF NOT EXISTS threads_agent ON threads(agent_name);
CREATE TABLE IF NOT EXISTS participants (
  team TEXT NOT NULL, channel TEXT NOT NULL, thread_ts TEXT NOT NULL, slack_user TEXT NOT NULL,
  first_seen_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL, messages INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (team, channel, thread_ts, slack_user)
);
CREATE TABLE IF NOT EXISTS agents (
  agent_name TEXT PRIMARY KEY, status TEXT NOT NULL,
  session_id TEXT, cli TEXT, model TEXT, summary TEXT,
  last_wake_at INTEGER, last_activity_at INTEGER NOT NULL, released_at INTEGER
);
CREATE TABLE IF NOT EXISTS events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, kind TEXT NOT NULL,
  team TEXT, channel TEXT, thread_ts TEXT, agent_name TEXT, slack_user TEXT,
  slack_ts TEXT UNIQUE, detail TEXT
);
`;

export class Ledger {
  readonly db: DatabaseSync;
  readonly #now: () => number;

  constructor(path: string, opts: { now?: () => number } = {}) {
    this.db = new DatabaseSync(path);
    this.db.exec("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000; PRAGMA foreign_keys = ON;");
    this.db.exec(SCHEMA);
    this.#now = opts.now ?? Date.now;
  }

  close(): void {
    this.db.close();
  }

  /**
   * Records an inbound Slack message and returns the deterministic route.
   * Returns null when this Slack message (team/channel/ts) was already
   * recorded, so Slack retries and duplicate event deliveries route once.
   */
  recordInbound(m: ThreadKey & { ts: string; user: string; text: string }): RouteDecision | null {
    const now = this.#now();
    const key = `${m.team}/${m.channel}/${m.ts}`;
    const dup = this.db.prepare("SELECT 1 FROM events WHERE slack_ts = ?").get(key);
    if (dup) return null;
    this.db.exec("BEGIN IMMEDIATE");
    try {
      this.db
        .prepare(
          `INSERT INTO threads (team, channel, thread_ts, created_at, last_activity_at) VALUES (?, ?, ?, ?, ?)
           ON CONFLICT (team, channel, thread_ts) DO UPDATE SET last_activity_at = excluded.last_activity_at, status = 'open'`,
        )
        .run(m.team, m.channel, m.threadTs, now, now);
      this.db
        .prepare(
          `INSERT INTO participants (team, channel, thread_ts, slack_user, first_seen_at, last_seen_at, messages) VALUES (?, ?, ?, ?, ?, ?, 1)
           ON CONFLICT DO UPDATE SET last_seen_at = excluded.last_seen_at, messages = messages + 1`,
        )
        .run(m.team, m.channel, m.threadTs, m.user, now, now);
      this.#event("inbound", { ...m, slackTs: key, detail: { text: m.text.slice(0, 2000) } });
      this.db.exec("COMMIT");
    } catch (err) {
      this.db.exec("ROLLBACK");
      throw err;
    }
    const thread = this.thread(m)!;
    if (!thread.agentName) return { kind: "unowned", thread };
    const agent = this.agent(thread.agentName);
    if (!agent) return { kind: "unowned", thread };
    return { kind: "owned", thread, agent, wake: agent.status === "released" || agent.status === "idle" || agent.status === "failed" };
  }

  /** Forgets an inbound Slack message that could not be delivered, so it can be routed again. */
  forgetInbound(key: ThreadKey, ts: string): void {
    this.db.prepare("DELETE FROM events WHERE slack_ts = ?").run(`${key.team}/${key.channel}/${ts}`);
    this.#event("inbound.undelivered", { ...key, detail: { ts } });
  }

  /** Assigns a thread to an agent (the orchestrator's decision, or a deterministic default). */
  assign(key: ThreadKey, agentName: string, by: string, reason = ""): void {
    const now = this.#now();
    this.db.exec("BEGIN IMMEDIATE");
    try {
      this.db
        .prepare("UPDATE threads SET agent_name = ?, last_activity_at = ? WHERE team = ? AND channel = ? AND thread_ts = ?")
        .run(agentName, now, key.team, key.channel, key.threadTs);
      this.db
        .prepare(
          `INSERT INTO agents (agent_name, status, last_activity_at) VALUES (?, 'spawning', ?)
           ON CONFLICT (agent_name) DO NOTHING`,
        )
        .run(agentName, now);
      this.#event("assign", { ...key, agentName, detail: { by, reason } });
      this.db.exec("COMMIT");
    } catch (err) {
      this.db.exec("ROLLBACK");
      throw err;
    }
  }

  setRelayParent(key: ThreadKey, relayParentId: string): void {
    this.db
      .prepare("UPDATE threads SET relay_parent_id = ? WHERE team = ? AND channel = ? AND thread_ts = ?")
      .run(relayParentId, key.team, key.channel, key.threadTs);
  }

  /** Records an agent lifecycle change (spawned, woke, went idle, released) and its session id. */
  setAgentStatus(agentName: string, status: AgentStatus, patch: Partial<Pick<AgentRow, "sessionId" | "cli" | "model" | "summary">> = {}): void {
    const now = this.#now();
    this.db
      .prepare(
        `INSERT INTO agents (agent_name, status, session_id, cli, model, summary, last_wake_at, last_activity_at, released_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (agent_name) DO UPDATE SET
           status = excluded.status,
           session_id = COALESCE(excluded.session_id, agents.session_id),
           cli = COALESCE(excluded.cli, agents.cli),
           model = COALESCE(excluded.model, agents.model),
           summary = COALESCE(excluded.summary, agents.summary),
           last_wake_at = COALESCE(excluded.last_wake_at, agents.last_wake_at),
           last_activity_at = excluded.last_activity_at,
           released_at = CASE WHEN excluded.status = 'released' THEN excluded.last_activity_at ELSE NULL END`,
      )
      .run(
        agentName,
        status,
        patch.sessionId ?? null,
        patch.cli ?? null,
        patch.model ?? null,
        patch.summary ?? null,
        status === "active" ? now : null,
        now,
        status === "released" ? now : null,
      );
    this.#event(`agent.${status}`, { agentName, detail: patch });
  }

  recordOutbound(key: ThreadKey, agentName: string, slackTs: string | undefined): void {
    this.db
      .prepare("UPDATE threads SET last_activity_at = ? WHERE team = ? AND channel = ? AND thread_ts = ?")
      .run(this.#now(), key.team, key.channel, key.threadTs);
    this.db.prepare("UPDATE agents SET last_activity_at = ? WHERE agent_name = ?").run(this.#now(), agentName);
    this.#event("outbound", { ...key, agentName, detail: { slackTs } });
  }

  thread(key: ThreadKey): ThreadRow | null {
    const r = this.db
      .prepare("SELECT * FROM threads WHERE team = ? AND channel = ? AND thread_ts = ?")
      .get(key.team, key.channel, key.threadTs) as Record<string, unknown> | undefined;
    return r ? toThread(r) : null;
  }

  threadByRelayParent(relayParentId: string): ThreadRow | null {
    const r = this.db.prepare("SELECT * FROM threads WHERE relay_parent_id = ?").get(relayParentId) as Record<string, unknown> | undefined;
    return r ? toThread(r) : null;
  }

  agent(agentName: string): AgentRow | null {
    const r = this.db.prepare("SELECT * FROM agents WHERE agent_name = ?").get(agentName) as Record<string, unknown> | undefined;
    return r ? toAgent(r) : null;
  }

  participants(key: ThreadKey): string[] {
    return (
      this.db
        .prepare("SELECT slack_user FROM participants WHERE team = ? AND channel = ? AND thread_ts = ? ORDER BY first_seen_at")
        .all(key.team, key.channel, key.threadTs) as Array<{ slack_user: string }>
    ).map((r) => r.slack_user);
  }

  /** What the orchestrator sees: every agent, its status and the threads it owns. */
  roster(): Array<AgentRow & { threads: Array<ThreadKey & { participants: string[] }> }> {
    const agents = (this.db.prepare("SELECT * FROM agents ORDER BY last_activity_at DESC").all() as Array<Record<string, unknown>>).map(toAgent);
    return agents.map((a) => ({
      ...a,
      threads: (
        this.db.prepare("SELECT team, channel, thread_ts FROM threads WHERE agent_name = ? AND status = 'open'").all(a.agentName) as Array<
          Record<string, string>
        >
      ).map((t) => {
        const key = { team: t.team!, channel: t.channel!, threadTs: t.thread_ts! };
        return { ...key, participants: this.participants(key) };
      }),
    }));
  }

  /** Agents active but silent for longer than `idleMs`: candidates to release. */
  idleAgents(idleMs: number): AgentRow[] {
    return (
      this.db
        .prepare("SELECT * FROM agents WHERE status IN ('active', 'idle') AND last_activity_at < ?")
        .all(this.#now() - idleMs) as Array<Record<string, unknown>>
    ).map(toAgent);
  }

  events(limit = 100): Array<Record<string, unknown>> {
    return this.db.prepare("SELECT * FROM events ORDER BY seq DESC LIMIT ?").all(limit) as Array<Record<string, unknown>>;
  }

  #event(
    kind: string,
    e: Partial<ThreadKey> & { agentName?: string; user?: string; slackTs?: string; detail?: unknown },
  ): void {
    this.db
      .prepare(
        "INSERT INTO events (at, kind, team, channel, thread_ts, agent_name, slack_user, slack_ts, detail) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        this.#now(),
        kind,
        e.team ?? null,
        e.channel ?? null,
        e.threadTs ?? null,
        e.agentName ?? null,
        e.user ?? null,
        e.slackTs ?? null,
        e.detail === undefined ? null : JSON.stringify(e.detail),
      );
  }
}

/** Deterministic default agent name for a thread: stable, relay-safe, unique per thread. */
export function threadAgentName(key: ThreadKey, prefix = "slack"): string {
  const ts = key.threadTs.replace(/\D/g, "");
  const name = `${prefix}-${key.channel.toLowerCase()}-${ts}`;
  if (name.length <= 63) return name;
  // Too long: keep a readable head and a hash of the whole thread key, so
  // distinct threads never collapse onto one agent.
  const hash = createHash("sha256").update(`${key.team}/${key.channel}/${key.threadTs}`).digest("hex").slice(0, 12);
  return `${name.slice(0, 63 - 13).replace(/-+$/, "")}-${hash}`;
}

function toThread(r: Record<string, unknown>): ThreadRow {
  return {
    team: String(r.team),
    channel: String(r.channel),
    threadTs: String(r.thread_ts),
    agentName: (r.agent_name as string | null) ?? null,
    relayParentId: (r.relay_parent_id as string | null) ?? null,
    status: r.status === "closed" ? "closed" : "open",
    createdAt: Number(r.created_at),
    lastActivityAt: Number(r.last_activity_at),
  };
}

function toAgent(r: Record<string, unknown>): AgentRow {
  return {
    agentName: String(r.agent_name),
    status: r.status as AgentStatus,
    sessionId: (r.session_id as string | null) ?? null,
    cli: (r.cli as string | null) ?? null,
    model: (r.model as string | null) ?? null,
    summary: (r.summary as string | null) ?? null,
    lastWakeAt: r.last_wake_at == null ? null : Number(r.last_wake_at),
    lastActivityAt: Number(r.last_activity_at),
    releasedAt: r.released_at == null ? null : Number(r.released_at),
  };
}
