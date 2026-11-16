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
  /** Agents Khaliq lets approve a narrow slice of requests until a hard expiry. Absent: only humanApprovers approve. */
  delegatedApprovers?: DelegatedApprover[];
}

/**
 * A standing delegation: one Relay agent may approve pending requests that
 * fall entirely inside one of its capabilities, until expiresAt. Checked
 * against the session policy the broker built (what IAM will enforce), never
 * against the request's prose. See checkDelegatedApproval.
 */
export interface DelegatedApprover {
  /** The Relay agent's name, as the Relay server resolves the approval message's sender. */
  agent: string;
  /**
   * The Relay agent id the name must resolve to (Relaycast agent_id). A name
   * can be re-registered by another session; the id can't, so a new holder of
   * the name never inherits the delegation. Re-pinning is an allowlist change.
   */
  agentId: string;
  /** Hard expiry (ISO 8601, UTC). After it the delegate's approvals are refused. At most MAX_DELEGATION_DAYS ahead. */
  expiresAt: string;
  /** Who granted it, and why: for the reviewer and the audit log. */
  grantedBy: string;
  reason: string;
  /** Required: only requests from these agents. A missing or empty list is a config error. */
  requesters: string[];
  capabilities: DelegatedCapability[];
}

export interface DelegatedCapability {
  id: string;
  /** Accounts (each must also be on the allowlist). */
  accounts: string[];
  /** The request must name its regions, all of them here. */
  regions: string[];
  /** Auto rules (scope "any", read verbs only) whose actions the delegate may approve on any resource. */
  readOnlyRules?: string[];
  grants: DelegatedGrant[];
}

export interface DelegatedGrant {
  id: string;
  actions: string[];
  /** Secrets Manager: secrets whose name starts with one of these (e.g. "neon-exit/"). */
  secretPrefixes?: string[];
  /** Secrets Manager: exactly these secrets (the ARN is the name plus AWS's 6-character suffix). */
  secretNames?: string[];
  /** SSM: only these literal instance ids (required for ssm grants). */
  instanceIds?: string[];
  /** SSM: and only while they carry this tag. Enforced in IAM by a deny the broker adds when the request names the delegate. */
  instanceTag?: { key: string; value: string };
  /** SSM documents the session may use (AWS-owned or the account's own). */
  ssmDocuments?: string[];
}

/** Who asked, from the Relay envelope the message arrived in: never from the request body. */
export interface Principal {
  name: string;
  address: string;
  kind: "agent" | "human";
  /** The Relay agent id, when the sender was verified with the Relay server (relay.ts). Delegated approval requires it. */
  agentId?: string;
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
  /** A delegated approver (allowlist delegatedApprovers) the requester asks to approve this instead of Khaliq. */
  delegate?: string;
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
  if (req.delegate !== undefined && (typeof req.delegate !== "string" || !(list.delegatedApprovers ?? []).some((d) => d.agent === req.delegate))) problems.push(`delegate ${JSON.stringify(req.delegate)} is not a delegated approver on the allowlist`);
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
function approvalStatements(req: CredentialRequest, list: Allowlist, namespace: string): PolicyStatement[] {
  const resources = req.resources?.length ? req.resources : ["*"];
  if (req.scope === "account") return [statement("approved-account-wide", [...req.actions], resources, undefined)];
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
  const policy: SessionPolicy = { Version: "2012-10-17", Statement: [...allows, ...guardStatements(list.tagKey, req.runTag, namespace, allows), ...regionStatement(regions), ...delegateGuards(req, list)] };
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

// ---------------------------------------------------------------------------
// Delegated approvers

/** The longest a delegation may run from the moment it is used: a longer expiresAt is refused as misconfigured. */
export const MAX_DELEGATION_DAYS = 30;

/** Never delegable, whatever a capability says: IAM and identity, audit controls, never-issue, deletes, and wildcards. */
export const DELETE_VERB_RE = /^(Delete|Terminate|Remove|Purge|Destroy|Untag|Schedule\w*Deletion)/;

export function neverDelegable(action: string, list: Allowlist): string | undefined {
  if (/[*?]/.test(action)) return `${action} is a wildcard`;
  if (globsIntersect(action, "iam:*")) return `${action} is IAM`;
  if (list.neverIssue.some((n) => globsIntersect(action, n))) return `${action} is never issued`;
  if (list.approvalOnly.some((n) => globsIntersect(action, n))) return `${action} is an identity or audit control`;
  if (DELETE_VERB_RE.test(action.split(":")[1] ?? "")) return `${action} deletes`;
  return undefined;
}

const READ_VERB_RE = /^(Describe|List|Get)[A-Z]/;
const SECRET_SUFFIX_RE = /^-[A-Za-z0-9]{6}$/;
const INSTANCE_ID_RE = /^i-[0-9a-f]{8,17}$/;
const NAME_RE = /^[A-Za-z0-9/_+=.@-]+$/;

/** Problems with the delegation config itself. Any problem refuses every delegated approval (Khaliq's are unaffected). */
export function delegationConfigProblems(list: Allowlist): string[] {
  const problems: string[] = [];
  const seen = new Set<string>();
  for (const d of list.delegatedApprovers ?? []) {
    const who = `delegate ${d.agent}`;
    if (typeof d.agent !== "string" || !NAME_RE.test(d.agent)) problems.push(`${who}: agent must be a Relay agent name`);
    if (seen.has(d.agent)) problems.push(`${who}: listed twice`);
    seen.add(d.agent);
    if (list.humanApprovers.includes(d.agent)) problems.push(`${who}: is a human approver already`);
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(String(d.expiresAt)) || Number.isNaN(Date.parse(d.expiresAt))) problems.push(`${who}: expiresAt must be an ISO 8601 UTC time`);
    if (!list.humanApprovers.includes(d.grantedBy)) problems.push(`${who}: grantedBy must be a human approver`);
    if (typeof d.agentId !== "string" || !/^[0-9]{6,32}$/.test(d.agentId)) problems.push(`${who}: agentId must be its Relay agent id`);
    if (!Array.isArray(d.requesters) || d.requesters.length === 0) problems.push(`${who}: requesters must list the agents whose requests it may approve`);
    else for (const r of d.requesters) if (typeof r !== "string" || !NAME_RE.test(r) || r === d.agent || list.humanApprovers.includes(r)) problems.push(`${who}: requester ${JSON.stringify(r)} must be another agent's Relay name`);
    if (!Array.isArray(d.capabilities) || d.capabilities.length === 0) problems.push(`${who}: no capabilities`);
    for (const c of d.capabilities ?? []) {
      const where = `${who} capability ${c.id}`;
      for (const a of c.accounts ?? []) {
        const acct = list.accounts[a];
        if (!acct) problems.push(`${where}: account ${a} is not on the allowlist`);
        else for (const r of c.regions ?? []) if (acct.regions && !acct.regions.includes(r)) problems.push(`${where}: region ${r} is not allowed in ${a}`);
      }
      if (!c.accounts?.length || !c.regions?.length) problems.push(`${where}: must name accounts and regions`);
      for (const id of c.readOnlyRules ?? []) {
        const rule = list.autoRules.find((r) => r.id === id);
        if (!rule) problems.push(`${where}: no auto rule ${id}`);
        else if (rule.scope !== "any" || rule.resources !== undefined || rule.actions.some((a) => !READ_VERB_RE.test(a.split(":")[1] ?? "") || neverDelegable(a, list))) problems.push(`${where}: auto rule ${id} is not read-only`);
      }
      for (const g of c.grants ?? []) {
        for (const a of g.actions) {
          const why = neverDelegable(a, list);
          if (why) problems.push(`${where} grant ${g.id}: ${why}, never delegable`);
        }
        const svc = new Set(g.actions.map((a) => a.split(":")[0]));
        const kinds = [g.secretPrefixes || g.secretNames ? "secretsmanager" : undefined, g.instanceTag || g.ssmDocuments || g.instanceIds ? "ssm" : undefined].filter(Boolean);
        if (kinds.length !== 1 || svc.size !== 1 || !svc.has(kinds[0]!)) problems.push(`${where} grant ${g.id}: a grant is secretsmanager actions on secrets, or ssm actions on tagged instances`);
        if (kinds[0] === "ssm" && !g.instanceTag) problems.push(`${where} grant ${g.id}: ssm needs instanceTag`);
        if (kinds[0] === "ssm" && !g.instanceIds?.length) problems.push(`${where} grant ${g.id}: ssm needs literal instanceIds`);
        for (const i of g.instanceIds ?? []) if (typeof i !== "string" || !INSTANCE_ID_RE.test(i)) problems.push(`${where} grant ${g.id}: ${JSON.stringify(i)} is not an instance id`);
        for (const n of [...(g.secretPrefixes ?? []), ...(g.secretNames ?? []), ...(g.ssmDocuments ?? []), ...(g.instanceTag ? [g.instanceTag.key, g.instanceTag.value] : [])]) {
          if (typeof n !== "string" || !NAME_RE.test(n)) problems.push(`${where} grant ${g.id}: ${JSON.stringify(n)} must be a literal name (no wildcards)`);
        }
        for (const pfx of g.secretPrefixes ?? []) if (!pfx.endsWith("/")) problems.push(`${where} grant ${g.id}: secret prefix ${pfx} must end with "/"`);
      }
    }
  }
  return problems;
}

/**
 * Denies the broker adds when a request names a delegate: for each SSM grant
 * the request touches, instances without the grant's tag are denied in IAM,
 * so the tag scope doesn't rest on the delegate's judgment. Denies only
 * narrow, so Khaliq can still approve such a request.
 */
export function delegateGuards(req: CredentialRequest, list: Allowlist): PolicyStatement[] {
  const d = (list.delegatedApprovers ?? []).find((x) => x.agent === req.delegate);
  if (!d) return [];
  const out: PolicyStatement[] = [];
  for (const c of d.capabilities) for (const g of c.grants) {
    if (!g.instanceTag) continue;
    const actions = g.actions.filter((a) => req.actions.some((r) => r.toLowerCase() === a.toLowerCase()));
    if (!actions.length) continue;
    out.push({ Sid: sid(`delegate-deny-untagged-${g.id}`), Effect: "Deny", Action: actions, Resource: ["arn:aws:ec2:*:*:instance/*", "arn:aws:ssm:*:*:managed-instance/*"], Condition: { StringNotEquals: { [`ssm:resourceTag/${g.instanceTag.key}`]: g.instanceTag.value } } });
  }
  return out;
}

/** Does the grant cover this resource ARN (a literal: no wildcard ever matches)? */
export function grantCovers(g: DelegatedGrant, resource: string, account: string, region: string): boolean {
  if (/[*?]/.test(resource)) return false;
  if (g.secretPrefixes || g.secretNames) {
    const head = `arn:aws:secretsmanager:${region}:${account}:secret:`;
    if (!resource.startsWith(head)) return false;
    const name = resource.slice(head.length);
    if ((g.secretPrefixes ?? []).some((p) => name.startsWith(p) && name.length > p.length && NAME_RE.test(name))) return true;
    return (g.secretNames ?? []).some((n) => name.startsWith(n) && SECRET_SUFFIX_RE.test(name.slice(n.length)));
  }
  if (g.instanceTag) {
    const inst = `arn:aws:ec2:${region}:${account}:instance/`;
    if (resource.startsWith(inst)) return (g.instanceIds ?? []).includes(resource.slice(inst.length));
    return (g.ssmDocuments ?? []).some((doc) => resource === `arn:aws:ssm:${region}::document/${doc}` || resource === `arn:aws:ssm:${region}:${account}:document/${doc}`);
  }
  return false;
}

export type DelegatedCheck =
  | { ok: true; delegate: DelegatedApprover; capability: string; grants: string[] }
  | { ok: false; reason: string };

/**
 * May this agent approve this pending request? Only if all of:
 * - it is a delegated approver, verified by the Relay server as the agent id
 *   the delegation pins, its delegation hasn't expired (and runs at
 *   most MAX_DELEGATION_DAYS from now), and the delegation config is sound;
 * - the requester named it (request.delegate), so the broker built the
 *   delegate's IAM guards into the policy, and is on its requesters list;
 * - one capability covers the account, the request's named regions, and
 *   every allowed action on every resource of the session policy: read-only
 *   auto-rule actions on anything, everything else only through a grant, on
 *   literal resources the grant names;
 * - nothing is never-delegable (IAM, identity and audit controls, deletes,
 *   wildcard actions or resources).
 * The caller still refuses self-approval, checks the digest and re-decides.
 */
export function checkDelegatedApproval(p: { request: CredentialRequest; requester: Principal; sessionPolicy: SessionPolicy }, approver: Principal, list: Allowlist, now: Date): DelegatedCheck {
  const d = (list.delegatedApprovers ?? []).find((x) => x.agent === approver.name);
  if (!d) return { ok: false, reason: `${approver.name} (${approver.kind}) is not an approver: only a human on humanApprovers, or a delegate on delegatedApprovers, can approve` };
  if (approver.agentId !== d.agentId) return { ok: false, reason: `${approver.name} is not the Relay agent the delegation names (agent id ${approver.agentId ?? "unverified"}, not ${d.agentId}): only ${list.humanApprovers.join(", ")} can approve` };
  const no = (reason: string): DelegatedCheck => ({ ok: false, reason: `${d.agent} can't approve this as a delegate: ${reason}; only ${list.humanApprovers.join(", ")} can` });
  const config = delegationConfigProblems(list);
  if (config.length) return no(`the delegation config is unsound (${config.join("; ")})`);
  const expires = Date.parse(d.expiresAt);
  if (!(now.getTime() < expires)) return no(`its delegation expired at ${d.expiresAt}`);
  if (expires - now.getTime() > MAX_DELEGATION_DAYS * 86_400_000) return no(`its delegation runs past ${MAX_DELEGATION_DAYS} days`);
  const req = p.request;
  if (req.delegate !== d.agent) return no(`the request didn't name ${d.agent} as its delegate`);
  if (!d.requesters?.includes(p.requester.name)) return no(`${p.requester.name} is not one of its requesters`);
  for (const a of req.actions) {
    const why = neverDelegable(a, list);
    if (why) return no(`${why}, never delegable`);
  }
  for (const r of req.resources ?? []) if (/[*?]/.test(r)) return no(`resource ${r} is a wildcard, never delegable`);
  const account = String(req.account);
  if (!list.accounts[account]) return no(`account ${account} is not on the allowlist`);
  const misses: string[] = [];
  for (const c of d.capabilities) {
    const miss = (m: string) => misses.push(`${c.id}: ${m}`);
    if (!c.accounts.includes(account)) { miss(`account ${account} is not in it`); continue; }
    if (!req.regions?.length) { miss(`the request must name its regions (${c.regions.join(", ")})`); continue; }
    const offRegion = req.regions.filter((r) => !c.regions.includes(r));
    if (offRegion.length) { miss(`regions ${offRegion.join(", ")} are not in it`); continue; }
    const reads = new Set(list.autoRules.filter((r) => (c.readOnlyRules ?? []).includes(r.id)).flatMap((r) => r.actions.map((a) => a.toLowerCase())));
    const used = new Set<string>();
    let bad: string | undefined;
    for (const s of p.sessionPolicy.Statement) {
      if (s.Effect !== "Allow") continue;
      if (s.NotAction || s.NotResource || !s.Action) { bad = `statement ${s.Sid} isn't a plain allow`; break; }
      const resources = [s.Resource ?? "*"].flat();
      for (const a of s.Action) {
        if (reads.has(a.toLowerCase())) { used.add("read-only"); continue; }
        const grant = c.grants.find((g) => g.actions.some((x) => x.toLowerCase() === a.toLowerCase()) && resources.every((r) => req.regions!.some((reg) => grantCovers(g, r, account, reg))));
        if (!grant) { bad = `${a} on ${resources.join(", ")} is outside it`; break; }
        used.add(grant.id);
      }
      if (bad) break;
    }
    if (bad) { miss(bad); continue; }
    // The IAM guards for tag-scoped grants must be in the policy as the broker builds them.
    const want = delegateGuards(req, list);
    const have = p.sessionPolicy.Statement.filter((s) => s.Sid.startsWith("DelegateDenyUntagged"));
    if (JSON.stringify(want) !== JSON.stringify(have)) { miss("the policy lacks the delegate's tag guard"); continue; }
    return { ok: true, delegate: d, capability: c.id, grants: [...used].sort() };
  }
  return no(misses.join("; ") || "it has no capabilities");
}
