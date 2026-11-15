// Continuous Slack ingest into a knowledge base (a gbrain "company brain")
// over MCP. Every human message in a channel the app is in is appended, as it
// arrives, to one page per channel per UTC day: slack/<channel>/<YYYY-MM-DD>.
// append_page is idempotent by request_id (derived from the Slack message), so
// Slack retries and router restarts never duplicate a line.
import { createHash } from "node:crypto";
import { McpToolError } from "./mcp.ts";

export interface IngestMessage {
  channel: string;
  channelName: string;
  /** Private channels can go to their own source (privateSourceId). */
  isPrivate?: boolean;
  ts: string;
  threadTs?: string;
  user: string;
  text: string;
}

export interface ToolCaller {
  callTool(name: string, args: Record<string, unknown>): Promise<unknown>;
}

/** Messages that look like they carry credentials are withheld from the brain. */
const SECRET_RE = /(xox[abposr]-[A-Za-z0-9-]{10,}|xapp-\d-[A-Za-z0-9-]{10,}|sk-ant-[A-Za-z0-9_-]{10,}|sk-[A-Za-z0-9]{32,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)/;

export function requestId(...parts: string[]): string {
  const h = createHash("sha256").update(parts.join("/")).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

/** slack/<channel name>-<channel id>/<YYYY-MM-DD>: readable, and distinct even when two names normalize alike. */
export function pageSlug(prefix: string, channelName: string, ts: string, channelId: string): string {
  const day = new Date(Number(ts.split(".")[0]) * 1000).toISOString().slice(0, 10);
  const name = channelName.toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "") || "channel";
  return `${prefix}/${name}-${channelId.toLowerCase()}/${day}`;
}

export function lineFor(m: IngestMessage): string {
  const time = new Date(Number(m.ts.split(".")[0]) * 1000).toISOString().slice(11, 16);
  const thread = m.threadTs && m.threadTs !== m.ts ? ` (in thread ${m.threadTs})` : "";
  const text = m.text.replace(/\r?\n/g, "\n  ");
  return `- ${time} UTC <@${m.user}>${thread}: ${text}`;
}

/** A channel-name rule: channels whose name matches go to `sourceId`. First match wins. */
export interface SourceRule {
  match: string;
  sourceId: string;
}

export class SlackIngest {
  readonly #brain: ToolCaller;
  readonly #brains: Map<string, ToolCaller>;
  readonly #sourceId: string | undefined;
  readonly #privateSourceId: string | undefined;
  readonly #rules: Array<{ re: RegExp; sourceId: string }>;
  readonly #prefix: string;
  readonly #log: (m: string) => void;
  readonly #chains = new Map<string, Promise<unknown>>();

  readonly #beforeWrite: ((slug: string, text: string, sourceId: string | undefined) => Promise<void>) | undefined;

  constructor(opts: {
    brain: ToolCaller;
    /**
     * A writer per source. gbrain lets a remote client write only to its own
     * write source, so each source other than the default needs its own
     * client. A source with no entry here uses `brain`.
     */
    brains?: Record<string, ToolCaller>;
    sourceId?: string;
    privateSourceId?: string;
    rules?: SourceRule[];
    prefix?: string;
    log?: (m: string) => void;
    /** Asked before each write (relaygate /v1/check); rejects to skip it. */
    beforeWrite?: (slug: string, text: string, sourceId: string | undefined) => Promise<void>;
  }) {
    this.#beforeWrite = opts.beforeWrite;
    this.#brain = opts.brain;
    this.#brains = new Map(Object.entries(opts.brains ?? {}));
    this.#sourceId = opts.sourceId || undefined;
    this.#privateSourceId = opts.privateSourceId || undefined;
    this.#rules = (opts.rules ?? []).map((r) => ({ re: new RegExp(r.match), sourceId: r.sourceId }));
    this.#prefix = opts.prefix ?? "slack";
    this.#log = opts.log ?? (() => {});
  }

  /** Appends one message; per-page appends are serialized. Resolves to the page slug, or null if withheld. */
  add(m: IngestMessage): Promise<string | null> {
    if (!m.text.trim()) return Promise.resolve(null);
    if (SECRET_RE.test(m.text)) {
      this.#log(`ingest: withheld a message in #${m.channelName} that looks like a credential`);
      return Promise.resolve(null);
    }
    const slug = pageSlug(this.#prefix, m.channelName, m.ts, m.channel);
    const prior = this.#chains.get(slug) ?? Promise.resolve();
    const run = prior.catch(() => undefined).then(() => this.#append(slug, m));
    this.#chains.set(slug, run);
    const cleanup = () => {
      if (this.#chains.get(slug) === run) this.#chains.delete(slug);
    };
    run.then(cleanup, cleanup);
    return run;
  }

  /** The source a channel's messages go to: name rules first, then private, then the default. */
  sourceFor(channelName: string, isPrivate: boolean): string | undefined {
    const rule = this.#rules.find((r) => r.re.test(channelName));
    if (rule) return rule.sourceId;
    if (isPrivate && this.#privateSourceId) return this.#privateSourceId;
    return this.#sourceId;
  }

  /** True when this message's create request is on record (gbrain get_write_request). */
  async #created(brain: ToolCaller, m: IngestMessage): Promise<boolean> {
    try {
      await brain.callTool("get_write_request", { request_id: requestId("create", m.channel, m.ts) });
      return true;
    } catch (err) {
      // not_found (or a server without receipts): not created by this message.
      if (err instanceof McpToolError) return false;
      throw err;
    }
  }

  async #append(slug: string, m: IngestMessage): Promise<string> {
    const line = lineFor(m);
    const sourceId = this.sourceFor(m.channelName, m.isPrivate === true);
    if (this.#beforeWrite) await this.#beforeWrite(slug, line, sourceId);
    const source = sourceId ? { source_id: sourceId } : {};
    const brain = (sourceId && this.#brains.get(sourceId)) || this.#brain;
    // The day's first message created the page under its "create" request;
    // a replay (backfill, Slack retry) would append it again under "append".
    if (await this.#created(brain, m)) return slug;
    try {
      await brain.callTool("append_page", { slug, text: line, request_id: requestId("append", m.channel, m.ts), ...source });
    } catch (err) {
      if (!(err instanceof McpToolError) || !/not.?found|no such page|does not exist|unknown page/i.test(err.message)) throw err;
      // First message of the day in this channel: create the page with it.
      const day = slug.split("/").pop();
      const content = `# #${m.channelName}: ${day}\n\nSlack messages in #${m.channelName} (${m.channel}) on ${day}, ingested as they were posted.\n\n${line}\n`;
      // relaygate's rule: what is written is exactly what was checked.
      if (this.#beforeWrite) await this.#beforeWrite(slug, content, sourceId);
      try {
        await brain.callTool("put_page", { slug, content, request_id: requestId("create", m.channel, m.ts), ...source });
      } catch (e) {
        // Another writer created it first: append after all.
        if (!(e instanceof McpToolError)) throw e;
        await brain.callTool("append_page", { slug, text: line, request_id: requestId("append", m.channel, m.ts), ...source });
      }
    }
    return slug;
  }
}
