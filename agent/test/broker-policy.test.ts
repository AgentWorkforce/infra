/**
 * The credential broker's policy engine: which requests are refused, issued
 * automatically or held for Khaliq, and the session policy each one gets.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { approverCounts, decide, globsIntersect, ownNamedResources, sessionName, SESSION_POLICY_MAX_CHARS, TAG_ACTIONS, UNTAG_ACTIONS, type Allowlist, type CredentialRequest, type Principal } from "../broker/src/policy.ts";

const allowlist = JSON.parse(readFileSync(new URL("../broker/allowlist.json", import.meta.url), "utf8")) as Allowlist;
const SANDBOX = "805532413586";
const PROD = "111122223333";
// The shipped allowlist has no prod account yet; tests add a fake one with an approval-tier role.
const withProd: Allowlist = {
  ...allowlist,
  accounts: {
    ...allowlist.accounts,
    [PROD]: { label: "prod-test", tier: "prod", roles: { elevated: `arn:aws:iam::${PROD}:role/agent-broker-elevated` } },
    [SANDBOX]: { ...allowlist.accounts[SANDBOX]!, roles: { ...allowlist.accounts[SANDBOX]!.roles, elevated: `arn:aws:iam::${SANDBOX}:role/agent-broker-sandbox-elevated` } },
  },
};
const agent: Principal = { name: "tersemigrationgrok", address: "tersemigrationgrok@linuyc-desktop", kind: "agent" };

const req = (over: Partial<CredentialRequest> = {}): CredentialRequest => ({
  account: SANDBOX,
  purpose: "migration soak test queue",
  actions: ["sqs:CreateQueue", "sqs:SendMessage", "sqs:DeleteQueue"],
  durationMinutes: 30,
  runTag: "terse-mig-42",
  delivery: { kind: "1password", vault: "agents" },
  ...over,
});

test("the shipped allowlist: sandbox only, Khaliq the only approver, 15 to 60 minutes", () => {
  assert.deepEqual(Object.keys(allowlist.accounts), [SANDBOX]);
  assert.equal(allowlist.accounts[SANDBOX]!.tier, "sandbox");
  assert.equal(allowlist.accounts[SANDBOX]!.roles.scoped, `arn:aws:iam::${SANDBOX}:role/agent-broker-sandbox-scoped`);
  assert.equal(allowlist.accounts[SANDBOX]!.roles.elevated, undefined, "no approval-tier role until Khaliq creates one");
  assert.deepEqual(allowlist.humanApprovers, ["khaliq-gant"]);
  assert.deepEqual(allowlist.duration, { minMinutes: 15, maxMinutes: 60, autoMaxMinutes: 60 });
  for (const r of allowlist.autoRules) for (const a of r.actions) {
    assert.ok(!a.includes("*"), `${r.id}: ${a} is literal`);
    assert.ok(!allowlist.neverIssue.some((n) => globsIntersect(a, n)), `${a} is never-issue`);
    assert.ok(!allowlist.approvalOnly.some((n) => globsIntersect(a, n)), `${a} is approval-only`);
  }
});

test("globsIntersect: case-insensitive, wildcards on either side", () => {
  assert.ok(globsIntersect("iam:Create*", "iam:CreateAccessKey"));
  assert.ok(globsIntersect("IAM:createaccesskey", "iam:*"));
  assert.ok(globsIntersect("s*:Get*", "sts:*"));
  assert.ok(!globsIntersect("s3:GetObject", "sts:*"));
  assert.ok(!globsIntersect("sqs:CreateQueue", "iam:*"));
});

test("sandbox, own run tag, allowlisted actions: issued automatically, scoped to the tag and regions", () => {
  const d = decide(req(), agent, allowlist);
  assert.equal(d.outcome, "auto");
  if (d.outcome !== "auto") return;
  assert.equal(d.roleArn, `arn:aws:iam::${SANDBOX}:role/agent-broker-sandbox-scoped`);
  assert.equal(d.durationSeconds, 1800);
  const by = (sid: string) => d.sessionPolicy.Statement.find((s) => s.Sid === sid)!;
  const create = by("SqsCreate");
  assert.deepEqual(create.Action, ["sqs:CreateQueue"]);
  assert.equal(create.Resource, "arn:aws:sqs:*:*:terse-mig-42-*", "creates are named for the run");
  assert.deepEqual(create.Condition, { StringEquals: { "aws:RequestTag/agent-run": "terse-mig-42" } });
  const own = by("OwnRunTagged");
  assert.deepEqual(own.Action, ["sqs:SendMessage", "sqs:DeleteQueue"]);
  assert.equal(own.Condition!.StringEquals!["aws:ResourceTag/agent-run"], "terse-mig-42");
  // Every Allow is tag- or read-scoped; deletes only ever on the run's own tag.
  for (const s of d.sessionPolicy.Statement.filter((x) => x.Effect === "Allow")) {
    const deletes = (s.Action ?? []).filter((a) => /:(Delete|Terminate)/.test(a));
    if (deletes.length) assert.equal(s.Condition?.StringEquals?.["aws:ResourceTag/agent-run"], "terse-mig-42", s.Sid);
  }
  assert.equal(by("DenyForeignRunTagOnCreate").Effect, "Deny");
  assert.deepEqual(by("DenyOutsideRegions").Condition, { StringNotEquals: { "aws:RequestedRegion": ["us-east-1", "us-west-2"] } });
  assert.ok(JSON.stringify(d.sessionPolicy).length <= SESSION_POLICY_MAX_CHARS);
});

test("tagged creates carry their tag-on-create permission, only on resources named for the run", () => {
  const cases: [string, string[], string][] = [
    ["sqs:CreateQueue", ["sqs:TagQueue"], "arn:aws:sqs:*:*:terse-mig-42-*"],
    ["sns:CreateTopic", ["sns:TagResource"], "arn:aws:sns:*:*:terse-mig-42-*"],
    ["logs:CreateLogGroup", ["logs:TagResource", "logs:TagLogGroup"], "arn:aws:logs:*:*:log-group:terse-mig-42-*"],
    ["dynamodb:CreateTable", ["dynamodb:TagResource"], "arn:aws:dynamodb:*:*:table/terse-mig-42-*"],
    ["secretsmanager:CreateSecret", ["secretsmanager:TagResource"], "arn:aws:secretsmanager:*:*:secret:terse-mig-42-*"],
  ];
  for (const [create, tags, resource] of cases) {
    const d = decide(req({ actions: [create] }), agent, allowlist);
    assert.equal(d.outcome, "auto", create);
    if (d.outcome !== "auto") continue;
    const allows = d.sessionPolicy.Statement.filter((s) => s.Effect === "Allow");
    const tagAllow = allows.find((s) => tags.every((t) => s.Action?.includes(t)))!;
    assert.ok(tagAllow, `${create} also gets ${tags.join(", ")}`);
    assert.equal(tagAllow.Resource, resource);
    assert.equal(tagAllow.Condition!.StringEquals!["aws:RequestTag/agent-run"], "terse-mig-42");
    // The deny that keeps the run tag off anything else exempts exactly the run's own names.
    const deny = d.sessionPolicy.Statement.find((s) => s.Sid === "DenyRunTagOnOthers")!;
    assert.ok(tags.every((t) => deny.Action!.includes(t)), `${create}: guard covers its tag action`);
    assert.ok(deny.NotResource!.includes(resource));
    assert.ok(!allows.some((s) => s.Action?.some((a) => /Untag|DeleteTags/.test(a))), "never an untag");
  }
});

test("the session guard and the role ceiling name the same tag actions and run-owned resources", () => {
  const tf = readFileSync(new URL("../broker/terraform/modules/scoped-role/main.tf", import.meta.url), "utf8");
  const block = (name: string) => /\[([^\]]*)\]/.exec(tf.slice(tf.indexOf(`${name} = [`)))![1]!.match(/"[^"]+"/g)!.map((x) => x.slice(1, -1));
  assert.deepEqual(block("tag_actions"), TAG_ACTIONS);
  assert.deepEqual(block("untag_actions"), UNTAG_ACTIONS);
  assert.deepEqual(block("own_named_resources"), ownNamedResources("${local.own_run}"));
});

test("ec2 RunInstances: tag required on what it creates, inputs (image, subnet, sg) untagged, CreateTags at launch implied", () => {
  const d = decide(req({ actions: ["ec2:RunInstances", "ec2:TerminateInstances"] }), agent, allowlist);
  assert.equal(d.outcome, "auto");
  if (d.outcome !== "auto") return;
  const tagged = d.sessionPolicy.Statement.find((s) => s.Sid === "Ec2RunInstancesTagged")!;
  assert.ok((tagged.Resource as string[]).includes("arn:aws:ec2:*:*:instance/*"));
  assert.equal(tagged.Condition!.StringEquals!["aws:RequestTag/agent-run"], "terse-mig-42");
  const inputs = d.sessionPolicy.Statement.find((s) => s.Sid === "Ec2RunInstancesInputs")!;
  assert.equal(inputs.Condition, undefined, "image, subnet and security group carry no request tag");
  const tagOnCreate = d.sessionPolicy.Statement.find((s) => s.Sid === "Ec2TagOnCreate")!;
  assert.deepEqual(tagOnCreate.Action, ["ec2:CreateTags"]);
  assert.deepEqual(tagOnCreate.Condition!.StringEquals!["ec2:CreateAction"], ["RunInstances", "CreateVolume"]);
  assert.ok(d.sessionPolicy.Statement.some((s) => s.Sid === "DenyEc2TagsAfterCreate"));
});

test("refused outright: unknown account, never-issue actions, bad shape", () => {
  const cases: [Partial<CredentialRequest>, RegExp][] = [
    [{ account: "999999999999" }, /not on the broker allowlist/],
    [{ actions: ["sts:AssumeRole"] }, /never issued/],
    [{ actions: ["iam:CreateAccessKey"] }, /never issued/],
    [{ actions: ["iam:Create*"] }, /never issued/],
    [{ actions: ["organizations:ListAccounts"] }, /never issued/],
    [{ actions: ["*"] }, /never issued/],
    [{ durationMinutes: 5 }, /durationMinutes/],
    [{ durationMinutes: 61 }, /durationMinutes/],
    [{ durationMinutes: 720 }, /durationMinutes/],
    [{ runTag: "Has Spaces" }, /runTag/],
    [{ purpose: "x" }, /purpose/],
    [{ regions: ["eu-west-1"] }, /not allowed in sandbox/],
    [{ regions: [] }, /at least one region/],
    [{ delivery: { kind: "relay" } as unknown as CredentialRequest["delivery"] }, /delivery.kind/],
  ];
  for (const [over, re] of cases) {
    const d = decide(req(over), agent, withProd);
    assert.equal(d.outcome, "deny", JSON.stringify(over));
    assert.match(d.reasons.join("; "), re, JSON.stringify(over));
  }
});

test("held for approval: prod, IAM, wildcards, account-wide changes, off-list actions, someone else's run tag", () => {
  const cases: [Partial<CredentialRequest>, string | undefined, RegExp][] = [
    [{ account: PROD, actions: ["sqs:SendMessage"] }, undefined, /prod account/],
    [{ actions: ["iam:PassRole"] }, undefined, /IAM/],
    [{ actions: ["s3:Get*"] }, undefined, /wildcard/],
    [{ scope: "account", actions: ["ec2:TerminateInstances"] }, undefined, /outside the run's own tag/],
    [{ actions: ["s3:DeleteBucket"] }, undefined, /not on the auto allowlist/],
    [{}, "some-other-agent", /belongs to some-other-agent/],
  ];
  for (const [over, owner, re] of cases) {
    const d = decide(req(over), agent, withProd, owner);
    assert.equal(d.outcome, "approval", JSON.stringify(over));
    assert.match(d.reasons.join("; "), re);
    if (d.outcome === "approval") assert.match(d.roleArn, /elevated$/);
  }
});

test("approval tier without an elevated role is refused, not parked: Khaliq is never asked for something un-issuable", () => {
  const d = decide(req({ actions: ["iam:PassRole"] }), agent, allowlist);
  assert.equal(d.outcome, "deny");
  assert.match(d.reasons.join("; "), /no approval-tier role/);
});

test("account-wide reads stay automatic", () => {
  const d = decide(req({ scope: "account", actions: ["ec2:DescribeInstances", "sqs:ListQueues"] }), agent, allowlist);
  assert.equal(d.outcome, "auto");
});

test("approved run-tag sessions give each action the condition IAM can enforce for it", () => {
  const d = decide(req({ account: PROD, actions: ["ec2:DescribeInstances", "s3:CreateBucket", "s3:DeleteBucket", "sqs:CreateQueue", "sqs:SendMessage"] }), agent, withProd);
  assert.equal(d.outcome, "approval");
  if (d.outcome !== "approval") return;
  const by = (sid: string) => d.sessionPolicy.Statement.find((s) => s.Sid === sid);
  // Account-level reads: no resource to carry a tag, so unconditioned (and listed as such in the prompt).
  assert.deepEqual(by("ReadDescribe")!.Action, ["ec2:DescribeInstances"]);
  assert.equal(by("ReadDescribe")!.Condition, undefined);
  // Creates the allowlist covers keep its name scope and tag-on-create; others must carry the run tag.
  assert.ok(by("SqsTagOnCreate"));
  assert.deepEqual(by("ApprovedCreatesWithRunTag")!.Action, ["s3:CreateBucket"]);
  assert.equal(by("ApprovedCreatesWithRunTag")!.Condition!.StringEquals!["aws:RequestTag/agent-run"], "terse-mig-42");
  // Everything else only on resources carrying the run tag.
  assert.deepEqual(by("ApprovedOnRunTagged")!.Action, ["s3:DeleteBucket"]);
  assert.equal(by("ApprovedOnRunTagged")!.Condition!.StringEquals!["aws:ResourceTag/agent-run"], "terse-mig-42");
  assert.equal(by("ApprovedActions"), undefined);
});

test("approved account-wide sessions: the requested resources, no tag condition, guards that overlap kept", () => {
  const wide = decide(req({ account: PROD, scope: "account", actions: ["s3:DeleteBucket", "sqs:TagQueue"], resources: ["arn:aws:s3:::old-bucket"] }), agent, withProd);
  assert.equal(wide.outcome, "approval");
  if (wide.outcome !== "approval") return;
  const w = wide.sessionPolicy.Statement.find((s) => s.Sid === "ApprovedAccountWide")!;
  assert.equal(w.Resource, "arn:aws:s3:::old-bucket");
  assert.equal(w.Condition, undefined);
  const guard = wide.sessionPolicy.Statement.find((s) => s.Sid === "DenyRunTagOnOthers")!;
  assert.deepEqual(guard.Action, ["sqs:TagQueue"], "only the guard actions the session could otherwise use");
});

test("only a human on the list approves; an agent never does, whatever its name", () => {
  assert.ok(approverCounts({ name: "khaliq-gant", address: "khaliq-gant@finn-mac-mini", kind: "human" }, allowlist));
  assert.ok(!approverCounts({ name: "khaliq-gant", address: "khaliq-gant@linuyc-desktop", kind: "agent" }, allowlist));
  assert.ok(!approverCounts({ name: "someone-else", address: "x@y", kind: "human" }, allowlist));
});

test("session name is the agent name, in STS's character set", () => {
  assert.equal(sessionName(agent), "tersemigrationgrok");
  assert.equal(sessionName({ ...agent, name: "a b/c" }), "a-b-c");
  assert.throws(() => sessionName({ ...agent, name: "x" }));
});
