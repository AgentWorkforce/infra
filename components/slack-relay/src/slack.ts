// Slack side of the bridge: request verification, the Web API calls the bridge
// makes, Socket Mode, and turning a Slack event into a bridge message.
import { createHmac, timingSafeEqual } from "node:crypto";

export interface SlackInbound {
  team?: string;
  channel: string;
  /** Slack thread root: the message's thread_ts, or its own ts for a new thread. */
  threadTs: string;
  ts: string;
  user: string;
  text: string;
  kind: "mention" | "dm" | "thread";
}

export interface SlackEventEnvelope {
  type?: string;
  team_id?: string;
  event_id?: string;
  challenge?: string;
  event?: Record<string, unknown>;
}

const MAX_SKEW_SECONDS = 60 * 5;

/** Verifies Slack's v0 request signature (HTTP Events API mode). */
export function verifySlackSignature(opts: {
  signingSecret: string;
  timestamp: string | undefined;
  signature: string | undefined;
  rawBody: string;
  nowSeconds?: number;
}): boolean {
  const { signingSecret, timestamp, signature, rawBody } = opts;
  if (!signingSecret || !timestamp || !signature || !/^\d+$/.test(timestamp)) return false;
  const now = opts.nowSeconds ?? Math.floor(Date.now() / 1000);
  if (Math.abs(now - Number(timestamp)) > MAX_SKEW_SECONDS) return false;
  const expected = `v0=${createHmac("sha256", signingSecret).update(`v0:${timestamp}:${rawBody}`).digest("hex")}`;
  const a = Buffer.from(expected);
  const b = Buffer.from(signature);
  return a.length === b.length && timingSafeEqual(a, b);
}

/**
 * Maps a Slack event to a bridge message, or null when the bridge ignores it.
 * Bot messages (including our own), edits and other subtypes are ignored.
 * `isTrackedThread` lets plain channel replies through only in threads the
 * bridge already relays (a conversation that started with a mention).
 */
export function normalizeSlackEvent(
  event: Record<string, unknown> | undefined,
  opts: { botUserId?: string; teamId?: string; isTrackedThread?: (channel: string, threadTs: string) => boolean },
): SlackInbound | null {
  if (!event) return null;
  const type = str(event.type);
  if (event.bot_id || event.subtype || event.hidden) return null;
  const channel = str(event.channel);
  const ts = str(event.ts);
  const user = str(event.user);
  if (!channel || !ts || !user) return null;
  if (opts.botUserId && user === opts.botUserId) return null;
  const threadTs = str(event.thread_ts) || ts;
  const text = stripMention(str(event.text), opts.botUserId);
  if (!text) return null;
  const base = { team: str(event.team) || opts.teamId, channel, threadTs, ts, user, text };

  if (type === "app_mention") return { ...base, kind: "mention" };
  if (type !== "message") return null;
  if (str(event.channel_type) === "im") return { ...base, kind: "dm" };
  // A channel message that mentions the bot also arrives as app_mention; take
  // only replies in threads the bridge is already relaying.
  if (str(event.thread_ts) && opts.isTrackedThread?.(channel, threadTs)) {
    if (opts.botUserId && str(event.text).includes(`<@${opts.botUserId}>`)) return null;
    return { ...base, kind: "thread" };
  }
  return null;
}

function stripMention(text: string, botUserId?: string): string {
  const out = botUserId ? text.split(`<@${botUserId}>`).join(" ") : text;
  return out.replace(/\s+/g, " ").trim();
}

function str(v: unknown): string {
  return typeof v === "string" ? v : "";
}

export interface SlackWebLike {
  postMessage(args: { channel: string; text: string; threadTs?: string }): Promise<{ ts?: string }>;
}

/** The few Slack Web API calls the bridge makes. */
export class SlackWeb implements SlackWebLike {
  readonly #token: string;
  readonly #baseUrl: string;

  constructor(token: string, baseUrl = "https://slack.com/api") {
    this.#token = token;
    this.#baseUrl = baseUrl.replace(/\/$/, "");
  }

  async call(method: string, body: Record<string, unknown>, token = this.#token): Promise<Record<string, unknown>> {
    for (let attempt = 0; ; attempt++) {
      const res = await fetch(`${this.#baseUrl}/${method}`, {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json; charset=utf-8" },
        body: JSON.stringify(body),
      });
      if (res.status === 429 && attempt < 3) {
        const wait = Number(res.headers.get("retry-after") ?? "1");
        await new Promise((r) => setTimeout(r, Math.min(Math.max(wait, 1), 30) * 1000));
        continue;
      }
      const json = (await res.json().catch(() => ({}))) as Record<string, unknown>;
      if (!res.ok || json.ok !== true) {
        throw new Error(`slack ${method} failed: ${res.status} ${String(json.error ?? "unknown_error")}`);
      }
      return json;
    }
  }

  async authTest(): Promise<{ userId: string; teamId: string; team: string }> {
    const r = await this.call("auth.test", {});
    return { userId: String(r.user_id ?? ""), teamId: String(r.team_id ?? ""), team: String(r.team ?? "") };
  }

  async postMessage(args: { channel: string; text: string; threadTs?: string }): Promise<{ ts?: string }> {
    const r = await this.call("chat.postMessage", {
      channel: args.channel,
      text: args.text,
      ...(args.threadTs ? { thread_ts: args.threadTs } : {}),
      unfurl_links: false,
    });
    return { ts: typeof r.ts === "string" ? r.ts : undefined };
  }

  async openSocketUrl(appToken: string): Promise<string> {
    const r = await this.call("apps.connections.open", {}, appToken);
    if (typeof r.url !== "string") throw new Error("slack apps.connections.open returned no url");
    return r.url;
  }
}

/**
 * Slack Socket Mode: an outbound WebSocket, so the bridge needs no public
 * ingress. Each envelope is acknowledged before it is handled; Slack asks for
 * an ack within 3 seconds. Reconnects when Slack sends `disconnect` or the
 * socket drops.
 */
export class SocketModeClient {
  readonly #web: SlackWeb;
  readonly #appToken: string;
  readonly #onEnvelope: (payload: SlackEventEnvelope) => void;
  readonly #log: (msg: string) => void;
  #ws: WebSocket | null = null;
  #stopped = false;
  #attempt = 0;
  connected = false;

  constructor(opts: { web: SlackWeb; appToken: string; onEnvelope: (p: SlackEventEnvelope) => void; log?: (m: string) => void }) {
    this.#web = opts.web;
    this.#appToken = opts.appToken;
    this.#onEnvelope = opts.onEnvelope;
    this.#log = opts.log ?? (() => {});
  }

  async start(): Promise<void> {
    this.#stopped = false;
    await this.#connect();
  }

  stop(): void {
    this.#stopped = true;
    this.#ws?.close();
  }

  async #connect(): Promise<void> {
    while (!this.#stopped) {
      try {
        const url = await this.#web.openSocketUrl(this.#appToken);
        this.#open(url);
        return;
      } catch (err) {
        const delay = Math.min(30_000, 1000 * 2 ** this.#attempt++);
        this.#log(`socket mode connect failed (${(err as Error).message}); retrying in ${delay}ms`);
        await new Promise((r) => setTimeout(r, delay));
      }
    }
  }

  #open(url: string): void {
    const ws = new WebSocket(url);
    this.#ws = ws;
    ws.onopen = () => {
      this.#attempt = 0;
    };
    ws.onmessage = (ev: MessageEvent) => {
      let msg: Record<string, unknown>;
      try {
        msg = JSON.parse(String(ev.data)) as Record<string, unknown>;
      } catch {
        return;
      }
      if (msg.type === "hello") {
        this.connected = true;
        this.#log("socket mode connected");
        return;
      }
      if (msg.type === "disconnect") {
        this.#log(`socket mode disconnect requested (${String(msg.reason ?? "")})`);
        ws.close();
        return;
      }
      if (typeof msg.envelope_id === "string") ws.send(JSON.stringify({ envelope_id: msg.envelope_id }));
      if (msg.type === "events_api" && msg.payload && typeof msg.payload === "object") {
        this.#onEnvelope(msg.payload as SlackEventEnvelope);
      }
    };
    ws.onclose = () => {
      if (this.#ws !== ws) return;
      this.connected = false;
      this.#ws = null;
      if (!this.#stopped) void this.#connect();
    };
    ws.onerror = () => {
      // onclose follows and reconnects.
    };
  }
}
