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
  /** Defaults to "*". A requester's own resources narrow only rules left on "*". */
  resources?: string[];
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

export type Delivery = { kind: "file" } | { kind: "1password"; vault: string };

export interface PolicyStatement {
  Sid: string;
  Effect: "Allow" | "Deny";
  Action: string[];
  Resource: string | string[];
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

const ACCOUNT_RE = /^\d{12}$/;
const RUN_TAG_RE = /^[a-z0-9][a-z0-9-]{2,62}$/;
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
  if (!RUN_TAG_RE.test(String(req.runTag))) problems.push("runTag must match ^[a-z0-9][a-z0-9-]{2,62}$");
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
  for (const r of req.regions ?? []) if (typeof r !== "string" || !REGION_RE.test(r)) problems.push(`region ${JSON.stringify(r)} is not a region`);
  const del = req.delivery as { kind?: string; vault?: string } | undefined;
  if (!del || (del.kind !== "file" && del.kind !== "1password")) problems.push("delivery.kind must be file or 1password");
  else if (del.kind === "1password" && (typeof del.vault !== "string" || !/^[\w .-]{1,64}$/.test(del.vault))) problems.push("delivery.vault must name a 1Password vault");
  return problems;
}

function regionsFor(req: CredentialRequest, account: AccountPolicy): { regions?: string[]; problem?: string } {
  if (!account.regions) return { regions: req.regions };
  if (!req.regions) return { regions: account.regions };
  const outside = req.regions.filter((r) => !account.regions!.includes(r));
  if (outside.length) return { problem: `regions ${outside.join(", ")} are not allowed in ${account.label}` };
  return { regions: req.regions };
}

function withRegion(cond: PolicyStatement["Condition"], regions: string[] | undefined): PolicyStatement["Condition"] {
  if (!regions?.length) return cond;
  return { ...cond, StringEquals: { ...(cond?.StringEquals ?? {}), "aws:RequestedRegion": regions } };
}

function sid(id: string): string {
  return id.replace(/[^A-Za-z0-9]/g, " ").split(" ").filter(Boolean).map((w) => w[0]!.toUpperCase() + w.slice(1)).join("");
}

/** Statements that hold on every issued session, whatever the tier: the run tag can't be moved or forged. */
function guardStatements(tagKey: string, runTag: string): PolicyStatement[] {
  return [
    {
      Sid: "DenyForeignRunTagOnCreate",
      Effect: "Deny",
      Action: ["*"],
      Resource: "*",
      Condition: { StringNotEquals: { [`aws:RequestTag/${tagKey}`]: runTag }, Null: { [`aws:RequestTag/${tagKey}`]: "false" } },
    },
    {
      Sid: "DenyRetaggingRunTag",
      Effect: "Deny",
      Action: RETAG_ACTIONS,
      Resource: "*",
      Condition: { "ForAnyValue:StringEquals": { "aws:TagKeys": [tagKey] } },
    },
    {
      Sid: "DenyEc2TagsAfterCreate",
      Effect: "Deny",
      Action: ["ec2:CreateTags"],
      Resource: "*",
      Condition: { Null: { "ec2:CreateAction": "true" } },
    },
  ];
}

/**
 * Tag writes that could move the run tag onto someone else's resource. Only
 * matters when an approved session's actions are broad (an auto session can't
 * tag at all: a session policy only narrows). The role's own policy denies the
 * same set (terraform/modules/scoped-role).
 */
export const RETAG_ACTIONS = [
  "ec2:DeleteTags",
  "tag:TagResources",
  "tag:UntagResources",
  "sqs:TagQueue",
  "sqs:UntagQueue",
  "sns:TagResource",
  "sns:UntagResource",
  "logs:TagResource",
  "logs:UntagResource",
  "logs:TagLogGroup",
  "logs:UntagLogGroup",
  "dynamodb:TagResource",
  "dynamodb:UntagResource",
  "secretsmanager:TagResource",
  "secretsmanager:UntagResource",
];

function autoStatements(req: CredentialRequest, list: Allowlist, regions: string[] | undefined): { statements: PolicyStatement[]; unmatched: string[] } {
  const statements: PolicyStatement[] = [];
  const matched = new Set<string>();
  const lower = new Map(req.actions.map((a) => [a.toLowerCase(), a]));
  for (const rule of list.autoRules) {
    const acts = rule.actions.filter((a) => lower.has(a.toLowerCase())).map((a) => lower.get(a.toLowerCase())!);
    if (!acts.length) continue;
    acts.forEach((a) => matched.add(a));
    const ruleResources = rule.resources ?? ["*"];
    const resources = rule.resources === undefined && req.resources?.length ? req.resources : ruleResources;
    let cond: PolicyStatement["Condition"] = rule.condition ? structuredClone(rule.condition) : undefined;
    if (rule.scope === "resource-tag") cond = { ...cond, StringEquals: { ...(cond?.StringEquals ?? {}), [`aws:ResourceTag/${list.tagKey}`]: req.runTag } };
    if (rule.scope === "request-tag") cond = { ...cond, StringEquals: { ...(cond?.StringEquals ?? {}), [`aws:RequestTag/${list.tagKey}`]: req.runTag } };
    cond = withRegion(cond, regions);
    statements.push({ Sid: sid(rule.id), Effect: "Allow", Action: acts, Resource: resources.length === 1 ? resources[0]! : resources, ...(cond ? { Condition: cond } : {}) });
  }
  return { statements, unmatched: req.actions.filter((a) => !matched.has(a)) };
}

function approvalStatements(req: CredentialRequest, list: Allowlist, regions: string[] | undefined): PolicyStatement[] {
  const resources = req.resources?.length ? req.resources : ["*"];
  let cond: PolicyStatement["Condition"] = undefined;
  if ((req.scope ?? "run-tag") === "run-tag") cond = { StringEquals: { [`aws:ResourceTag/${list.tagKey}`]: req.runTag } };
  cond = withRegion(cond, regions);
  return [{ Sid: "ApprovedActions", Effect: "Allow", Action: [...req.actions], Resource: resources.length === 1 ? resources[0]! : resources, ...(cond ? { Condition: cond } : {}) }];
}

/**
 * Decide one request. `runTagOwner` is whoever first received credentials for
 * this run tag (from the broker's state), so a run tag stays its owner's.
 */
export function decide(req: CredentialRequest, requester: Principal, list: Allowlist, runTagOwner?: string): Decision {
  const problems = validate(req, list);
  if (problems.length) return { outcome: "deny", reasons: problems };
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

  const auto = autoStatements(req, list, regions);
  const accountWide = (req.scope ?? "run-tag") === "account";
  if (accountWide) {
    const readOnly = auto.unmatched.length === 0 && list.autoRules.filter((r) => r.scope !== "any").every((r) => !r.actions.some((x) => req.actions.some((a) => a.toLowerCase() === x.toLowerCase())));
    if (!readOnly) needs.push("scope account: changes outside the run's own tag");
  }
  for (const a of auto.unmatched) if (!a.includes("*") && !list.approvalOnly.some((p) => globsIntersect(a, p))) needs.push(`${a} is not on the auto allowlist`);

  if (needs.length === 0 && account.roles.scoped) {
    const policy: SessionPolicy = { Version: "2012-10-17", Statement: [...auto.statements, ...guardStatements(list.tagKey, req.runTag)] };
    const size = JSON.stringify(policy).length;
    if (size > SESSION_POLICY_MAX_CHARS) return { outcome: "deny", reasons: [`session policy is ${size} characters, over AWS's ${SESSION_POLICY_MAX_CHARS}: split the request`] };
    return { outcome: "auto", roleArn: account.roles.scoped, sessionPolicy: policy, durationSeconds, reasons: [`${account.label}: allowlisted actions on run tag ${req.runTag}`] };
  }
  if (needs.length === 0) needs.push(`${account.label} has no scoped role for automatic issue`);
  if (!account.roles.elevated) return { outcome: "deny", reasons: [...needs, `${account.label} has no approval-tier role configured, so this cannot be issued even with approval`] };
  const policy: SessionPolicy = { Version: "2012-10-17", Statement: [...approvalStatements(req, list, regions), ...guardStatements(list.tagKey, req.runTag)] };
  const size = JSON.stringify(policy).length;
  if (size > SESSION_POLICY_MAX_CHARS) return { outcome: "deny", reasons: [`session policy is ${size} characters, over AWS's ${SESSION_POLICY_MAX_CHARS}: split the request`] };
  return { outcome: "approval", roleArn: account.roles.elevated, sessionPolicy: policy, durationSeconds, reasons: needs };
}

/** Is this principal one whose approval counts? Humans on the list only; an agent never. */
export function approverCounts(p: Principal, list: Allowlist): boolean {
  return p.kind === "human" && list.humanApprovers.includes(p.name);
}
