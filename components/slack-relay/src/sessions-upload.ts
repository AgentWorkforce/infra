// Headless session uploader: each hosted agent's Claude Code transcript goes to
// Agent Relay Sessions through relaygate's /sessions proxy, as that agent.
//
// relaygate makes the first uploader of a session its owner and gives it the
// uploader's group (contract "Session uploads"), so uploading with the
// agent's own rg_ token puts every Slack agent's session in the agent's group
// (the pit, gid 22). Who can read it is then the policy's sessionDefaults for
// that group.
//
// Wire format: the native delivery protocol (relayhistory-delivery-v1,
// POST <sessions>/v1/delivery/batches), the one the Desktop uses, so the
// dashboard shows these sessions like any other Claude Code session: a
// `session` record (title, first prompt, activity) plus one `session_event`
// per user or assistant message.
//
// Incremental and restart-safe: a per-session cursor (byte offset of the last
// uploaded line) lives on the host volume. Record and batch ids are derived
// from the transcript, so a retried batch is an exact replay, never a
// duplicate. Transcript content and tokens are never logged.
import { createHash } from "node:crypto";
import { closeSync, existsSync, fstatSync, mkdirSync, openSync, readdirSync, readFileSync, readSync, renameSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/** Where Claude Code keeps a session started in `cwd`: <home>/.claude/projects/<cwd with every non-alphanumeric as ->/<id>.jsonl. */
export function transcriptPath(home: string, cwd: string, sessionId: string): string | null {
  const projects = join(home, ".claude", "projects");
  const direct = join(projects, cwd.replace(/[^A-Za-z0-9]/g, "-"), `${sessionId}.jsonl`);
  if (existsSync(direct)) return direct;
  // Claude Code may encode the directory differently between versions: look for the session file anywhere.
  if (!existsSync(projects)) return null;
  for (const d of readdirSync(projects, { withFileTypes: true })) {
    if (!d.isDirectory()) continue;
    const p = join(projects, d.name, `${sessionId}.jsonl`);
    if (existsSync(p)) return p;
  }
  return null;
}

/** The account a delivery batch is for: relayhistory:sha256(canonical JSON of [orgId, workspaceId]). */
export function accountId(orgId: string, workspaceId: string): string {
  return `relayhistory:${createHash("sha256").update(JSON.stringify([orgId, workspaceId])).digest("hex")}`;
}

/** A Sessions credential the host holds for uploads (sent in Authorization, with the rg_ token in X-Relaygate-Token). */
export interface SessionsCredential {
  /** A current bearer, or null to let relaygate use its own SESSIONS_TOKEN. */
  get(): Promise<string | null>;
  /** The bearer was refused (401): get a new one next time. */
  invalidate(): void;
}

export interface UploadTarget {
  agent: string;
  /** The agent's rg_ token: relaygate makes the agent the session's owner. */
  token: string;
  sessionId: string;
  /** The agent's workdir (Claude Code's cwd for its session). */
  workdir: string;
  /** The Slack thread the agent owns, for the session title (ids only, never text). */
  slack?: { channel: string; thread_ts: string };
}

export interface UploaderOptions {
  /** relaygate's Sessions proxy, e.g. http://relaygate:8080/sessions. */
  baseUrl: string;
  /** Where the cursors live (on the host volume). */
  stateDir: string;
  /** The HOME Claude Code runs with. */
  home: string;
  orgId: string;
  workspaceId: string;
  credential?: SessionsCredential;
  /** Instance name in each batch (the host). */
  instance?: string;
  fetch?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
  log?: (m: string) => void;
  /** Records per batch (Sessions takes at most 500 and 2 MiB). */
  maxRecords?: number;
  maxBytes?: number;
  /** Attempts per batch on 429/503/5xx/network errors before waiting for the next turn. */
  attempts?: number;
  /** Transcript bytes read per pass (a longer single line is still read whole). */
  readBytes?: number;
  /** The window reader (a seam for tests that count reads). */
  readLines?: typeof readLinesFrom;
  /** Upper bound on any wait, whatever Retry-After says. */
  maxWaitMs?: number;
}

interface Cursor {
  offset: number;
  /** relaygate refused this session (403): final, never retried. */
  denied?: boolean;
  firstPrompt?: string;
  firstMs?: number;
  lastMs?: number;
  models?: string[];
  slack?: { channel: string; thread_ts: string };
}

/** The outcome of one upload pass for a session. */
export type UploadResult = "uploaded" | "nothing" | "denied" | "missing" | "failed";

const ORIGIN = "slack-relay";
/**
 * Bytes reserved per request for the envelope and the session record (title, cwd, a first prompt of at most 2000
 * characters, so at most 8 KB in UTF-8). A single message is capped at MAX_TEXT characters (at most 256 KB).
 */
const BATCH_OVERHEAD = 16 * 1024;
const MAX_TEXT = 64 * 1024;

export class SessionUploader {
  readonly #o: Required<Omit<UploaderOptions, "credential">> & Pick<UploaderOptions, "credential">;
  readonly #queues = new Map<string, Promise<UploadResult>>();

  constructor(o: UploaderOptions) {
    this.#o = {
      instance: "slack-agent-host",
      fetch: globalThis.fetch,
      sleep: (ms) => new Promise((r) => setTimeout(r, ms).unref()),
      log: () => {},
      maxRecords: 200,
      maxBytes: 1_500_000,
      attempts: 4,
      readBytes: 4 * 1024 * 1024,
      readLines: readLinesFrom,
      maxWaitMs: 5 * 60_000,
      ...o,
      baseUrl: o.baseUrl.replace(/\/$/, ""),
    };
    mkdirSync(this.#o.stateDir, { recursive: true });
  }

  /** Uploads whatever the session has past its cursor. Calls for one session run one at a time. */
  upload(t: UploadTarget): Promise<UploadResult> {
    const prev = this.#queues.get(t.sessionId) ?? Promise.resolve("nothing" as UploadResult);
    // Never rejects: an unexpected error (a full volume, an unreadable transcript) is logged and the upload is
    // retried after the next turn, so the queue can't wedge and no rejection goes unhandled.
    const run: Promise<UploadResult> = prev
      .then(() => this.#upload(t))
      .catch((err) => {
        this.#o.log(`sessions: ${t.agent} upload of ${t.sessionId} failed (${(err as NodeJS.ErrnoException).code ?? (err as Error).name}); retried after the next turn`);
        return "failed" as const;
      });
    this.#queues.set(t.sessionId, run);
    void run.then(() => {
      if (this.#queues.get(t.sessionId) === run) this.#queues.delete(t.sessionId);
    });
    return run;
  }

  #cursorPath(sessionId: string): string {
    return join(this.#o.stateDir, `${sessionId.replace(/[^A-Za-z0-9._-]/g, "_")}.json`);
  }

  #readCursor(sessionId: string): Cursor {
    try {
      return JSON.parse(readFileSync(this.#cursorPath(sessionId), "utf8")) as Cursor;
    } catch {
      return { offset: 0 };
    }
  }

  #writeCursor(sessionId: string, c: Cursor): void {
    const p = this.#cursorPath(sessionId);
    writeFileSync(`${p}.tmp`, JSON.stringify(c), { mode: 0o600 });
    renameSync(`${p}.tmp`, p);
  }

  async #upload(t: UploadTarget): Promise<UploadResult> {
    const cursor = this.#readCursor(t.sessionId);
    if (cursor.denied) return "denied";
    if (t.slack && !cursor.slack) cursor.slack = t.slack;
    const file = transcriptPath(this.#o.home, t.workdir, t.sessionId);
    if (!file) return "missing";
    let result: UploadResult = "nothing";
    // One batch at a time, from a bounded window of the transcript, so a large backlog never sits in memory whole.
    // The window is kept across batches and its remaining lines are consumed before another is read, so short
    // lines are not read and decoded again for every batch. It is dropped when the file was replaced (another
    // device or inode) or shrank below what the window read, and a failed batch returns, dropping it too.
    let win: ReturnType<typeof readLinesFrom> | null = null;
    let at = 0;
    for (;;) {
      if (win && !(at < win.lines.length && win.lines[at]!.start === cursor.offset && sameFile(file, win))) win = null;
      if (!win) {
        win = this.#o.readLines(file, cursor.offset, this.#o.readBytes);
        at = 0;
      }
      const lines = win.lines;
      if (!lines.length) return result;
      const next: Cursor = { ...cursor, models: [...(cursor.models ?? [])] };
      const records: Rec[] = [];
      // The request size in UTF-8 bytes: every batch also carries the envelope and the session record.
      let bytes = BATCH_OVERHEAD;
      let i = at;
      for (; i < lines.length; i++) {
        const line = lines[i]!;
        const ev = eventOf(line.text);
        if (ev) {
          const rec = this.#record(`cc:${t.sessionId}:${ev.id}`, 1, "session_event", t.sessionId, {
            role: ev.role,
            text: ev.text,
            ts_ms: notLuhn(ev.ts),
            message_id: ev.id,
            ...(ev.model ? { model: ev.model } : {}),
          });
          const size = Buffer.byteLength(JSON.stringify(rec), "utf8") + 1;
          // The batch ends at a line boundary, so the cursor can move past exactly what was sent.
          if (records.length && (records.length + 1 >= this.#o.maxRecords || bytes + size > this.#o.maxBytes)) break;
          if (ev.role === "user" && !next.firstPrompt) next.firstPrompt = ev.text.slice(0, 2000);
          next.firstMs = Math.min(next.firstMs ?? ev.ts, ev.ts);
          next.lastMs = Math.max(next.lastMs ?? ev.ts, ev.ts);
          if (ev.model && !next.models!.includes(ev.model)) next.models!.push(ev.model);
          records.push(rec);
          bytes += size;
        }
        next.offset = line.end;
      }
      if (records.length) {
        // Every batch carries the session record, so the session exists (with its title, activity and first prompt
        // current) whichever batch lands first. Its revision is the last activity, so newer wins.
        const sent = await this.#send(t, [this.#sessionRecord(t, next), ...records]);
        if (sent === "denied") {
          this.#writeCursor(t.sessionId, { ...cursor, denied: true });
          return "denied";
        }
        if (sent !== "ok") return "failed";
        result = "uploaded";
      }
      Object.assign(cursor, next);
      this.#writeCursor(t.sessionId, cursor);
      at = i;
    }
  }

  #record(recordId: string, revision: number, kind: string, sessionId: string, payload: Record<string, unknown>): Rec {
    return {
      schema_version: 1,
      origin_id: ORIGIN,
      record_id: recordId,
      revision_id: `${recordId}:${revision}`,
      revision,
      kind,
      source: "claude",
      session_id: sessionId,
      operation: "upsert",
      payload,
    };
  }

  #sessionRecord(t: UploadTarget, c: Cursor): Rec {
    const where = c.slack ? `Slack ${c.slack.channel} thread ${c.slack.thread_ts}` : "Agent Relay";
    const now = Date.now();
    return this.#record(`session:${t.sessionId}`, Math.max(1, c.lastMs ?? now), "session", t.sessionId, {
      title: `${t.agent} · ${where}`,
      cwd: t.workdir,
      ...(c.firstPrompt ? { first_prompt: c.firstPrompt } : {}),
      first_activity_ms: notLuhn(c.firstMs ?? now),
      last_activity_ms: notLuhn(c.lastMs ?? now),
      models_json: JSON.stringify(c.models ?? []),
    });
  }

  /** One batch, with the retry rules: 429/503 honor Retry-After, other 5xx and network errors back off, 403 is final. */
  async #send(t: UploadTarget, records: Rec[]): Promise<"ok" | "denied" | "failed"> {
    const batch = {
      schema_version: 1,
      origin_id: ORIGIN,
      // Content-addressed: a retry of the same records is the same batch, which Sessions replays.
      batch_id: `sr_${createHash("sha256").update(JSON.stringify(records)).digest("hex").slice(0, 48)}`,
      job_id: "slack-relay-session-upload",
      generation: 1,
      destination_id: "relayhistory",
      instance_id: this.#o.instance,
      account_id: accountId(this.#o.orgId, this.#o.workspaceId),
      mapping_version: "relayhistory-delivery-v1",
      records,
    };
    const body = JSON.stringify({ protocolVersion: 1, batch });
    let refreshed = false;
    for (let attempt = 1; ; attempt++) {
      let status = 0;
      let retryAfter: string | null = null;
      try {
        const cred = await this.#o.credential?.get();
        const headers: Record<string, string> = { "content-type": "application/json" };
        // With a Sessions credential of our own: rg_ in X-Relaygate-Token, ours in Authorization (forwarded as is).
        // Without one: rg_ in Authorization, and relaygate uses its SESSIONS_TOKEN.
        if (cred) {
          headers["x-relaygate-token"] = t.token;
          headers.authorization = `Bearer ${cred}`;
        } else {
          headers.authorization = `Bearer ${t.token}`;
        }
        const res = await this.#o.fetch(`${this.#o.baseUrl}/v1/delivery/batches`, { method: "POST", headers, body, signal: AbortSignal.timeout(30_000) });
        status = res.status;
        retryAfter = res.headers.get("retry-after");
        const text = await res.text().catch(() => "");
        if (res.ok) {
          this.#o.log(`sessions: ${t.agent} uploaded ${records.length - 1} event(s) of ${t.sessionId}`);
          return "ok";
        }
        // relaygate's denial (mode bits or classifier) is final. A 403 from Sessions behind it (a credential
        // without rth:sync, a capture policy) is a configuration problem: retried after the next turn.
        if (status === 403 && errorCode(text).startsWith("relaygate_")) {
          this.#o.log(`sessions: ${t.agent} upload of ${t.sessionId} refused by relaygate (403 ${errorCode(text)}); not retried`);
          return "denied";
        }
        if (status === 401 && this.#o.credential && !refreshed) {
          refreshed = true;
          this.#o.credential.invalidate();
          attempt--;
          continue;
        }
        if (status !== 429 && status < 500) {
          this.#o.log(`sessions: ${t.agent} upload of ${t.sessionId} failed (${status} ${errorCode(text)}); retried after the next turn`);
          return "failed";
        }
      } catch (err) {
        status = 0;
        if (err instanceof CredentialError) {
          this.#o.log(`sessions: no Sessions credential (${err.message}); retried after the next turn`);
          return "failed";
        }
      }
      if (attempt >= this.#o.attempts) {
        this.#o.log(`sessions: ${t.agent} upload of ${t.sessionId} gave up for now (${status || "network error"}); retried after the next turn`);
        return "failed";
      }
      await this.#o.sleep(this.#wait(retryAfter, attempt));
    }
  }

  #wait(retryAfter: string | null, attempt: number): number {
    const backoff = Math.min(1000 * 2 ** (attempt - 1), this.#o.maxWaitMs);
    if (!retryAfter) return backoff;
    const secs = Number(retryAfter);
    const ms = Number.isFinite(secs) ? secs * 1000 : Date.parse(retryAfter) - Date.now();
    return Number.isFinite(ms) && ms >= 0 ? Math.min(ms, this.#o.maxWaitMs) : backoff;
  }
}

interface Rec {
  schema_version: 1;
  origin_id: string;
  record_id: string;
  revision_id: string;
  revision: number;
  kind: string;
  source: string;
  session_id: string;
  operation: "upsert";
  payload: Record<string, unknown>;
}

/**
 * Sessions' ingest nulls any number that passes the Luhn check (it could be a card number), about one timestamp in
 * ten. Move such a timestamp by a millisecond or two so it survives (as relaygate's acceptance uploads do).
 */
export function notLuhn(ms: number): number {
  const luhn = (n: number) =>
    String(n)
      .split("")
      .reverse()
      .map(Number)
      .reduce((sum, d, i) => sum + (i % 2 ? (d * 2 > 9 ? d * 2 - 9 : d * 2) : d), 0) % 10 === 0;
  while (luhn(ms)) ms += 1;
  return ms;
}

/** The error code from a flat JSON error body (`{error: "..."}` or `{error: {code}}`), never the body itself. */
function errorCode(text: string): string {
  try {
    const j = JSON.parse(text) as { error?: unknown };
    const e = j.error;
    const code = typeof e === "string" ? e : (e as { code?: unknown } | undefined)?.code;
    return typeof code === "string" ? code.slice(0, 80) : "";
  } catch {
    return "";
  }
}

/** Whether `file` is still the file the window was read from and has not shrunk below what the window read. */
function sameFile(file: string, w: { dev: number; ino: number; readEnd: number }): boolean {
  try {
    const st = statSync(file);
    return st.dev === w.dev && st.ino === w.ino && st.size >= w.readEnd;
  } catch {
    return false;
  }
}

/**
 * Complete lines (ending in \n) from `offset`, reading at most about `maxBytes` (more only when a single line is
 * longer: the window grows until it holds one whole line). Each line has its start and the offset past its \n.
 * `dev`, `ino` and `readEnd` (the file offset the read reached) let a caller tell whether the file changed since.
 */
export function readLinesFrom(
  file: string,
  offset: number,
  maxBytes = 4 * 1024 * 1024,
): { lines: Array<{ text: string; start: number; end: number }>; end: number; dev: number; ino: number; readEnd: number } {
  // A zero or fractional window would never grow (0 * 2 is 0) or never fill: refuse it rather than loop.
  if (!Number.isInteger(maxBytes) || maxBytes <= 0) throw new RangeError(`readLinesFrom: maxBytes must be a positive integer, got ${maxBytes}`);
  const fd = openSync(file, "r");
  try {
    const { size, dev, ino } = fstatSync(fd);
    for (let window = maxBytes; ; window *= 2) {
      if (offset >= size) return { lines: [], end: offset, dev, ino, readEnd: offset };
      const len = Math.min(window, size - offset);
      const buf = Buffer.alloc(len);
      const got = readSync(fd, buf, 0, len, offset);
      const lines: Array<{ text: string; start: number; end: number }> = [];
      let start = 0;
      for (let i = 0; i < got; i++) {
        if (buf[i] !== 0x0a) continue;
        lines.push({ text: buf.subarray(start, i).toString("utf8"), start: offset + start, end: offset + i + 1 });
        start = i + 1;
      }
      // No complete line in the window: a longer line, or the tail Claude is still writing. A short read means the
      // file ends before `size` (it was truncated after the fstat): stop there, a bigger window would read no more.
      if (lines.length || got < len || offset + got >= size) return { lines, end: offset + start, dev, ino, readEnd: offset + got };
    }
  } finally {
    closeSync(fd);
  }
}

/** A user or assistant message from one Claude Code transcript line, or null for anything else. */
export function eventOf(line: string): { id: string; role: "user" | "assistant"; text: string; ts: number; model?: string } | null {
  let j: { type?: string; uuid?: string; timestamp?: string; isMeta?: boolean; message?: { role?: string; model?: string; content?: unknown } };
  try {
    j = JSON.parse(line);
  } catch {
    return null;
  }
  if ((j.type !== "user" && j.type !== "assistant") || !j.uuid || j.isMeta) return null;
  const content = j.message?.content;
  const parts: string[] = [];
  if (typeof content === "string") parts.push(content);
  else if (Array.isArray(content)) {
    for (const b of content as Array<{ type?: string; text?: string; name?: string }>) {
      if (b?.type === "text" && typeof b.text === "string") parts.push(b.text);
      else if (b?.type === "tool_use" && typeof b.name === "string") parts.push(`[tool: ${b.name}]`);
    }
  }
  const text = parts.join("\n").trim();
  // Tool results (a user line with no text) and empty lines are not messages.
  if (!text) return null;
  const ts = Date.parse(j.timestamp ?? "");
  return {
    id: j.uuid,
    role: j.type,
    text: text.length > MAX_TEXT ? `${text.slice(0, MAX_TEXT)}…` : text,
    ts: Number.isFinite(ts) ? ts : Date.now(),
    ...(j.type === "assistant" && typeof j.message?.model === "string" ? { model: j.message.model } : {}),
  };
}

export class CredentialError extends Error {}

/**
 * A Sessions upload credential from a Desktop enrollment key (sh_ek_): exchanged once at relay-control for a
 * device session (access token sh_at_, 24 h; refresh token sh_rt_, rotated on every refresh), kept on the host
 * volume and refreshed before it expires. The ingest edge accepts only such user tokens with rth:sync.
 */
export class EnrollmentCredential implements SessionsCredential {
  readonly #controlUrl: string;
  readonly #key: () => string;
  readonly #file: string;
  readonly #host: string;
  readonly #fetch: typeof fetch;
  #pending: Promise<string> | null = null;
  #stale = false;

  constructor(o: { controlUrl: string; enrollmentKey: () => string; stateFile: string; hostName: string; fetch?: typeof fetch }) {
    this.#controlUrl = o.controlUrl.replace(/\/$/, "");
    this.#key = o.enrollmentKey;
    this.#file = o.stateFile;
    this.#host = o.hostName.slice(0, 80);
    this.#fetch = o.fetch ?? globalThis.fetch;
  }

  invalidate(): void {
    this.#stale = true;
  }

  get(): Promise<string> {
    this.#pending ??= this.#get().finally(() => (this.#pending = null));
    return this.#pending;
  }

  async #get(): Promise<string> {
    let s: { accessToken?: string; accessExpiresAt?: string; refreshToken?: string } = {};
    try {
      s = JSON.parse(readFileSync(this.#file, "utf8"));
    } catch {
      /* first use */
    }
    const fresh = s.accessToken && Date.parse(s.accessExpiresAt ?? "") - Date.now() > 10 * 60_000;
    if (fresh && !this.#stale) return s.accessToken!;
    let next: { accessToken: string; accessExpiresAt: string; refreshToken: string } | null = null;
    if (s.refreshToken) {
      const j = await this.#post("/api/v1/auth/token/refresh", { refreshToken: s.refreshToken });
      if (j) next = { accessToken: j.accessToken, accessExpiresAt: j.accessTokenExpiresAt, refreshToken: j.refreshToken };
    }
    if (!next) {
      const key = this.#key();
      if (!key) throw new CredentialError("no enrollment key and no stored session");
      const j = await this.#post("/api/v1/auth/enrollment/token", { enrollment_key: key, client_name: "slack-relay session uploader", desktop_host_name: this.#host });
      if (!j) throw new CredentialError("enrollment key refused (already exchanged, expired or revoked): mint a new one, or keep the stored session");
      next = { accessToken: j.access_token, accessExpiresAt: j.access_token_expires_at, refreshToken: j.refresh_token };
    }
    if (typeof next.accessToken !== "string" || typeof next.refreshToken !== "string") throw new CredentialError("relay-control answered without tokens");
    mkdirSync(join(this.#file, ".."), { recursive: true });
    writeFileSync(`${this.#file}.tmp`, JSON.stringify(next), { mode: 0o600 });
    renameSync(`${this.#file}.tmp`, this.#file);
    this.#stale = false;
    return next.accessToken;
  }

  /** The JSON answer on 200, null on a refused grant (400/401/403); anything else throws (retried later). */
  async #post(path: string, body: unknown): Promise<any> {
    let res: Response;
    try {
      res = await this.#fetch(`${this.#controlUrl}${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(15_000) });
    } catch (err) {
      throw new CredentialError(`relay-control unreachable (${(err as Error).name})`);
    }
    if (res.ok) return res.json();
    if ([400, 401, 403].includes(res.status)) return null;
    throw new CredentialError(`relay-control ${res.status}`);
  }
}
