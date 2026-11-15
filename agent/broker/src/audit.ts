/**
 * The broker's audit log: one JSON line per event, append-only, each line
 * hash-chained to the one before it so an edit or a dropped line shows up in
 * verifyAudit. It never holds a secret: an entry is built from AuditEvent,
 * which has no credential field, and appendAudit refuses any line that looks
 * like it carries one. The access key id is not a secret and is logged so a
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
}

export interface AuditLine extends AuditEvent {
  seq: number;
  ts: string;
  prev: string;
  hash: string;
}

const GENESIS = "0".repeat(64);
/** Shapes of secret material: STS secret keys are 40 base64 chars, session tokens are long base64. */
const SECRETISH = /("(secretAccessKey|SecretAccessKey|sessionToken|SessionToken)"\s*:)|[A-Za-z0-9/+]{40}(?![A-Za-z0-9/+])|IQoJb3JpZ2lu/;

function lineHash(prev: string, body: Omit<AuditLine, "hash">): string {
  return createHash("sha256").update(prev).update("\n").update(JSON.stringify(body)).digest("hex");
}

function lastLine(path: string): AuditLine | undefined {
  if (!existsSync(path)) return undefined;
  const lines = readFileSync(path, "utf8").split("\n").filter(Boolean);
  const last = lines.at(-1);
  return last ? (JSON.parse(last) as AuditLine) : undefined;
}

export function appendAudit(path: string, event: AuditEvent, now: Date, forbidden: string[] = []): AuditLine {
  const prev = lastLine(path);
  const body: Omit<AuditLine, "hash"> = { seq: (prev?.seq ?? 0) + 1, ts: now.toISOString(), prev: prev?.hash ?? GENESIS, ...event };
  const line: AuditLine = { ...body, hash: lineHash(body.prev, body) };
  const text = JSON.stringify(line);
  const policyDigestFree = text.replace(/"(hash|prev|policyDigest)":"[0-9a-f]{64}"/g, "");
  if (SECRETISH.test(policyDigestFree) || forbidden.some((s) => s && text.includes(s))) {
    throw new Error("audit: refusing to write a line that looks like it holds a credential");
  }
  appendFileSync(path, text + "\n", { mode: 0o600 });
  return line;
}

/** Returns the problems found: an empty list means the chain is intact. */
export function verifyAudit(path: string): string[] {
  if (!existsSync(path)) return [];
  const problems: string[] = [];
  let prev = GENESIS;
  let seq = 0;
  for (const [i, raw] of readFileSync(path, "utf8").split("\n").filter(Boolean).entries()) {
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
