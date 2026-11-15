/**
 * The broker: takes one request (with the requester from the Relay envelope),
 * decides it, and either refuses it, issues it (STS, out-of-band delivery,
 * audit) or parks it for Khaliq's approval. Approvals are bound to the exact
 * request by a digest, single use and time-limited; only a human on the
 * allowlist's humanApprovers counts, never an agent.
 *
 * State lives in one directory (single writer, serialized by a lock):
 *   pending/<id>.json   requests waiting for approval
 *   issued/<id>.json    delivery refs to remove after expiry (no credentials),
 *                       written before minting so a delivery is never untracked
 *   run-tags.json       run tag -> the agent that first got credentials for it
 *   audit.jsonl         the hash-chained audit log
 */
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { appendAudit, type AuditEvent } from "./audit.ts";
import type { Deliverer, DeliveryRef } from "./deliver.ts";
import { approverCounts, decide, sessionName, type Allowlist, type CredentialRequest, type Decision, type Principal, type SessionPolicy } from "./policy.ts";
import type { StsClient } from "./sts.ts";

export interface BrokerDeps {
  allowlist: Allowlist;
  stateDir: string;
  sts: StsClient;
  deliverer: Deliverer;
  now?: () => Date;
  newId?: () => string;
}

/** What the broker sends back over Relay. Never a credential: a pointer, the expiry and ids for CloudTrail. */
export interface Reply {
  requestId: string;
  outcome: "issued" | "denied" | "pending-approval" | "error";
  reasons: string[];
  account?: string;
  roleArn?: string;
  sessionName?: string;
  delivery?: DeliveryRef;
  expiration?: string;
  accessKeyId?: string;
  policyDigest?: string;
  /** For pending-approval: the message the broker DMs to the approver, verbatim. */
  approvalPrompt?: string;
}

interface Pending {
  requestId: string;
  request: CredentialRequest;
  requester: Principal;
  relayMessageId?: string;
  roleArn: string;
  sessionPolicy: SessionPolicy;
  durationSeconds: number;
  digest: string;
  createdAt: string;
  reasons: string[];
}

interface Issued {
  requestId: string;
  delivery: DeliveryRef;
  expiration: string;
}

const MIN_DIGEST_CHARS = 12;

export function requestDigest(p: { request: CredentialRequest; requester: Principal; roleArn: string; sessionPolicy: SessionPolicy; durationSeconds: number }): string {
  const canonical = JSON.stringify({ request: p.request, requester: { name: p.requester.name, address: p.requester.address }, roleArn: p.roleArn, sessionPolicy: p.sessionPolicy, durationSeconds: p.durationSeconds });
  return createHash("sha256").update(canonical).digest("hex");
}

function newRequestId(): string {
  return `cb-${randomBytes(6).toString("hex")}`;
}

function readJson<T>(path: string, fallback: T): T {
  return existsSync(path) ? (JSON.parse(readFileSync(path, "utf8")) as T) : fallback;
}

function writeJson(path: string, value: unknown): void {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
  renameSync(tmp, path);
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "EPERM";
  }
}

/**
 * One broker run at a time. The lock directory holds its owner's pid and a
 * random token. It is taken over only when that pid is dead (or the owner file
 * was never written and the lock is old), never by age while its owner runs;
 * every external call it covers has a timeout (sts.ts, deliver.ts). A run
 * releases the lock only if the token is still its own.
 *
 * Taking over a dead lock is serialized by a second mutex (`.lock.recover`):
 * only its holder may remove the lock, and it re-reads the owner while holding
 * it. A dead owner's lock can't change hands meanwhile (its owner can't
 * release it, and no one else may remove it), so a recoverer can never move a
 * live lock that another waiter has just taken. A recover mutex left by a
 * crashed recoverer is cleared once its pid is dead and it is 30 s old (a live
 * one is held for milliseconds).
 */
export async function withLock<T>(dir: string, fn: () => Promise<T>, waitMs = 60_000): Promise<T> {
  const lock = join(dir, ".lock");
  const owner = join(lock, "owner");
  const recover = join(dir, ".lock.recover");
  const token = randomBytes(8).toString("hex");
  const deadline = Date.now() + waitMs;
  const readOwner = (): string | undefined => {
    try {
      return readFileSync(owner, "utf8");
    } catch {
      return undefined;
    }
  };
  const stale = (content: string | undefined): boolean => {
    if (content === undefined) {
      // mkdir'd but no owner yet: a crash between the two steps, or a run that is just starting.
      try {
        return Date.now() - statSync(lock).mtimeMs > 10_000;
      } catch {
        return false;
      }
    }
    const pid = Number(content.split(" ")[0]);
    return !Number.isInteger(pid) || pid <= 0 || !alive(pid);
  };
  const recoverStaleLock = () => {
    try {
      mkdirSync(recover);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
      try {
        const pid = Number(readFileSync(join(recover, "pid"), "utf8"));
        if (Date.now() - statSync(recover).mtimeMs > 30_000 && !(Number.isInteger(pid) && pid > 0 && alive(pid))) rmSync(recover, { recursive: true, force: true });
      } catch {
        // gone already, or just created: retry later
      }
      return;
    }
    try {
      writeFileSync(join(recover, "pid"), `${process.pid}\n`, { mode: 0o600 });
      if (stale(readOwner())) {
        const grave = `${lock}.stale-${token}`;
        renameSync(lock, grave);
        rmSync(grave, { recursive: true, force: true });
      }
    } catch {
      // the lock went away on its own: the next mkdir decides
    } finally {
      rmSync(recover, { recursive: true, force: true });
    }
  };
  for (;;) {
    try {
      mkdirSync(lock);
      writeFileSync(owner, `${process.pid} ${token}\n`, { mode: 0o600 });
      break;
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
      if (stale(readOwner())) recoverStaleLock();
      if (Date.now() > deadline) throw new Error("broker: state is locked by another run");
      await new Promise((r) => setTimeout(r, 25));
    }
  }
  try {
    return await fn();
  } finally {
    try {
      if (readFileSync(owner, "utf8").trim().endsWith(token)) rmSync(lock, { recursive: true, force: true });
    } catch {
      // already gone: nothing of ours to release
    }
  }
}

export class Broker {
  readonly deps: Required<BrokerDeps>;

  constructor(deps: BrokerDeps) {
    this.deps = { now: () => new Date(), newId: newRequestId, ...deps };
    for (const d of ["", "pending", "issued", "consumed"]) mkdirSync(join(deps.stateDir, d), { recursive: true, mode: 0o700 });
  }

  get auditPath(): string {
    return join(this.deps.stateDir, "audit.jsonl");
  }

  private audit(event: AuditEvent, forbidden: string[] = []): void {
    appendAudit(this.auditPath, event, this.deps.now(), forbidden);
  }

  private runTags(): Record<string, string> {
    return readJson(join(this.deps.stateDir, "run-tags.json"), {} as Record<string, string>);
  }

  private base(requestId: string, req: CredentialRequest, requester: Principal, relayMessageId?: string): AuditEvent {
    return {
      kind: "requested",
      requestId,
      requester: { name: requester.name, address: requester.address, kind: requester.kind },
      ...(relayMessageId ? { relayMessageId } : {}),
      account: String(req.account),
      runTag: String(req.runTag),
      purpose: String(req.purpose).slice(0, 500),
      actions: Array.isArray(req.actions) ? req.actions.map(String) : [],
    };
  }

  request(req: CredentialRequest, requester: Principal, relayMessageId?: string): Promise<Reply> {
    return withLock(this.deps.stateDir, async () => {
      const requestId = this.deps.newId();
      let base: AuditEvent;
      try {
        base = this.base(requestId, req, requester, relayMessageId);
        this.audit(base);
      } catch (e) {
        return { requestId, outcome: "error", reasons: [`could not audit the request: ${(e as Error).message}`] };
      }
      let decision: Decision;
      let name: string;
      try {
        name = sessionName(requester);
        decision = decide(req, requester, this.deps.allowlist, this.runTags()[req.runTag]);
      } catch (e) {
        decision = { outcome: "deny", reasons: [(e as Error).message] };
        name = "";
      }
      if (decision.outcome === "deny") {
        this.audit({ ...base, kind: "denied", reasons: decision.reasons });
        return { requestId, outcome: "denied", reasons: decision.reasons, account: String(req.account) };
      }
      const digest = requestDigest({ request: req, requester, roleArn: decision.roleArn, sessionPolicy: decision.sessionPolicy, durationSeconds: decision.durationSeconds });
      if (decision.outcome === "approval") {
        const pending: Pending = { requestId, request: req, requester, ...(relayMessageId ? { relayMessageId } : {}), roleArn: decision.roleArn, sessionPolicy: decision.sessionPolicy, durationSeconds: decision.durationSeconds, digest, createdAt: this.deps.now().toISOString(), reasons: decision.reasons };
        writeJson(join(this.deps.stateDir, "pending", `${requestId}.json`), pending);
        this.audit({ ...base, kind: "pending-approval", roleArn: decision.roleArn, sessionName: name, durationSeconds: decision.durationSeconds, policyDigest: digest, reasons: decision.reasons });
        return { requestId, outcome: "pending-approval", reasons: decision.reasons, account: req.account, roleArn: decision.roleArn, sessionName: name, policyDigest: digest, approvalPrompt: approvalPrompt(pending, this.deps.allowlist) };
      }
      return this.issue(requestId, req, requester, name, decision.roleArn, decision.sessionPolicy, decision.durationSeconds, digest, base, decision.reasons);
    });
  }

  approve(requestId: string, digestPrefix: string, approver: Principal, relayMessageId?: string): Promise<Reply> {
    return withLock(this.deps.stateDir, async () => {
      const path = join(this.deps.stateDir, "pending", `${safeId(requestId)}.json`);
      const reject = (reason: string, p?: Pending): Reply => {
        this.audit({ kind: "approval-rejected", requestId, approver: { name: approver.name, address: approver.address, kind: approver.kind }, ...(relayMessageId ? { relayMessageId } : {}), ...(p ? { account: p.request.account } : {}), reasons: [reason] });
        return { requestId, outcome: "error", reasons: [reason] };
      };
      if (!existsSync(path)) return reject("no pending request with that id (already decided, expired or never existed)");
      const p = readJson<Pending>(path, undefined as unknown as Pending);
      if (!approverCounts(approver, this.deps.allowlist)) return reject(`${approver.name} (${approver.kind}) is not an approver: only a human on humanApprovers can approve`, p);
      if (approver.name === p.requester.name) return reject("a requester cannot approve its own request", p);
      const ageMin = (this.deps.now().getTime() - Date.parse(p.createdAt)) / 60_000;
      if (ageMin > this.deps.allowlist.approvalWindowMinutes) {
        renameSync(path, join(this.deps.stateDir, "consumed", `${p.requestId}.json`));
        return reject(`approval window of ${this.deps.allowlist.approvalWindowMinutes} minutes has passed: ask the requester to send it again`, p);
      }
      const prefix = digestPrefix.trim().toLowerCase();
      if (prefix.length < MIN_DIGEST_CHARS || !p.digest.startsWith(prefix)) return reject(`digest does not match: approve with the first ${MIN_DIGEST_CHARS}+ characters of ${p.requestId}'s digest`, p);
      // Re-decide against today's allowlist: an approval never outlives a policy change.
      const again = decide(p.request, p.requester, this.deps.allowlist, this.runTags()[p.request.runTag]);
      if (again.outcome === "deny") {
        renameSync(path, join(this.deps.stateDir, "consumed", `${p.requestId}.json`));
        return reject(`the allowlist now refuses this request: ${again.reasons.join("; ")}`, p);
      }
      const digestNow = requestDigest({ request: p.request, requester: p.requester, roleArn: again.roleArn, sessionPolicy: again.sessionPolicy, durationSeconds: again.durationSeconds });
      if (digestNow !== p.digest) return reject("the request's policy changed since it was shown to you: ask the requester to send it again", p);
      renameSync(path, join(this.deps.stateDir, "consumed", `${p.requestId}.json`));
      const base = this.base(p.requestId, p.request, p.requester, p.relayMessageId);
      this.audit({ ...base, kind: "approved", approver: { name: approver.name, address: approver.address, kind: approver.kind }, ...(relayMessageId ? { relayMessageId } : {}), policyDigest: p.digest });
      return this.issue(p.requestId, p.request, p.requester, sessionName(p.requester), p.roleArn, p.sessionPolicy, p.durationSeconds, p.digest, base, [...p.reasons, `approved by ${approver.name}`]);
    });
  }

  refuse(requestId: string, by: Principal, relayMessageId?: string): Promise<Reply> {
    return withLock(this.deps.stateDir, async () => {
      const path = join(this.deps.stateDir, "pending", `${safeId(requestId)}.json`);
      if (!existsSync(path)) return { requestId, outcome: "error", reasons: ["no pending request with that id"] };
      const p = readJson<Pending>(path, undefined as unknown as Pending);
      if (!approverCounts(by, this.deps.allowlist) && by.name !== p.requester.name) return { requestId, outcome: "error", reasons: ["only an approver or the requester can refuse a pending request"] };
      renameSync(path, join(this.deps.stateDir, "consumed", `${p.requestId}.json`));
      this.audit({ kind: "refused", requestId, approver: { name: by.name, address: by.address, kind: by.kind }, ...(relayMessageId ? { relayMessageId } : {}), account: p.request.account });
      return { requestId, outcome: "denied", reasons: [`refused by ${by.name}`] };
    });
  }

  /** Removes deliveries whose credentials have expired. */
  sweep(): Promise<number> {
    return withLock(this.deps.stateDir, async () => {
      let n = 0;
      const dir = join(this.deps.stateDir, "issued");
      for (const f of readdirSync(dir).filter((x) => x.endsWith(".json"))) {
        const rec = readJson<Issued>(join(dir, f), undefined as unknown as Issued);
        if (Date.parse(rec.expiration) > this.deps.now().getTime()) continue;
        try {
          await this.deps.deliverer.remove(rec.delivery);
          rmSync(join(dir, f));
          this.audit({ kind: "delivery-removed", requestId: rec.requestId, delivery: rec.delivery, expiration: rec.expiration });
          n++;
        } catch (e) {
          this.audit({ kind: "error", requestId: rec.requestId, delivery: rec.delivery, reasons: [`sweep: ${(e as Error).message}`] });
        }
      }
      return n;
    });
  }

  private async issue(requestId: string, req: CredentialRequest, requester: Principal, name: string, roleArn: string, sessionPolicy: SessionPolicy, durationSeconds: number, digest: string, base: AuditEvent, reasons: string[]): Promise<Reply> {
    const tags = { "broker-request-id": requestId, [this.deps.allowlist.tagKey]: req.runTag, agent: name };
    const fail = (reason: string, extra: Partial<AuditEvent> = {}, forbidden: string[] = []): Reply => {
      this.audit({ ...base, kind: "error", roleArn, sessionName: name, ...extra, reasons: [reason] }, forbidden);
      return { requestId, outcome: "error", reasons: [reason] };
    };
    // Every state write that can fail happens before anything is minted: the
    // run-tag claim and the cleanup record (with the planned delivery and the
    // longest possible expiry), so sweep can always find and remove a delivery.
    const tagsFile = join(this.deps.stateDir, "run-tags.json");
    const owners = this.runTags();
    const claimed = !owners[req.runTag];
    const issuedFile = join(this.deps.stateDir, "issued", `${requestId}.json`);
    // Releases a claim this issue made (never one that existed before it), when
    // nobody ends up holding credentials for the tag.
    const unclaim = () => {
      if (!claimed) return;
      try {
        const now = this.runTags();
        if (now[req.runTag] === requester.name) {
          delete now[req.runTag];
          writeJson(tagsFile, now);
        }
      } catch {
        // a leftover claim only keeps the tag with the agent that asked for it
      }
    };
    let planned: DeliveryRef;
    try {
      planned = this.deps.deliverer.planned(req.delivery, name, requestId);
      if (claimed) writeJson(tagsFile, { ...owners, [req.runTag]: requester.name });
      writeJson(issuedFile, { requestId, delivery: planned, expiration: new Date(this.deps.now().getTime() + durationSeconds * 1000 + 60_000).toISOString() } satisfies Issued);
    } catch (e) {
      // Nothing was minted: undo whatever of the two writes landed.
      rmSync(issuedFile, { force: true });
      unclaim();
      return fail(`could not record the issue: ${(e as Error).message}`);
    }
    let creds;
    try {
      creds = await this.deps.sts.assumeRole({ roleArn, sessionName: name, sourceIdentity: name, durationSeconds, policy: sessionPolicy, tags });
    } catch (e) {
      rmSync(issuedFile, { force: true });
      unclaim();
      return fail((e as Error).message);
    }
    const forbidden = [creds.secretAccessKey, creds.sessionToken];
    let delivery: DeliveryRef;
    try {
      delivery = await this.deps.deliverer.deliver(req.delivery, name, requestId, creds);
    } catch (e) {
      // Maybe partly written (e.g. op timed out after creating the item): try to remove it now. Once
      // it is gone nobody holds the credentials, so a claim this issue made is released too. If removal
      // fails, the planned record stays for sweep and the claim stays with the requester (the only
      // agent who could read a leftover delivery). The credentials lapse at expiry either way.
      try {
        await this.deps.deliverer.remove(planned);
        rmSync(issuedFile, { force: true });
        unclaim();
      } catch {
        // sweep retries from the planned record
      }
      return fail(`delivery failed: ${(e as Error).message}`, { accessKeyId: creds.accessKeyId, expiration: creds.expiration }, forbidden);
    }
    try {
      writeJson(issuedFile, { requestId, delivery, expiration: creds.expiration } satisfies Issued);
    } catch {
      // The planned record (same file path, or the 1Password item's title) still lets sweep remove it.
    }
    this.audit({ ...base, kind: "issued", roleArn, sessionName: name, durationSeconds, policyDigest: digest, accessKeyId: creds.accessKeyId, expiration: creds.expiration, delivery, reasons }, forbidden);
    return { requestId, outcome: "issued", reasons, account: req.account, roleArn, sessionName: name, delivery, expiration: creds.expiration, accessKeyId: creds.accessKeyId, policyDigest: digest };
  }
}

function safeId(id: string): string {
  if (!/^cb-[0-9a-f]{12}$/.test(id)) throw new Error(`bad request id ${JSON.stringify(id)}`);
  return id;
}

function describeCondition(c: SessionPolicy["Statement"][number]["Condition"]): string {
  const eq = c?.StringEquals ?? {};
  const parts: string[] = [];
  for (const [k, v] of Object.entries(eq)) {
    if (k.startsWith("aws:ResourceTag/")) parts.push(`only resources tagged ${k.slice(16)}=${String(v)}`);
    else if (k.startsWith("aws:RequestTag/")) parts.push(`must tag ${k.slice(15)}=${String(v)} at create`);
    else if (k === "aws:RequestedRegion") parts.push(`regions ${[v].flat().join("/")}`);
    else parts.push(`${k}=${[v].flat().join("/")}`);
  }
  return parts.length ? ` (${parts.join("; ")})` : " (account-wide, no tag condition)";
}

export function approvalPrompt(p: Pending, list: Allowlist): string {
  const account = list.accounts[p.request.account];
  return [
    `AWS credential request ${p.requestId} needs your approval.`,
    `From: ${p.requester.name} (${p.requester.address})`,
    `Account: ${p.request.account} (${account?.label ?? "?"}, ${account?.tier ?? "?"}) via ${p.roleArn}`,
    `Purpose: ${p.request.purpose}`,
    `Actions: ${p.request.actions.join(", ")}`,
    `Resources: ${(p.request.resources ?? ["*"]).join(", ")}  Scope: ${p.request.scope ?? "run-tag"} (${p.request.runTag})`,
    `Duration: ${p.durationSeconds / 60} min. Why approval: ${p.reasons.join("; ")}`,
    "Grants (exactly what IAM will enforce):",
    ...p.sessionPolicy.Statement.filter((s) => s.Effect === "Allow").map((s) => `  - ${(s.Action ?? []).join(", ")} on ${[s.Resource ?? "*"].flat().join(", ")}${describeCondition(s.Condition)}`),
    `Session policy digest: ${p.digest.slice(0, 16)}`,
    `To approve, reply exactly: approve ${p.requestId} ${p.digest.slice(0, 16)}`,
    `To refuse: refuse ${p.requestId}. Expires in ${list.approvalWindowMinutes} min.`,
  ].join("\n");
}
