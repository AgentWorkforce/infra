/**
 * The broker's audit log: one JSON line per event, append-only, each line
 * hash-chained to the one before it so an edit or a dropped line shows up in
 * verifyAudit. It never holds a secret: an entry is built from AuditEvent,
 * which has no credential field, and appendAudit refuses a line with a
 * credential field name or one of the exact secret values just minted. It
 * never guesses from a value's shape: a commit SHA in a purpose or a long run
 * tag is ordinary metadata. The access key id is not a secret and is logged so a
 * CloudTrail event can be traced back to its request.
 */
import { createHash } from "node:crypto";
import { appendFileSync, existsSync, readFileSync } from "node:fs";

export type AuditKind =
  | "requested"
  | "denied"
  | "issued"
  | "pending-approval"
  | "approval-rejected"
  | "approved"
  | "refused"
  | "delivery-removed"
  | "error";

export interface AuditEvent {
  kind: AuditKind;
  requestId: string;
  requester?: { name: string; address: string; kind: string };
  approver?: { name: string; address: string; kind: string };
  relayMessageId?: string;
  account?: string;
  roleArn?: string;
  sessionName?: string;
  runTag?: string;
  purpose?: string;
  actions?: string[];
  durationSeconds?: number;
  policyDigest?: string;
  accessKeyId?: string;
  expiration?: string;
  delivery?: { kind: string; ref: string };
  reasons?: string[];
  /** On an approval by a delegated approver: who, under which capability and grants, until when. */
  delegation?: { delegate: string; capability: string; grants: string[]; expiresAt: string };
}

export interface AuditLine extends AuditEvent {
  seq: number;
  ts: string;
  prev: string;
  hash: string;
}

const GENESIS = "0".repeat(64);
/** Credential field names, as any JSON key. */
const CREDENTIAL_KEY = /"(secret_?access_?key|session_?token|aws_secret_access_key|aws_session_token)"\s*:/i;

function lineHash(prev: string, body: Omit<AuditLine, "hash">): string {
  return createHash("sha256").update(prev).update("\n").update(JSON.stringify(body)).digest("hex");
}

function lastLine(path: string): AuditLine | undefined {
  if (!existsSync(path)) return undefined;
  const lines = readFileSync(path, "utf8").split("\n").filter(Boolean);
  const last = lines.at(-1);
  return last ? (JSON.parse(last) as AuditLine) : undefined;
}

/** Bounds on one line, so every line stays well under CloudWatch's 256 KiB event limit (ship.ts). */
export const MAX_AUDIT_STRING = 2_000;
export const MAX_AUDIT_LIST = 100;

/** Caps long strings and lists, saying how much was cut. Applied before hashing, so the chain covers what's stored. */
export function boundAuditEvent(event: AuditEvent): AuditEvent {
  const s = (v: string) => (v.length > MAX_AUDIT_STRING ? `${v.slice(0, MAX_AUDIT_STRING)}… (${v.length - MAX_AUDIT_STRING} more characters)` : v);
  const list = (v: unknown[]) => {
    const kept = v.slice(0, MAX_AUDIT_LIST).map((x) => (typeof x === "string" ? s(x) : x));
    return v.length > MAX_AUDIT_LIST ? [...kept, `… (${v.length - MAX_AUDIT_LIST} more)`] : kept;
  };
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(event)) out[k] = typeof v === "string" ? s(v) : Array.isArray(v) ? list(v) : v;
  return out as unknown as AuditEvent;
}

export function appendAudit(path: string, event: AuditEvent, now: Date, forbidden: string[] = []): AuditLine {
  const prev = lastLine(path);
  const body: Omit<AuditLine, "hash"> = { seq: (prev?.seq ?? 0) + 1, ts: now.toISOString(), prev: prev?.hash ?? GENESIS, ...boundAuditEvent(event) };
  const line: AuditLine = { ...body, hash: lineHash(body.prev, body) };
  const text = JSON.stringify(line);
  if (CREDENTIAL_KEY.test(text) || forbidden.some((s) => s.length >= 16 && text.includes(s))) {
    throw new Error("audit: refusing to write a line that looks like it holds a credential");
  }
  appendFileSync(path, text + "\n", { mode: 0o600 });
  return line;
}

/** Returns the problems found: an empty list means the chain is intact. */
export function verifyAudit(path: string): string[] {
  if (!existsSync(path)) return [];
  return verifyAuditText(readFileSync(path, "utf8"));
}

/** verifyAudit on text already read (ship.ts checks the exact snapshot it ships). */
export function verifyAuditText(text: string): string[] {
  const problems: string[] = [];
  let prev = GENESIS;
  let seq = 0;
  for (const [i, raw] of text.split("\n").filter(Boolean).entries()) {
    let line: AuditLine;
    try {
      line = JSON.parse(raw) as AuditLine;
    } catch {
      problems.push(`line ${i + 1}: not JSON`);
      break;
    }
    const { hash, ...body } = line;
    if (line.prev !== prev) problems.push(`line ${i + 1}: prev does not match line ${i}'s hash`);
    if (line.seq !== seq + 1) problems.push(`line ${i + 1}: seq ${line.seq} after ${seq}`);
    if (lineHash(line.prev, body) !== hash) problems.push(`line ${i + 1}: hash does not match its content`);
    prev = hash;
    seq = line.seq;
  }
  return problems;
}
