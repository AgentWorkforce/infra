/**
 * The broker's policy engine: decides, for one credential request, whether it
 * is refused, issued straight away (sandbox, own run tag, allowlisted
 * actions) or held for Khaliq's approval, and builds the inline session
 * policy STS will intersect with the target role's own policy.
 *
 * Pure: no clock, no I/O. Everything it needs is in the arguments, so the
 * tests can pin every tier.
 */

export type Scope = "any" | "resource-tag" | "request-tag";

export interface AutoRule {
  id: string;
  scope: Scope;
  actions: string[];
  /** Defaults to "*". "{ns}" is replaced by the run's broker-assigned namespace. A requester's own resources narrow only rules left on "*". */
  resources?: string[];
  /** Also granted, in this rule's statement, whenever one of these is requested (create-time tagging). */
  impliedBy?: string[];
  /** Extra IAM condition merged into the rule's statement. */
  condition?: Record<string, Record<string, string | string[]>>;
}

export interface AccountPolicy {
  label: string;
  tier: "sandbox" | "prod";
  regions?: string[];
  roles: { scoped?: string; elevated?: string };
}

export interface Allowlist {
  version: 1;
  tagKey: string;
  humanApprovers: string[];
  duration: { minMinutes: number; maxMinutes: number; autoMaxMinutes: number };
  approvalWindowMinutes: number;
  accounts: Record<string, AccountPolicy>;
  neverIssue: string[];
  approvalOnly: string[];
  autoRules: AutoRule[];
}

/** Who asked, from the Relay envelope the message arrived in: never from the request body. */
export interface Principal {
  name: string;
  address: string;
  kind: "agent" | "human";
}

export interface CredentialRequest {
  account: string;
  purpose: string;
  actions: string[];
  durationMinutes: number;
  runTag: string;
  /** "run-tag" (default): mutations only on resources carrying the run tag. "account": anywhere in the account (approval). */
  scope?: "run-tag" | "account";
  /** Optional ARNs. Narrows "*" rules; required context for approval-tier requests. */
  resources?: string[];
  regions?: string[];
  delivery: Delivery;
}

export type Delivery = { kind: "file" } | { kind: "1password"; vault: string } | { kind: "encrypted"; publicKey: string };

export interface PolicyStatement {
  Sid: string;
  Effect: "Allow" | "Deny";
  Action?: string[];
  NotAction?: string[];
  Resource?: string | string[];
  NotResource?: string[];
  Condition?: Record<string, Record<string, string | string[]>>;
}

export interface SessionPolicy {
  Version: "2012-10-17";
  Statement: PolicyStatement[];
}

export type Decision =
  | { outcome: "deny"; reasons: string[] }
  | { outcome: "auto"; roleArn: string; sessionPolicy: SessionPolicy; durationSeconds: number; reasons: string[] }
  | { outcome: "approval"; roleArn: string; sessionPolicy: SessionPolicy; durationSeconds: number; reasons: string[] };

/** AWS's limit on an inline session policy, in characters of its JSON. */
export const SESSION_POLICY_MAX_CHARS = 2048;

import { isPublicKey } from "./envelope.ts";

const ACCOUNT_RE = /^\d{12}$/;
/**
 * Run tags: lowercase words joined by single hyphens, 3 to 40 characters. No
 * "--", no leading or trailing hyphen (see RUN_NAMESPACE_RE).
 */
export const RUN_TAG_RE = /^(?=.{3,40}$)[a-z0-9]+(-[a-z0-9]+)*$/;

/**
 * A run's namespace, assigned by the broker when the run tag is first claimed:
 * "<runTag>-<8 random hex>". The run's tag-on-create names are
 * "<namespace>--…". The broker picks it, so nothing that existed before the
 * claim can carry it (an existing untagged queue named "foo--shared" is not
 * run foo's). It contains no "--", so no namespace's names ever match another
 * namespace's. It travels as the session tag agent-ns, which the role ceiling
 * reads as ${aws:PrincipalTag/agent-ns}.
 */
export const RUN_NAMESPACE_RE = /^[a-z0-9]+(-[a-z0-9]+)*-[0-9a-f]{8}$/;
export const NAMESPACE_TAG_KEY = "agent-ns";

/** Who first got credentials for a run tag, and the namespace the broker gave the run. */
export interface RunClaim {
  owner: string;
  namespace: string;
  /** Set once credentials for the run were delivered: from then on the claim is never released. */
  delivered?: boolean;
}
const ACTION_RE = /^[a-z0-9-]+:[A-Za-z0-9*]+$/;
const ARN_RE = /^arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:(\d{12})?:[^\s]+$/;
const REGION_RE = /^[a-z]{2}(-[a-z]+)+-\d$/;

/** Does any action match both globs? IAM action names are case-insensitive; "*" is the only wildcard we accept. */
export function globsIntersect(a: string, b: string): boolean {
  const x = a.toLowerCase();
  const y = b.toLowerCase();
  const memo = new Map<number, boolean>();
  const go = (i: number, j: number): boolean => {
    const key = i * (y.length + 1) + j;
    const hit = memo.get(key);
    if (hit !== undefined) return hit;
    let r = false;
    if (i === x.length && j === y.length) r = true;
    else if (x[i] === "*") r = go(i + 1, j) || (j < y.length && go(i, j + 1));
    else if (y[j] === "*") r = go(i, j + 1) || (i < x.length && go(i + 1, j));
    else if (i < x.length && j < y.length && x[i] === y[j]) r = go(i + 1, j + 1);
    memo.set(key, r);
    return r;
  };
  return go(0, 0);
}

/** The RoleSessionName / SourceIdentity form of an agent name: [\w+=,.@-], 2 to 64 characters. */
export function sessionName(principal: Principal): string {
  const clean = principal.name.replace(/[^\w+=,.@-]/g, "-").slice(0, 64);
  if (clean.length < 2 || /^aws:/i.test(clean)) throw new Error(`requester name ${JSON.stringify(principal.name)} cannot be a session name`);
  return clean;
}

export function validate(req: CredentialRequest, list: Allowlist): string[] {
  const problems: string[] = [];
  if (!ACCOUNT_RE.test(String(req.account))) problems.push("account must be a 12-digit AWS account id");
  if (typeof req.purpose !== "string" || req.purpose.trim().length < 8 || req.purpose.length > 500) problems.push("purpose must say what the credentials are for (8 to 500 characters)");
  if (!RUN_TAG_RE.test(String(req.runTag))) problems.push("runTag must be 3 to 40 lowercase letters and digits in words joined by single hyphens (no --)");
  if (!Array.isArray(req.actions) || req.actions.length === 0) problems.push("actions must list at least one service:Action");
  else {
    if (req.actions.length > 40) problems.push("at most 40 actions per request");
    for (const a of req.actions) {
      if (a === "*") problems.push("the action \"*\" is never issued");
      else if (typeof a !== "string" || !ACTION_RE.test(a)) problems.push(`action ${JSON.stringify(a)} is not service:Action`);
    }
  }
  const d = req.durationMinutes;
  if (!Number.isInteger(d) || d < list.duration.minMinutes || d > list.duration.maxMinutes) {
    problems.push(`durationMinutes must be a whole number from ${list.duration.minMinutes} to ${list.duration.maxMinutes}`);
  }
  if (req.scope !== undefined && req.scope !== "run-tag" && req.scope !== "account") problems.push("scope must be run-tag or account");
  for (const r of req.resources ?? []) if (typeof r !== "string" || !ARN_RE.test(r)) problems.push(`resource ${JSON.stringify(r)} is not an ARN`);
  if (req.regions !== undefined && (!Array.isArray(req.regions) || req.regions.length === 0)) problems.push("regions, when given, must list at least one region");
  for (const r of req.regions ?? []) if (typeof r !== "string" || !REGION_RE.test(r)) problems.push(`region ${JSON.stringify(r)} is not a region`);
  const del = req.delivery as { kind?: string; vault?: string } | undefined;
  if (!del || (del.kind !== "file" && del.kind !== "1password" && del.kind !== "encrypted")) problems.push("delivery.kind must be encrypted, file or 1password");
  else if (del.kind === "1password" && (typeof del.vault !== "string" || !/^[\w .-]{1,64}$/.test(del.vault))) problems.push("delivery.vault must name a 1Password vault");
  else if (del.kind === "encrypted" && !isPublicKey((del as { publicKey?: unknown }).publicKey)) problems.push("delivery.publicKey must be a base64 32-byte X25519 key (client.ts keygen)");
  return problems;
}

function regionsFor(req: CredentialRequest, account: AccountPolicy): { regions?: string[]; problem?: string } {
  if (!account.regions) return { regions: req.regions };
  if (!req.regions?.length) return { regions: account.regions };
  const outside = req.regions.filter((r) => !account.regions!.includes(r));
  if (outside.length) return { problem: `regions ${outside.join(", ")} are not allowed in ${account.label}` };
  return { regions: req.regions };
}

/** Global services, whose calls carry us-east-1 (or no region) whatever region the session works in. */
export const GLOBAL_ACTIONS = ["iam:*", "sts:*", "cloudfront:*", "route53:*", "support:*", "health:*", "s3:ListAllMyBuckets"];

/** One deny for the region limit, rather than a condition on every allow: keeps the policy under STS's size limit. */
function regionStatement(regions: string[] | undefined): PolicyStatement[] {
  if (!regions?.length) return [];
  return [{ Sid: "DenyOutsideRegions", Effect: "Deny", NotAction: GLOBAL_ACTIONS, Resource: "*", Condition: { StringNotEquals: { "aws:RequestedRegion": regions } } }];
}

function sid(id: string): string {
  return id.replace(/[^A-Za-z0-9]/g, " ").split(" ").filter(Boolean).map((w) => w[0]!.toUpperCase() + w.slice(1)).join("");
}

/**
 * Resources a run owns by name: what it creates must be named
 * "<namespace>--…" (RUN_NAMESPACE_RE). Tag-on-create authorization
 * (CreateQueue also checks sqs:TagQueue, and so on) is granted only on these.
 * The namespace is broker-assigned and unpredictable, so a session can never
 * put its run tag on a resource it didn't create, and namespaces never overlap.
 * As a second layer, no session may overwrite a run tag that is already
 * another run's (DenyOverwritingAnotherRunsTag). EC2 instead uses
 * ec2:CreateAction (see ec2-tag-on-create). terraform/modules/scoped-role holds
 * the same patterns with ${aws:PrincipalTag/agent-ns} in place of the namespace.
 */
export function ownNamedResources(namespace: string): string[] {
  return [
    `arn:aws:sqs:*:*:${namespace}--*`,
    `arn:aws:sns:*:*:${namespace}--*`,
    `arn:aws:logs:*:*:log-group:${namespace}--*`,
    `arn:aws:dynamodb:*:*:table/${namespace}--*`,
    `arn:aws:secretsmanager:*:*:secret:${namespace}--*`,
  ];
}

/** Tag writes that add a tag key; allowed for the run tag only on the run's own named resources. */
export const TAG_ACTIONS = ["sqs:TagQueue", "sns:TagResource", "logs:TagResource", "logs:TagLogGroup", "dynamodb:TagResource", "secretsmanager:TagResource"];

/** Tag writes that remove the run tag, or tag through the generic tagging API: never with the run tag. */
export const UNTAG_ACTIONS = [
  "ec2:DeleteTags",
  "tag:TagResources",
  "tag:UntagResources",
  "sqs:UntagQueue",
  "sns:UntagResource",
  "logs:UntagResource",
  "logs:UntagLogGroup",
  "dynamodb:UntagResource",
  "secretsmanager:UntagResource",
];

/**
 * Denies that keep the run tag from being forged, moved or removed. A session
 * policy only narrows, so a deny matters only for actions the session also
 * allows: each guard keeps just the actions that overlap the allows (which keeps
 * the policy under STS's 2048-character limit). The role's ceiling
 * (terraform/modules/scoped-role) holds all of them in full regardless.
 */
function guardStatements(tagKey: string, runTag: string, namespace: string, allows: PolicyStatement[]): PolicyStatement[] {
  const allowed = allows.flatMap((s) => s.Action ?? []);
  const overlap = (actions: string[]) => actions.filter((a) => a === "*" || allowed.some((x) => globsIntersect(a, x)));
  return allGuards(tagKey, runTag, namespace)
    .map((g) => {
      const Action = overlap(g.Action ?? []);
      // NotResource: only the kept actions' services (an ARN of another service can't be a resource of these actions).
      const services = new Set(Action.map((a) => a.split(":")[0]));
      return { ...g, Action, ...(g.NotResource ? { NotResource: g.NotResource.filter((r) => services.has(r.split(":")[2])) } : {}) };
    })
    .filter((g) => g.Action.length > 0);
}

function allGuards(tagKey: string, runTag: string, namespace: string): PolicyStatement[] {
  const hasRunTag = { "ForAnyValue:StringEquals": { "aws:TagKeys": [tagKey] } };
  return [
    {
      Sid: "DenyForeignRunTagOnCreate",
      Effect: "Deny",
      Action: ["*"],
      Resource: "*",
      Condition: { StringNotEquals: { [`aws:RequestTag/${tagKey}`]: runTag }, Null: { [`aws:RequestTag/${tagKey}`]: "false" } },
    },
    { Sid: "DenyRemovingRunTag", Effect: "Deny", Action: UNTAG_ACTIONS, Resource: "*", Condition: hasRunTag },
    { Sid: "DenyRunTagOnOthers", Effect: "Deny", Action: TAG_ACTIONS, NotResource: ownNamedResources(namespace), Condition: hasRunTag },
    {
      Sid: "DenyOverwritingAnotherRunsTag",
      Effect: "Deny",
      Action: [...TAG_ACTIONS, "ec2:CreateTags"],
      Resource: "*",
      Condition: { ...hasRunTag, StringNotEquals: { [`aws:ResourceTag/${tagKey}`]: runTag }, Null: { [`aws:ResourceTag/${tagKey}`]: "false" } },
    },
    { Sid: "DenyEc2TagsAfterCreate", Effect: "Deny", Action: ["ec2:CreateTags"], Resource: "*", Condition: { Null: { "ec2:CreateAction": "true" } } },
  ];
}

function scopeCondition(scope: Scope, list: Allowlist, runTag: string, base?: PolicyStatement["Condition"]): PolicyStatement["Condition"] {
  let cond: PolicyStatement["Condition"] = base ? structuredClone(base) : undefined;
  if (scope === "resource-tag") cond = { ...cond, StringEquals: { ...(cond?.StringEquals ?? {}), [`aws:ResourceTag/${list.tagKey}`]: runTag } };
  if (scope === "request-tag") cond = { ...cond, StringEquals: { ...(cond?.StringEquals ?? {}), [`aws:RequestTag/${list.tagKey}`]: runTag } };
  return cond;
}

function statement(id: string, actions: string[], resources: string[], cond: PolicyStatement["Condition"]): PolicyStatement {
  return { Sid: sid(id), Effect: "Allow", Action: actions, Resource: resources.length === 1 ? resources[0]! : resources, ...(cond ? { Condition: cond } : {}) };
}

function ruleResources(rule: AutoRule, req: CredentialRequest, namespace: string): string[] {
  if (rule.resources === undefined) return req.resources?.length ? req.resources : ["*"];
  return rule.resources.map((r) => r.replaceAll("{ns}", namespace));
}

function autoStatements(req: CredentialRequest, list: Allowlist, namespace: string): { statements: PolicyStatement[]; unmatched: string[] } {
  const statements: PolicyStatement[] = [];
  const matched = new Set<string>();
  const lower = new Map(req.actions.map((a) => [a.toLowerCase(), a]));
  const requested = (a: string) => lower.has(a.toLowerCase());
  for (const rule of list.autoRules) {
    const direct = rule.actions.filter(requested).map((a) => lower.get(a.toLowerCase())!);
    const implied = rule.impliedBy?.some(requested) ?? false;
    if (!direct.length && !implied) continue;
    direct.forEach((a) => matched.add(a));
    const acts = implied ? [...new Set([...direct, ...rule.actions])] : direct;
    statements.push(statement(rule.id, acts, ruleResources(rule, req, namespace), scopeCondition(rule.scope, list, req.runTag, rule.condition)));
  }
  return { statements, unmatched: req.actions.filter((a) => !matched.has(a)) };
}

/**
 * How an approved action that no auto rule covers is scoped under scope
 * run-tag, by its verb. Only verbs that make a new resource (Create, Run) get
 * the request-tag condition; Put, Update, Register and the rest act on
 * existing resources (e.g. secretsmanager:PutResourcePolicy takes no tags), so
 * they are scoped by the resource's tag.
 */
export function approvalScope(action: string): Scope {
  const verb = action.split(":")[1] ?? "";
  if (/^(Describe|List)/.test(verb)) return "any";
  if (/^(Create|Run)[A-Z*]/.test(verb)) return "request-tag";
  return "resource-tag";
}

/**
 * Approved sessions. Under scope account: the actions on the requested
 * resources, no tag condition (Khaliq approves that explicitly). Under scope
 * run-tag: each action gets the condition IAM can actually enforce for it:
 * an auto rule's scope where one covers it, otherwise by verb (account-level
 * reads unconditioned, creates must carry the run tag, everything else only on
 * resources carrying it). The approval prompt lists the statements, so no
 * isolation is claimed that IAM can't provide.
 */
/**
 * Actions IAM authorizes only on Resource "*" (no resource-level permissions):
 * naming resources for them makes AWS refuse them. An approved account-wide
 * session gets them in their own "*" statement, which the approval prompt
 * shows as such, while every other action stays on the named resources.
 */
export const RESOURCE_WILDCARD_ONLY = new Set([
  "ssm:GetCommandInvocation",
  "ssm:ListCommandInvocations",
  "ssm:ListCommands",
  "ssm:DescribeSessions",
  "ssm:DescribeInstanceInformation",
  "ec2:DescribeInstances",
  "secretsmanager:ListSecrets",
]);
const RESOURCE_WILDCARD_ONLY_LOWER = new Set([...RESOURCE_WILDCARD_ONLY].map((a) => a.toLowerCase()));

/** Case-insensitive, like IAM action matching and the auto-rule lookup. */
export function isResourceWildcardOnly(action: string): boolean {
  return RESOURCE_WILDCARD_ONLY_LOWER.has(action.toLowerCase());
}

function approvalStatements(req: CredentialRequest, list: Allowlist, namespace: string): PolicyStatement[] {
  const resources = req.resources?.length ? req.resources : ["*"];
  if (req.scope === "account") {
    const wildcardOnly = req.actions.filter(isResourceWildcardOnly);
    const named = req.actions.filter((a) => !isResourceWildcardOnly(a));
    return [
      ...(named.length ? [statement("approved-account-wide", named, resources, undefined)] : []),
      ...(wildcardOnly.length ? [statement("approved-without-resource-level-permissions", wildcardOnly, ["*"], undefined)] : []),
    ];
  }
  const auto = autoStatements(req, list, namespace);
  const groups: Record<Scope, string[]> = { any: [], "request-tag": [], "resource-tag": [] };
  for (const a of auto.unmatched) groups[approvalScope(a)].push(a);
  const names: Record<Scope, string> = { any: "approved-reads", "request-tag": "approved-creates-with-run-tag", "resource-tag": "approved-on-run-tagged" };
  const extra = (Object.keys(groups) as Scope[]).filter((s) => groups[s].length).map((s) => statement(names[s], groups[s], resources, scopeCondition(s, list, req.runTag)));
  return [...auto.statements, ...extra];
}

/**
 * Decide one request. `run` is the run tag's claim from the broker's state:
 * its owner (whoever first received credentials for it, so a run tag stays its
 * owner's) and its namespace; for an unclaimed tag, the namespace the broker
 * will record if it issues (newNamespace).
 */
export function decide(req: CredentialRequest, requester: Principal, list: Allowlist, run: { owner?: string; namespace: string }): Decision {
  const runTagOwner = run.owner;
  const namespace = run.namespace;
  const problems = validate(req, list);
  if (problems.length) return { outcome: "deny", reasons: problems };
  if (!RUN_NAMESPACE_RE.test(namespace) || !namespace.startsWith(`${req.runTag}-`)) return { outcome: "deny", reasons: [`bad run namespace ${JSON.stringify(namespace)}`] };
  const account = list.accounts[req.account];
  if (!account) return { outcome: "deny", reasons: [`account ${req.account} is not on the broker allowlist`] };
  const never = req.actions.filter((a) => list.neverIssue.some((n) => globsIntersect(a, n)));
  if (never.length) return { outcome: "deny", reasons: never.map((a) => `${a} is never issued by the broker`) };
  const { regions, problem } = regionsFor(req, account);
  if (problem) return { outcome: "deny", reasons: [problem] };
  const durationSeconds = req.durationMinutes * 60;

  const needs: string[] = [];
  if (account.tier !== "sandbox") needs.push(`${account.label} is a ${account.tier} account`);
  for (const a of req.actions) {
    if (a.includes("*")) needs.push(`${a} is a wildcard`);
    else if (list.approvalOnly.some((p) => globsIntersect(a, p))) needs.push(`${a} needs approval (IAM, identity or audit control)`);
  }
  if (req.durationMinutes > list.duration.autoMaxMinutes) needs.push(`${req.durationMinutes} minutes is over the ${list.duration.autoMaxMinutes}-minute auto limit`);
  if (runTagOwner && runTagOwner !== requester.name) needs.push(`run tag ${req.runTag} belongs to ${runTagOwner}`);

  const auto = autoStatements(req, list, namespace);
  const accountWide = (req.scope ?? "run-tag") === "account";
  if (accountWide) {
    const readOnly = auto.unmatched.length === 0 && list.autoRules.filter((r) => r.scope !== "any").every((r) => !r.actions.some((x) => req.actions.some((a) => a.toLowerCase() === x.toLowerCase())));
    if (!readOnly) needs.push("scope account: changes outside the run's own tag");
  }
  for (const a of auto.unmatched) if (!a.includes("*") && !list.approvalOnly.some((p) => globsIntersect(a, p))) needs.push(`${a} is not on the auto allowlist`);

  if (needs.length === 0 && account.roles.scoped) {
    const policy: SessionPolicy = { Version: "2012-10-17", Statement: [...auto.statements, ...guardStatements(list.tagKey, req.runTag, namespace, auto.statements), ...regionStatement(regions)] };
    const size = JSON.stringify(policy).length;
    if (size > SESSION_POLICY_MAX_CHARS) return { outcome: "deny", reasons: [`session policy is ${size} characters, over AWS's ${SESSION_POLICY_MAX_CHARS}: split the request`] };
    return { outcome: "auto", roleArn: account.roles.scoped, sessionPolicy: policy, durationSeconds, reasons: [`${account.label}: allowlisted actions on run tag ${req.runTag}`] };
  }
  if (needs.length === 0) needs.push(`${account.label} has no scoped role for automatic issue`);
  if (!account.roles.elevated) return { outcome: "deny", reasons: [...needs, `${account.label} has no approval-tier role configured, so this cannot be issued even with approval`] };
  const allows = approvalStatements(req, list, namespace);
  const policy: SessionPolicy = { Version: "2012-10-17", Statement: [...allows, ...guardStatements(list.tagKey, req.runTag, namespace, allows), ...regionStatement(regions)] };
  const size = JSON.stringify(policy).length;
  if (size > SESSION_POLICY_MAX_CHARS) return { outcome: "deny", reasons: [`session policy is ${size} characters, over AWS's ${SESSION_POLICY_MAX_CHARS}: split the request`] };
  return { outcome: "approval", roleArn: account.roles.elevated, sessionPolicy: policy, durationSeconds, reasons: needs };
}

/** A new run namespace: "<runTag>-<8 random hex>". */
export function newNamespace(runTag: string, random: () => string): string {
  return `${runTag}-${random()}`;
}

/** Is this principal one whose approval counts? Humans on the list only; an agent never. */
export function approverCounts(p: Principal, list: Allowlist): boolean {
  return p.kind === "human" && list.humanApprovers.includes(p.name);
}
