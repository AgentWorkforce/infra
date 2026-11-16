/**
 * Workspace auto-issue (Khaliq, 2026-11-16): any agent the Relay server
 * verifies as a member of our workspace gets credentials with no approval,
 * when the request falls entirely inside a workspaceAuto capability. The same
 * capability rules and checks as a delegation; everything else still goes to
 * a human.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Broker } from "../broker/src/broker.ts";
import { defaultDeliverer } from "../broker/src/deliver.ts";
import { checkWorkspaceAuto, workspaceAutoProblems, type Allowlist, type CredentialRequest } from "../broker/src/policy.ts";
import { dmChannelId, type RelayAgent, type RelayApi, type RelayMessage } from "../broker/src/relay.ts";
import type { StsClient } from "../broker/src/sts.ts";

const shipped = JSON.parse(readFileSync(new URL("../broker/allowlist.json", import.meta.url), "utf8")) as Allowlist;
const HOSTS = "500268966557";
const NOW = new Date("2026-11-16T12:00:00Z");
const WS = shipped.workspaceAuto!.workspaceId;
const BROKER = "layered-infra-ops";
const agents: Record<string, RelayAgent> = {
  "any-workspace-agent": { id: "300000000000000011", name: "any-workspace-agent", type: "agent", workspaceId: WS },
  "outsider-agent": { id: "300000000000000012", name: "outsider-agent", type: "agent", workspaceId: "rw_otherws1" },
  [BROKER]: { id: "246905220461514752", name: BROKER, type: "agent", workspaceId: WS },
};
const AGENT = "any-workspace-agent";
const SECRET = `arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:neon-exit/runner-AbC123`;
const OTHER_SECRET = `arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:relay-control/db-AbC123`;
const TOKEN_SECRET = `arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:infra-ops/supabase-management-token-Xy9Zq1`;
const RUNNER = `arn:aws:ec2:us-east-1:${HOSTS}:instance/i-0887caee00ca9029a`;
const OTHER_HOST = `arn:aws:ec2:us-east-1:${HOSTS}:instance/i-0123456789abcdef0`;
const SHELL_DOC = "arn:aws:ssm:us-east-1::document/AWS-RunShellScript";

const req = (over: Partial<CredentialRequest> = {}): CredentialRequest => ({
  account: HOSTS,
  purpose: "neon exit: read and update the runner secret",
  actions: ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"],
  durationMinutes: 30,
  runTag: "neon-exit-ws-test",
  scope: "account",
  resources: [SECRET],
  regions: ["us-east-1"],
  delivery: { kind: "file" },
  ...over,
});

function relay(messages: RelayMessage[]): RelayApi {
  return { async message(id) { return messages.find((m) => m.id === id); }, async agentByName(name) { return agents[name]; } };
}
const msg = (id: string, from: string, text: string, ws = agents[from]!.workspaceId): RelayMessage => ({
  id, agentId: agents[from]!.id, agentName: from, agentAddress: `${from}@somewhere`, text,
  channelId: dmChannelId(ws, agents[from]!.id, agents[BROKER]!.id), createdAt: new Date(NOW.getTime() - 60_000).toISOString(),
});

function setup(list: Allowlist = shipped) {
  const dir = mkdtempSync(join(tmpdir(), "broker-ws-"));
  const calls: { roleArn: string; policy: { Statement: { Sid: string }[] } }[] = [];
  const sts: StsClient = { async assumeRole(i) { calls.push(i as never); return { accessKeyId: "ASIAFAKE", secretAccessKey: "s".repeat(40), sessionToken: "t".repeat(300), expiration: new Date(NOW.getTime() + i.durationSeconds * 1000).toISOString() }; } };
  let n = 0;
  const broker = new Broker({ allowlist: list, stateDir: join(dir, "state"), sts, deliverer: defaultDeliverer(join(dir, "creds")), now: () => NOW, newId: () => `cb-${(++n).toString(16).padStart(12, "0")}`, newNamespaceSuffix: () => "0a1b2c3d" });
  return { broker, calls };
}

test("the shipped workspaceAuto: our workspace, granted by Khaliq, one narrow capability, sound", () => {
  const w = shipped.workspaceAuto!;
  assert.equal(w.workspaceId, "rw_7ccfea89");
  assert.equal(w.grantedBy, "khaliq-gant");
  assert.deepEqual(workspaceAutoProblems(shipped), []);
  assert.deepEqual(w.capabilities.map((c) => c.id), ["project-neon-exit"]);
  const c = w.capabilities[0]!;
  assert.deepEqual(c.accounts, [HOSTS]);
  assert.deepEqual(c.grants.flatMap((g) => g.actions).sort(), ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "ssm:SendCommand", "ssm:StartSession"]);
  assert.ok(!c.grants.some((g) => g.secretNames?.length), "no named secrets (the Supabase management token stays delegate-only)");
});

test("a verified workspace agent gets project secrets with no approval; audited as workspace-auto", async () => {
  const { broker, calls } = setup();
  const r = await broker.requestViaRelay(relay([msg("7000001", AGENT, JSON.stringify(req()))]), "7000001", BROKER);
  assert.equal(r.outcome, "issued", r.reasons.join("; "));
  assert.equal(calls[0]!.roleArn, "arn:aws:iam::500268966557:role/agent-broker-elevated");
  assert.match(r.reasons.join("; "), /issued without approval: any-workspace-agent is a verified agent of workspace rw_7ccfea89 .*project-neon-exit/);
  const lines = readFileSync(broker.auditPath, "utf8").trim().split("\n").map((l) => JSON.parse(l) as { kind: string; approver?: unknown });
  assert.deepEqual(lines.find((l) => l.kind === "approved")!.approver, { name: "workspace-auto", address: "rw_7ccfea89", kind: "policy" });
  assert.deepEqual(lines.map((l) => l.kind), ["requested", "approved", "issued"]);
});

test("SSM on the runner is issued too, with the IAM tag guard in the policy it gets", async () => {
  const { broker, calls } = setup();
  const ssm = req({ actions: ["ssm:StartSession", "ssm:SendCommand", "ssm:GetCommandInvocation"], resources: [RUNNER, SHELL_DOC] });
  const r = await broker.requestViaRelay(relay([msg("7000002", AGENT, JSON.stringify(ssm))]), "7000002", BROKER);
  assert.equal(r.outcome, "issued", r.reasons.join("; "));
  assert.ok(calls[0]!.policy.Statement.some((s) => s.Sid.startsWith("WorkspaceDenyUntagged")), "instances without project=neon-exit are denied in IAM");
});

test("anything outside the capability still goes to Khaliq, with the reason", async () => {
  const cases: [Partial<CredentialRequest>, RegExp][] = [
    [{ resources: [OTHER_SECRET] }, /outside it/],
    [{ resources: [TOKEN_SECRET] }, /outside it/],
    [{ actions: ["ssm:SendCommand"], resources: [OTHER_HOST, SHELL_DOC] }, /outside it/],
    [{ actions: ["secretsmanager:DeleteSecret"] }, /deletes/],
    [{ actions: ["iam:PassRole"] }, /IAM/],
    [{ regions: ["us-west-2"] }, /regions us-west-2 are not in it/],
    [{ resources: [`arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:neon-exit/*`] }, /wildcard/],
  ];
  for (const [over, re] of cases) {
    const { broker, calls } = setup();
    const r = await broker.requestViaRelay(relay([msg("7000003", AGENT, JSON.stringify(req(over)))]), "7000003", BROKER);
    assert.equal(r.outcome, "pending-approval", JSON.stringify(over));
    assert.equal(r.approver, "khaliq-gant");
    assert.match(r.reasons.join("; "), re, JSON.stringify(over));
    assert.equal(calls.length, 0);
  }
});

test("only verified members of our workspace: another workspace's agent, or an unverified local request, gets nothing automatically", async () => {
  const { broker, calls } = setup();
  const outsider = await broker.requestViaRelay(relay([msg("7000004", "outsider-agent", JSON.stringify(req()), WS)]), "7000004", BROKER);
  assert.equal(outsider.outcome, "denied");
  assert.match(outsider.reasons[0]!, /isn't in the broker's Relay workspace/);
  // Local (non-Relay) mode carries no verified identity: always approval.
  const local = await broker.request(req(), { name: AGENT, address: AGENT, kind: "agent" });
  assert.equal(local.outcome, "pending-approval");
  assert.equal(calls.length, 0);
  assert.equal(checkWorkspaceAuto({ request: req(), requester: { name: AGENT, address: AGENT, kind: "agent", agentId: "1", workspaceId: "rw_otherws1" }, sessionPolicy: { Version: "2012-10-17", Statement: [] } }, shipped).ok, false);
});

test("an unsound workspaceAuto config turns auto-issue off; everything goes to approval", async () => {
  const bad: Allowlist = { ...shipped, workspaceAuto: { ...shipped.workspaceAuto!, grantedBy: "some-agent" } };
  assert.ok(workspaceAutoProblems(bad).length > 0);
  const { broker, calls } = setup(bad);
  const r = await broker.requestViaRelay(relay([msg("7000005", AGENT, JSON.stringify(req()))]), "7000005", BROKER);
  assert.equal(r.outcome, "pending-approval");
  assert.match(r.reasons.join("; "), /config is unsound/);
  assert.equal(calls.length, 0);
});
