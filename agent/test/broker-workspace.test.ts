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
import { checkWorkspaceAuto, delegationConfigProblems, workspaceAutoProblems, type Allowlist, type CredentialRequest, type PolicyStatement } from "../broker/src/policy.ts";
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
  const calls: { roleArn: string; policy: { Statement: PolicyStatement[] } }[] = [];
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
  assert.deepEqual(w.capabilities.map((c) => c.id), ["project-neon-exit", "dev-cluster-read", "prod-cluster-read"]);
  assert.deepEqual(w.capabilities.filter((c) => c.requesters !== undefined).map((c) => c.id), ["prod-cluster-read"], "only the prod capability is limited to named requesters");
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

test("review fixes: humans aren't auto-issued, another agent's run tag stays on approval, a malformed config falls back to approval", async () => {
  // A verified human in the workspace (not an approver) goes through approval.
  const human: RelayAgent = { id: "300000000000000013", name: "some-human", type: "human", workspaceId: WS };
  agents["some-human"] = human;
  {
    const { broker, calls } = setup();
    const r = await broker.requestViaRelay(relay([msg("7000006", "some-human", JSON.stringify(req()))]), "7000006", BROKER);
    assert.equal(r.outcome, "pending-approval");
    assert.match(r.reasons.join("; "), /only workspace agents/);
    assert.equal(calls.length, 0);
  }
  // Two agents, one run tag: the second one is not auto-issued into the first one's run.
  agents["second-agent"] = { id: "300000000000000014", name: "second-agent", type: "agent", workspaceId: WS };
  {
    const { broker, calls } = setup();
    const first = await broker.requestViaRelay(relay([msg("7000007", AGENT, JSON.stringify(req()))]), "7000007", BROKER);
    assert.equal(first.outcome, "issued", first.reasons.join("; "));
    const second = await broker.requestViaRelay(relay([msg("7000008", "second-agent", JSON.stringify(req()))]), "7000008", BROKER);
    assert.equal(second.outcome, "pending-approval");
    assert.match(second.reasons.join("; "), /belongs to any-workspace-agent/);
    assert.equal(calls.length, 1);
  }
  // Malformed nested config (a capability with no grants, a grant with no actions): no crash, approval.
  for (const capabilities of [
    [{ ...shipped.workspaceAuto!.capabilities[0]!, grants: undefined }],
    [{ ...shipped.workspaceAuto!.capabilities[0]!, grants: [{ id: "x" }] }],
    [{ ...shipped.workspaceAuto!.capabilities[0]!, grants: [{ ...shipped.workspaceAuto!.capabilities[0]!.grants[0]!, secretPrefixes: 7 }] }],
    "nope",
  ]) {
    const bad = { ...shipped, workspaceAuto: { ...shipped.workspaceAuto!, capabilities } } as unknown as Allowlist;
    assert.ok(workspaceAutoProblems(bad).length > 0, JSON.stringify(capabilities));
    const { broker, calls } = setup(bad);
    const r = await broker.requestViaRelay(relay([msg("7000009", AGENT, JSON.stringify(req()))]), "7000009", BROKER);
    assert.equal(r.outcome, "pending-approval", JSON.stringify(capabilities));
    assert.match(r.reasons.join("; "), /config is unsound/);
    assert.equal(calls.length, 0);
  }
});

// Read-only access to the dev cluster (capability dev-cluster-read): eks:DescribeCluster on one named cluster
// in one region of one account, which is what `aws eks update-kubeconfig` calls. The Kubernetes side is the
// role's EKS access entry (terraform/dev), not this policy.
const DEV = Object.entries(shipped.accounts).find(([, a]) => a.label === "agentrelay-dev")![0];
const CLUSTER = `arn:aws:eks:us-west-2:${DEV}:cluster/agent-relay-dev`;
const devReq = (over: Partial<CredentialRequest> = {}): CredentialRequest => ({
  account: DEV,
  purpose: "dev proof: EKS token for kubectl get pods, jobs and logs (read-only)",
  actions: ["eks:DescribeCluster"],
  durationMinutes: 30,
  runTag: "dev-read-test",
  scope: "account",
  resources: [CLUSTER],
  regions: ["us-west-2"],
  delivery: { kind: "file" },
  ...over,
});

test("dev cluster: a verified workspace agent gets eks:DescribeCluster on exactly agent-relay-dev, with no approval", async () => {
  const { broker, calls } = setup();
  const r = await broker.requestViaRelay(relay([msg("7100001", AGENT, JSON.stringify(devReq()))]), "7100001", BROKER);
  assert.equal(r.outcome, "issued", r.reasons.join("; "));
  assert.equal(calls[0]!.roleArn, shipped.accounts[DEV]!.roles.elevated);
  assert.match(r.reasons.join("; "), /issued without approval: any-workspace-agent .*dev-cluster-read \(dev-cluster-describe\)/);
  const allows = calls[0]!.policy.Statement.filter((s) => s.Effect === "Allow");
  assert.deepEqual(allows.map((s) => ({ a: s.Action, r: s.Resource })), [{ a: ["eks:DescribeCluster"], r: CLUSTER }]);
  const lines = readFileSync(broker.auditPath, "utf8").trim().split("\n").map((l) => JSON.parse(l) as { kind: string; approver?: unknown });
  assert.deepEqual(lines.find((l) => l.kind === "approved")!.approver, { name: "workspace-auto", address: "rw_7ccfea89", kind: "policy" });
  // The session can't leave the account's one region either.
  assert.ok(calls[0]!.policy.Statement.some((s) => s.Sid === "DenyOutsideRegions"));
});

test("dev cluster: anything but that one read goes to Khaliq (or is refused), and nothing is issued", async () => {
  const cases: [Partial<CredentialRequest>, "pending-approval" | "denied", RegExp][] = [
    [{ resources: [`arn:aws:eks:us-west-2:${DEV}:cluster/agent-relay-prod`] }, "pending-approval", /outside it/],
    [{ resources: [`arn:aws:eks:us-west-2:${DEV}:cluster/agent-relay-dev-2`] }, "pending-approval", /outside it/],
    [{ resources: [CLUSTER, `arn:aws:eks:us-west-2:${DEV}:cluster/other`] }, "pending-approval", /outside it/],
    [{ resources: [`arn:aws:eks:us-east-1:${DEV}:cluster/agent-relay-dev`] }, "pending-approval", /outside it/],
    [{ resources: [`arn:aws:eks:us-west-2:${HOSTS}:cluster/agent-relay-dev`] }, "pending-approval", /outside it/],
    [{ resources: [`arn:aws:eks:us-west-2:${DEV}:cluster/agent-relay-*`] }, "pending-approval", /wildcard/],
    [{ resources: undefined }, "pending-approval", /outside it/],
    [{ resources: [`arn:aws:eks:us-west-2:${DEV}:nodegroup/agent-relay-dev/ng/0a1b2c3d-0000-0000-0000-000000000000`] }, "pending-approval", /outside it/],
    [{ regions: undefined }, "pending-approval", /must name its regions/],
    [{ regions: ["us-east-1"] }, "denied", /not allowed in agentrelay-dev/],
    [{ regions: ["us-west-2", "us-east-1"] }, "denied", /not allowed in agentrelay-dev/],
    [{ actions: ["eks:DescribeCluster", "eks:ListClusters"] }, "pending-approval", /outside it/],
    [{ actions: ["eks:DescribeCluster", "eks:DescribeNodegroup"] }, "pending-approval", /outside it/],
    [{ actions: ["eks:DescribeCluster", "ec2:DescribeInstances"] }, "pending-approval", /outside it/],
    [{ actions: ["eks:AccessKubernetesApi"] }, "pending-approval", /outside it/],
    [{ actions: ["eks:UpdateClusterConfig"] }, "pending-approval", /outside it/],
    [{ actions: ["eks:CreateAccessEntry"] }, "pending-approval", /outside it/],
    [{ actions: ["eks:AssociateAccessPolicy"] }, "pending-approval", /outside it/],
    [{ actions: ["eks:DeleteCluster"] }, "pending-approval", /deletes/],
    [{ actions: ["eks:*"] }, "pending-approval", /wildcard/],
    [{ actions: ["eks:Describe*"] }, "pending-approval", /wildcard/],
    [{ actions: ["iam:PassRole"] }, "pending-approval", /IAM/],
    [{ actions: ["sts:AssumeRole"] }, "denied", /never issued/],
    [{ account: "111122223333" }, "denied", /not on the broker allowlist/],
    [{ delegate: "neon-exit-lead-2" }, "pending-approval", /names a delegate/],
  ];
  for (const [over, outcome, re] of cases) {
    const { broker, calls } = setup();
    const r = await broker.requestViaRelay(relay([msg("7100002", AGENT, JSON.stringify(devReq(over)))]), "7100002", BROKER);
    assert.equal(r.outcome, outcome, `${JSON.stringify(over)}: ${r.reasons.join("; ")}`);
    assert.match(r.reasons.join("; "), re, JSON.stringify(over));
    assert.equal(calls.length, 0, JSON.stringify(over));
  }
});

test("dev cluster: the default scope with the exact cluster ARN is the same read; humans and outsiders still don't get it automatically", async () => {
  const { broker, calls } = setup();
  const r = await broker.requestViaRelay(relay([msg("7100003", AGENT, JSON.stringify(devReq({ scope: undefined })))]), "7100003", BROKER);
  assert.equal(r.outcome, "issued", r.reasons.join("; "));
  assert.deepEqual(calls[0]!.policy.Statement.filter((s) => s.Effect === "Allow").flatMap((s) => s.Action ?? []), ["eks:DescribeCluster"]);
  agents["dev-human"] = { id: "300000000000000015", name: "dev-human", type: "human", workspaceId: WS };
  for (const who of ["dev-human"]) {
    const h = await setup().broker.requestViaRelay(relay([msg("7100004", who, JSON.stringify(devReq()))]), "7100004", BROKER);
    assert.equal(h.outcome, "pending-approval");
  }
  const o = await setup().broker.requestViaRelay(relay([msg("7100005", "outsider-agent", JSON.stringify(devReq()), WS)]), "7100005", BROKER);
  assert.equal(o.outcome, "denied");
});

test("dev cluster: the capability is read-only by construction; a config that tries to widen it is unsound", () => {
  assert.deepEqual(workspaceAutoProblems(shipped), []);
  const grant = shipped.workspaceAuto!.capabilities.find((c) => c.id === "dev-cluster-read")!.grants[0]!;
  assert.deepEqual(grant.actions, ["eks:DescribeCluster"]);
  assert.deepEqual(grant.eksClusters, ["agent-relay-dev"]);
  const withGrant = (g: object): Allowlist => ({ ...shipped, workspaceAuto: { ...shipped.workspaceAuto!, capabilities: [{ ...shipped.workspaceAuto!.capabilities.find((c) => c.id === "dev-cluster-read")!, grants: [g as never] }] } });
  const bad: [object, RegExp][] = [
    [{ ...grant, actions: ["eks:DescribeCluster", "eks:UpdateClusterConfig"] }, /not a read action/],
    [{ ...grant, actions: ["eks:CreateAccessEntry"] }, /not a read action/],
    [{ ...grant, actions: ["eks:AccessKubernetesApi"] }, /not a read action/],
    [{ ...grant, actions: ["eks:DeleteCluster"] }, /deletes, never delegable/],
    [{ ...grant, actions: ["eks:*"] }, /wildcard/],
    [{ ...grant, eksClusters: ["agent-relay-*"] }, /literal cluster name/],
    [{ ...grant, eksClusters: ["*"] }, /literal cluster name/],
    [{ ...grant, eksClusters: [] }, /needs literal eksClusters/],
    [{ ...grant, actions: ["eks:DescribeCluster", "ec2:DescribeInstances"] }, /a grant is/],
    [{ ...grant, secretPrefixes: ["neon-exit/"] }, /a grant is/],
    [{ ...grant, eksClusters: "agent-relay-dev" }, /lists of names/],
  ];
  for (const [g, re] of bad) assert.match(workspaceAutoProblems(withGrant(g)).join("; "), re, JSON.stringify(g));
});

// Read-only access to the prod cluster (capability prod-cluster-read): the same single read as the dev
// cluster, but the capability names its requesters. Only they are issued it without approval; any other
// workspace agent's request is not matched against it and goes to the approver. The Kubernetes side is
// the role's EKS access entry (terraform/prod), not this policy.
const PROD = Object.entries(shipped.accounts).find(([, a]) => a.label === "agentrelay-prod")![0];
const PROD_CLUSTER = `arn:aws:eks:us-west-2:${PROD}:cluster/agent-relay-prod`;
const LISTED = "envs-lead";
agents[LISTED] = { id: "100000000000000021", name: LISTED, type: "agent", workspaceId: WS };
const prodReq = (over: Partial<CredentialRequest> = {}): CredentialRequest => ({
  account: PROD,
  purpose: "prod: EKS token for kubectl get on deployments and ingresses (read-only)",
  actions: ["eks:DescribeCluster"],
  durationMinutes: 30,
  runTag: "prod-read-test",
  scope: "account",
  resources: [PROD_CLUSTER],
  regions: ["us-west-2"],
  delivery: { kind: "file" },
  ...over,
});
const withProdRequesters = (requesters: unknown): Allowlist => ({
  ...shipped,
  workspaceAuto: { ...shipped.workspaceAuto!, capabilities: shipped.workspaceAuto!.capabilities.map((c) => (c.id === "prod-cluster-read" ? { ...c, requesters } : c)) },
}) as unknown as Allowlist;
const describeOnly = (cluster: string) => ({ Version: "2012-10-17" as const, Statement: [{ Sid: "ApprovedAccountWide", Effect: "Allow" as const, Action: ["eks:DescribeCluster"], Resource: cluster }] });

test("prod cluster: the shipped capability is one read on one cluster, limited to the one named agent, and no delegate can approve in that account", () => {
  const c = shipped.workspaceAuto!.capabilities.find((x) => x.id === "prod-cluster-read")!;
  assert.deepEqual(c.requesters, [LISTED]);
  assert.deepEqual(c.accounts, [PROD]);
  assert.deepEqual(c.regions, ["us-west-2"]);
  assert.equal(c.readOnlyRules, undefined);
  assert.deepEqual(c.grants, [{ id: "prod-cluster-describe", actions: ["eks:DescribeCluster"], eksClusters: ["agent-relay-prod"] }]);
  const account = shipped.accounts[PROD]!;
  assert.deepEqual({ tier: account.tier, regions: account.regions, scoped: account.roles.scoped }, { tier: "prod", regions: ["us-west-2"], scoped: undefined });
  assert.match(account.roles.elevated!, new RegExp(`^arn:aws:iam::${PROD}:role/agent-broker-prod-read$`));
  for (const d of shipped.delegatedApprovers ?? []) for (const dc of d.capabilities) assert.ok(!dc.accounts.includes(PROD), `${d.agent} has a capability in the prod account`);
  assert.deepEqual(workspaceAutoProblems(shipped), []);
});

test("prod cluster: the listed requester gets eks:DescribeCluster on exactly agent-relay-prod, with no approval", async () => {
  const { broker, calls } = setup();
  const r = await broker.requestViaRelay(relay([msg("7200001", LISTED, JSON.stringify(prodReq()))]), "7200001", BROKER);
  assert.equal(r.outcome, "issued", r.reasons.join("; "));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.roleArn, shipped.accounts[PROD]!.roles.elevated);
  assert.match(r.reasons.join("; "), /issued without approval: envs-lead .*prod-cluster-read \(prod-cluster-describe\)/);
  assert.deepEqual(calls[0]!.policy.Statement.filter((s) => s.Effect === "Allow").map((s) => ({ a: s.Action, r: s.Resource })), [{ a: ["eks:DescribeCluster"], r: PROD_CLUSTER }]);
  assert.ok(calls[0]!.policy.Statement.some((s) => s.Sid === "DenyOutsideRegions"));
});

test("prod cluster: another verified workspace agent is not issued it automatically; the same request goes to approval and nothing is issued", async () => {
  const { broker, calls } = setup();
  const r = await broker.requestViaRelay(relay([msg("7200002", AGENT, JSON.stringify(prodReq()))]), "7200002", BROKER);
  assert.equal(r.outcome, "pending-approval", r.reasons.join("; "));
  assert.match(r.reasons.join("; "), /prod-cluster-read: only issued without approval to envs-lead/);
  assert.equal(calls.length, 0);
  // The pure check, for every way of not being the listed agent of this workspace.
  const p = (requester: object) => checkWorkspaceAuto({ request: prodReq(), requester: requester as never, sessionPolicy: describeOnly(PROD_CLUSTER) }, shipped);
  const listed = { name: LISTED, address: `${LISTED}@somewhere`, kind: "agent", agentId: agents[LISTED]!.id, workspaceId: WS };
  assert.deepEqual(p(listed), { ok: true, capability: "prod-cluster-read", grants: ["prod-cluster-describe"] });
  for (const other of [
    { ...listed, name: AGENT },
    { ...listed, name: "envs-lead-2" },
    { ...listed, name: "ENVS-LEAD" },
    { ...listed, name: "" },
    { ...listed, kind: "human" },
    { ...listed, workspaceId: "rw_someoneelse" },
    { ...listed, workspaceId: undefined },
    { ...listed, agentId: undefined },
  ]) assert.equal(p(other).ok, false, JSON.stringify(other));
});

test("prod cluster: the listed requester gets nothing wider than the one read", async () => {
  const cases: [Partial<CredentialRequest>, "pending-approval" | "denied", RegExp][] = [
    [{ resources: [`arn:aws:eks:us-west-2:${PROD}:cluster/agent-relay-dev`] }, "pending-approval", /outside it/],
    [{ resources: [`arn:aws:eks:us-west-2:${PROD}:cluster/agent-relay-prod-2`] }, "pending-approval", /outside it/],
    [{ resources: [PROD_CLUSTER, `arn:aws:eks:us-west-2:${PROD}:cluster/other`] }, "pending-approval", /outside it/],
    [{ resources: [`arn:aws:eks:us-west-2:${PROD}:cluster/*`] }, "pending-approval", /wildcard/],
    [{ resources: undefined }, "pending-approval", /outside it/],
    [{ regions: undefined }, "pending-approval", /must name its regions/],
    [{ regions: ["us-east-1"] }, "denied", /not allowed in agentrelay-prod/],
    [{ actions: ["eks:DescribeCluster", "eks:ListClusters"] }, "pending-approval", /outside it/],
    [{ actions: ["eks:AccessKubernetesApi"] }, "pending-approval", /outside it/],
    [{ actions: ["eks:CreateAccessEntry"] }, "pending-approval", /outside it/],
    [{ actions: ["eks:UpdateClusterConfig"] }, "pending-approval", /outside it/],
    [{ actions: ["secretsmanager:GetSecretValue"], resources: [`arn:aws:secretsmanager:us-west-2:${PROD}:secret:neon-exit/runner-AbC123`] }, "pending-approval", /outside it/],
    [{ actions: ["eks:DeleteCluster"] }, "pending-approval", /deletes/],
    [{ actions: ["iam:PassRole"] }, "pending-approval", /IAM/],
    [{ actions: ["sts:AssumeRole"] }, "denied", /never issued/],
    [{ delegate: "neon-exit-lead-2" }, "pending-approval", /names a delegate/],
  ];
  for (const [over, outcome, re] of cases) {
    const { broker, calls } = setup();
    const r = await broker.requestViaRelay(relay([msg("7200003", LISTED, JSON.stringify(prodReq(over)))]), "7200003", BROKER);
    assert.equal(r.outcome, outcome, `${JSON.stringify(over)}: ${r.reasons.join("; ")}`);
    assert.match(r.reasons.join("; "), re, JSON.stringify(over));
    assert.equal(calls.length, 0, JSON.stringify(over));
  }
});

test("requesters: capabilities without the field are unchanged, for every workspace agent", async () => {
  // The same decision with and without the limited capability in the list.
  const without: Allowlist = { ...shipped, workspaceAuto: { ...shipped.workspaceAuto!, capabilities: shipped.workspaceAuto!.capabilities.filter((c) => c.requesters === undefined) } };
  assert.equal(without.workspaceAuto!.capabilities.length, shipped.workspaceAuto!.capabilities.length - 1);
  for (const who of [AGENT, LISTED]) {
    const requester = { name: who, address: `${who}@somewhere`, kind: "agent" as const, agentId: agents[who]!.id, workspaceId: WS };
    const p = { request: devReq(), requester, sessionPolicy: describeOnly(CLUSTER) };
    assert.deepEqual(checkWorkspaceAuto(p, shipped), { ok: true, capability: "dev-cluster-read", grants: ["dev-cluster-describe"] });
    assert.deepEqual(checkWorkspaceAuto(p, shipped), checkWorkspaceAuto(p, without));
    const { broker, calls } = setup();
    const r = await broker.requestViaRelay(relay([msg("7200004", who, JSON.stringify(devReq({ runTag: `dev-read-${who.length}` })))]), "7200004", BROKER);
    assert.equal(r.outcome, "issued", r.reasons.join("; "));
    assert.equal(calls[0]!.roleArn, shipped.accounts[DEV]!.roles.elevated);
  }
  const s = await setup().broker.requestViaRelay(relay([msg("7200005", AGENT, JSON.stringify(req()))]), "7200005", BROKER);
  assert.equal(s.outcome, "issued", s.reasons.join("; "));
});

test("requesters: an empty or malformed list is a config error that turns auto-issue off; it is never read as everyone", async () => {
  const bad: unknown[] = [[], null, "envs-lead", { 0: "envs-lead" }, [""], [7], [null], ["envs lead"], ["envs-*"], ["*"], ["envs-lead", ""], [shipped.humanApprovers[0]]];
  for (const requesters of bad) {
    const list = withProdRequesters(requesters);
    assert.match(workspaceAutoProblems(list).join("; "), /workspaceAuto capability prod-cluster-read: requester/, JSON.stringify(requesters));
    for (const [who, body] of [[LISTED, prodReq()], [AGENT, prodReq()], [AGENT, devReq()]] as const) {
      const { broker, calls } = setup(list);
      const r = await broker.requestViaRelay(relay([msg("7200006", who, JSON.stringify(body))]), "7200006", BROKER);
      assert.equal(r.outcome, "pending-approval", `${JSON.stringify(requesters)} ${who}: ${r.reasons.join("; ")}`);
      assert.match(r.reasons.join("; "), /workspaceAuto config is unsound/);
      assert.equal(calls.length, 0);
    }
  }
  // Sound lists: more names is still only those names.
  const two = withProdRequesters([LISTED, "another-lead"]);
  assert.deepEqual(workspaceAutoProblems(two), []);
  const r = await setup(two).broker.requestViaRelay(relay([msg("7200007", AGENT, JSON.stringify(prodReq()))]), "7200007", BROKER);
  assert.equal(r.outcome, "pending-approval", r.reasons.join("; "));
});

test("requesters: on a delegation's capability the field is refused, so it is never mistaken for a limit", () => {
  assert.deepEqual(delegationConfigProblems(shipped), []);
  const d = shipped.delegatedApprovers![0]!;
  const list = { ...shipped, delegatedApprovers: [{ ...d, capabilities: d.capabilities.map((c) => ({ ...c, requesters: [LISTED] })) }] } as unknown as Allowlist;
  assert.match(delegationConfigProblems(list).join("; "), /requesters belongs on the delegation/);
});
