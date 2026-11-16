/**
 * Audit shipping: copies the broker's hash-chained audit log
 * (<state>/audit.jsonl, audit.ts) to a CloudWatch Logs group in the broker's
 * account, so the record survives the host. Every line is sent verbatim, with
 * its seq, prev and hash, so the copy can be checked with the same chain rule
 * as the local file.
 *
 * Shipping is at least once and in order. A cursor
 * (<state>/ship/cursor.json: the seq and hash of the last line sent) moves
 * forward only after CloudWatch accepts a batch. Before anything is sent:
 *  - the snapshot being shipped must verify as a chain (verifyAuditText);
 *  - its line at the cursor's seq must still have the cursor's hash.
 * Either failing means the local log was edited after it was written: nothing
 * is sent, and the result says why (the shipped copy is the evidence).
 *
 * It never takes the broker's state lock, so a slow CloudWatch never holds up
 * a credential request. The writer appends whole lines, so shipping reads the
 * file once and ignores a trailing line without its newline (one still being
 * written). Concurrent shippers (the timer and a manual run) are serialized by
 * their own lock in <state>/ship.
 *
 * A line over CloudWatch's event limit (only possible from before audit.ts
 * bounded its lines) is sent as a stub with its seq, prev, hash, size and
 * sha256, so the chain's links stay checkable and shipping never stalls.
 *
 * Audit lines never hold a secret (audit.ts refuses one), so the CloudWatch
 * copy doesn't either. The sink calls the AWS CLI as the broker role (the
 * aws-cred-broker profile) with the batch in a 0600 file it removes after.
 */
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { verifyAuditText, type AuditLine } from "./audit.ts";
import { withLock } from "./lock.ts";

export interface LogEvent {
  timestamp: number;
  message: string;
}

export interface LogSink {
  /** Sends one batch, in order. Creates the stream when it doesn't exist yet. Throws on any failure. */
  put(events: LogEvent[]): Promise<void>;
}

export interface ShipCursor {
  seq: number;
  hash: string;
}

export interface ShipResult {
  ok: boolean;
  shipped: number;
  /** The cursor after this run: the last line CloudWatch has. */
  cursor?: ShipCursor;
  problems: string[];
}

/** CloudWatch Logs limits: 10,000 events and 1,048,576 bytes (each event's size plus 26) per batch. */
export const MAX_BATCH_EVENTS = 1_000;
export const MAX_BATCH_BYTES = 900_000;
/** CloudWatch rejects a single event over 256 KiB (with its 26-byte overhead). */
export const MAX_EVENT_BYTES = 256 * 1024 - 26;

export function shipDir(stateDir: string): string {
  return join(stateDir, "ship");
}

export function cursorPath(stateDir: string): string {
  return join(shipDir(stateDir), "cursor.json");
}

function readCursor(path: string): ShipCursor | undefined {
  if (!existsSync(path)) return undefined;
  const c = JSON.parse(readFileSync(path, "utf8")) as ShipCursor;
  if (!Number.isInteger(c.seq) || c.seq < 1 || typeof c.hash !== "string" || !/^[0-9a-f]{64}$/.test(c.hash)) throw new Error("the shipping cursor is not valid");
  return c;
}

function writeCursor(path: string, c: ShipCursor): void {
  writeFileSync(`${path}.new`, JSON.stringify(c) + "\n", { mode: 0o600 });
  renameSync(`${path}.new`, path);
}

/** The event sent for one line: the line itself, or a stub when it's over CloudWatch's limit. */
export function eventMessage(raw: string, line: AuditLine): string {
  const bytes = Buffer.byteLength(raw);
  if (bytes <= MAX_EVENT_BYTES) return raw;
  return JSON.stringify({ seq: line.seq, ts: line.ts, prev: line.prev, hash: line.hash, kind: line.kind, requestId: line.requestId, oversized: { bytes, sha256: createHash("sha256").update(raw).digest("hex") } });
}

/**
 * Ships every line after the cursor. `now` timestamps the events: CloudWatch
 * needs them in order and recent; the line's own ts is inside the message.
 */
export async function shipAudit(auditPath: string, stateDir: string, sink: LogSink, now: () => Date = () => new Date()): Promise<ShipResult> {
  mkdirSync(shipDir(stateDir), { recursive: true, mode: 0o700 });
  return withLock(shipDir(stateDir), () => shipUnlocked(auditPath, stateDir, sink, now), 5_000);
}

async function shipUnlocked(auditPath: string, stateDir: string, sink: LogSink, now: () => Date): Promise<ShipResult> {
  const cpath = cursorPath(stateDir);
  let cursor: ShipCursor | undefined;
  try {
    cursor = readCursor(cpath);
  } catch (e) {
    return { ok: false, shipped: 0, problems: [(e as Error).message] };
  }
  const keep = (c: ShipCursor | undefined) => (c ? { cursor: c } : {});
  if (!existsSync(auditPath)) return { ok: true, shipped: 0, ...keep(cursor), problems: [] };
  // One read; only whole lines (a line still being appended has no newline yet).
  const text = readFileSync(auditPath, "utf8");
  const snapshot = text.slice(0, text.lastIndexOf("\n") + 1);
  const problems = verifyAuditText(snapshot);
  if (problems.length) return { ok: false, shipped: 0, ...keep(cursor), problems: ["the local audit chain does not verify; nothing was shipped", ...problems] };
  const lines = snapshot.split("\n").filter(Boolean).map((raw) => ({ raw, line: JSON.parse(raw) as AuditLine }));
  if (cursor) {
    const at = lines[cursor.seq - 1];
    if (!at || at.line.seq !== cursor.seq || at.line.hash !== cursor.hash) {
      return { ok: false, shipped: 0, cursor, problems: [`the local audit log no longer has line ${cursor.seq} as shipped (hash ${cursor.hash.slice(0, 12)}…); it was rewritten after shipping. Nothing was shipped`] };
    }
  }
  const pending = lines.slice(cursor?.seq ?? 0).map((l) => ({ line: l.line, message: eventMessage(l.raw, l.line) }));
  let shipped = 0;
  let i = 0;
  while (i < pending.length) {
    const batch: typeof pending = [];
    let bytes = 0;
    while (i < pending.length && batch.length < MAX_BATCH_EVENTS) {
      const size = Buffer.byteLength(pending[i]!.message) + 26;
      if (batch.length && bytes + size > MAX_BATCH_BYTES) break;
      batch.push(pending[i]!);
      bytes += size;
      i++;
    }
    const ts = now().getTime();
    try {
      await sink.put(batch.map((b) => ({ timestamp: ts, message: b.message })));
    } catch (e) {
      return { ok: false, shipped, ...keep(cursor), problems: [`CloudWatch did not accept the batch: ${(e as Error).message}`] };
    }
    const last = batch.at(-1)!.line;
    cursor = { seq: last.seq, hash: last.hash };
    writeCursor(cpath, cursor);
    shipped += batch.length;
  }
  return { ok: true, shipped, ...keep(cursor), problems: [] };
}

/** A call that takes longer is killed. */
export const LOGS_TIMEOUT_MS = 30_000;

function aws(args: string[], profile: string, region: string | undefined): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(
      "aws",
      [...args, "--profile", profile, ...(region ? ["--region", region] : []), "--output", "json"],
      { maxBuffer: 1 << 20, timeout: LOGS_TIMEOUT_MS, killSignal: "SIGKILL", env: { ...process.env, AWS_PAGER: "", AWS_MAX_ATTEMPTS: "3" } },
      (err, stdout, stderr) => (err ? reject(new Error(String(stderr).trim().split("\n").at(-1) || err.message)) : resolve(String(stdout))),
    );
  });
}

/**
 * The CloudWatch Logs sink, through the AWS CLI already on the host. The batch
 * goes in a 0600 file under `dir` (the AWS CLI can't reopen a Node child's
 * stdin, which is a socket on Linux), removed after each call.
 */
export function awsCliLogs(group: string, stream: string, dir: string, profile = process.env.BROKER_AWS_PROFILE ?? "aws-cred-broker", region = process.env.AWS_REGION): LogSink {
  const file = join(dir, "batch.json");
  const put = async (events: LogEvent[]) => {
    writeFileSync(file, JSON.stringify({ logGroupName: group, logStreamName: stream, logEvents: events }), { mode: 0o600 });
    try {
      await aws(["logs", "put-log-events", "--cli-input-json", `file://${file}`], profile, region);
    } finally {
      rmSync(file, { force: true });
    }
  };
  return {
    async put(events) {
      try {
        await put(events);
      } catch (e) {
        if (!/ResourceNotFoundException/.test((e as Error).message)) throw e;
        // First run: make the stream, then send again. An existing stream is fine.
        try {
          await aws(["logs", "create-log-stream", "--log-group-name", group, "--log-stream-name", stream], profile, region);
        } catch (c) {
          if (!/ResourceAlreadyExistsException/.test((c as Error).message)) throw c;
        }
        await put(events);
      }
    },
  };
}
