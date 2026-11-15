/**
 * The broker end to end with a fake STS and real file delivery: issue,
 * approval (digest-bound, single use, humans only), run-tag ownership, the
 * audit chain, sweep, and that no credential reaches a reply or the audit log.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendAudit, verifyAudit } from "../broker/src/audit.ts";
import { Broker, withLock } from "../broker/src/broker.ts";
import { defaultDeliverer, onePasswordTemplate, type Deliverer, type OpRunner } from "../broker/src/deliver.ts";
import type { Allowlist, CredentialRequest, Principal } from "../broker/src/policy.ts";
import { assumeRoleArgs, type AssumeInput, type StsClient } from "../broker/src/sts.ts";

const base = JSON.parse(readFileSync(new URL("../broker/allowlist.json", import.meta.url), "utf8")) as Allowlist;
const SANDBOX = "805532413586";
const allowlist: Allowlist = {
  ...base,
  accounts: { ...base.accounts, "111122223333": { label: "prod-test", tier: "prod", roles: { elevated: "arn:aws:iam::111122223333:role/agent-broker-elevated" } } },
};
const SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYFAKEFAKEKEY";
const TOKEN = "IQoJb3JpZ2luX2VjEFAKE" + "x".repeat(300);
const requester: Principal = { name: "tersemigrationgrok", address: "tersemigrationgrok@linuyc-desktop", kind: "agent" };
const khaliq: Principal = { name: "khaliq-gant", address: "khaliq-gant@finn-mac-mini", kind: "human" };

function setup(start = new Date("2026-11-14T12:00:00Z"), over: { sts?: StsClient; deliverer?: (base: Deliverer) => Deliverer } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "broker-test-"));
  const calls: AssumeInput[] = [];
  let clock = start;
  let n = 0;
  const sts: StsClient = over.sts ?? {
    async assumeRole(input) {
      calls.push(input);
      return { accessKeyId: `ASIAFAKE${calls.length}`, secretAccessKey: SECRET, sessionToken: TOKEN, expiration: new Date(clock.getTime() + input.durationSeconds * 1000).toISOString() };
    },
  };
  const base = defaultDeliverer(join(dir, "creds"));
  const broker = new Broker({ allowlist, stateDir: join(dir, "state"), sts, deliverer: over.deliverer ? over.deliverer(base) : base, now: () => clock, newId: () => `cb-${(++n).toString(16).padStart(12, "0")}` });
  return { dir, broker, calls, tick: (min: number) => (clock = new Date(clock.getTime() + min * 60_000)) };
}

const req = (over: Partial<CredentialRequest> = {}): CredentialRequest => ({
  account: SANDBOX,
  purpose: "migration soak test queue",
  actions: ["sqs:CreateQueue", "sqs:SendMessage"],
  durationMinutes: 15,
  runTag: "terse-mig-42",
  delivery: { kind: "file" },
  ...over,
});

function noSecrets(text: string, where: string) {
  assert.ok(!text.includes(SECRET), `${where} holds the secret key`);
  assert.ok(!text.includes(TOKEN.slice(0, 30)), `${where} holds the session token`);
}

test("auto issue: STS gets the agent's name, tags and session policy; creds go to a 0600 file; the reply has none", async () => {
  const { broker, calls } = setup();
  const r = await broker.request(req(), requester, "msg-1");
  assert.equal(r.outcome, "issued", r.reasons.join("; "));
  assert.equal(calls.length, 1);
  const c = calls[0]!;
  assert.equal(c.roleArn, `arn:aws:iam::${SANDBOX}:role/agent-broker-sandbox-scoped`);
  assert.equal(c.sessionName, "tersemigrationgrok");
  assert.equal(c.sourceIdentity, "tersemigrationgrok");
  assert.equal(c.durationSeconds, 900);
  assert.deepEqual(c.tags, { "broker-request-id": r.requestId, "agent-run": "terse-mig-42", agent: "tersemigrationgrok" });
  assert.equal(r.delivery!.kind, "file");
  assert.equal(statSync(r.delivery!.ref).mode & 0o777, 0o600);
  const file = JSON.parse(readFileSync(r.delivery!.ref, "utf8")) as Record<string, unknown>;
  assert.equal(file.Version, 1);
  assert.equal(file.SecretAccessKey, SECRET);
  noSecrets(JSON.stringify(r), "reply");
  noSecrets(readFileSync(broker.auditPath, "utf8"), "audit log");
  assert.deepEqual(verifyAudit(broker.auditPath), []);
  const kinds = readFileSync(broker.auditPath, "utf8").trim().split("\n").map((l) => (JSON.parse(l) as { kind: string }).kind);
  assert.deepEqual(kinds, ["requested", "issued"]);
});

test("denied requests are audited and never reach STS", async () => {
  const { broker, calls } = setup();
  const r = await broker.request(req({ actions: ["sts:AssumeRole"] }), requester);
  assert.equal(r.outcome, "denied");
  assert.equal(calls.length, 0);
  assert.match(readFileSync(broker.auditPath, "utf8"), /"kind":"denied"/);
});

test("a run tag stays its first owner's: another agent's request for it needs approval (refused here: no elevated role)", async () => {
  const { broker } = setup();
  assert.equal((await broker.request(req(), requester)).outcome, "issued");
  const other: Principal = { name: "other-agent", address: "other-agent@linuyc-desktop", kind: "agent" };
  const r = await broker.request(req(), other);
  assert.equal(r.outcome, "denied", "the sandbox has no approval-tier role, so it is refused rather than parked");
  assert.match(r.reasons.join("; "), /belongs to tersemigrationgrok/);
});

test("approval: prompt names the digest; agents, wrong digests and late approvals are rejected; single use", async () => {
  const { broker, calls, tick } = setup();
  const r = await broker.request(req({ account: "111122223333", actions: ["sqs:SendMessage"] }), requester, "msg-7");
  assert.equal(r.outcome, "pending-approval");
  assert.match(r.approvalPrompt!, new RegExp(`approve ${r.requestId} ${r.policyDigest!.slice(0, 16)}`));
  assert.equal(calls.length, 0);

  const impostor: Principal = { name: "khaliq-gant", address: "khaliq-gant@linuyc-desktop", kind: "agent" };
  assert.match((await broker.approve(r.requestId, r.policyDigest!, impostor)).reasons[0]!, /not an approver/);
  assert.match((await broker.approve(r.requestId, r.policyDigest!, requester)).reasons[0]!, /not an approver/);
  assert.match((await broker.approve(r.requestId, "deadbeefdeadbeef", khaliq)).reasons[0]!, /digest does not match/);
  assert.match((await broker.approve(r.requestId, r.policyDigest!.slice(0, 6), khaliq)).reasons[0]!, /digest does not match/);
  assert.equal(calls.length, 0);

  tick(5);
  const ok = await broker.approve(r.requestId, r.policyDigest!.slice(0, 16), khaliq, "msg-8");
  assert.equal(ok.outcome, "issued", ok.reasons.join("; "));
  assert.equal(calls[0]!.roleArn, "arn:aws:iam::111122223333:role/agent-broker-elevated");
  assert.match(ok.reasons.join("; "), /approved by khaliq-gant/);
  assert.equal((await broker.approve(r.requestId, r.policyDigest!, khaliq)).outcome, "error", "single use");
  assert.equal(calls.length, 1);

  const late = await broker.request(req({ account: "111122223333", actions: ["sqs:SendMessage"], runTag: "terse-mig-43" }), requester);
  tick(31);
  assert.match((await broker.approve(late.requestId, late.policyDigest!, khaliq)).reasons[0]!, /approval window/);
  const log = readFileSync(broker.auditPath, "utf8");
  assert.match(log, /"kind":"approval-rejected"/);
  assert.match(log, /"kind":"approved".*"approver":\{"name":"khaliq-gant"/);
  assert.deepEqual(verifyAudit(broker.auditPath), []);
});

test("an approval never outlives a policy change: re-decided against the allowlist at approval time", async () => {
  const { broker } = setup();
  const r = await broker.request(req({ account: "111122223333", actions: ["sqs:SendMessage"] }), requester);
  delete (broker.deps.allowlist.accounts as Record<string, unknown>)["111122223333"];
  const res = await broker.approve(r.requestId, r.policyDigest!, khaliq);
  assert.equal(res.outcome, "error");
  assert.match(res.reasons[0]!, /allowlist now refuses/);
  allowlist.accounts["111122223333"] = { label: "prod-test", tier: "prod", roles: { elevated: "arn:aws:iam::111122223333:role/agent-broker-elevated" } };
});

test("refuse: by the approver or the requester, not by a third agent", async () => {
  const { broker } = setup();
  const r = await broker.request(req({ account: "111122223333", actions: ["sqs:SendMessage"] }), requester);
  assert.equal((await broker.refuse(r.requestId, { name: "x-agent", address: "x@y", kind: "agent" })).outcome, "error");
  assert.equal((await broker.refuse(r.requestId, khaliq)).outcome, "denied");
  assert.equal((await broker.approve(r.requestId, r.policyDigest!, khaliq)).outcome, "error");
});

test("sweep removes expired deliveries, and only those", async () => {
  const { broker, tick } = setup();
  const a = await broker.request(req({ durationMinutes: 15 }), requester);
  const b = await broker.request(req({ durationMinutes: 60 }), requester);
  tick(16);
  assert.equal(await broker.sweep(), 1);
  assert.ok(!existsSync(a.delivery!.ref));
  assert.ok(existsSync(b.delivery!.ref));
  assert.match(readFileSync(broker.auditPath, "utf8"), /"kind":"delivery-removed"/);
});

test("the audit chain detects an edited line", async () => {
  const { broker } = setup();
  await broker.request(req(), requester);
  await broker.request(req({ actions: ["sts:AssumeRole"] }), requester);
  const lines = readFileSync(broker.auditPath, "utf8").split("\n");
  lines[1] = lines[1]!.replace("tersemigrationgrok", "someone-else");
  writeFileSync(broker.auditPath, lines.join("\n"));
  assert.ok(verifyAudit(broker.auditPath).some((p) => /hash does not match/.test(p)));
});

test("1Password delivery: the template goes on stdin, never argv; the ref is op://vault/id", async () => {
  const seen: { args: string[]; stdin?: string }[] = [];
  const op: OpRunner = async (args, stdin) => {
    seen.push({ args, ...(stdin !== undefined ? { stdin } : {}) });
    return args[1] === "create" ? JSON.stringify({ id: "abc123xyz" }) : "";
  };
  const d = defaultDeliverer(mkdtempSync(join(tmpdir(), "broker-op-")), op);
  const creds = { accessKeyId: "ASIAFAKE", secretAccessKey: SECRET, sessionToken: TOKEN, expiration: "2026-11-14T13:00:00Z" };
  const ref = await d.deliver({ kind: "1password", vault: "agents" }, "tersemigrationgrok", "cb-000000000001", creds);
  assert.deepEqual(ref, { kind: "1password", ref: "op://agents/abc123xyz" });
  noSecrets(seen[0]!.args.join(" "), "op argv");
  assert.equal(seen[0]!.stdin, onePasswordTemplate("tersemigrationgrok", "cb-000000000001", creds));
  await d.remove(ref);
  assert.deepEqual(seen[1]!.args, ["item", "delete", "abc123xyz", "--vault", "agents"]);
});

test("the STS call: session policy and tags on argv (not secret), the broker profile, no credential", () => {
  const args = assumeRoleArgs({ roleArn: "arn:aws:iam::805532413586:role/r", sessionName: "a-b", sourceIdentity: "a-b", durationSeconds: 900, policy: { Version: "2012-10-17", Statement: [] }, tags: { "broker-request-id": "cb-1", "agent-run": "t1", agent: "a-b" } }, "aws-cred-broker");
  assert.deepEqual(args.slice(0, 4), ["sts", "assume-role", "--profile", "aws-cred-broker"]);
  assert.ok(args.includes("--source-identity"));
  assert.deepEqual(args.slice(-3), ["Key=broker-request-id,Value=cb-1", "Key=agent-run,Value=t1", "Key=agent,Value=a-b"]);
});

test("ordinary metadata is never mistaken for a credential: 40-char run tags, commit SHAs, long names", async () => {
  const { broker } = setup();
  const sha = "0123456789abcdef0123456789abcdef01234567";
  const r = await broker.request(req({ runTag: "a".repeat(40), purpose: `soak test for commit ${sha} and ${"B".repeat(48)}` }), { ...requester, name: "x".repeat(60) });
  assert.equal(r.outcome, "issued", r.reasons.join("; "));
  assert.deepEqual(verifyAudit(broker.auditPath), []);
});

test("the audit writer still refuses credential fields and the exact minted values", () => {
  const path = join(mkdtempSync(join(tmpdir(), "broker-audit-")), "audit.jsonl");
  const now = new Date();
  assert.throws(() => appendAudit(path, { kind: "issued", requestId: "cb-1", reasons: [SECRET] }, now, [SECRET, TOKEN]), /credential/);
  assert.throws(() => appendAudit(path, { kind: "issued", requestId: "cb-1", ...({ SessionToken: "x" } as object) }, now), /credential/);
  assert.doesNotThrow(() => appendAudit(path, { kind: "issued", requestId: "cb-1", reasons: ["a".repeat(64)] }, now, [SECRET, TOKEN]));
});

test("the lock: a live owner keeps it however long it runs; a dead owner's lock is taken over; only the owner releases", async () => {
  const dir = mkdtempSync(join(tmpdir(), "broker-lock-"));
  // A live process (this one) holding the lock: a second run waits, then gives up, never steals it.
  mkdirSync(join(dir, ".lock"));
  writeFileSync(join(dir, ".lock", "owner"), `${process.pid} othertoken\n`);
  await assert.rejects(withLock(dir, async () => "stolen", 300), /locked by another run/);
  assert.equal(readFileSync(join(dir, ".lock", "owner"), "utf8"), `${process.pid} othertoken\n`, "untouched");
  // The owner dies: its lock is taken over.
  const child = spawn(process.execPath, ["-e", ""]);
  await new Promise((r) => child.on("exit", r));
  writeFileSync(join(dir, ".lock", "owner"), `${child.pid} deadtoken\n`);
  assert.equal(await withLock(dir, async () => "ran", 2_000), "ran");
  assert.ok(!existsSync(join(dir, ".lock")), "released after the run");
  // A run whose lock was replaced under it does not remove the replacement.
  await withLock(dir, async () => {
    writeFileSync(join(dir, ".lock", "owner"), `${process.pid} someoneelse\n`);
  });
  assert.ok(existsSync(join(dir, ".lock")), "not ours any more, so left alone");
});

test("the run-tag claim and cleanup record are written before minting; a failed mint undoes both", async () => {
  let seenRecord = false;
  let stateDir = "";
  const failing: StsClient = {
    async assumeRole() {
      seenRecord = readdirSync(join(stateDir, "issued")).length === 1 && JSON.parse(readFileSync(join(stateDir, "run-tags.json"), "utf8"))["terse-mig-42"] === "tersemigrationgrok";
      throw new Error("sts assume-role failed: AccessDenied");
    },
  };
  const { broker } = setup(undefined, { sts: failing });
  stateDir = broker.deps.stateDir;
  const r = await broker.request(req(), requester);
  assert.equal(r.outcome, "error");
  assert.ok(seenRecord, "both were on disk while STS ran");
  assert.deepEqual(readdirSync(join(stateDir, "issued")), []);
  assert.deepEqual(JSON.parse(readFileSync(join(stateDir, "run-tags.json"), "utf8")), {}, "claim rolled back");
});

test("a delivery that fails partway is removed; if removal fails too, sweep still finds it from the planned record", async () => {
  // deliver writes the file, then throws (an op timeout after the item was created looks the same).
  const partial = (base: Deliverer): Deliverer => ({
    ...base,
    async deliver(d, agent, id, creds) {
      await base.deliver(d, agent, id, creds);
      throw new Error("timed out");
    },
  });
  const a = setup(undefined, { deliverer: partial });
  const r = await a.broker.request(req(), requester);
  assert.equal(r.outcome, "error");
  const planned = join(a.dir, "creds", "tersemigrationgrok", `${r.requestId}.json`);
  assert.ok(!existsSync(planned), "removed straight away");
  assert.deepEqual(readdirSync(join(a.broker.deps.stateDir, "issued")), []);
  noSecrets(readFileSync(a.broker.auditPath, "utf8"), "audit log");

  let removeFails = true;
  const stuck = (base: Deliverer): Deliverer => ({
    ...partial(base),
    async remove(ref) {
      if (removeFails) throw new Error("op unavailable");
      return base.remove(ref);
    },
  });
  const b = setup(undefined, { deliverer: stuck });
  const r2 = await b.broker.request(req(), requester);
  assert.equal(r2.outcome, "error");
  const path2 = join(b.dir, "creds", "tersemigrationgrok", `${r2.requestId}.json`);
  assert.ok(existsSync(path2), "still there: removal failed");
  removeFails = false;
  b.tick(17);
  assert.equal(await b.broker.sweep(), 1);
  assert.ok(!existsSync(path2), "sweep removed it from the planned record");
});

test("1Password: the planned ref is the item title, so an item whose id was never returned can still be deleted", () => {
  const d = defaultDeliverer(mkdtempSync(join(tmpdir(), "broker-op-")), async () => "");
  assert.deepEqual(d.planned({ kind: "1password", vault: "agents" }, "tersemigrationgrok", "cb-000000000001"), { kind: "1password", ref: "op://agents/aws-broker-cb-000000000001" });
});
