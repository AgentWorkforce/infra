/**
 * Audit shipping: copies the broker's hash-chained audit log
 * (<state>/audit.jsonl, audit.ts) to a CloudWatch Logs group in the broker's
 * account, so the record survives the host. Every line is sent verbatim, with
 * its seq, prev and hash, so the copy can be checked with the same chain rule
 * as the local file.
 *
 * Shipping is at least once and in order. A cursor (<state>/audit-shipped.json:
 * the seq and hash of the last line sent) moves forward only after CloudWatch
 * accepts a batch. Before anything is sent:
 *  - the whole local chain must verify (verifyAudit);
 *  - the local line at the cursor's seq must still have the cursor's hash.
 * Either failing means the local log was edited after it was written: nothing
 * is sent, and the result says why (the shipped copy is the evidence).
 *
 * Audit lines never hold a secret (audit.ts refuses one), so the CloudWatch
 * copy doesn't either. The sink calls the AWS CLI as the broker role (the
 * aws-cred-broker profile), with the events on stdin, never on a command line.
 */
import { execFile } from "node:child_process";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { verifyAudit, type AuditLine } from "./audit.ts";

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

export function cursorPath(stateDir: string): string {
  return join(stateDir, "audit-shipped.json");
}

function readCursor(path: string): ShipCursor | undefined {
  if (!existsSync(path)) return undefined;
  const c = JSON.parse(readFileSync(path, "utf8")) as ShipCursor;
  if (!Number.isInteger(c.seq) || c.seq < 1 || typeof c.hash !== "string" || !/^[0-9a-f]{64}$/.test(c.hash)) throw new Error("audit-shipped.json is not a valid cursor");
  return c;
}

function writeCursor(path: string, c: ShipCursor): void {
  writeFileSync(`${path}.new`, JSON.stringify(c) + "\n", { mode: 0o600 });
  renameSync(`${path}.new`, path);
}

/**
 * Ships every line after the cursor. Call it under the broker's state lock
 * (cli.ts does), so no run is appending a half-written line meanwhile.
 * `now` timestamps the events: CloudWatch needs them in order and recent; the
 * line's own ts is inside the message.
 */
export async function shipAudit(auditPath: string, stateDir: string, sink: LogSink, now: () => Date = () => new Date()): Promise<ShipResult> {
  const cpath = cursorPath(stateDir);
  let cursor: ShipCursor | undefined;
  try {
    cursor = readCursor(cpath);
  } catch (e) {
    return { ok: false, shipped: 0, problems: [(e as Error).message] };
  }
  if (!existsSync(auditPath)) return { ok: true, shipped: 0, ...(cursor ? { cursor } : {}), problems: [] };
  const problems = verifyAudit(auditPath);
  if (problems.length) return { ok: false, shipped: 0, ...(cursor ? { cursor } : {}), problems: ["the local audit chain does not verify; nothing was shipped", ...problems] };
  const raw = readFileSync(auditPath, "utf8").split("\n").filter(Boolean);
  const lines = raw.map((r) => ({ raw: r, line: JSON.parse(r) as AuditLine }));
  if (cursor) {
    const at = lines[cursor.seq - 1];
    if (!at || at.line.seq !== cursor.seq || at.line.hash !== cursor.hash) {
      return { ok: false, shipped: 0, cursor, problems: [`the local audit log no longer has line ${cursor.seq} as shipped (hash ${cursor.hash.slice(0, 12)}…); it was rewritten after shipping. Nothing was shipped`] };
    }
  }
  const pending = lines.slice(cursor?.seq ?? 0);
  let shipped = 0;
  let i = 0;
  while (i < pending.length) {
    const batch: typeof pending = [];
    let bytes = 0;
    while (i < pending.length && batch.length < MAX_BATCH_EVENTS) {
      const size = Buffer.byteLength(pending[i]!.raw) + 26;
      if (size > MAX_EVENT_BYTES + 26) return { ok: false, shipped, ...(cursor ? { cursor } : {}), problems: [`audit line ${pending[i]!.line.seq} is over CloudWatch's event size limit`] };
      if (batch.length && bytes + size > MAX_BATCH_BYTES) break;
      batch.push(pending[i]!);
      bytes += size;
      i++;
    }
    const ts = now().getTime();
    try {
      await sink.put(batch.map((b) => ({ timestamp: ts, message: b.raw })));
    } catch (e) {
      return { ok: false, shipped, ...(cursor ? { cursor } : {}), problems: [`CloudWatch did not accept the batch: ${(e as Error).message}`] };
    }
    const last = batch.at(-1)!.line;
    cursor = { seq: last.seq, hash: last.hash };
    writeCursor(cpath, cursor);
    shipped += batch.length;
  }
  return { ok: true, shipped, ...(cursor ? { cursor } : {}), problems: [] };
}

/** A call that takes longer is killed: shipping runs under the broker's lock. */
export const LOGS_TIMEOUT_MS = 30_000;

function aws(args: string[], input: string | undefined, profile: string, region: string | undefined): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = execFile(
      "aws",
      [...args, "--profile", profile, ...(region ? ["--region", region] : []), "--output", "json"],
      { maxBuffer: 1 << 20, timeout: LOGS_TIMEOUT_MS, killSignal: "SIGKILL", env: { ...process.env, AWS_PAGER: "", AWS_MAX_ATTEMPTS: "3" } },
      (err, stdout, stderr) => (err ? reject(new Error(String(stderr).trim().split("\n").at(-1) || err.message)) : resolve(String(stdout))),
    );
    child.stdin?.end(input ?? "");
  });
}

/** The CloudWatch Logs sink, through the AWS CLI already on the host. */
export function awsCliLogs(group: string, stream: string, profile = process.env.BROKER_AWS_PROFILE ?? "aws-cred-broker", region = process.env.AWS_REGION): LogSink {
  const putArgs = ["logs", "put-log-events", "--cli-input-json", "file:///dev/stdin"];
  const body = (events: LogEvent[]) => JSON.stringify({ logGroupName: group, logStreamName: stream, logEvents: events });
  return {
    async put(events) {
      try {
        await aws(putArgs, body(events), profile, region);
      } catch (e) {
        if (!/ResourceNotFoundException/.test((e as Error).message)) throw e;
        // First run: make the stream, then send again. An existing stream is fine.
        try {
          await aws(["logs", "create-log-stream", "--log-group-name", group, "--log-stream-name", stream], undefined, profile, region);
        } catch (c) {
          if (!/ResourceAlreadyExistsException/.test((c as Error).message)) throw c;
        }
        await aws(putArgs, body(events), profile, region);
      }
    },
  };
}
