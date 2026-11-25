/**
 * The edge-dns profile: requests that name "profile": "edge-dns" and fall
 * entirely inside it go to approval on the prod account's dedicated
 * agent-broker-prod-edge-dns role (terraform/prod), not on roles.elevated.
 * Anything else that names the profile is refused; requests without it are
 * routed exactly as before.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Broker } from "../broker/src/broker.ts";
import { defaultDeliverer } from "../broker/src/deliver.ts";
import { checkWorkspaceAuto, decide as decideWith, EDGE_DNS_PROFILE, type Allowlist, type CredentialRequest, type PolicyStatement, type Principal } from "../broker/src/policy.ts";
import type { StsClient } from "../broker/src/sts.ts";

const shipped = JSON.parse(readFileSync(new URL("../broker/allowlist.json", import.meta.url), "utf8")) as Allowlist;
const PROD = "786098391924";
const HOSTS = "500268966557";
const ELEVATED = `arn:aws:iam::${PROD}:role/agent-broker-prod-read`;
const EDGE_DNS = `arn:aws:iam::${PROD}:role/agent-broker-prod-edge-dns`;
const BUCKET = `arn:aws:s3:::agentrelay-prod-tfstate-${PROD}`;
const STATE = `${BUCKET}/${PROD}/us-west-2/prod/edge-dns/terraform.tfstate`;
const LOCK = `${STATE}.tflock`;
const KMS = `arn:aws:kms:us-west-2:${PROD}:key/717fa644-8436-4042-abfa-0ddaa9b696c9`;
const CERT = `arn:aws:acm:us-west-2:${PROD}:certificate/4a0284eb-d27f-4aaa-8185-0cc2dd87cac0`;
const CLUSTER = `arn:aws:eks:us-west-2:${PROD}:cluster/agent-relay-prod`;
const ELB = ["elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeTags", "elasticloadbalancing:DescribeLoadBalancerAttributes"];
const EDGE_ACTIONS = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "kms:Decrypt", "kms:GenerateDataKey", ...ELB, "acm:DescribeCertificate", "acm:ListTagsForCertificate"];

const agent: Principal = { name: "envs-lead", address: "envs-lead@somewhere", kind: "agent" };
const decide = (r: CredentialRequest, l: Allowlist = shipped) => decideWith(r, agent, l, { namespace: `${r.runTag}-0a1b2c3d` });
// The allowlist as it was before the edge-dns role: what "unchanged" is measured against.
const withoutEdgeDns: Allowlist = { ...shipped, accounts: { ...shipped.accounts, [PROD]: { ...shipped.accounts[PROD]!, roles: { elevated: ELEVATED } } } };

const edgeReq = (over: Partial<CredentialRequest> = {}): CredentialRequest => ({
  account: PROD,
  purpose: "agentrelay-edge-dns prod: plan and apply the public.agentrelay.com records and certificate",
  actions: EDGE_ACTIONS,
  durationMinutes: 60,
  runTag: "edge-dns-prod-1",
  scope: "account",
  resources: [BUCKET, STATE, LOCK, KMS, CERT],
  regions: ["us-west-2"],
  delivery: { kind: "file" },
  profile: "edge-dns",
  ...over,
});

test("the shipped profile and allowlist: one role in the prod account, the exact resources terraform/prod grants", () => {
  assert.equal(shipped.accounts[PROD]!.roles.edgeDns, EDGE_DNS);
  assert.equal(EDGE_DNS_PROFILE.account, PROD);
  assert.deepEqual(EDGE_DNS_PROFILE.regions, ["us-west-2"]);
  assert.deepEqual(EDGE_DNS_PROFILE.grants.flatMap((g) => g.actions).sort(), [...EDGE_ACTIONS].sort());
  assert.deepEqual(EDGE_DNS_PROFILE.grants.find((g) => g.actions.includes("s3:DeleteObject"))!.resources, [LOCK], "DeleteObject on the lockfile only");
  assert.deepEqual(EDGE_DNS_PROFILE.grants.filter((g) => g.resources.includes("*")).flatMap((g) => g.actions), ELB, "\"*\" only for the ELB Describe actions");
  // The role's Terraform names the same key and certificate (and its test checks this file back).
  const tf = readFileSync(new URL("../broker/terraform/prod/variables.tf", import.meta.url), "utf8");
  assert.ok(tf.includes('"717fa644-8436-4042-abfa-0ddaa9b696c9"') && tf.includes('"4a0284eb-d27f-4aaa-8185-0cc2dd87cac0"'));
});

test("(1) a valid edge-dns request: approval on the edge-dns role, never auto, ELB on \"*\" apart", () => {
  const d = decide(edgeReq());
  assert.equal(d.outcome, "approval", d.reasons.join("; "));
  if (d.outcome !== "approval") return;
  assert.equal(d.roleArn, EDGE_DNS);
  assert.match(d.reasons.join("; "), /profile edge-dns: owner approval per request/);
  const allows = d.sessionPolicy.Statement.filter((s) => s.Effect === "Allow");
  const by = (sid: string) => allows.find((s) => s.Sid === sid);
  assert.deepEqual(by("ApprovedAccountWideS3")!.Action, ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]);
  assert.deepEqual(by("ApprovedAccountWideS3")!.Resource, [BUCKET, STATE, LOCK]);
  assert.deepEqual(by("ApprovedAccountWideKms")!.Resource, KMS);
  assert.deepEqual(by("ApprovedAccountWideAcm")!.Resource, CERT);
  assert.deepEqual(by("ApprovedWithoutResourceLevelPermissions")!.Action, ELB);
  assert.equal(by("ApprovedWithoutResourceLevelPermissions")!.Resource, "*");
  assert.equal(allows.length, 4);
  assert.ok(allows.every((s) => s.Resource === "*" ? s.Action!.every((a) => ELB.includes(a)) : true), "only the ELB actions on \"*\"");
  assert.ok(d.sessionPolicy.Statement.some((s) => s.Sid === "DenyOutsideRegions"));
  // A subset is fine too (e.g. a read-only plan without the lock release).
  const sub = decide(edgeReq({ actions: ["s3:GetObject", "kms:Decrypt", ...ELB], resources: [STATE, KMS] }));
  assert.equal(sub.outcome, "approval", sub.reasons.join("; "));
  assert.equal(sub.outcome === "approval" && sub.roleArn, EDGE_DNS);
});

test("(2) the profile with anything outside it is refused, not sent to the elevated role", () => {
  const cases: [Partial<CredentialRequest>, RegExp][] = [
    [{ resources: [BUCKET, STATE, LOCK, KMS, CERT, `${BUCKET}/${PROD}/us-west-2/prod/data/terraform.tfstate`] }, /resource .*prod\/data\/terraform\.tfstate is not in it/],
    [{ actions: [...EDGE_ACTIONS, "iam:PassRole"] }, /iam:PassRole is not in it/],
    [{ actions: [...EDGE_ACTIONS, "s3:GetObjectVersion"] }, /s3:GetObjectVersion is not in it/],
    [{ actions: [...EDGE_ACTIONS, "route53:ChangeResourceRecordSets"] }, /route53:ChangeResourceRecordSets is not in it/],
    [{ actions: ["s3:DeleteObject"], resources: [STATE] }, /s3:DeleteObject needs one of its resources: .*tflock/],
    [{ resources: [`arn:aws:acm:us-west-2:${PROD}:certificate/00000000-0000-0000-0000-000000000000`, BUCKET, STATE, LOCK, KMS] }, /certificate\/0000.* is not in it/],
    [{ actions: ["s3:GetObject"], resources: [STATE, CERT] }, /resource .*certificate.* is not used by any requested action/],
    [{ actions: ["acm:DescribeCertificate"], resources: [] }, /acm:DescribeCertificate needs one of its resources/],
    [{ scope: "run-tag" }, /scope must be "account"/],
    [{ scope: undefined }, /scope must be "account"/],
    [{ profile: "edge-dns-2" }, /profile "edge-dns-2" is not a known profile/],
    [{ profile: "toString" }, /profile "toString" is not a known profile/],
  ];
  for (const [over, re] of cases) {
    const d = decide(edgeReq(over));
    assert.equal(d.outcome, "deny", JSON.stringify(over));
    assert.match(d.reasons.join("; "), re, JSON.stringify(over));
  }
});

test("(3) the same actions without the profile: routed exactly as before, on the elevated role", () => {
  const { profile: _, ...plain } = edgeReq();
  const d = decide(plain);
  assert.equal(d.outcome, "approval");
  assert.equal(d.outcome === "approval" && d.roleArn, ELEVATED);
  assert.deepEqual(d, decide(plain, withoutEdgeDns), "same decision as with no edge-dns role on the allowlist");
  assert.ok(!d.reasons.some((r) => /profile/.test(r)));
});

test("(4) unrelated prod requests keep their outcome and role", () => {
  const cluster: CredentialRequest = { ...edgeReq(), profile: undefined, purpose: "prod-cluster-read: kubectl get deployments", actions: ["eks:DescribeCluster"], resources: [CLUSTER], durationMinutes: 30 };
  const secret: CredentialRequest = { ...edgeReq(), profile: undefined, purpose: "rotate the read API config", actions: ["secretsmanager:PutSecretValue"], resources: [`arn:aws:secretsmanager:us-west-2:${PROD}:secret:agentrelay-prod/read-api-config-QBoVHR`] };
  for (const r of [cluster, secret]) {
    const d = decide(r);
    assert.equal(d.outcome, "approval", r.purpose);
    assert.equal(d.outcome === "approval" && d.roleArn, ELEVATED, r.purpose);
    assert.deepEqual(d, decide(r, withoutEdgeDns), r.purpose);
  }
});

test("(5) the profile in another account or region is refused", () => {
  const cases: [Partial<CredentialRequest>, RegExp][] = [
    [{ account: HOSTS, regions: ["us-east-1"] }, /only in account 786098391924, not 500268966557/],
    [{ account: HOSTS }, /only in account 786098391924/],
    [{ account: "154551280135" }, /only in account 786098391924/],
    [{ regions: ["us-east-1"] }, /regions us-east-1 are not allowed in agentrelay-prod/],
    [{ regions: ["us-west-2", "us-east-1"] }, /not allowed in agentrelay-prod/],
    [{ regions: undefined }, /regions must be exactly us-west-2/],
  ];
  for (const [over, re] of cases) {
    const d = decide(edgeReq(over));
    assert.equal(d.outcome, "deny", JSON.stringify(over));
    assert.match(d.reasons.join("; "), re, JSON.stringify(over));
  }
});

test("(6) a mixed request (edge-dns plus eks:DescribeCluster) with the profile is refused", () => {
  const d = decide(edgeReq({ actions: [...EDGE_ACTIONS, "eks:DescribeCluster"], resources: [BUCKET, STATE, LOCK, KMS, CERT, CLUSTER] }));
  assert.equal(d.outcome, "deny");
  assert.match(d.reasons.join("; "), /eks:DescribeCluster is not in it/);
  assert.match(d.reasons.join("; "), /cluster\/agent-relay-prod is not in it/);
});

test("no silent fallback: the profile without its role on the allowlist is refused", () => {
  const d = decide(edgeReq(), withoutEdgeDns);
  assert.equal(d.outcome, "deny");
  assert.match(d.reasons.join("; "), /roles\.edgeDns for 786098391924 is missing/);
  const wrong: Allowlist = { ...shipped, accounts: { ...shipped.accounts, [PROD]: { ...shipped.accounts[PROD]!, roles: { elevated: ELEVATED, edgeDns: `arn:aws:iam::${HOSTS}:role/agent-broker-prod-edge-dns` } } } };
  assert.equal(decide(edgeReq(), wrong).outcome, "deny", "a role in another account");
});

test("never issued without approval: workspace auto-issue refuses any profile request", () => {
  const listed = { name: "envs-lead", address: "envs-lead@somewhere", kind: "agent" as const, agentId: "100000000000000021", workspaceId: shipped.workspaceAuto!.workspaceId };
  // The prod-cluster read would be issued to envs-lead automatically; naming a profile takes that away.
  const request: CredentialRequest = { ...edgeReq(), purpose: "prod-cluster-read", actions: ["eks:DescribeCluster"], resources: [CLUSTER], durationMinutes: 30 };
  const sessionPolicy = { Version: "2012-10-17" as const, Statement: [{ Sid: "ApprovedAccountWide", Effect: "Allow" as const, Action: ["eks:DescribeCluster"], Resource: CLUSTER }] };
  assert.equal(checkWorkspaceAuto({ request: { ...request, profile: undefined }, requester: listed, sessionPolicy }, shipped).ok, true);
  const r = checkWorkspaceAuto({ request, requester: listed, sessionPolicy }, shipped);
  assert.equal(r.ok, false);
  assert.match(!r.ok ? r.reason : "", /names profile "edge-dns", which is always approved per request/);
});

test("end to end: pending on the edge-dns role, the prompt names the profile, Khaliq's approval assumes that role", async () => {
  const dir = mkdtempSync(join(tmpdir(), "broker-edge-dns-"));
  const NOW = new Date("2026-11-24T12:00:00Z");
  const calls: { roleArn: string; policy: { Statement: PolicyStatement[] } }[] = [];
  const sts: StsClient = { async assumeRole(i) { calls.push(i as never); return { accessKeyId: "ASIAFAKE", secretAccessKey: "s".repeat(40), sessionToken: "t".repeat(300), expiration: new Date(NOW.getTime() + i.durationSeconds * 1000).toISOString() }; } };
  let n = 0;
  const broker = new Broker({ allowlist: shipped, stateDir: join(dir, "state"), sts, deliverer: defaultDeliverer(join(dir, "creds")), now: () => NOW, newId: () => `cb-${(++n).toString(16).padStart(12, "0")}`, newNamespaceSuffix: () => "0a1b2c3d" });
  const r = await broker.request(edgeReq(), agent);
  assert.equal(r.outcome, "pending-approval", r.reasons.join("; "));
  assert.equal(r.roleArn, EDGE_DNS);
  assert.match(r.approvalPrompt!, /via arn:aws:iam::786098391924:role\/agent-broker-prod-edge-dns \(profile edge-dns\)/);
  assert.equal(calls.length, 0);
  const ok = await broker.approve(r.requestId, r.policyDigest!.slice(0, 16), { name: "khaliq-gant", address: "khaliq-gant@relay", kind: "human" });
  assert.equal(ok.outcome, "issued", ok.reasons.join("; "));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.roleArn, EDGE_DNS);
});
