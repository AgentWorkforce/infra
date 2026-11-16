/**
 * The broker: takes one request (with the requester from the Relay envelope),
 * decides it, and either refuses it, issues it (STS, out-of-band delivery,
 * audit) or parks it for Khaliq's approval. Approvals are bound to the exact
 * request by a digest, single use and time-limited; only a human on the
 * allowlist's humanApprovers counts, never an agent.
 *
 * State lives in one directory (single writer, serialized by a kernel lock, lock.ts):
 *   pending/<id>.json   requests waiting for approval
 *   issued/<id>.json    delivery refs to remove after expiry (no credentials),
 *                       written before minting so a delivery is never untracked
 *   run-tags.json       run tag -> its claim: the agent that first got
 *                       credentials for it and the namespace the broker gave it
 *   audit.jsonl         the hash-chained audit log
 */
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { appendAudit, type AuditEvent } from "./audit.ts";
import type { Deliverer, DeliveryRef } from "./deliver.ts";
import { withLock } from "./lock.ts";
import { decisionFromText, RelayVerificationError, requestFromText, verifiedMessage, type Decision as RelayDecision, type RelayApi, type Verified } from "./relay.ts";
import { approverCounts, checkDelegatedApproval, decide, NAMESPACE_TAG_KEY, newNamespace, sessionName, type Allowlist, type CredentialRequest, type Decision, type Principal, type RunClaim, type SessionPolicy } from "./policy.ts";
import type { StsClient } from "./sts.ts";

export { withLock };

export interface BrokerDeps {
  allowlist: Allowlist;
  stateDir: string;
  sts: StsClient;
  deliverer: Deliverer;
  now?: () => Date;
  newId?: () => string;
  /** 8 hex characters for a new run namespace (random by default). */
  newNamespaceSuffix?: () => string;
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
  /** The run's namespace: name SQS queues, SNS topics, log groups, DynamoDB tables and secrets "<namespace>--…". */
  namespace?: string;
  /** For pending-approval: the message the broker DMs to the approver, verbatim. */
  approvalPrompt?: string;
  /** For pending-approval: who to send approvalPrompt to (the named delegate when it can approve this, else Khaliq). */
  approver?: string;
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
  /** The namespace the policy was built with (the run's claim, or the one it gets if issued). */
  namespace: string;
}

interface Issued {
  requestId: string;
  delivery: DeliveryRef;
  expiration: string;
  /** Set when a delivery failed: sweep releases this issue's new claim once it has removed the delivery. */
  releaseClaim?: { runTag: string; owner: string };
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

export class Broker {
  readonly deps: Required<BrokerDeps>;

  constructor(deps: BrokerDeps) {
    this.deps = { now: () => new Date(), newId: newRequestId, newNamespaceSuffix: () => randomBytes(4).toString("hex"), ...deps };
    for (const d of ["", "pending", "issued", "consumed"]) mkdirSync(join(deps.stateDir, d), { recursive: true, mode: 0o700 });
  }

  get auditPath(): string {
    return join(this.deps.stateDir, "audit.jsonl");
  }

  private audit(event: AuditEvent, forbidden: string[] = []): void {
    appendAudit(this.auditPath, event, this.deps.now(), forbidden);
  }

  private runTags(): Record<string, RunClaim> {
    return readJson(join(this.deps.stateDir, "run-tags.json"), {} as Record<string, RunClaim>);
  }

  /** The run's claim, or for an unclaimed tag a fresh namespace (recorded only if credentials are issued). */
  private runFor(runTag: string): { owner?: string; namespace: string } {
    const claim = this.runTags()[runTag];
    return claim ?? { namespace: newNamespace(String(runTag), this.deps.newNamespaceSuffix) };
  }

  /** Releases a claim no credentials were ever delivered for. Once a run has had credentials, its claim stays. */
  private releaseClaim(runTag: string, owner: string): void {
    try {
      const now = this.runTags();
      if (now[runTag]?.owner === owner && !now[runTag]!.delivered) {
        delete now[runTag];
        writeJson(join(this.deps.stateDir, "run-tags.json"), now);
      }
    } catch {
      // a leftover claim only keeps the tag with the agent that asked for it
    }
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

  /**
   * Marks a Relay message as acted on, once: a second use of the same message
   * id returns the reason it is refused. Entries older than a day are pruned
   * (verifiedMessage refuses messages older than 15 minutes anyway).
   */
  private useMessageOnce(messageId: string): string | undefined {
    const file = join(this.deps.stateDir, "used-messages.json");
    const used = readJson(file, {} as Record<string, string>);
    if (used[messageId]) {
      const reason = `Relay message ${messageId} was already acted on (${used[messageId]}): send a new message`;
      this.audit({ kind: "denied", requestId: "-", relayMessageId: messageId, reasons: [reason] });
      return reason;
    }
    const now = this.deps.now();
    const cutoff = now.getTime() - 86_400_000;
    const kept = Object.fromEntries(Object.entries(used).filter(([, at]) => Date.parse(at) > cutoff));
    writeJson(file, { ...kept, [messageId]: now.toISOString() });
    return undefined;
  }

  /** A request whose requester and body come from the Relay server (relay.ts): the lead passes only the message id. */
  async requestViaRelay(api: RelayApi, messageId: string, brokerName: string): Promise<Reply> {
    let v: Verified;
    let req: CredentialRequest;
    try {
      v = await verifiedMessage(api, messageId, this.deps.now(), brokerName);
      req = requestFromText(v.text) as CredentialRequest;
    } catch (e) {
      return this.relayRefused(messageId, e as Error);
    }
    return this.request(req, v.principal, messageId, true);
  }

  /** An "approve <id> <digest>" or "refuse <id>" whose sender and text come from the Relay server. */
  async decideViaRelay(api: RelayApi, messageId: string, brokerName: string): Promise<Reply> {
    let v: Verified;
    let d: RelayDecision;
    try {
      v = await verifiedMessage(api, messageId, this.deps.now(), brokerName);
      d = decisionFromText(v.text);
    } catch (e) {
      return this.relayRefused(messageId, e as Error);
    }
    return d.verb === "approve" ? this.approve(d.requestId, d.digest, v.principal, messageId, true) : this.refuse(d.requestId, v.principal, messageId, true);
  }

  private async relayRefused(messageId: string, e: Error): Promise<Reply> {
    const reason = e instanceof RelayVerificationError ? e.message : `could not verify the message with Relay: ${e.message}`;
    return withLock(this.deps.stateDir, async () => {
      this.audit({ kind: "denied", requestId: "-", relayMessageId: messageId, reasons: [reason] });
      return { requestId: "-", outcome: "denied", reasons: [reason] };
    });
  }

  request(req: CredentialRequest, requester: Principal, relayMessageId?: string, once = false): Promise<Reply> {
    return withLock(this.deps.stateDir, async () => {
      if (once && relayMessageId) {
        const used = this.useMessageOnce(relayMessageId);
        if (used) return { requestId: "-", outcome: "denied", reasons: [used] };
      }
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
      let run: { owner?: string; namespace: string } = { namespace: "" };
      try {
        name = sessionName(requester);
        run = this.runFor(req.runTag);
        decision = decide(req, requester, this.deps.allowlist, run);
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
        const pending: Pending = { requestId, request: req, requester, ...(relayMessageId ? { relayMessageId } : {}), roleArn: decision.roleArn, sessionPolicy: decision.sessionPolicy, durationSeconds: decision.durationSeconds, digest, createdAt: this.deps.now().toISOString(), reasons: decision.reasons, namespace: run.namespace };
        writeJson(join(this.deps.stateDir, "pending", `${requestId}.json`), pending);
        this.audit({ ...base, kind: "pending-approval", roleArn: decision.roleArn, sessionName: name, durationSeconds: decision.durationSeconds, policyDigest: digest, reasons: decision.reasons });
        const reasons = [...decision.reasons];
        let approver: string | undefined;
        if (req.delegate) {
          // Say up front whether the named delegate can approve this, so the request goes to the right approver.
          const check = req.delegate === requester.name ? { ok: false as const, reason: "a requester cannot approve its own request" } : checkDelegatedApproval(pending, { name: req.delegate, address: req.delegate, kind: "agent" }, this.deps.allowlist, this.deps.now());
          if (check.ok) approver = req.delegate;
          else reasons.push(check.reason);
        }
        return { requestId, outcome: "pending-approval", reasons, account: req.account, roleArn: decision.roleArn, sessionName: name, policyDigest: digest, namespace: run.namespace, approver: approver ?? this.deps.allowlist.humanApprovers[0]!, approvalPrompt: approvalPrompt(pending, this.deps.allowlist, approver) };
      }
      return this.issue(requestId, req, requester, name, run.namespace, decision.roleArn, decision.sessionPolicy, decision.durationSeconds, digest, base, decision.reasons);
    });
  }

  approve(requestId: string, digestPrefix: string, approver: Principal, relayMessageId?: string, once = false): Promise<Reply> {
    return withLock(this.deps.stateDir, async () => {
      if (once && relayMessageId) {
        const used = this.useMessageOnce(relayMessageId);
        if (used) return { requestId, outcome: "error", reasons: [used] };
      }
      const path = join(this.deps.stateDir, "pending", `${safeId(requestId)}.json`);
      const reject = (reason: string, p?: Pending): Reply => {
        this.audit({ kind: "approval-rejected", requestId, approver: { name: approver.name, address: approver.address, kind: approver.kind }, ...(relayMessageId ? { relayMessageId } : {}), ...(p ? { account: p.request.account } : {}), reasons: [reason] });
        return { requestId, outcome: "error", reasons: [reason] };
      };
      if (!existsSync(path)) return reject("no pending request with that id (already decided, expired or never existed)");
      const p = readJson<Pending>(path, undefined as unknown as Pending);
      // A human on humanApprovers exactly as before; otherwise only a delegate, inside its capability, before its expiry.
      let delegation: AuditEvent["delegation"];
      if (!approverCounts(approver, this.deps.allowlist)) {
        if (!(this.deps.allowlist.delegatedApprovers ?? []).some((d) => d.agent === approver.name)) return reject(`${approver.name} (${approver.kind}) is not an approver: only a human on humanApprovers can approve`, p);
        if (approver.name === p.requester.name) return reject("a requester cannot approve its own request", p);
        const check = checkDelegatedApproval(p, approver, this.deps.allowlist, this.deps.now());
        if (!check.ok) return reject(check.reason, p);
        delegation = { delegate: check.delegate.agent, capability: check.capability, grants: check.grants, expiresAt: check.delegate.expiresAt };
      }
      if (approver.name === p.requester.name) return reject("a requester cannot approve its own request", p);
      const ageMin = (this.deps.now().getTime() - Date.parse(p.createdAt)) / 60_000;
      if (ageMin > this.deps.allowlist.approvalWindowMinutes) {
        renameSync(path, join(this.deps.stateDir, "consumed", `${p.requestId}.json`));
        return reject(`approval window of ${this.deps.allowlist.approvalWindowMinutes} minutes has passed: ask the requester to send it again`, p);
      }
      const prefix = digestPrefix.trim().toLowerCase();
      if (prefix.length < MIN_DIGEST_CHARS || !p.digest.startsWith(prefix)) return reject(`digest does not match: approve with the first ${MIN_DIGEST_CHARS}+ characters of ${p.requestId}'s digest`, p);
      // Re-decide against today's allowlist: an approval never outlives a policy change.
      // The run's claim if it has one by now (another agent may have claimed the tag meanwhile), else the namespace shown.
      const run = this.runTags()[p.request.runTag] ?? { namespace: p.namespace };
      const again = decide(p.request, p.requester, this.deps.allowlist, run);
      if (again.outcome === "deny") {
        renameSync(path, join(this.deps.stateDir, "consumed", `${p.requestId}.json`));
        return reject(`the allowlist now refuses this request: ${again.reasons.join("; ")}`, p);
      }
      const digestNow = requestDigest({ request: p.request, requester: p.requester, roleArn: again.roleArn, sessionPolicy: again.sessionPolicy, durationSeconds: again.durationSeconds });
      if (digestNow !== p.digest) return reject("the request's policy changed since it was shown to you: ask the requester to send it again", p);
      // A delegate approves what the broker would build today, not only what it was shown.
      if (delegation) {
        const recheck = checkDelegatedApproval({ request: p.request, requester: p.requester, sessionPolicy: again.sessionPolicy }, approver, this.deps.allowlist, this.deps.now());
        if (!recheck.ok) return reject(recheck.reason, p);
      }
      renameSync(path, join(this.deps.stateDir, "consumed", `${p.requestId}.json`));
      const base = this.base(p.requestId, p.request, p.requester, p.relayMessageId);
      this.audit({ ...base, kind: "approved", approver: { name: approver.name, address: approver.address, kind: approver.kind }, ...(relayMessageId ? { relayMessageId } : {}), policyDigest: p.digest, ...(delegation ? { delegation } : {}) });
      const by = delegation ? `approved by ${approver.name} (delegated by ${this.deps.allowlist.delegatedApprovers!.find((d) => d.agent === approver.name)!.grantedBy}, capability ${delegation.capability}, until ${delegation.expiresAt})` : `approved by ${approver.name}`;
      return this.issue(p.requestId, p.request, p.requester, sessionName(p.requester), run.namespace, p.roleArn, p.sessionPolicy, p.durationSeconds, p.digest, base, [...p.reasons, by]);
    });
  }

  refuse(requestId: string, by: Principal, relayMessageId?: string, once = false): Promise<Reply> {
    return withLock(this.deps.stateDir, async () => {
      if (once && relayMessageId) {
        const used = this.useMessageOnce(relayMessageId);
        if (used) return { requestId, outcome: "error", reasons: [used] };
      }
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
          if (rec.releaseClaim) this.releaseClaim(rec.releaseClaim.runTag, rec.releaseClaim.owner);
          this.audit({ kind: "delivery-removed", requestId: rec.requestId, delivery: rec.delivery, expiration: rec.expiration });
          n++;
        } catch (e) {
          this.audit({ kind: "error", requestId: rec.requestId, delivery: rec.delivery, reasons: [`sweep: ${(e as Error).message}`] });
        }
      }
      return n;
    });
  }

  private async issue(requestId: string, req: CredentialRequest, requester: Principal, name: string, namespace: string, roleArn: string, sessionPolicy: SessionPolicy, durationSeconds: number, digest: string, base: AuditEvent, reasons: string[]): Promise<Reply> {
    const tags = { "broker-request-id": requestId, [this.deps.allowlist.tagKey]: req.runTag, [NAMESPACE_TAG_KEY]: namespace, agent: name };
    const fail = (reason: string, extra: Partial<AuditEvent> = {}, forbidden: string[] = []): Reply => {
      this.audit({ ...base, kind: "error", roleArn, sessionName: name, ...extra, reasons: [reason] }, forbidden);
      return { requestId, outcome: "error", reasons: [reason] };
    };
    // Every state write that can fail happens before anything is minted: the
    // run-tag claim (owner and namespace) and the cleanup record (with the
    // planned delivery and the longest possible expiry), so sweep can always
    // find and remove a delivery.
    const owners = this.runTags();
    const claimed = !owners[req.runTag];
    if (!claimed && owners[req.runTag]!.namespace !== namespace) return fail("the run's namespace changed while deciding: send the request again");
    const issuedFile = join(this.deps.stateDir, "issued", `${requestId}.json`);
    // Releases a claim this issue made (never one that existed before it), when nobody holds credentials for it.
    const unclaim = () => {
      if (claimed) this.releaseClaim(req.runTag, requester.name);
    };
    const expiryBound = new Date(this.deps.now().getTime() + durationSeconds * 1000 + 60_000).toISOString();
    let planned: DeliveryRef;
    try {
      planned = this.deps.deliverer.planned(req.delivery, name, requestId);
      if (claimed) writeJson(join(this.deps.stateDir, "run-tags.json"), { ...owners, [req.runTag]: { owner: requester.name, namespace } satisfies RunClaim });
      writeJson(issuedFile, { requestId, delivery: planned, expiration: expiryBound } satisfies Issued);
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
      // Maybe partly written. Try to remove it now. A file is removed for certain, so its record goes and a
      // claim this issue made is released (nobody holds the credentials). A 1Password create that timed out
      // may still commit after our delete, so its planned record stays: sweep deletes by the same title
      // after expiry, and only then releases the claim. If removal fails, both stay for sweep.
      try {
        await this.deps.deliverer.remove(planned);
        if (planned.kind === "file") {
          rmSync(issuedFile, { force: true });
          unclaim();
        } else if (claimed) {
          writeJson(issuedFile, { requestId, delivery: planned, expiration: expiryBound, releaseClaim: { runTag: req.runTag, owner: requester.name } } satisfies Issued);
        }
      } catch {
        // sweep retries from the planned record; the claim stays with the requester meanwhile
      }
      return fail(`delivery failed: ${(e as Error).message}`, { accessKeyId: creds.accessKeyId, expiration: creds.expiration }, forbidden);
    }
    try {
      writeJson(issuedFile, { requestId, delivery: { kind: delivery.kind, ref: delivery.ref }, expiration: creds.expiration } satisfies Issued);
    } catch {
      // The planned record (same file path, or the 1Password item's title) still lets sweep remove it.
    }
    // The run has had credentials: its claim is permanent now, so no deferred release from an
    // earlier failed delivery (a releaseClaim record still waiting for sweep) can free it.
    try {
      const claims = this.runTags();
      const claim = claims[req.runTag];
      if (claim?.owner === requester.name && !claim.delivered) writeJson(join(this.deps.stateDir, "run-tags.json"), { ...claims, [req.runTag]: { ...claim, delivered: true } });
    } catch {
      // Unmarked, a later sweep could release the claim; the issue itself already succeeded.
    }
    // The audit keeps where it went, never the envelope itself.
    this.audit({ ...base, kind: "issued", roleArn, sessionName: name, durationSeconds, policyDigest: digest, accessKeyId: creds.accessKeyId, expiration: creds.expiration, delivery: { kind: delivery.kind, ref: delivery.ref }, reasons }, forbidden);
    return { requestId, outcome: "issued", reasons, account: req.account, roleArn, sessionName: name, delivery, expiration: creds.expiration, accessKeyId: creds.accessKeyId, policyDigest: digest, namespace };
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

export function approvalPrompt(p: Pending, list: Allowlist, delegate?: string): string {
  const account = list.accounts[p.request.account];
  const d = delegate ? list.delegatedApprovers?.find((x) => x.agent === delegate) : undefined;
  return [
    `AWS credential request ${p.requestId} needs your approval.`,
    ...(d ? [`You may approve it as a delegate of ${d.grantedBy} until ${d.expiresAt}, only inside your capability. Approve only what you asked for; refuse anything you didn't.`] : []),
    `From: ${p.requester.name} (${p.requester.address})`,
    `Account: ${p.request.account} (${account?.label ?? "?"}, ${account?.tier ?? "?"}) via ${p.roleArn}`,
    `Purpose: ${p.request.purpose}`,
    `Actions: ${p.request.actions.join(", ")}`,
    `Resources: ${(p.request.resources ?? ["*"]).join(", ")}  Scope: ${p.request.scope ?? "run-tag"} (${p.request.runTag}, namespace ${p.namespace})`,
    `Duration: ${p.durationSeconds / 60} min. Why approval: ${p.reasons.join("; ")}`,
    "Grants (exactly what IAM will enforce):",
    ...p.sessionPolicy.Statement.filter((s) => s.Effect === "Allow").map((s) => `  - ${(s.Action ?? []).join(", ")} on ${[s.Resource ?? "*"].flat().join(", ")}${describeCondition(s.Condition)}`),
    `Session policy digest: ${p.digest.slice(0, 16)}`,
    `To approve, reply exactly: approve ${p.requestId} ${p.digest.slice(0, 16)}`,
    `To refuse: refuse ${p.requestId}. Expires in ${list.approvalWindowMinutes} min.`,
  ].join("\n");
}
