/**
 * The credential broker's policy engine: which requests are refused, issued
 * automatically or held for Khaliq, and the session policy each one gets.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { approvalScope, approverCounts, decide as decideWith, globsIntersect, ownNamedResources, RUN_NAMESPACE_RE, RUN_TAG_RE, sessionName, SESSION_POLICY_MAX_CHARS, TAG_ACTIONS, UNTAG_ACTIONS, type Allowlist, type CredentialRequest, type Principal } from "../broker/src/policy.ts";

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
const SUFFIX = "0a1b2c3d";
// The broker passes the run's claim (owner and namespace); a test's namespace is "<runTag>-0a1b2c3d".
const decide = (r: CredentialRequest, p: Principal, l: Allowlist, owner?: string) => decideWith(r, p, l, { ...(owner ? { owner } : {}), namespace: `${r.runTag}-${SUFFIX}` });
const NS = `terse-mig-42-${SUFFIX}`;
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

test("the shipped allowlist: auto only in the sandbox, the agent-hosts account approval-only, Khaliq the only approver, 15 to 60 minutes", () => {
  assert.deepEqual(Object.keys(allowlist.accounts), [SANDBOX, "500268966557"]);
  assert.equal(allowlist.accounts[SANDBOX]!.tier, "sandbox");
  assert.equal(allowlist.accounts[SANDBOX]!.roles.scoped, `arn:aws:iam::${SANDBOX}:role/agent-broker-sandbox-scoped`);
  assert.equal(allowlist.accounts[SANDBOX]!.roles.elevated, undefined, "no approval-tier role in the sandbox");
  // The broker's own account (the agent hosts'): no automatic issue at all, only Khaliq-approved sessions.
  const hosts = allowlist.accounts["500268966557"]!;
  assert.equal(hosts.tier, "prod");
  assert.deepEqual(hosts.roles, { elevated: "arn:aws:iam::500268966557:role/agent-broker-elevated" });
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
  assert.equal(create.Resource, "arn:aws:sqs:*:*:terse-mig-42-0a1b2c3d--*", "creates are named for the run");
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
    ["sqs:CreateQueue", ["sqs:TagQueue"], "arn:aws:sqs:*:*:terse-mig-42-0a1b2c3d--*"],
    ["sns:CreateTopic", ["sns:TagResource"], "arn:aws:sns:*:*:terse-mig-42-0a1b2c3d--*"],
    ["logs:CreateLogGroup", ["logs:TagResource", "logs:TagLogGroup"], "arn:aws:logs:*:*:log-group:terse-mig-42-0a1b2c3d--*"],
    ["dynamodb:CreateTable", ["dynamodb:TagResource"], "arn:aws:dynamodb:*:*:table/terse-mig-42-0a1b2c3d--*"],
    ["secretsmanager:CreateSecret", ["secretsmanager:TagResource"], "arn:aws:secretsmanager:*:*:secret:terse-mig-42-0a1b2c3d--*"],
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

test("run namespaces are disjoint: no run's names match another run's, even when one tag prefixes the other", () => {
  const tags = ["foo", "foo-bar", "foo-bar-baz", "foob", "build", "build-other", "a1b", "a1b-2"];
  for (const t of tags) assert.ok(RUN_TAG_RE.test(t), t);
  // Namespaces as the broker makes them, including two runs whose random parts collide on a prefix.
  const spaces = tags.flatMap((t) => [`${t}-${SUFFIX}`, `${t}-0a1b2c3e`]);
  for (const ns of spaces) assert.ok(RUN_NAMESPACE_RE.test(ns), ns);
  for (const mine of spaces) {
    for (const theirs of spaces) {
      if (mine === theirs) continue;
      for (const [pattern, theirName] of ownNamedResources(mine).map((p, i) => [p, ownNamedResources(theirs)[i]!.replace(/\*$/, "work").replaceAll("*", "x1")] as const)) {
        assert.ok(!globsIntersect(pattern, theirName), `${mine}'s ${pattern} must not match ${theirs}'s ${theirName}`);
      }
    }
    for (const [p, i] of ownNamedResources(mine).map((p, i) => [p, i] as const)) assert.ok(globsIntersect(p, ownNamedResources(mine)[i]!.replace(/\*$/, "work").replaceAll("*", "x1")), `${mine} owns its own names`);
  }
});

test("a name chosen before the claim never matches: tag-on-create applies only under the broker-assigned namespace", () => {
  // An untagged queue someone made earlier, named as if it were run foo's.
  for (const existing of ["arn:aws:sqs:us-east-1:805532413586:foo--shared", "arn:aws:sqs:us-east-1:805532413586:foo-shared"]) {
    for (const pattern of ownNamedResources(`foo-${SUFFIX}`)) assert.ok(!globsIntersect(pattern, existing), `${pattern} vs ${existing}`);
  }
  const d = decide(req({ actions: ["sqs:CreateQueue"] }), agent, allowlist);
  assert.equal(d.outcome, "auto");
  if (d.outcome !== "auto") return;
  assert.equal(d.sessionPolicy.Statement.find((s) => s.Sid === "SqsTagOnCreate")!.Resource, `arn:aws:sqs:*:*:${NS}--*`);
  // The broker never decides with a namespace that isn't "<this run tag>-<8 hex>".
  for (const namespace of ["terse-mig-42", "other-run-0a1b2c3d", "terse-mig-42--0a1b2c3d", "terse-mig-42-XYZ"]) {
    const bad = decideWith(req(), agent, allowlist, { namespace });
    assert.equal(bad.outcome, "deny", namespace);
    assert.match(bad.reasons.join("; "), /bad run namespace/);
  }
});

test("a resource already carrying another run's tag can't be re-tagged by this session", () => {
  const d = decide(req({ actions: ["sqs:CreateQueue", "sqs:TagQueue"] }), agent, allowlist);
  assert.equal(d.outcome, "auto");
  if (d.outcome !== "auto") return;
  const g = d.sessionPolicy.Statement.find((s) => s.Sid === "DenyOverwritingAnotherRunsTag")!;
  assert.deepEqual(g.Action, ["sqs:TagQueue"]);
  assert.deepEqual(g.Condition, {
    "ForAnyValue:StringEquals": { "aws:TagKeys": ["agent-run"] },
    StringNotEquals: { "aws:ResourceTag/agent-run": "terse-mig-42" },
    Null: { "aws:ResourceTag/agent-run": "false" },
  });
  assert.ok(JSON.stringify(d.sessionPolicy).length <= SESSION_POLICY_MAX_CHARS);
});

test("approval scoping by verb: only Create/Run are tagged creates; Put and other updates act on tagged resources", () => {
  assert.equal(approvalScope("s3:CreateBucket"), "request-tag");
  assert.equal(approvalScope("ec2:RunInstances"), "request-tag");
  assert.equal(approvalScope("secretsmanager:PutResourcePolicy"), "resource-tag");
  assert.equal(approvalScope("s3:PutObject"), "resource-tag");
  assert.equal(approvalScope("ssm:PutParameter"), "resource-tag");
  assert.equal(approvalScope("ec2:RegisterImage"), "resource-tag");
  assert.equal(approvalScope("ec2:DescribeInstances"), "any");
  const d = decide(req({ account: PROD, actions: ["secretsmanager:PutResourcePolicy"] }), agent, withProd);
  assert.equal(d.outcome, "approval");
  if (d.outcome !== "approval") return;
  const s = d.sessionPolicy.Statement.find((x) => x.Sid === "ApprovedOnRunTagged")!;
  assert.deepEqual(s.Action, ["secretsmanager:PutResourcePolicy"]);
  assert.equal(s.Condition!.StringEquals!["aws:ResourceTag/agent-run"], "terse-mig-42");
});

test("the session guard and the role ceiling name the same tag actions and run-owned resources", () => {
  const tf = readFileSync(new URL("../broker/terraform/modules/scoped-role/main.tf", import.meta.url), "utf8");
  const block = (name: string) => /\[([^\]]*)\]/.exec(tf.slice(tf.indexOf(`${name} = [`)))![1]!.match(/"[^"]+"/g)!.map((x) => x.slice(1, -1));
  assert.deepEqual(block("tag_actions"), TAG_ACTIONS);
  assert.deepEqual(block("untag_actions"), UNTAG_ACTIONS);
  assert.deepEqual(block("own_named_resources"), ownNamedResources("${local.own_namespace}"));
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
    [{ runTag: "foo--bar" }, /runTag/],
    [{ runTag: "foo-" }, /runTag/],
    [{ runTag: "-foo" }, /runTag/],
    [{ runTag: "ab" }, /runTag/],
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
  // ec2:DescribeInstances has no resource-level permissions, so it gets its own "*" statement.
  assert.deepEqual(by("ReadDescribeAnyResource")!.Action, ["ec2:DescribeInstances"]);
  assert.equal(by("ReadDescribeAnyResource")!.Resource, "*");
  assert.equal(by("ReadDescribeAnyResource")!.Condition, undefined);
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

test("a runner request in the agent-hosts account: approval only, named resources, wildcard-only reads apart, at most 60 minutes", () => {
  // Fake identifiers (CONTRIBUTING.md): the shape of legacy-copy's request.
  const RES = [
    "arn:aws:secretsmanager:us-east-1:500268966557:secret:example/runner-secret-AbCdEf",
    "arn:aws:ec2:us-east-1:500268966557:instance/i-0123456789abcdef0",
    "arn:aws:ssm:us-east-1::document/AWS-RunShellScript",
    "arn:aws:ssm:us-east-1:500268966557:session/*",
  ];
  const runner = (over: Partial<CredentialRequest> = {}): CredentialRequest => ({
    account: "500268966557",
    purpose: "drive a copy job on the runner over SSM",
    actions: ["secretsmanager:PutSecretValue", "ssm:StartSession", "ssm:SendCommand", "ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:TerminateSession", "ssm:DescribeSessions", "ssm:ResumeSession"],
    durationMinutes: 60,
    runTag: "example-runner-copy",
    scope: "account",
    resources: RES,
    regions: ["us-east-1"],
    delivery: { kind: "encrypted", publicKey: Buffer.alloc(32, 9).toString("base64") },
    ...over,
  });
  const d = decide(runner(), agent, allowlist);
  assert.equal(d.outcome, "approval", d.reasons.join("; "));
  if (d.outcome !== "approval") return;
  assert.equal(d.roleArn, "arn:aws:iam::500268966557:role/agent-broker-elevated");
  const by = (sid: string) => d.sessionPolicy.Statement.find((s) => s.Sid === sid)!;
  // Commands and the secret write: only on the named runner, secret, document and sessions.
  assert.deepEqual(by("ApprovedAccountWide").Action, ["secretsmanager:PutSecretValue", "ssm:StartSession", "ssm:SendCommand", "ssm:TerminateSession", "ssm:ResumeSession"]);
  assert.deepEqual(by("ApprovedAccountWide").Resource, RES);
  // The reads IAM authorizes only on "*": their own statement, so AWS doesn't refuse them.
  assert.deepEqual(by("ApprovedWithoutResourceLevelPermissions").Action, ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:DescribeSessions"]);
  assert.equal(by("ApprovedWithoutResourceLevelPermissions").Resource, "*");
  assert.deepEqual(by("DenyOutsideRegions").Condition, { StringNotEquals: { "aws:RequestedRegion": ["us-east-1"] } });
  assert.match(d.reasons.join("; "), /agent-hosts is a prod account/);
  assert.equal(decide(runner({ durationMinutes: 720 }), agent, allowlist).outcome, "deny", "12 h is refused: at most 60 minutes per request");
  // IAM matches actions case-insensitively, so a differently capitalised read still lands on "*".
  const mixed = decide(runner({ actions: ["ssm:SendCommand", "ssm:getcommandinvocation", "ssm:DESCRIBESESSIONS"] }), agent, allowlist);
  assert.equal(mixed.outcome, "approval", mixed.reasons.join("; "));
  if (mixed.outcome !== "approval") return;
  const mixedBy = (sid: string) => mixed.sessionPolicy.Statement.find((s) => s.Sid === sid)!;
  assert.deepEqual(mixedBy("ApprovedAccountWide").Action, ["ssm:SendCommand"]);
  assert.deepEqual(mixedBy("ApprovedWithoutResourceLevelPermissions").Action, ["ssm:getcommandinvocation", "ssm:DESCRIBESESSIONS"]);
  assert.equal(mixedBy("ApprovedWithoutResourceLevelPermissions").Resource, "*");
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
