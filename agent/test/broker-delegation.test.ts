/**
 * Delegated approvers: an agent on the allowlist's delegatedApprovers may
 * approve, over Relay, a pending request that names it and falls entirely
 * inside one of its capabilities, until a hard expiry. Everything else still
 * needs Khaliq, and his approvals work exactly as before.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AuditLine } from "../broker/src/audit.ts";
import { Broker } from "../broker/src/broker.ts";
import { defaultDeliverer } from "../broker/src/deliver.ts";
import { checkDelegatedApproval, decide, delegationConfigProblems, grantCovers, type Allowlist, type CredentialRequest, type DelegatedApprover } from "../broker/src/policy.ts";
import { dmChannelId, type RelayAgent, type RelayApi, type RelayMessage } from "../broker/src/relay.ts";
import type { StsClient } from "../broker/src/sts.ts";

const allowlist = JSON.parse(readFileSync(new URL("../broker/allowlist.json", import.meta.url), "utf8")) as Allowlist;
const HOSTS = "500268966557";
const NOW = new Date("2026-11-15T22:00:00Z");
const WS = "rw_test0001";
const BROKER = "layered-infra-ops";
const DELEGATE = "neon-exit-lead";
const WORKER = "neon-exit-worker";
const agents: Record<string, RelayAgent> = {
  [WORKER]: { id: "300000000000000001", name: WORKER, type: "agent", workspaceId: WS },
  [DELEGATE]: { id: "300000000000000002", name: DELEGATE, type: "agent", workspaceId: WS },
  "khaliq-gant": { id: "229221621257396224", name: "khaliq-gant", type: "human", workspaceId: WS },
  "some-other-agent": { id: "300000000000000005", name: "some-other-agent", type: "agent", workspaceId: WS },
  [BROKER]: { id: "246905220461514752", name: BROKER, type: "agent", workspaceId: WS },
};
/** The broker's clock in the current test: messages are sent a minute before it. */
let clock = NOW;
const toBroker = (from: string) => dmChannelId(WS, agents[from]!.id, agents[BROKER]!.id);

const SECRET = `arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:neon-exit/database-url-AbC123`;
const TOKEN_SECRET = `arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:infra-ops/supabase-management-token-Xy9Zq1`;
const INSTANCE = `arn:aws:ec2:us-east-1:${HOSTS}:instance/i-0123456789abcdef0`;
const SHELL_DOC = "arn:aws:ssm:us-east-1::document/AWS-RunShellScript";

const secretsReq = (over: Partial<CredentialRequest> = {}): CredentialRequest => ({
  account: HOSTS,
  purpose: "neon exit: write the new database url",
  actions: ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"],
  durationMinutes: 15,
  runTag: "neon-exit-cutover",
  scope: "account",
  resources: [SECRET, TOKEN_SECRET],
  regions: ["us-east-1"],
  delivery: { kind: "file" },
  delegate: DELEGATE,
  ...over,
});
const ssmReq = (over: Partial<CredentialRequest> = {}) => secretsReq({ purpose: "neon exit: run the cutover script", actions: ["ssm:SendCommand"], resources: [INSTANCE, SHELL_DOC], ...over });

function fakeRelay(messages: RelayMessage[]): RelayApi {
  return {
    async message(id) {
      return messages.find((m) => m.id === id);
    },
    async agentByName(name) {
      return agents[name];
    },
  };
}

const msg = (id: string, from: string, text: string, over: Partial<RelayMessage> = {}): RelayMessage => ({
  id,
  agentId: agents[from]!.id,
  agentName: from,
  agentAddress: `${from}@somewhere`,
  text,
  channelId: toBroker(from),
  createdAt: new Date(clock.getTime() - 60_000).toISOString(),
  ...over,
});

function setup(list: Allowlist = allowlist, now = NOW) {
  clock = now;
  const dir = mkdtempSync(join(tmpdir(), "broker-delegation-"));
  const calls: { sessionName: string }[] = [];
  const sts: StsClient = {
    async assumeRole(input) {
      calls.push(input);
      return { accessKeyId: "ASIAFAKE", secretAccessKey: "s".repeat(40), sessionToken: "t".repeat(300), expiration: new Date(now.getTime() + input.durationSeconds * 1000).toISOString() };
    },
  };
  let n = 0;
  const broker = new Broker({ allowlist: list, stateDir: join(dir, "state"), sts, deliverer: defaultDeliverer(join(dir, "creds")), now: () => now, newId: () => `cb-${(++n).toString(16).padStart(12, "0")}`, newNamespaceSuffix: () => "0a1b2c3d" });
  const audit = () => readFileSync(broker.auditPath, "utf8").trim().split("\n").map((l) => JSON.parse(l) as AuditLine);
  return { broker, calls, audit };
}

/** The worker asks over Relay (message 1); returns the pending reply and the approve text. */
async function pend(broker: Broker, req: CredentialRequest, from = WORKER) {
  const r = await broker.requestViaRelay(fakeRelay([msg("1000001", from, JSON.stringify(req))]), "1000001", BROKER);
  assert.equal(r.outcome, "pending-approval", r.reasons.join("; "));
  return { r, text: `approve ${r.requestId} ${r.policyDigest!.slice(0, 16)}` };
}

const withDelegate = (over: Partial<DelegatedApprover>): Allowlist => ({ ...allowlist, delegatedApprovers: [{ ...allowlist.delegatedApprovers![0]!, ...over }] });

test("the shipped delegation: neon-exit-lead, expiring 2026-11-19, one capability in agent-hosts us-east-1, sound config", () => {
  assert.deepEqual(delegationConfigProblems(allowlist), []);
  assert.deepEqual(allowlist.humanApprovers, ["khaliq-gant"], "Khaliq is still the only human approver");
  const [d, ...rest] = allowlist.delegatedApprovers!;
  assert.equal(rest.length, 0);
  assert.equal(d!.agent, DELEGATE);
  assert.equal(d!.expiresAt, "2026-11-19T00:00:00Z");
  assert.equal(d!.grantedBy, "khaliq-gant");
  const [c] = d!.capabilities;
  assert.deepEqual(c!.accounts, [HOSTS]);
  assert.deepEqual(c!.regions, ["us-east-1"]);
  assert.deepEqual(c!.readOnlyRules, ["read-describe"]);
  assert.deepEqual(c!.grants.flatMap((g) => g.actions).sort(), ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "ssm:SendCommand", "ssm:StartSession"]);
});

test("happy path: a worker's request naming the delegate goes to it; its own DM approves; the audit names delegate, request, digest and capability", async () => {
  const { broker, calls, audit } = setup();
  const { r, text } = await pend(broker, secretsReq());
  assert.equal(r.approver, DELEGATE, "the reply says who to send the approval prompt to");
  assert.match(r.approvalPrompt!, /as a delegate of khaliq-gant until 2026-11-19T00:00:00Z/);
  const ok = await broker.decideViaRelay(fakeRelay([msg("1000002", DELEGATE, text)]), "1000002", BROKER);
  assert.equal(ok.outcome, "issued", ok.reasons.join("; "));
  assert.match(ok.reasons.join("; "), /approved by neon-exit-lead \(delegated by khaliq-gant, capability neon-exit, until 2026-11-19T00:00:00Z\)/);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.sessionName, WORKER, "the credentials are the requester's, not the delegate's");
  const approved = audit().find((l) => l.kind === "approved")!;
  assert.equal(approved.requestId, r.requestId);
  assert.equal(approved.policyDigest, r.policyDigest);
  assert.equal(approved.approver!.name, DELEGATE);
  assert.equal(approved.relayMessageId, "1000002");
  assert.deepEqual(approved.delegation, { delegate: DELEGATE, capability: "neon-exit", grants: ["neon-exit-secrets"], expiresAt: "2026-11-19T00:00:00Z" });
});

test("happy path, SSM: only on instances tagged project=neon-exit, enforced by a deny in the session policy", async () => {
  const { broker, calls } = setup();
  const { r, text } = await pend(broker, ssmReq({ actions: ["ssm:SendCommand", "ec2:DescribeInstances"] }));
  assert.equal(r.approver, DELEGATE, r.reasons.join("; "));
  const ok = await broker.decideViaRelay(fakeRelay([msg("1000002", DELEGATE, text)]), "1000002", BROKER);
  assert.equal(ok.outcome, "issued", ok.reasons.join("; "));
  const policy = (calls[0] as unknown as { policy: { Statement: { Sid: string; Effect: string; Action?: string[]; Condition?: unknown }[] } }).policy;
  const guard = policy.Statement.find((s) => s.Sid === "DelegateDenyUntaggedNeonExitSsm")!;
  assert.equal(guard.Effect, "Deny");
  assert.deepEqual(guard.Action, ["ssm:SendCommand"]);
  assert.deepEqual(guard.Condition, { StringNotEquals: { "ssm:resourceTag/project": "neon-exit" } });
});

test("an expired delegate is refused, and so is a delegation set to run past 30 days", async () => {
  const late = setup(allowlist, new Date("2026-11-19T00:00:00Z"));
  const { text } = await pend(late.broker, secretsReq());
  const r = await late.broker.decideViaRelay(fakeRelay([msg("1000002", DELEGATE, text)]), "1000002", BROKER);
  assert.equal(r.outcome, "error");
  assert.match(r.reasons[0]!, /delegation expired at 2026-11-19T00:00:00Z/);
  assert.equal(late.calls.length, 0);
  assert.equal(late.audit().at(-1)!.kind, "approval-rejected");

  const long = setup(withDelegate({ expiresAt: "2027-01-01T00:00:00Z" }));
  const p = await pend(long.broker, secretsReq());
  const r2 = await long.broker.decideViaRelay(fakeRelay([msg("1000002", DELEGATE, p.text)]), "1000002", BROKER);
  assert.match(r2.reasons[0]!, /runs past 30 days/);
  assert.equal(long.calls.length, 0);
});

test("out of scope: other actions, secrets, instances, documents, regions and accounts are refused", async () => {
  const cases: [Partial<CredentialRequest>, RegExp][] = [
    [{ actions: ["secretsmanager:GetSecretValue", "secretsmanager:UpdateSecret"] }, /UpdateSecret on .* is outside it/],
    [{ actions: ["ec2:StopInstances"], resources: [INSTANCE] }, /StopInstances on .* is outside it/],
    [{ resources: [`arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:relaycast/database-url-AbC123`] }, /is outside it/],
    [{ resources: [`arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:infra-ops/supabase-management-token-extra-AbC123`] }, /is outside it/],
    [{ resources: [`arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:neon-exit/`] }, /is outside it/],
    [{ resources: [`arn:aws:secretsmanager:us-west-2:${HOSTS}:secret:neon-exit/database-url-AbC123`], regions: ["us-west-2"] }, /regions us-west-2 are not in it/],
    [{ regions: undefined }, /must name its regions/],
    [{ resources: [`arn:aws:secretsmanager:us-east-1:111122223333:secret:neon-exit/database-url-AbC123`] }, /is outside it/],
  ];
  for (const [over, re] of cases) {
    const { broker, calls } = setup();
    const { r, text } = await pend(broker, secretsReq(over));
    assert.equal(r.approver, "khaliq-gant", `${JSON.stringify(over)}: goes to Khaliq`);
    assert.ok(r.reasons.some((x) => re.test(x)), `${JSON.stringify(over)}: ${r.reasons.join("; ")}`);
    const d = await broker.decideViaRelay(fakeRelay([msg("1000002", DELEGATE, text)]), "1000002", BROKER);
    assert.equal(d.outcome, "error", JSON.stringify(over));
    assert.match(d.reasons[0]!, re, JSON.stringify(over));
    assert.equal(calls.length, 0);
  }
  const ssmCases: [Partial<CredentialRequest>, RegExp][] = [
    [{ resources: [INSTANCE, "arn:aws:ssm:us-east-1::document/AWS-ApplyPatchBaseline"] }, /outside it/],
    [{ actions: ["ssm:StartAutomationExecution"] }, /outside it/],
  ];
  for (const [over, re] of ssmCases) {
    const { broker } = setup();
    const { text } = await pend(broker, ssmReq(over));
    assert.match((await broker.decideViaRelay(fakeRelay([msg("1000002", DELEGATE, text)]), "1000002", BROKER)).reasons[0]!, re, JSON.stringify(over));
  }
  // An account not on the allowlist never reaches approval at all.
  assert.equal(decide(secretsReq({ account: "999999999999" }), { name: WORKER, address: WORKER, kind: "agent" }, allowlist, { namespace: "neon-exit-cutover-0a1b2c3d" }).outcome, "deny");
});

test("wildcards, IAM and deletes are never delegable", async () => {
  const cases: [Partial<CredentialRequest>, RegExp][] = [
    [{ resources: [`arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:neon-exit/*`] }, /wildcard, never delegable/],
    [{ resources: [`arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:neon-exit/database-url-??????`] }, /wildcard, never delegable/],
    [{ resources: undefined }, /outside it/],
    [{ actions: ["secretsmanager:Get*"] }, /wildcard, never delegable/],
    [{ actions: ["iam:PassRole"] }, /IAM, never delegable/],
    [{ actions: ["secretsmanager:DeleteSecret"] }, /deletes, never delegable/],
    [{ actions: ["ec2:TerminateInstances"], resources: [INSTANCE] }, /deletes, never delegable/],
  ];
  for (const [over, re] of cases) {
    const { broker, calls } = setup();
    const { text } = await pend(broker, secretsReq(over));
    const d = await broker.decideViaRelay(fakeRelay([msg("1000002", DELEGATE, text)]), "1000002", BROKER);
    assert.equal(d.outcome, "error", JSON.stringify(over));
    assert.match(d.reasons[0]!, re, JSON.stringify(over));
    assert.equal(calls.length, 0);
  }
  // A capability that lists any of them is unsound, which refuses every delegated approval.
  const bad = withDelegate({ capabilities: [{ ...allowlist.delegatedApprovers![0]!.capabilities[0]!, grants: [{ id: "x", actions: ["iam:PutRolePolicy", "secretsmanager:DeleteSecret"], secretPrefixes: ["neon-exit/*"] }] }] });
  const problems = delegationConfigProblems(bad).join("; ");
  assert.match(problems, /iam:PutRolePolicy is IAM, never delegable/);
  assert.match(problems, /DeleteSecret deletes, never delegable/);
  assert.match(problems, /no wildcards/);
  const pending = decide(secretsReq(), { name: WORKER, address: WORKER, kind: "agent" }, bad, { namespace: "neon-exit-cutover-0a1b2c3d" });
  assert.equal(pending.outcome, "approval");
  if (pending.outcome !== "approval") return;
  const c = checkDelegatedApproval({ request: secretsReq(), requester: { name: WORKER, address: WORKER, kind: "agent" }, sessionPolicy: pending.sessionPolicy }, { name: DELEGATE, address: DELEGATE, kind: "agent" }, bad, NOW);
  assert.ok(!c.ok && /config is unsound/.test(c.reason));
  assert.ok(!grantCovers({ id: "s", actions: [], secretPrefixes: ["neon-exit/"] }, `arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:neon-exit/*`, HOSTS, "us-east-1"));
});

test("a replayed approval message id is refused", async () => {
  const { broker, calls } = setup();
  const first = await pend(broker, secretsReq());
  const relay = fakeRelay([msg("1000002", DELEGATE, first.text)]);
  assert.equal((await broker.decideViaRelay(relay, "1000002", BROKER)).outcome, "issued");
  // Same message again (whatever request it would now name) is refused before anything else.
  const again = await broker.decideViaRelay(relay, "1000002", BROKER);
  assert.equal(again.outcome, "error");
  assert.match(again.reasons[0]!, /already acted on/);
  assert.equal(calls.length, 1);
});

test("only the delegate's own DM to the broker counts: channel posts, DMs elsewhere, stale messages and display-name spoofs are refused", async () => {
  const { broker, calls } = setup();
  const { text } = await pend(broker, secretsReq());
  const relay = fakeRelay([
    msg("1000002", DELEGATE, text, { channelId: "ch_neon_exit" }),
    msg("1000003", DELEGATE, text, { channelId: dmChannelId(WS, agents[DELEGATE]!.id, agents["some-other-agent"]!.id) }),
    msg("1000004", DELEGATE, text, { createdAt: new Date(NOW.getTime() - 16 * 60_000).toISOString() }),
    msg("1000005", DELEGATE, text, { agentId: agents["some-other-agent"]!.id, channelId: toBroker("some-other-agent") }),
  ]);
  assert.match((await broker.decideViaRelay(relay, "1000002", BROKER)).reasons[0]!, /not a channel post/);
  assert.match((await broker.decideViaRelay(relay, "1000003", BROKER)).reasons[0]!, /wasn't sent to layered-infra-ops/);
  assert.match((await broker.decideViaRelay(relay, "1000004", BROKER)).reasons[0]!, /last 15 minutes/);
  assert.match((await broker.decideViaRelay(relay, "1000005", BROKER)).reasons[0]!, /doesn't resolve/);
  assert.equal(calls.length, 0);
});

test("the delegate never approves its own request, one that didn't name it, or one from outside its requesters", async () => {
  {
    const { broker, calls } = setup();
    const { r, text } = await pend(broker, secretsReq(), DELEGATE);
    assert.equal(r.approver, "khaliq-gant");
    assert.match((await broker.decideViaRelay(fakeRelay([msg("1000002", DELEGATE, text)]), "1000002", BROKER)).reasons[0]!, /cannot approve its own request/);
    assert.equal(calls.length, 0);
  }
  {
    const { broker, calls } = setup();
    const { r, text } = await pend(broker, secretsReq({ delegate: undefined }));
    assert.equal(r.approver, "khaliq-gant");
    assert.match((await broker.decideViaRelay(fakeRelay([msg("1000002", DELEGATE, text)]), "1000002", BROKER)).reasons[0]!, /didn't name neon-exit-lead/);
    assert.equal(calls.length, 0);
  }
  {
    const { broker, calls } = setup(withDelegate({ requesters: ["someone-else"] }));
    const { text } = await pend(broker, secretsReq());
    assert.match((await broker.decideViaRelay(fakeRelay([msg("1000002", DELEGATE, text)]), "1000002", BROKER)).reasons[0]!, /not one of its requesters/);
    assert.equal(calls.length, 0);
  }
  // Another agent is still not an approver, delegate field or not.
  const { broker } = setup();
  const { text } = await pend(broker, secretsReq());
  assert.match((await broker.decideViaRelay(fakeRelay([msg("1000002", "some-other-agent", text)]), "1000002", BROKER)).reasons[0]!, /not an approver/);
  // Naming a delegate that isn't on the allowlist is refused outright.
  const unknown = await broker.requestViaRelay(fakeRelay([msg("1000009", WORKER, JSON.stringify(secretsReq({ delegate: "some-other-agent" })))]), "1000009", BROKER);
  assert.equal(unknown.outcome, "denied");
  assert.match(unknown.reasons.join("; "), /not a delegated approver/);
});

test("khaliq-gant's approval works unchanged: with or without a delegate named, in scope or not, and after the delegation expires", async () => {
  for (const [req, now] of [
    [secretsReq({ delegate: undefined }), NOW],
    [secretsReq(), NOW],
    [secretsReq({ actions: ["iam:PassRole"], resources: [`arn:aws:iam::${HOSTS}:role/some-role`] }), NOW],
    [secretsReq(), new Date("2026-12-01T00:00:00Z")],
  ] as const) {
    const { broker, calls, audit } = setup(allowlist, now);
    const r = await broker.requestViaRelay(fakeRelay([msg("1000001", WORKER, JSON.stringify(req))]), "1000001", BROKER);
    assert.equal(r.outcome, "pending-approval", r.reasons.join("; "));
    const text = `approve ${r.requestId} ${r.policyDigest!.slice(0, 16)}`;
    const ok = await broker.decideViaRelay(fakeRelay([msg("1000002", "khaliq-gant", text)]), "1000002", BROKER);
    assert.equal(ok.outcome, "issued", ok.reasons.join("; "));
    assert.equal(ok.reasons.at(-1), "approved by khaliq-gant");
    assert.equal(calls.length, 1);
    assert.equal(audit().find((l) => l.kind === "approved")!.delegation, undefined, "no delegation on Khaliq's approvals");
  }
});

test("a request without a delegate gets exactly the policy it got before this change", () => {
  const requester = { name: WORKER, address: WORKER, kind: "agent" as const };
  const run = { namespace: "neon-exit-cutover-0a1b2c3d" };
  const without = decide(ssmReq({ delegate: undefined }), requester, { ...allowlist, delegatedApprovers: undefined }, run);
  const withList = decide(ssmReq({ delegate: undefined }), requester, allowlist, run);
  assert.deepEqual(withList, without);
  const named = decide(ssmReq(), requester, allowlist, run);
  assert.ok(named.outcome === "approval" && named.sessionPolicy.Statement.some((s) => s.Sid === "DelegateDenyUntaggedNeonExitSsm"), "naming the delegate only adds its deny");
});
