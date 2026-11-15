// The wire contract between the router and the agent host, carried in the
// `data` of relay messages in the Slack relay channel. Each Slack thread is one
// relay thread: the router's first message is the top-level message, later
// Slack messages and the agent's answers are replies in that relay thread.

export interface SlackRef {
  team: string;
  channel: string;
  thread_ts: string;
}

export interface RosterEntry {
  name: string;
  status: string;
  summary: string | null;
  threads: number;
}

/** Router -> agent: a Slack message for the agent that owns the thread. */
export interface InboundData {
  kind: "slack.inbound";
  slack: SlackRef & { ts: string; user: string; participants: string[] };
  target: string;
  /** The agent's Claude session: resume it when `resume`, else start it with this id. */
  session: { id: string; resume: boolean };
  /** The orchestrator's brief, sent when it assigned the thread. */
  brief?: string;
  /** Every other agent and what it is doing, from the ledger. */
  roster: RosterEntry[];
}

/** Agent -> router: the agent's answer, posted back to the Slack thread. */
export interface ReplyData {
  kind: "agent.reply";
  session_id: string;
  /** One line on what the agent is working on, for the roster. */
  summary?: string;
  error?: boolean;
}

export function inboundOf(data: Record<string, unknown> | undefined): InboundData | null {
  const d = data as Partial<InboundData> | undefined;
  if (d?.kind !== "slack.inbound" || typeof d.target !== "string" || !d.slack || !d.session) return null;
  if (typeof d.session.id !== "string" || typeof d.slack.channel !== "string" || typeof d.slack.thread_ts !== "string") return null;
  return d as InboundData;
}

export function replyOf(data: Record<string, unknown> | undefined): ReplyData | null {
  const d = data as Partial<ReplyData> | undefined;
  if (d?.kind !== "agent.reply" || typeof d.session_id !== "string") return null;
  return d as ReplyData;
}

/** A relay message as events and reads deliver it (camelized by the SDK). */
export interface RelayMessageLike {
  id: string;
  agentName?: string;
  text?: string;
  metadata?: Record<string, unknown>;
  data?: Record<string, unknown>;
}

export interface RelayEventLike {
  type: string;
  channel?: string;
  parentId?: string;
  message: RelayMessageLike;
}

/** The message's `data`, wherever this engine version surfaces it. */
export function dataOf(m: RelayMessageLike | undefined): Record<string, unknown> | undefined {
  if (!m) return undefined;
  if (m.data && typeof m.data === "object") return m.data;
  const meta = m.metadata;
  if (meta && typeof meta === "object") {
    if (meta.data && typeof meta.data === "object") return meta.data as Record<string, unknown>;
    if (typeof meta.kind === "string") return meta;
  }
  return undefined;
}
