/**
 * Owner delegates: when the allowlist has an ownerDelegates block, an agent
 * whose Relay agent id has a live grant in the owner's root-owned file on the
 * broker host may approve, over Relay, a pending request that holds nothing
 * beyond any delegation (IAM, identity and audit controls, never-issue,
 * deletes, wildcards). Who the delegates are is never in the repo: every name
 * and id here is a placeholder. Khaliq's approvals and the named
 * delegatedApprovers work exactly as before.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AuditLine } from "../broker/src/audit.ts";
import { Broker } from "../broker/src/broker.ts";
import { defaultDeliverer } from "../broker/src/deliver.ts";
import { fileFacts, hostFileSource, noOwnerDelegates, type FileFacts, type OwnerDelegateSource } from "../broker/src/owner-delegates.ts";
import { checkOwnerDelegateApproval, decide, ownerDelegableProblem, ownerDelegatesProblems, type Allowlist, type CredentialRequest, type OwnerDelegateGrants, type Principal } from "../broker/src/policy.ts";
import { dmChannelId, type RelayAgent, type RelayApi, type RelayMessage } from "../broker/src/relay.ts";
import type { StsClient } from "../broker/src/sts.ts";

const shippedText = readFileSync(new URL("../broker/allowlist.json", import.meta.url), "utf8");
const shipped = JSON.parse(shippedText) as Allowlist;
const example = JSON.parse(readFileSync(new URL("../broker/owner-delegates.example.json", import.meta.url), "utf8")) as { version: number; grantedBy: string; delegates: Record<string, unknown>[] };

const HOSTS = "500268966557";
const NOW = new Date("2026-11-15T22:00:00Z");
const WS = "rw_test0001";
const BROKER = "layered-infra-ops";
const OWNER = "khaliq-gant";
const WORKER = "some-worker";
/** A placeholder owner delegate: its name is in no file, only its agent id is in the (temporary) grant file. */
const DELEGATE = "some-delegate";
const DELEGATE_ID = "300000000000000009";
const BROKER_ID = "246905220461514752";
/** The allowlist's named delegated approver and one of its requesters, read from the file (their rule is not this one). */
const NAMED = shipped.delegatedApprovers![0]!.agent;
const NAMED_ID = "300000000000000002";
const NAMED_REQUESTER = shipped.delegatedApprovers![0]!.requesters[0]!;
const agents: Record<string, RelayAgent> = {
  [WORKER]: { id: "300000000000000001", name: WORKER, type: "agent", workspaceId: WS },
  [NAMED]: { id: NAMED_ID, name: NAMED, type: "agent", workspaceId: WS },
  [NAMED_REQUESTER]: { id: "300000000000000003", name: NAMED_REQUESTER, type: "agent", workspaceId: WS },
  [DELEGATE]: { id: DELEGATE_ID, name: DELEGATE, type: "agent", workspaceId: WS },
  [OWNER]: { id: "229221621257396224", name: OWNER, type: "human", workspaceId: WS },
  "some-other-agent": { id: "300000000000000005", name: "some-other-agent", type: "agent", workspaceId: WS },
  [BROKER]: { id: BROKER_ID, name: BROKER, type: "agent", workspaceId: WS },
};
/** The shipped allowlist (owner delegation on), with the fake Relay's id for the named delegated approver pinned. */
const allowlist = (): Allowlist => {
  const list = structuredClone(shipped);
  list.delegatedApprovers![0]!.agentId = NAMED_ID;
  return list;
};
/** The same without the ownerDelegates block: the feature off. */
const withoutBlock = (): Allowlist => {
  const list = allowlist();
  delete list.ownerDelegates;
  return list;
};
/** The broker's clock in the current test: messages are sent a minute before it. */
let clock = NOW;
const toBroker = (from: string) => dmChannelId(WS, agents[from]!.id, agents[BROKER]!.id);

const TOKEN_SECRET = `arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:infra-ops/some-token-Xy9Zq1`;
const NEON_SECRET = `arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:neon-exit/database-url-AbC123`;
const INSTANCE = `arn:aws:ec2:us-east-1:${HOSTS}:instance/i-0887caee00ca9029a`;

/** A write on one literal secret outside every automatic rule: it needs an approval. */
const secretsReq = (over: Partial<CredentialRequest> = {}): CredentialRequest => ({
  account: HOSTS,
  purpose: "rotate the token: write the new value",
  actions: ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"],
  durationMinutes: 15,
  runTag: "token-rotation",
  scope: "account",
  resources: [TOKEN_SECRET],
  regions: ["us-east-1"],
  delivery: { kind: "file" },
  ...over,
});

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

/** The file as root would own it: the uid is the one fact a test can't make true. Mode, symlink and content are the real ones. */
const asRoot = (fd: number): FileFacts => ({ ...fileFacts(fd), uid: 0 });
const grant = (agentId: string = DELEGATE_ID, expiresAt = "2026-12-01T00:00:00Z") => ({ agentId, expiresAt, note: "a placeholder" });
const grantFileBody = (delegates: unknown[] = [grant()], over: Record<string, unknown> = {}) => JSON.stringify({ version: 1, grantedBy: OWNER, delegates, ...over });

/** A broker on a temporary state dir whose owner-delegate grants come from `file` (written 0644 unless `file` is false). */
function setup(opts: { list?: Allowlist; now?: Date; file?: string | false; facts?: (fd: number) => FileFacts; sts?: StsClient } = {}) {
  const now = opts.now ?? NOW;
  const list = opts.list ?? allowlist();
  clock = now;
  const dir = mkdtempSync(join(tmpdir(), "broker-owner-delegates-"));
  const grantFile = join(dir, "owner-delegates.json");
  if (opts.file !== false) {
    writeFileSync(grantFile, opts.file ?? grantFileBody());
    chmodSync(grantFile, 0o644);
  }
  const calls: { sessionName: string }[] = [];
  const sts: StsClient = opts.sts ?? {
    async assumeRole(input) {
      calls.push(input);
      return { accessKeyId: "ASIAFAKE", secretAccessKey: "s".repeat(40), sessionToken: "t".repeat(300), expiration: new Date(now.getTime() + input.durationSeconds * 1000).toISOString() };
    },
  };
  let n = 0;
  const source = hostFileSource(grantFile, list, opts.facts ?? asRoot);
  const broker = new Broker({ allowlist: list, stateDir: join(dir, "state"), sts, deliverer: defaultDeliverer(join(dir, "creds")), now: () => now, newId: () => `cb-${(++n).toString(16).padStart(12, "0")}`, newNamespaceSuffix: () => "0a1b2c3d", ownerDelegates: source });
  const audit = () => readFileSync(broker.auditPath, "utf8").trim().split("\n").map((l) => JSON.parse(l) as AuditLine);
  return { broker, calls, audit, dir, grantFile, source, list };
}

/** The worker asks over Relay (message 1); returns the pending reply and the approve text. */
async function pend(broker: Broker, req: CredentialRequest = secretsReq(), from = WORKER) {
  const r = await broker.requestViaRelay(fakeRelay([msg("1000001", from, JSON.stringify(req))]), "1000001", BROKER);
  assert.equal(r.outcome, "pending-approval", r.reasons.join("; "));
  return { r, text: `approve ${r.requestId} ${r.policyDigest!.slice(0, 16)}` };
}

/** `who` DMs the broker `text` as message `id`; the broker decides. */
const dm = (broker: Broker, who: string, text: string, id = "1000002") => broker.decideViaRelay(fakeRelay([msg(id, who, text)]), id, BROKER);

const NOT_APPROVER = `${DELEGATE} (agent) is not an approver: only a human on humanApprovers can approve`;

test("the repo names no owner delegate: the allowlist block only switches the rule on, and the example file holds placeholders", () => {
  assert.deepEqual(ownerDelegatesProblems(shipped), []);
  const block = shipped.ownerDelegates as unknown as Record<string, unknown>;
  assert.deepEqual(Object.keys(block).sort(), ["$comment", "grantedBy", "notDelegable", "source"]);
  // notDelegable holds IAM actions, never an agent.
  for (const a of block.notDelegable as string[]) assert.match(a, /^[a-z0-9-]+:[A-Za-z*]+$/);
  for (const k of ["agent", "agents", "name", "names", "delegates", "agentId", "agentIds"]) assert.ok(!(k in block), `ownerDelegates must not have ${k}`);
  assert.equal(block.source, "host-file");
  assert.equal(block.grantedBy, OWNER);
  assert.deepEqual(shipped.humanApprovers, [OWNER], "Khaliq is still the only human approver");
  // Nothing else in the allowlist changed shape: the named delegated approver is still the only one.
  assert.equal(shipped.delegatedApprovers!.length, 1);
  // The example: placeholder ids only, and no key that could carry a name.
  assert.equal(example.version, 1);
  assert.equal(example.grantedBy, OWNER);
  for (const d of example.delegates) {
    assert.match(String(d.agentId), /^30000000000000000\d$/, "a placeholder id");
    for (const k of Object.keys(d)) assert.ok(["agentId", "expiresAt", "note"].includes(k), `example entry key ${k}`);
  }
  // And no real agent's Relay id from this file's fixtures or the allowlist's pin is in the example.
  assert.ok(!example.delegates.some((d) => d.agentId === shipped.delegatedApprovers![0]!.agentId));
});

test("a block that names a delegate, another source or a non-approver is a config problem: owner delegation is off, Khaliq still approves", async () => {
  const bad: [Record<string, unknown>, RegExp][] = [
    [{ source: "relay", grantedBy: OWNER }, /source must be "host-file"/],
    [{ grantedBy: OWNER }, /source must be "host-file"/],
    [{ source: "host-file", grantedBy: "some-other-agent" }, /grantedBy must be a human approver/],
    [{ source: "host-file" }, /grantedBy must be a human approver/],
    [{ source: "host-file", grantedBy: OWNER, delegates: [grant()] }, /"delegates" is not a key of this block/],
    [{ source: "host-file", grantedBy: OWNER, agent: DELEGATE }, /"agent" is not a key of this block/],
  ];
  for (const [block, re] of bad) {
    const list = { ...allowlist(), ownerDelegates: block } as unknown as Allowlist;
    assert.match(ownerDelegatesProblems(list).join("; "), re);
    const { broker, calls, source } = setup({ list });
    assert.deepEqual(source.load(NOW).grants, []);
    assert.match(source.load(NOW).problems.join("; "), re);
    const { r, text } = await pend(broker);
    assert.equal(r.ownerDelegable, false);
    const d = await dm(broker, DELEGATE, text);
    assert.equal(d.outcome, "error");
    assert.ok(d.reasons[0]!.startsWith(`${NOT_APPROVER} (owner delegation is off: `), d.reasons[0]);
    assert.match(d.reasons[0]!, re);
    assert.equal(calls.length, 0);
    assert.equal((await dm(broker, OWNER, text, "1000003")).outcome, "issued");
  }
  assert.deepEqual(ownerDelegatesProblems({ ...allowlist(), ownerDelegates: [] } as unknown as Allowlist), ["ownerDelegates: must be an object"]);
});

test("feature off: without the block nothing changes, even with a valid grant file on the host", async () => {
  const { broker, calls, audit, source } = setup({ list: withoutBlock() });
  assert.deepEqual(source.load(NOW), { grants: [], problems: ["the allowlist has no ownerDelegates block"] });
  const { r, text } = await pend(broker);
  assert.ok(!("ownerDelegable" in r), "the pending reply has no new key");
  assert.equal(r.approver, OWNER);
  const d = await dm(broker, DELEGATE, text);
  assert.deepEqual(d, { requestId: r.requestId, outcome: "error", reasons: [NOT_APPROVER] });
  assert.equal(calls.length, 0);
  const ok = await dm(broker, OWNER, text, "1000003");
  assert.equal(ok.outcome, "issued");
  assert.ok(!("ownerNotice" in ok));
  assert.equal(ok.reasons.at(-1), `approved by ${OWNER}`);
  assert.ok(!audit().some((l) => "ownerDelegation" in l));
  // The request's policy and digest don't depend on the block at all.
  const who: Principal = { name: WORKER, address: WORKER, kind: "agent", agentId: agents[WORKER]!.id, workspaceId: WS };
  assert.deepEqual(decide(secretsReq(), who, allowlist(), { namespace: "token-rotation-0a1b2c3d" }), decide(secretsReq(), who, withoutBlock(), { namespace: "token-rotation-0a1b2c3d" }));
  const on = setup();
  assert.equal((await pend(on.broker)).r.policyDigest, r.policyDigest);
});

test("a broker given no grant source grants nothing", async () => {
  assert.deepEqual(noOwnerDelegates.load(NOW), { grants: [], problems: ["no owner-delegate source is configured"] });
  const dir = mkdtempSync(join(tmpdir(), "broker-owner-delegates-"));
  clock = NOW;
  const broker = new Broker({ allowlist: allowlist(), stateDir: join(dir, "state"), sts: { assumeRole: async () => assert.fail("nothing is issued") }, deliverer: defaultDeliverer(join(dir, "creds")), now: () => NOW, newId: () => "cb-000000000001", newNamespaceSuffix: () => "0a1b2c3d" });
  const { r, text } = await pend(broker);
  assert.equal(r.ownerDelegable, false);
  assert.equal((await dm(broker, DELEGATE, text)).reasons[0], `${NOT_APPROVER} (owner-delegate grants unavailable: no owner-delegate source is configured)`);
});

test("happy path: an agent whose Relay agent id has a live grant approves by its own DM; the audit line and the owner notice say so", async () => {
  const { broker, calls, audit } = setup();
  const { r, text } = await pend(broker);
  assert.equal(r.approver, OWNER, "the approver to ask is still the human");
  assert.equal(r.ownerDelegable, true);
  assert.ok(!r.approvalPrompt!.includes(DELEGATE), "the prompt names no delegate");
  const ok = await dm(broker, DELEGATE, text);
  assert.equal(ok.outcome, "issued", ok.reasons.join("; "));
  assert.equal(ok.reasons.at(-1), `approved by ${DELEGATE} (owner delegate of ${OWNER}, grant until 2026-12-01T00:00:00Z)`);
  assert.equal(
    ok.ownerNotice,
    `AWS credential request ${r.requestId} from ${WORKER} for account ${HOSTS} (${shipped.accounts[HOSTS]!.label}) was approved in your name by your owner delegate ${DELEGATE} (Relay agent id ${DELEGATE_ID}, grant until 2026-12-01T00:00:00Z); credentials expire 2026-11-15T22:15:00.000Z. Not yours? Remove that agent id from the broker host's owner-delegates file.`,
  );
  assert.ok(!ok.ownerNotice!.includes("\n"), "one line");
  assert.equal(calls.length, 1);
  const approved = audit().find((l) => l.kind === "approved")!;
  assert.equal(approved.requestId, r.requestId);
  assert.equal(approved.policyDigest, r.policyDigest);
  assert.equal(approved.relayMessageId, "1000002");
  assert.equal(approved.approver!.name, DELEGATE);
  assert.deepEqual(approved.ownerDelegation, { agentId: DELEGATE_ID, grantedBy: OWNER, expiresAt: "2026-12-01T00:00:00Z", source: "host-file" });
  assert.ok(!("delegation" in approved));
  assert.equal(audit().find((l) => l.kind === "issued")!.requestId, r.requestId);
});

test("the owner is told even when the approval was taken and issuing then failed", async () => {
  const { broker } = setup({ sts: { assumeRole: async () => Promise.reject(new Error("AccessDenied")) } });
  const { r, text } = await pend(broker);
  const d = await dm(broker, DELEGATE, text);
  assert.notEqual(d.outcome, "issued");
  assert.match(d.ownerNotice!, new RegExp(`^AWS credential request ${r.requestId} from ${WORKER} .* by your owner delegate ${DELEGATE} .*; no credentials were issued \\(`));
});

test("the grant file grants nothing, with the reason, unless it is the owner's: missing, unreadable, bad JSON, wrong shape, version or grantedBy, not root's, writable by others, a symlink", async (t) => {
  const cases: { name: string; file?: string | false; facts?: (fd: number) => FileFacts; arrange?: (path: string, dir: string) => void; why: RegExp; skip?: boolean }[] = [
    { name: "missing", file: false, why: /owner-delegates\.json is missing$/ },
    { name: "unreadable", arrange: (p) => chmodSync(p, 0o000), why: /owner-delegates\.json is unreadable \(EACCES\)$/, skip: process.getuid?.() === 0 },
    { name: "bad JSON", file: "{ version: 1", why: /is not valid JSON$/ },
    { name: "empty", file: "", why: /is not valid JSON$/ },
    { name: "a list", file: JSON.stringify([grant()]), why: /is not a JSON object$/ },
    { name: "version 2", file: grantFileBody([grant()], { version: 2 }), why: /version must be 1$/ },
    { name: "version as text", file: grantFileBody([grant()], { version: "1" }), why: /version must be 1$/ },
    { name: "no version", file: JSON.stringify({ grantedBy: OWNER, delegates: [grant()] }), why: /version must be 1$/ },
    { name: "granted by someone else", file: grantFileBody([grant()], { grantedBy: "some-other-agent" }), why: /grantedBy is not khaliq-gant, the allowlist's ownerDelegates\.grantedBy$/ },
    { name: "granted by the delegate itself", file: grantFileBody([grant()], { grantedBy: DELEGATE }), why: /grantedBy is not khaliq-gant/ },
    { name: "no grantedBy", file: JSON.stringify({ version: 1, delegates: [grant()] }), why: /grantedBy is not khaliq-gant/ },
    { name: "delegates not a list", file: grantFileBody([], { delegates: { [DELEGATE_ID]: grant() } }), why: /delegates must be a list$/ },
    { name: "not owned by root", facts: (fd) => ({ ...fileFacts(fd), uid: 1000 }), why: /is not owned by root$/ },
    { name: "owned by whoever runs this test", facts: fileFacts, why: /is not owned by root$/, skip: process.getuid?.() === 0 },
    { name: "writable by group", arrange: (p) => chmodSync(p, 0o664), why: /is writable by group or others$/ },
    { name: "writable by others", arrange: (p) => chmodSync(p, 0o646), why: /is writable by group or others$/ },
    {
      name: "a symlink to a good file",
      arrange: (p, dir) => {
        writeFileSync(join(dir, "real.json"), grantFileBody());
        rmSync(p);
        symlinkSync(join(dir, "real.json"), p);
      },
      why: /is a symlink$/,
    },
    {
      name: "a directory",
      arrange: (p) => {
        rmSync(p);
        mkdirSync(p);
      },
      why: /is not a regular file$/,
    },
    { name: "too large", file: grantFileBody([grant()], { padding: "x".repeat(70_000) }), why: /is too large to be a grant file$/ },
  ];
  for (const c of cases) {
    await t.test(c.name, { skip: c.skip }, async () => {
      const { broker, calls, source, grantFile, dir } = setup({ file: c.file, facts: c.facts });
      c.arrange?.(grantFile, dir);
      const loaded = source.load(NOW);
      assert.deepEqual(loaded.grants, []);
      assert.equal(loaded.problems.length, 1);
      assert.match(loaded.problems[0]!, c.why);
      const { r, text } = await pend(broker);
      assert.equal(r.ownerDelegable, false);
      assert.equal(r.approver, OWNER);
      const d = await dm(broker, DELEGATE, text);
      assert.equal(d.outcome, "error");
      assert.equal(d.reasons[0], `${NOT_APPROVER} (owner-delegate grants unavailable: ${loaded.problems[0]})`);
      assert.ok(!("ownerNotice" in d));
      assert.equal(calls.length, 0);
      // The request is still pending and Khaliq's own DM still approves it.
      assert.equal((await dm(broker, OWNER, text, "1000003")).outcome, "issued");
    });
  }
});

test("one bad entry is dropped and the others stay: no or empty agent id, expired, past 30 days, listed twice, a malformed expiry", async () => {
  const good = grant();
  const file = grantFileBody([
    good,
    { expiresAt: "2026-12-01T00:00:00Z" },
    { agentId: "", expiresAt: "2026-12-01T00:00:00Z" },
    { agentId: DELEGATE, expiresAt: "2026-12-01T00:00:00Z" },
    grant("300000000000000011", "2026-11-15T21:59:59Z"),
    grant("300000000000000012", "2026-11-15T22:00:00Z"),
    grant("300000000000000013", "2026-12-15T22:00:01Z"),
    grant("300000000000000014"),
    grant("300000000000000014", "2026-11-20T00:00:00Z"),
    grant("300000000000000015", "2026-12-01"),
    grant("300000000000000016", "next week"),
    { agentId: "300000000000000017" },
    "300000000000000018",
    null,
    grant("300000000000000019", "2026-12-15T22:00:00Z"),
  ]);
  const { broker, source, grantFile } = setup({ file });
  const loaded = source.load(NOW);
  assert.deepEqual(loaded.grants, [
    { agentId: DELEGATE_ID, expiresAt: "2026-12-01T00:00:00Z", grantedBy: OWNER, source: "host-file" },
    { agentId: "300000000000000019", expiresAt: "2026-12-15T22:00:00Z", grantedBy: OWNER, source: "host-file" },
  ]);
  const at = (i: number, why: string) => `${grantFile}: delegates[${i}] dropped: ${why}`;
  assert.deepEqual(loaded.problems, [
    at(1, "agentId must be a Relay agent id"),
    at(2, "agentId must be a Relay agent id"),
    at(3, "agentId must be a Relay agent id"),
    at(4, "expired at 2026-11-15T21:59:59Z"),
    at(5, "expired at 2026-11-15T22:00:00Z"),
    at(6, "expiresAt is more than 30 days away"),
    at(7, "its agentId is listed more than once"),
    at(8, "its agentId is listed more than once"),
    at(9, "expiresAt must be an ISO 8601 UTC time"),
    at(10, "expiresAt must be an ISO 8601 UTC time"),
    at(11, "expiresAt must be an ISO 8601 UTC time"),
    at(12, "not an object"),
    at(13, "not an object"),
  ]);
  assert.ok(!loaded.problems.join("\n").includes("placeholder"), "a problem never repeats a note");
  // The good entry still approves.
  const { r, text } = await pend(broker);
  assert.equal(r.ownerDelegable, true);
  assert.equal((await dm(broker, DELEGATE, text)).outcome, "issued");

  // An agent whose own entry was dropped has no grant: expired, too far out, or listed twice.
  for (const entries of [[grant(DELEGATE_ID, "2026-11-15T22:00:00Z")], [grant(DELEGATE_ID, "2026-12-16T00:00:00Z")], [grant(), grant()], [grant(), grant(DELEGATE_ID, "2026-11-20T00:00:00Z"), grant("300000000000000019")]]) {
    const s = setup({ file: grantFileBody(entries) });
    const p = await pend(s.broker);
    const d = await dm(s.broker, DELEGATE, p.text);
    assert.equal(d.outcome, "error", JSON.stringify(entries));
    assert.match(d.reasons[0]!, entries.length === 3 ? /\(no owner-delegate grant for this agent id\)$/ : /\(owner-delegate grants unavailable: .* dropped: /);
    assert.equal(s.calls.length, 0);
  }
});

test("a grant ends at its expiry: the same file approves a minute before and not at the time", async () => {
  const file = grantFileBody([grant(DELEGATE_ID, "2026-11-20T00:00:00Z")]);
  const before = setup({ file, now: new Date("2026-11-19T23:59:00Z") });
  assert.equal((await dm(before.broker, DELEGATE, (await pend(before.broker)).text)).outcome, "issued");
  const after = setup({ file, now: new Date("2026-11-20T00:00:00Z") });
  const { r, text } = await pend(after.broker);
  assert.equal(r.ownerDelegable, false);
  assert.match((await dm(after.broker, DELEGATE, text)).reasons[0]!, /grants unavailable: .* dropped: expired at 2026-11-20T00:00:00Z\)$/);
  assert.equal((await dm(after.broker, OWNER, text, "1000003")).outcome, "issued");
});

test("the grant is bound to the Relay agent id, never the name: the right name under another id can't approve, and no reason names a delegate", async () => {
  // The file grants another id; the agent that DMs is called some-delegate all the same.
  const { broker, calls, audit } = setup({ file: grantFileBody([grant("300000000000000008")]) });
  const { r, text } = await pend(broker);
  assert.equal(r.ownerDelegable, true, "some agent could approve it; not this one");
  const d = await dm(broker, DELEGATE, text);
  assert.equal(d.outcome, "error");
  assert.equal(d.reasons[0], `${NOT_APPROVER} (no owner-delegate grant for this agent id)`);
  assert.equal(calls.length, 0);
  assert.equal(audit().at(-1)!.kind, "approval-rejected");
  // A grant for some-delegate's id is no use to another agent, whatever it is called.
  const other = setup();
  const p = await pend(other.broker);
  assert.match((await dm(other.broker, "some-other-agent", p.text)).reasons[0]!, /^some-other-agent \(agent\) is not an approver: .* \(no owner-delegate grant for this agent id\)$/);
  // A message under the delegate's name from another agent's id never reaches the rule.
  const spoof = await other.broker.decideViaRelay(fakeRelay([msg("1000004", DELEGATE, p.text, { agentId: agents["some-other-agent"]!.id, channelId: toBroker("some-other-agent") })]), "1000004", BROKER);
  assert.match(spoof.reasons[0]!, /doesn't resolve/);
  assert.equal(other.calls.length, 0);
});

test("an owner delegate never approves its own request", async () => {
  const { broker, calls } = setup();
  const { r, text } = await pend(broker, secretsReq(), DELEGATE);
  assert.equal(r.ownerDelegable, false, "the only grant is the requester's own");
  const d = await dm(broker, DELEGATE, text);
  assert.equal(d.outcome, "error");
  assert.equal(d.reasons[0], "a requester cannot approve its own request");
  assert.equal(calls.length, 0);
  // By agent id as well as by name: the same agent under another name is still the requester.
  const req = secretsReq();
  const pending = decide(req, { name: WORKER, address: WORKER, kind: "agent", agentId: DELEGATE_ID, workspaceId: WS }, allowlist(), { namespace: "token-rotation-0a1b2c3d" });
  assert.equal(pending.outcome, "approval");
  if (pending.outcome !== "approval") return;
  const live: OwnerDelegateGrants = { grants: [{ agentId: DELEGATE_ID, expiresAt: "2026-12-01T00:00:00Z", grantedBy: OWNER, source: "host-file" }], problems: [] };
  const c = checkOwnerDelegateApproval({ request: req, requester: { name: WORKER, address: WORKER, kind: "agent", agentId: DELEGATE_ID }, sessionPolicy: pending.sessionPolicy }, { name: DELEGATE, address: DELEGATE, kind: "agent", agentId: DELEGATE_ID }, allowlist(), live, NOW, BROKER);
  assert.deepEqual(c, { ok: false, reason: "a requester cannot approve its own request" });
  // With a second delegate on file, another one can approve the first one's request.
  const two = setup({ file: grantFileBody([grant(), grant(agents["some-other-agent"]!.id)]) });
  const p = await pend(two.broker, secretsReq(), DELEGATE);
  assert.equal(p.r.ownerDelegable, true);
  assert.equal((await dm(two.broker, "some-other-agent", p.text)).outcome, "issued");
});

test("the broker's own Relay identity is never an owner delegate, and a grant counts only on a Relay-verified message", async () => {
  // A grant for the broker's own agent id: its own message is refused by the Relay check before any rule.
  const { broker, calls } = setup({ file: grantFileBody([grant(BROKER_ID)]) });
  const { text } = await pend(broker);
  const own = await broker.decideViaRelay(fakeRelay([msg("1000002", BROKER, text, { channelId: toBroker(WORKER) })]), "1000002", BROKER);
  assert.notEqual(own.outcome, "issued");
  assert.match(own.reasons[0]!, /broker sent itself/);
  // And the rule itself refuses it, were such a message ever verified.
  const req = secretsReq();
  const requester: Principal = { name: WORKER, address: WORKER, kind: "agent", agentId: agents[WORKER]!.id, workspaceId: WS };
  const pending = decide(req, requester, allowlist(), { namespace: "token-rotation-0a1b2c3d" });
  assert.equal(pending.outcome, "approval");
  if (pending.outcome !== "approval") return;
  const p = { request: req, requester, sessionPolicy: pending.sessionPolicy };
  const live = (id: string): OwnerDelegateGrants => ({ grants: [{ agentId: id, expiresAt: "2026-12-01T00:00:00Z", grantedBy: OWNER, source: "host-file" }], problems: [] });
  const asBroker = checkOwnerDelegateApproval(p, { name: BROKER, address: BROKER, kind: "agent", agentId: BROKER_ID }, allowlist(), live(BROKER_ID), NOW, BROKER);
  assert.deepEqual(asBroker, { ok: false, reason: `the broker's own Relay identity cannot approve as an owner delegate; needs ${OWNER}'s own DM` });
  // The same check passes for a delegate that is neither, so the refusals above are the rule's and not the fixture's.
  const delegate: Principal = { name: DELEGATE, address: DELEGATE, kind: "agent", agentId: DELEGATE_ID };
  assert.equal(checkOwnerDelegateApproval(p, delegate, allowlist(), live(DELEGATE_ID), NOW, BROKER).ok, true);
  // No verified agent id, no verified requester, or no Relay path (local mode): no owner-delegate approval.
  const noId = checkOwnerDelegateApproval(p, { name: DELEGATE, address: DELEGATE, kind: "agent" }, allowlist(), live(DELEGATE_ID), NOW, BROKER);
  assert.ok(!noId.ok && /only by a message the Relay server verified/.test(noId.reason));
  const local = checkOwnerDelegateApproval(p, delegate, allowlist(), live(DELEGATE_ID), NOW, undefined);
  assert.ok(!local.ok && /only by a message the Relay server verified/.test(local.reason));
  const unverifiedRequester = checkOwnerDelegateApproval({ ...p, requester: { name: WORKER, address: WORKER, kind: "agent" } }, delegate, allowlist(), live(DELEGATE_ID), NOW, BROKER);
  assert.ok(!unverifiedRequester.ok && /requester wasn't verified with the Relay server/.test(unverifiedRequester.reason));
  // A grant that isn't the owner's, is expired or runs too long is refused where it is used, whatever the source said.
  const from = (over: object) => checkOwnerDelegateApproval(p, delegate, allowlist(), { grants: [{ ...live(DELEGATE_ID).grants[0]!, ...over }], problems: [] }, NOW, BROKER);
  for (const [over, re] of [
    [{ grantedBy: "some-other-agent" }, /grant is not khaliq-gant's from host-file/],
    [{ source: "somewhere-else" }, /grant is not khaliq-gant's from host-file/],
    [{ expiresAt: "2026-11-15T22:00:00Z" }, /grant expired at/],
    [{ expiresAt: "not a time" }, /grant expired at/],
    [{ expiresAt: "2026-12-16T00:00:00Z" }, /runs past 30 days/],
  ] as [object, RegExp][]) {
    const c = from(over);
    assert.ok(!c.ok && re.test(c.reason), JSON.stringify(over));
  }
  // Local mode on the broker itself: approve() without the Relay path never uses a grant.
  const s = setup();
  const pp = await pend(s.broker);
  const direct = await s.broker.approve(pp.r.requestId, pp.r.policyDigest!, { name: DELEGATE, address: DELEGATE, kind: "agent", agentId: DELEGATE_ID });
  assert.equal(direct.reasons[0], `${NOT_APPROVER} (an owner delegate approves only by a message the Relay server verified)`);
  assert.equal(calls.length + s.calls.length, 0);
});

test("IAM, identity and audit controls, deletes and wildcards are never an owner delegate's to approve; Khaliq's own DM still is", async () => {
  const cases: [Partial<CredentialRequest>, RegExp][] = [
    [{ actions: ["iam:PassRole"], resources: [`arn:aws:iam::${HOSTS}:role/some-role`] }, /iam:PassRole is IAM/],
    [{ actions: ["secretsmanager:GetSecretValue", "iam:GetRole"] }, /iam:GetRole is IAM/],
    [{ actions: ["kms:PutKeyPolicy"], resources: [`arn:aws:kms:us-east-1:${HOSTS}:key/11111111-2222-3333-4444-555555555555`] }, /kms:PutKeyPolicy is an identity or audit control/],
    [{ actions: ["cloudtrail:StopLogging"], resources: [`arn:aws:cloudtrail:us-east-1:${HOSTS}:trail/some-trail`] }, /cloudtrail:StopLogging is an identity or audit control/],
    [{ actions: ["secretsmanager:DeleteSecret"] }, /secretsmanager:DeleteSecret deletes/],
    [{ actions: ["ec2:TerminateInstances"], resources: [INSTANCE] }, /ec2:TerminateInstances deletes/],
    [{ actions: ["secretsmanager:Get*"] }, /secretsmanager:Get\* is a wildcard/],
    [{ actions: ["secretsmanager:*"] }, /secretsmanager:\* is a wildcard/],
    [{ resources: [`arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:infra-ops/*`] }, /resource .*infra-ops\/\* is a wildcard/],
    [{ resources: [`arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:infra-ops/some-token-??????`] }, /is a wildcard/],
    [{ resources: undefined }, /is not on literal resources/],
  ];
  for (const [over, re] of cases) {
    const { broker, calls, audit } = setup();
    const { r, text } = await pend(broker, secretsReq(over));
    assert.equal(r.ownerDelegable, false, JSON.stringify(over));
    assert.equal(r.approver, OWNER);
    const d = await dm(broker, DELEGATE, text);
    assert.equal(d.outcome, "error", JSON.stringify(over));
    assert.match(d.reasons[0]!, re, JSON.stringify(over));
    assert.match(d.reasons[0]!, new RegExp(`^owner delegates cannot approve this: .*; needs ${OWNER}'s own DM$`), JSON.stringify(over));
    assert.ok(!d.reasons[0]!.includes(DELEGATE), "the reason names no delegate");
    assert.ok(!("ownerNotice" in d));
    assert.equal(calls.length, 0);
    assert.ok(!audit().some((l) => l.kind === "approved"));
    // Still pending: the owner's own DM approves it.
    const ok = await dm(broker, OWNER, text, "1000003");
    assert.equal(ok.outcome, "issued", JSON.stringify(over));
    assert.equal(calls.length, 1);
  }
});

test("letter case never gets a delete past an owner delegate: IAM ignores an action's case, and so does the deletes limit", async () => {
  // kms:ScheduleKeyDeletion is also on approvalOnly. Without that entry the deletes limit has to hold on its own.
  const noKmsEntry = allowlist();
  noKmsEntry.approvalOnly = noKmsEntry.approvalOnly.filter((a) => a !== "kms:ScheduleKeyDeletion");
  const KEY = `arn:aws:kms:us-east-1:${HOSTS}:key/11111111-2222-3333-4444-555555555555`;
  const cases: [Partial<CredentialRequest>, string, Allowlist?][] = [
    [{ actions: ["secretsmanager:deletesecret"] }, "secretsmanager:deletesecret deletes"],
    [{ actions: ["secretsmanager:GetSecretValue", "secretsmanager:dELETEsECRET"] }, "secretsmanager:dELETEsECRET deletes"],
    [{ actions: ["ec2:TERMINATEINSTANCES"], resources: [INSTANCE] }, "ec2:TERMINATEINSTANCES deletes"],
    [{ actions: ["kms:scheduleKeyDELETION"], resources: [KEY] }, "kms:scheduleKeyDELETION deletes", noKmsEntry],
    [{ actions: ["secretsmanager:untagresource"] }, "secretsmanager:untagresource deletes"],
  ];
  for (const [over, why, list] of cases) {
    const { broker, calls, audit } = setup({ list });
    const { r, text } = await pend(broker, secretsReq(over));
    assert.equal(r.ownerDelegable, false, JSON.stringify(over));
    assert.equal(r.approver, OWNER);
    const d = await dm(broker, DELEGATE, text);
    assert.equal(d.outcome, "error", JSON.stringify(over));
    assert.equal(d.reasons[0], `owner delegates cannot approve this: ${why}; needs ${OWNER}'s own DM`);
    assert.ok(!("ownerNotice" in d));
    assert.equal(calls.length, 0);
    assert.ok(!audit().some((l) => l.kind === "approved"));
    // Still pending: the owner's own DM approves it.
    assert.equal((await dm(broker, OWNER, text, "1000003")).outcome, "issued", JSON.stringify(over));
    assert.equal(calls.length, 1);
  }
  // The rule itself, on the request and on the session policy's allowed actions.
  const policy = (action: string) => ({ Version: "2012-10-17" as const, Statement: [{ Sid: "x", Effect: "Allow" as const, Action: [action], Resource: TOKEN_SECRET }] });
  for (const a of ["secretsmanager:deletesecret", "ec2:terminateinstances", "s3:REMOVEsomething", "sqs:purgequeue", "x:destroyThing", "kms:SCHEDULEkeyDELETION"]) {
    assert.match(ownerDelegableProblem({ request: secretsReq({ actions: [a] }), sessionPolicy: policy(a) }, noKmsEntry) ?? "", new RegExp(`: ${a} deletes; `), a);
    assert.match(ownerDelegableProblem({ request: secretsReq(), sessionPolicy: policy(a) }, noKmsEntry) ?? "", new RegExp(`: ${a} deletes; `), `${a} in the session policy only`);
  }
  // A write that is not a delete is still an owner delegate's to approve.
  assert.equal(ownerDelegableProblem({ request: secretsReq({ actions: ["secretsmanager:putsecretvalue"] }), sessionPolicy: policy("secretsmanager:putsecretvalue") }, noKmsEntry), undefined);
});

test("a named pipe at the grant path grants nothing and never blocks the broker; a regular file there reads as before", async (t) => {
  const { broker, calls, source, grantFile, list } = setup({ file: false });
  try {
    execFileSync("mkfifo", [grantFile], { stdio: "ignore" });
  } catch {
    t.skip("mkfifo is unavailable");
    return;
  }
  const problem = `${grantFile} is not a regular file`;
  // In its own process first, with a time limit: opening a pipe that has no writer blocks for ever unless the open is non-blocking.
  const cli = new URL("../broker/src/cli.ts", import.meta.url).pathname;
  const env: NodeJS.ProcessEnv = { ...process.env, BROKER_STATE_DIR: join(grantFile, "..", "cli-state"), BROKER_DELIVERY_DIR: join(grantFile, "..", "cli-creds"), BROKER_OWNER_DELEGATES_FILE: grantFile };
  delete env.BROKER_RELAY_TOKEN_FILE;
  const started = Date.now();
  const out = JSON.parse(execFileSync(process.execPath, ["--no-warnings", cli, "owner-delegates"], { env, encoding: "utf8", timeout: 15_000 })) as { valid: number; problems: string[] };
  assert.deepEqual({ valid: out.valid, problems: out.problems }, { valid: 0, problems: [problem] });
  assert.ok(Date.now() - started < 15_000);
  // In this process, and through the broker: the request stays the owner's to approve.
  assert.deepEqual(source.load(NOW), { grants: [], problems: [problem] });
  const { r, text } = await pend(broker);
  assert.equal(r.ownerDelegable, false);
  const d = await dm(broker, DELEGATE, text);
  assert.equal(d.outcome, "error");
  assert.equal(d.reasons[0], `${NOT_APPROVER} (owner-delegate grants unavailable: ${problem})`);
  assert.equal(calls.length, 0);
  assert.equal((await dm(broker, OWNER, text, "1000003")).outcome, "issued");
  // A regular file at the same path is read exactly as before.
  rmSync(grantFile);
  writeFileSync(grantFile, grantFileBody());
  chmodSync(grantFile, 0o644);
  assert.deepEqual(hostFileSource(grantFile, list, asRoot).load(NOW), { grants: [{ agentId: DELEGATE_ID, expiresAt: "2026-12-01T00:00:00Z", grantedBy: OWNER, source: "host-file" }], problems: [] });
});

/** A command on one named instance in a region no automatic rule covers: it needs an approval. */
const WEST_INSTANCE =`arn:aws:ec2:us-west-2:${HOSTS}:instance/i-0123456789abcdef0`;
const commandReq = (over: Partial<CredentialRequest> = {}): CredentialRequest =>
  secretsReq({ purpose: "run one command on the host", actions: ["ssm:SendCommand"], resources: [WEST_INSTANCE, "arn:aws:ssm:us-west-2::document/AWS-RunShellScript"], regions: ["us-west-2"], runTag: "one-command", ...over });

test("notDelegable: a command on a host is never an owner delegate's to approve, by exact action or by glob; Khaliq's own DM still is", async () => {
  assert.ok(shipped.ownerDelegates!.notDelegable!.includes("ssm:SendCommand"));
  assert.ok(shipped.ownerDelegates!.notDelegable!.includes("ec2-instance-connect:*"));
  const cases: [Partial<CredentialRequest>, string][] = [
    [{}, "ssm:SendCommand"],
    [{ actions: ["ssm:StartSession"], resources: [WEST_INSTANCE] }, "ssm:StartSession"],
    [{ actions: ["ssm:DescribeInstanceInformation", "ssm:sendcommand"] }, "ssm:sendcommand"],
    [{ actions: ["ec2-instance-connect:SendSSHPublicKey"], resources: [WEST_INSTANCE] }, "ec2-instance-connect:SendSSHPublicKey"],
    [{ actions: ["ec2:ModifyInstanceAttribute"], resources: [WEST_INSTANCE] }, "ec2:ModifyInstanceAttribute"],
  ];
  for (const [over, action] of cases) {
    const { broker, calls, audit } = setup();
    const { r, text } = await pend(broker, commandReq(over));
    assert.equal(r.ownerDelegable, false, action);
    assert.equal(r.approver, OWNER);
    const d = await dm(broker, DELEGATE, text);
    assert.equal(d.outcome, "error", action);
    assert.equal(d.reasons[0], `owner delegates cannot approve this: ${action} is beyond an owner delegate (ownerDelegates.notDelegable); needs ${OWNER}'s own DM`);
    assert.ok(!("ownerNotice" in d));
    assert.equal(calls.length, 0);
    assert.ok(!audit().some((l) => l.kind === "approved"));
    const ok = await dm(broker, OWNER, text, "1000003");
    assert.equal(ok.outcome, "issued", action);
    assert.ok(!("ownerNotice" in ok));
  }
  // The fixed limits are checked first, so their reasons stay.
  const fixed = setup();
  const pf = await pend(fixed.broker, commandReq({ actions: ["ssm:SendCommand", "iam:PassRole"] }));
  assert.match((await dm(fixed.broker, DELEGATE, pf.text)).reasons[0]!, /^owner delegates cannot approve this: iam:PassRole is IAM; /);
  // The session policy is checked as well as the request: an allowed action on the list is refused whatever was asked.
  const stmt = { Version: "2012-10-17" as const, Statement: [{ Sid: "Requested", Effect: "Allow" as const, Action: ["ssm:GetCommandInvocation", "SSM:SendCommand"], Resource: [WEST_INSTANCE] }] };
  assert.match(ownerDelegableProblem({ request: secretsReq(), sessionPolicy: stmt }, allowlist())!, /SSM:SendCommand is beyond an owner delegate \(ownerDelegates\.notDelegable\)/);
  // An action that only looks alike is not on the list.
  const near = setup();
  const pn = await pend(near.broker, commandReq({ actions: ["ssm:PutParameter"], resources: [`arn:aws:ssm:us-west-2:${HOSTS}:parameter/some/name`] }));
  assert.equal(pn.r.ownerDelegable, true);
  assert.equal((await dm(near.broker, DELEGATE, pn.text)).outcome, "issued");
});

test("notDelegable: a block without the key has only the fixed limits, as before", async () => {
  const list = allowlist();
  delete list.ownerDelegates!.notDelegable;
  assert.deepEqual(ownerDelegatesProblems(list), []);
  const { broker, calls } = setup({ list });
  const { r, text } = await pend(broker, commandReq());
  assert.equal(r.ownerDelegable, true);
  const ok = await dm(broker, DELEGATE, text);
  assert.equal(ok.outcome, "issued", ok.reasons.join("; "));
  assert.match(ok.ownerNotice!, /by your owner delegate /);
  assert.equal(calls.length, 1);
  // The fixed limits are still there.
  const iam = setup({ list });
  const pi = await pend(iam.broker, secretsReq({ actions: ["iam:PassRole"], resources: [`arn:aws:iam::${HOSTS}:role/some-role`] }));
  assert.equal(pi.r.ownerDelegable, false);
  assert.match((await dm(iam.broker, DELEGATE, pi.text)).reasons[0]!, /iam:PassRole is IAM/);
});

test("notDelegable: a list that can't be read as written is a config problem and owner delegation is off, never a list that guards nothing", async () => {
  const bad: [unknown, RegExp][] = [
    [[], /notDelegable must be a non-empty list of actions/],
    ["ssm:SendCommand", /notDelegable must be a non-empty list of actions/],
    [null, /notDelegable must be a non-empty list of actions/],
    [{ "ssm:SendCommand": true }, /notDelegable must be a non-empty list of actions/],
    [["ssm:SendCommand", 5], /notDelegable 5 is not service:Action/],
    [["ssm:SendCommand", ["ssm:StartSession"]], /notDelegable \["ssm:StartSession"\] is not service:Action/],
    [["SendCommand"], /notDelegable "SendCommand" is not service:Action/],
    [["ssm:SendCommand", ""], /notDelegable "" is not service:Action/],
    [["ssm:Send?ommand"], /notDelegable "ssm:Send\?ommand" is not service:Action/],
    [["*"], /notDelegable "\*" is not service:Action/],
  ];
  for (const [value, re] of bad) {
    const list = allowlist();
    (list.ownerDelegates as unknown as Record<string, unknown>).notDelegable = value;
    assert.match(ownerDelegatesProblems(list).join("; "), re, JSON.stringify(value));
    const { broker, calls, source } = setup({ list });
    assert.deepEqual(source.load(NOW).grants, [], JSON.stringify(value));
    // Off for every request, not only the ones the list was meant to catch.
    const { r, text } = await pend(broker);
    assert.equal(r.ownerDelegable, false, JSON.stringify(value));
    const d = await dm(broker, DELEGATE, text);
    assert.equal(d.outcome, "error", JSON.stringify(value));
    assert.ok(d.reasons[0]!.startsWith(`${NOT_APPROVER} (owner delegation is off: `), d.reasons[0]);
    assert.match(d.reasons[0]!, re);
    assert.equal(calls.length, 0);
    assert.equal((await dm(broker, OWNER, text, "1000003")).outcome, "issued");
  }
  // A sound list with a glob is fine.
  const ok = allowlist();
  ok.ownerDelegates!.notDelegable = ["ssm:Send*", "ec2-instance-connect:*"];
  assert.deepEqual(ownerDelegatesProblems(ok), []);
  assert.match(ownerDelegableProblem({ request: commandReq(), sessionPolicy: { Version: "2012-10-17", Statement: [] } }, ok)!, /ssm:SendCommand is beyond an owner delegate/);
});

test("never-issue actions never reach an approver at all, and the owner-delegate rule refuses them on its own", () => {
  const list = allowlist();
  const who: Principal = { name: WORKER, address: WORKER, kind: "agent", agentId: agents[WORKER]!.id, workspaceId: WS };
  for (const action of ["sts:AssumeRole", "organizations:ListAccounts", "iam:CreateAccessKey"]) {
    const req = secretsReq({ actions: [action], resources: [`arn:aws:iam::${HOSTS}:role/some-role`] });
    assert.equal(decide(req, who, list, { namespace: "token-rotation-0a1b2c3d" }).outcome, "deny", action);
    // The rule's own answer, on the request and on a session policy that allows the action.
    const plain = { Version: "2012-10-17" as const, Statement: [{ Sid: "Requested", Effect: "Allow" as const, Action: [action], Resource: [TOKEN_SECRET] }] };
    assert.match(ownerDelegableProblem({ request: req, sessionPolicy: plain }, list)!, /is never issued|is IAM/, action);
    assert.match(ownerDelegableProblem({ request: secretsReq(), sessionPolicy: plain }, list)!, /is never issued|is IAM/, action);
  }
  // A session policy that isn't plain allows on literal resources is refused whatever the request says.
  const req = secretsReq();
  const stmt = (over: object) => ({ Version: "2012-10-17" as const, Statement: [{ Sid: "Requested", Effect: "Allow" as const, Action: ["secretsmanager:PutSecretValue"], Resource: [TOKEN_SECRET], ...over }] });
  assert.equal(ownerDelegableProblem({ request: req, sessionPolicy: stmt({}) }, list), undefined);
  assert.match(ownerDelegableProblem({ request: req, sessionPolicy: stmt({ Resource: "*" }) }, list)!, /secretsmanager:PutSecretValue on \* is not on literal resources/);
  assert.match(ownerDelegableProblem({ request: req, sessionPolicy: stmt({ Resource: undefined }) }, list)!, /is not on literal resources/);
  assert.match(ownerDelegableProblem({ request: req, sessionPolicy: stmt({ Action: undefined, NotAction: ["iam:*"] }) }, list)!, /statement Requested isn't a plain allow/);
  assert.match(ownerDelegableProblem({ request: req, sessionPolicy: stmt({ NotResource: [TOKEN_SECRET] }) }, list)!, /statement Requested isn't a plain allow/);
  assert.match(ownerDelegableProblem({ request: req, sessionPolicy: stmt({ Action: ["secretsmanager:PutSecretValue", "iam:PassRole"] }) }, list)!, /iam:PassRole is IAM/);
});

test("the approval is checked against today's allowlist and today's grants, not the ones the request was shown under", async () => {
  // The action became an identity or audit control after the request went pending: the delegate is refused, Khaliq is not.
  const a = setup();
  const pa = await pend(a.broker);
  assert.equal(pa.r.ownerDelegable, true);
  a.list.approvalOnly.push("secretsmanager:PutSecretValue");
  const da = await dm(a.broker, DELEGATE, pa.text);
  assert.match(da.reasons[0]!, /^owner delegates cannot approve this: secretsmanager:PutSecretValue is an identity or audit control; needs khaliq-gant's own DM$/);
  assert.equal(a.calls.length, 0);
  assert.equal((await dm(a.broker, OWNER, pa.text, "1000003")).outcome, "issued");

  // The grant was removed after the request went pending: the delegate no longer counts.
  const b = setup();
  const pb = await pend(b.broker);
  writeFileSync(b.grantFile, grantFileBody([]));
  assert.equal((await dm(b.broker, DELEGATE, pb.text)).reasons[0], `${NOT_APPROVER} (no owner-delegate grant for this agent id)`);
  rmSync(b.grantFile);
  assert.match((await dm(b.broker, DELEGATE, pb.text, "1000003")).reasons[0]!, /grants unavailable: .* is missing\)$/);
  // Put back, it counts again: nothing about a grant is cached.
  writeFileSync(b.grantFile, grantFileBody());
  assert.equal((await dm(b.broker, DELEGATE, pb.text, "1000004")).outcome, "issued");

  // The block was removed after the request went pending: exactly the old refusal.
  const c = setup();
  const pc = await pend(c.broker);
  delete c.list.ownerDelegates;
  assert.deepEqual((await dm(c.broker, DELEGATE, pc.text)).reasons, [NOT_APPROVER]);

  // The policy the request would get changed: an owner delegate's approval is refused like anyone's.
  const d = setup();
  const pd = await pend(d.broker);
  d.list.tagKey = "another-tag-key";
  const dd = await dm(d.broker, DELEGATE, pd.text);
  assert.equal(dd.outcome, "error");
  assert.match(dd.reasons[0]!, /policy changed since it was shown/);
  assert.equal(d.calls.length, 0);
  // The allowlist no longer allows the request at all: the same.
  const f = setup();
  const pf = await pend(f.broker);
  f.list.duration.maxMinutes = 10;
  const df = await dm(f.broker, DELEGATE, pf.text);
  assert.equal(df.outcome, "error");
  assert.match(df.reasons[0]!, /allowlist now refuses this request/);
  assert.ok(!("ownerNotice" in df));
  assert.equal(f.calls.length, 0);

  // A wrong digest, a stale approval window and a replayed message are refused for an owner delegate as for anyone.
  const e = setup();
  const pe = await pend(e.broker);
  assert.match((await dm(e.broker, DELEGATE, `approve ${pe.r.requestId} ${"0".repeat(16)}`)).reasons[0]!, /digest does not match/);
  const relay = fakeRelay([msg("1000003", DELEGATE, pe.text)]);
  assert.equal((await e.broker.decideViaRelay(relay, "1000003", BROKER)).outcome, "issued");
  assert.match((await e.broker.decideViaRelay(relay, "1000003", BROKER)).reasons[0]!, /already acted on/);
  assert.equal(e.calls.length, 1);
});

test("the grants are read again where the request is re-decided: one removed while the approval was being checked doesn't count", async () => {
  const live: OwnerDelegateGrants = { grants: [{ agentId: DELEGATE_ID, expiresAt: "2026-12-01T00:00:00Z", grantedBy: OWNER, source: "host-file" }], problems: [] };
  for (const [second, re] of [
    [{ grants: [], problems: [] }, /\(no owner-delegate grant for this agent id\)$/],
    [{ grants: [], problems: ["the file is missing"] }, /\(owner-delegate grants unavailable: the file is missing\)$/],
    [{ grants: [{ ...live.grants[0]!, expiresAt: "2026-11-15T22:00:00Z" }], problems: [] }, /^the owner-delegate grant expired at 2026-11-15T22:00:00Z; needs khaliq-gant's own DM$/],
  ] as [OwnerDelegateGrants, RegExp][]) {
    clock = NOW;
    const dir = mkdtempSync(join(tmpdir(), "broker-owner-delegates-"));
    // The pending reply reads the grants once (ownerDelegable); the approval reads them when it starts and again after the re-decide.
    let loads = 0;
    const source: OwnerDelegateSource = { kind: "host-file", where: "a test", load: () => (++loads <= 2 ? live : second) };
    const calls: unknown[] = [];
    const sts: StsClient = { assumeRole: async (input) => (calls.push(input), assert.fail("nothing is issued")) };
    const broker = new Broker({ allowlist: allowlist(), stateDir: join(dir, "state"), sts, deliverer: defaultDeliverer(join(dir, "creds")), now: () => NOW, newId: () => "cb-000000000001", newNamespaceSuffix: () => "0a1b2c3d", ownerDelegates: source });
    const { r, text } = await pend(broker);
    assert.equal(r.ownerDelegable, true);
    const d = await dm(broker, DELEGATE, text);
    assert.equal(loads, 3);
    assert.equal(d.outcome, "error");
    assert.match(d.reasons[0]!, re);
    assert.ok(!("ownerNotice" in d));
    assert.equal(calls.length, 0);
    const lines = readFileSync(broker.auditPath, "utf8");
    assert.ok(!lines.includes('"kind":"approved"') && lines.includes('"kind":"approval-rejected"'));
  }
});

test("only the delegate's own DM to the broker counts: channel posts, DMs elsewhere and stale messages are refused", async () => {
  const { broker, calls } = setup();
  const { text } = await pend(broker);
  const relay = fakeRelay([
    msg("1000002", DELEGATE, text, { channelId: "ch_general" }),
    msg("1000003", DELEGATE, text, { channelId: dmChannelId(WS, agents[DELEGATE]!.id, agents["some-other-agent"]!.id) }),
    msg("1000004", DELEGATE, text, { createdAt: new Date(NOW.getTime() - 16 * 60_000).toISOString() }),
    msg("1000005", "some-other-agent", `${OWNER} and ${DELEGATE} both said: ${text}`),
    msg("1000006", "some-other-agent", text),
  ]);
  assert.match((await broker.decideViaRelay(relay, "1000002", BROKER)).reasons[0]!, /not a channel post/);
  assert.match((await broker.decideViaRelay(relay, "1000003", BROKER)).reasons[0]!, /wasn't sent to layered-infra-ops/);
  assert.match((await broker.decideViaRelay(relay, "1000004", BROKER)).reasons[0]!, /last 15 minutes/);
  // A relayed approval: the words are right, the sender isn't.
  assert.notEqual((await broker.decideViaRelay(relay, "1000005", BROKER)).outcome, "issued");
  assert.match((await broker.decideViaRelay(relay, "1000006", BROKER)).reasons[0]!, /no owner-delegate grant for this agent id/);
  assert.equal(calls.length, 0);
});

test("an owner delegate's refuse doesn't count (as a delegated approver's doesn't); the owner's and the requester's still do", async () => {
  const { broker, audit } = setup();
  const { r, text } = await pend(broker);
  const refused = await dm(broker, DELEGATE, `refuse ${r.requestId}`);
  assert.deepEqual(refused, { requestId: r.requestId, outcome: "error", reasons: ["only an approver or the requester can refuse a pending request"] });
  assert.ok(!audit().some((l) => l.kind === "refused"));
  // Still pending: the delegate can approve it after all.
  assert.equal((await dm(broker, DELEGATE, text, "1000003")).outcome, "issued");
  const s = setup();
  const p = await pend(s.broker);
  assert.deepEqual((await dm(s.broker, OWNER, `refuse ${p.r.requestId}`)).reasons, [`refused by ${OWNER}`]);
  const w = setup();
  const q = await pend(w.broker);
  assert.deepEqual((await dm(w.broker, WORKER, `refuse ${q.r.requestId}`)).reasons, [`refused by ${WORKER}`]);
});

test("khaliq-gant's approval is unchanged with owner delegation on: no owner notice, no ownerDelegation in the audit", async () => {
  for (const over of [{}, { actions: ["iam:PassRole"], resources: [`arn:aws:iam::${HOSTS}:role/some-role`] }, { actions: ["secretsmanager:DeleteSecret"] }] as Partial<CredentialRequest>[]) {
    for (const file of [undefined, false as const, "not json"]) {
      const { broker, calls, audit } = setup({ file });
      const { text } = await pend(broker, secretsReq(over));
      const ok = await dm(broker, OWNER, text);
      assert.equal(ok.outcome, "issued", JSON.stringify(over));
      assert.equal(ok.reasons.at(-1), `approved by ${OWNER}`);
      assert.ok(!("ownerNotice" in ok));
      assert.ok(!("ownerDelegable" in ok));
      const approved = audit().find((l) => l.kind === "approved")!;
      assert.equal(approved.approver!.name, OWNER);
      assert.ok(!("ownerDelegation" in approved) && !("delegation" in approved));
      assert.equal(calls.length, 1);
    }
  }
  // A grant under the owner's own agent id changes nothing: he approves as the human he is.
  const { broker, audit } = setup({ file: grantFileBody([grant(agents[OWNER]!.id)]) });
  const { text } = await pend(broker, secretsReq({ actions: ["iam:PassRole"], resources: [`arn:aws:iam::${HOSTS}:role/some-role`] }));
  const ok = await dm(broker, OWNER, text);
  assert.equal(ok.outcome, "issued");
  assert.ok(!("ownerNotice" in ok));
  assert.ok(!("ownerDelegation" in audit().find((l) => l.kind === "approved")!));
});

test("the named delegatedApprovers rule is unchanged with owner delegation on, and an owner-delegate grant never widens it", async () => {
  const neon = (over: Partial<CredentialRequest> = {}) => secretsReq({ purpose: "neon exit: write the new database url", runTag: "neon-exit-cutover", resources: [NEON_SECRET, `arn:aws:secretsmanager:us-east-1:${HOSTS}:secret:infra-ops/supabase-management-token-Xy9Zq1`], delegate: NAMED, ...over });
  // Its own capability, exactly as before: delegation in the audit, no owner notice.
  const { broker, calls, audit } = setup();
  const { r, text } = await pend(broker, neon(), NAMED_REQUESTER);
  assert.equal(r.approver, NAMED);
  const ok = await dm(broker, NAMED, text);
  assert.equal(ok.outcome, "issued", ok.reasons.join("; "));
  assert.match(ok.reasons.at(-1)!, new RegExp(`^approved by ${NAMED} \\(delegated by ${OWNER}, capability `));
  assert.ok(!("ownerNotice" in ok));
  const approved = audit().find((l) => l.kind === "approved")!;
  assert.equal(approved.delegation!.delegate, NAMED);
  assert.ok(!("ownerDelegation" in approved));
  assert.equal(calls.length, 1);

  // Outside its capability it is refused by its own rule, even when its agent id also has an owner-delegate grant.
  const both = setup({ file: grantFileBody([grant(NAMED_ID), grant()]) });
  const out = await pend(both.broker, secretsReq(), NAMED_REQUESTER);
  assert.equal(out.r.ownerDelegable, true, "an owner delegate could approve it");
  const no = await dm(both.broker, NAMED, out.text);
  assert.equal(no.outcome, "error");
  assert.ok(!/owner/.test(no.reasons[0]!), no.reasons[0]);
  assert.equal(both.calls.length, 0);
  // The owner delegate, a different agent, can.
  const yes = await dm(both.broker, DELEGATE, out.text, "1000003");
  assert.equal(yes.outcome, "issued");
  assert.match(yes.ownerNotice!, new RegExp(`by your owner delegate ${DELEGATE} `));

  // A request that names the delegated approver can also be approved by an owner delegate: it is the owner's approval that stands in.
  const named = setup();
  const pn = await pend(named.broker, neon(), NAMED_REQUESTER);
  assert.equal(pn.r.approver, NAMED);
  assert.equal(pn.r.ownerDelegable, true);
  const viaOwner = await dm(named.broker, DELEGATE, pn.text);
  assert.equal(viaOwner.outcome, "issued");
  assert.deepEqual(named.audit().find((l) => l.kind === "approved")!.ownerDelegation, { agentId: DELEGATE_ID, grantedBy: OWNER, expiresAt: "2026-12-01T00:00:00Z", source: "host-file" });
});

test("cli.ts owner-delegates is read-only and prints the source, the file, the valid count and the problems", () => {
  const dir = mkdtempSync(join(tmpdir(), "broker-owner-delegates-cli-"));
  const cli = new URL("../broker/src/cli.ts", import.meta.url).pathname;
  const file = join(dir, "owner-delegates.json");
  const run = (env: NodeJS.ProcessEnv) => {
    const full: NodeJS.ProcessEnv = { ...process.env, BROKER_STATE_DIR: join(dir, "state"), BROKER_DELIVERY_DIR: join(dir, "creds"), BROKER_OWNER_DELEGATES_FILE: file, ...env };
    delete full.BROKER_RELAY_TOKEN_FILE;
    return JSON.parse(execFileSync(process.execPath, ["--no-warnings", cli, "owner-delegates"], { env: full, encoding: "utf8" })) as { source: string | null; file: string; valid: number; grants: { agentId: string; expiresAt: string }[]; problems: string[] };
  };
  // No file: nothing is granted, and the command says why. It exits 0 and writes no state.
  assert.deepEqual(run({}), { source: "host-file", file, valid: 0, grants: [], problems: [`${file} is missing`] });
  // A file this test wrote is not root's (unless the test runs as root, where the entry is live or expired by date).
  const expiresAt = new Date(Date.now() + 86_400_000).toISOString().replace(/\.\d{3}Z$/, "Z");
  writeFileSync(file, grantFileBody([grant(DELEGATE_ID, expiresAt)]));
  chmodSync(file, 0o644);
  const out = run({});
  if (process.getuid?.() === 0) assert.deepEqual(out, { source: "host-file", file, valid: 1, grants: [{ agentId: DELEGATE_ID, expiresAt }], problems: [] });
  else assert.deepEqual(out, { source: "host-file", file, valid: 0, grants: [], problems: [`${file} is not owned by root`] });
  // The default path is the host's, outside the repo.
  const unset: NodeJS.ProcessEnv = { BROKER_OWNER_DELEGATES_FILE: undefined };
  assert.equal(run(unset).file, "/etc/aws-cred-broker/owner-delegates.json");
  // An allowlist without the block: off.
  const off = join(dir, "allowlist.json");
  writeFileSync(off, JSON.stringify(withoutBlock()));
  assert.deepEqual(run({ BROKER_ALLOWLIST: off }), { source: null, file, valid: 0, grants: [], problems: ["owner delegation is off: the allowlist has no ownerDelegates block"] });
  // Read-only: no state dir was made.
  assert.throws(() => readFileSync(join(dir, "state", "audit.jsonl")));
});
