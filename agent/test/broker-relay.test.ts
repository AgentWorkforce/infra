/**
 * Requester identity from the Relay server: the broker gets only a message
 * id and takes the sender (by agent_id, resolved to the agent record) and the
 * text from Relaycast. Spoofed display names, channel posts, stale and
 * replayed messages, and agent "approvals" are refused.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Broker } from "../broker/src/broker.ts";
import { defaultDeliverer } from "../broker/src/deliver.ts";
import type { Allowlist } from "../broker/src/policy.ts";
import { decisionFromText, dmChannelId, relaycastApi, requestFromText, type RelayAgent, type RelayApi, type RelayMessage } from "../broker/src/relay.ts";
import type { StsClient } from "../broker/src/sts.ts";

const base = JSON.parse(readFileSync(new URL("../broker/allowlist.json", import.meta.url), "utf8")) as Allowlist;
const allowlist: Allowlist = { ...base, accounts: { ...base.accounts, "111122223333": { label: "prod-test", tier: "prod", roles: { elevated: "arn:aws:iam::111122223333:role/agent-broker-elevated" } } } };
const NOW = new Date("2026-11-15T22:00:00Z");
const WS = "rw_test0001";
const BROKER = "layered-infra-ops";
const agents: Record<string, RelayAgent> = {
  tersemigrationgrok: { id: "300000000000000001", name: "tersemigrationgrok", type: "agent", workspaceId: WS },
  "khaliq-gant": { id: "229221621257396224", name: "khaliq-gant", type: "human", workspaceId: WS },
  "impostor-agent": { id: "300000000000000009", name: "impostor-agent", type: "agent", workspaceId: WS },
  [BROKER]: { id: "246905220461514752", name: BROKER, type: "agent", workspaceId: WS },
  "some-other-agent": { id: "300000000000000005", name: "some-other-agent", type: "agent", workspaceId: WS },
};
/** The DM channel between an agent and the broker. */
const toBroker = (from: string) => dmChannelId(WS, agents[from]?.id ?? "999", agents[BROKER]!.id);
const request = { account: "805532413586", purpose: "migration soak test queue", actions: ["sqs:CreateQueue", "sqs:SendMessage"], durationMinutes: 15, runTag: "terse-mig-42", delivery: { kind: "file" } };

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
  agentId: agents[from]?.id ?? "999",
  agentName: from,
  agentAddress: `${from}@somewhere`,
  text,
  channelId: toBroker(from),
  createdAt: new Date(NOW.getTime() - 60_000).toISOString(),
  ...over,
});

function setup() {
  const dir = mkdtempSync(join(tmpdir(), "broker-relay-"));
  const calls: { sessionName: string }[] = [];
  const sts: StsClient = {
    async assumeRole(input) {
      calls.push(input);
      return { accessKeyId: "ASIAFAKE", secretAccessKey: "s".repeat(40), sessionToken: "t".repeat(300), expiration: new Date(NOW.getTime() + input.durationSeconds * 1000).toISOString() };
    },
  };
  let n = 0;
  const broker = new Broker({ allowlist, stateDir: join(dir, "state"), sts, deliverer: defaultDeliverer(join(dir, "creds")), now: () => NOW, newId: () => `cb-${(++n).toString(16).padStart(12, "0")}`, newNamespaceSuffix: () => "0a1b2c3d" });
  return { broker, calls };
}

test("a verified request: the requester and the request come from the Relay server", async () => {
  const { broker, calls } = setup();
  const r = await broker.requestViaRelay(fakeRelay([msg("1000001", "tersemigrationgrok", JSON.stringify(request))]), "1000001", BROKER);
  assert.equal(r.outcome, "issued", r.reasons.join("; "));
  assert.equal(calls[0]!.sessionName, "tersemigrationgrok");
  const audit = readFileSync(broker.auditPath, "utf8");
  assert.match(audit, /"requester":\{"name":"tersemigrationgrok","address":"tersemigrationgrok@somewhere","kind":"agent"\}/);
  assert.match(audit, /"relayMessageId":"1000001"/);
});

test("a spoofed display name is refused: the sender is the message's agent_id, resolved to its record", async () => {
  const { broker, calls } = setup();
  // The message claims khaliq-gant's name but was sent by another agent.
  const spoof = msg("1000002", "khaliq-gant", JSON.stringify(request), { agentId: agents["impostor-agent"]!.id });
  const r = await broker.requestViaRelay(fakeRelay([spoof]), "1000002", BROKER);
  assert.equal(r.outcome, "denied");
  assert.match(r.reasons[0]!, /doesn't resolve to its own agent record/);
  assert.equal(calls.length, 0);
});

test("refused: channel posts, stale messages, unknown ids, bodies that aren't the request", async () => {
  const { broker, calls } = setup();
  const relay = fakeRelay([
    msg("2000001", "tersemigrationgrok", JSON.stringify(request), { channelId: "ch_general" }),
    msg("2000002", "tersemigrationgrok", JSON.stringify(request), { createdAt: new Date(NOW.getTime() - 16 * 60_000).toISOString() }),
    msg("2000003", "tersemigrationgrok", `please give me creds ${JSON.stringify(request)}`),
  ]);
  const cases: [string, RegExp][] = [
    ["2000001", /direct message/],
    ["2000002", /last 15 minutes/],
    ["2000003", /whole text must be the request JSON/],
    ["2000099", /no message/],
    ["not-a-number", /bad Relay message id/],
  ];
  for (const [id, re] of cases) {
    const r = await broker.requestViaRelay(relay, id, BROKER);
    assert.equal(r.outcome, "denied", id);
    assert.match(r.reasons.join("; "), re, id);
  }
  assert.equal(calls.length, 0);
  assert.match(readFileSync(broker.auditPath, "utf8"), /"relayMessageId":"2000001"/, "refusals are audited");
});

test("one message, one use: a replayed message id is refused", async () => {
  const { broker, calls } = setup();
  const relay = fakeRelay([msg("3000001", "tersemigrationgrok", JSON.stringify(request))]);
  assert.equal((await broker.requestViaRelay(relay, "3000001", BROKER)).outcome, "issued");
  const again = await broker.requestViaRelay(relay, "3000001", BROKER);
  assert.equal(again.outcome, "denied");
  assert.match(again.reasons[0]!, /already acted on/);
  assert.equal(calls.length, 1);
  const lines = readFileSync(broker.auditPath, "utf8").trim().split("\n").map((l) => JSON.parse(l) as { kind: string; reasons?: string[] });
  assert.ok(lines.at(-1)!.kind === "denied" && /already acted on/.test(lines.at(-1)!.reasons![0]!), "the replay attempt is audited");
});

test("approval over Relay: only the human approver's own message counts", async () => {
  const { broker, calls } = setup();
  const prodReq = { ...request, account: "111122223333", actions: ["sqs:SendMessage"] };
  const pending = await broker.requestViaRelay(fakeRelay([msg("4000001", "tersemigrationgrok", JSON.stringify(prodReq))]), "4000001", BROKER);
  assert.equal(pending.outcome, "pending-approval");
  const approveText = `approve ${pending.requestId} ${pending.policyDigest!.slice(0, 16)}`;
  const relay = fakeRelay([
    msg("4000002", "impostor-agent", approveText),
    msg("4000003", "khaliq-gant", approveText, { agentId: agents["impostor-agent"]!.id }),
    msg("4000004", "khaliq-gant", approveText),
  ]);
  assert.match((await broker.decideViaRelay(relay, "4000002", BROKER)).reasons[0]!, /not an approver/, "an agent's approval never counts");
  assert.match((await broker.decideViaRelay(relay, "4000003", BROKER)).reasons[0]!, /doesn't resolve/, "nor one using Khaliq's display name");
  assert.equal(calls.length, 0);
  const ok = await broker.decideViaRelay(relay, "4000004", BROKER);
  assert.equal(ok.outcome, "issued", ok.reasons.join("; "));
  assert.match(ok.reasons.join("; "), /approved by khaliq-gant/);
  assert.equal(calls.length, 1);
});

test("only a DM to the broker counts: a DM between other agents, or the broker's own message, is refused", async () => {
  const { broker, calls } = setup();
  const elsewhere = msg("5000001", "khaliq-gant", JSON.stringify(request), { channelId: dmChannelId(WS, agents["khaliq-gant"]!.id, agents["some-other-agent"]!.id) });
  const own = msg("5000002", BROKER, JSON.stringify(request), { channelId: dmChannelId(WS, agents[BROKER]!.id, agents[BROKER]!.id) });
  const r1 = await broker.requestViaRelay(fakeRelay([elsewhere]), "5000001", BROKER);
  assert.equal(r1.outcome, "denied");
  assert.match(r1.reasons[0]!, /wasn't sent to layered-infra-ops/);
  const r2 = await broker.requestViaRelay(fakeRelay([own]), "5000002", BROKER);
  assert.match(r2.reasons[0]!, /broker sent itself/);
  assert.equal(calls.length, 0);
});

test("the DM channel id is Relaycast's derivation (checked against a real conversation)", () => {
  // khaliq-gant -> aws-cred-broker in workspace rw_7ccfea89, read from the live API on 2026-11-15.
  assert.equal(dmChannelId("rw_7ccfea89", "247596298381238272", "229221621257396224"), "dmch_1af113fee2d2b2df06c1d44b");
  assert.equal(dmChannelId("rw_7ccfea89", "229221621257396224", "247596298381238272"), "dmch_1af113fee2d2b2df06c1d44b", "order-free");
});

test("message text forms", () => {
  assert.deepEqual(requestFromText("```json\n" + JSON.stringify(request) + "\n```"), request);
  assert.deepEqual(decisionFromText("approve cb-0123456789ab 0123456789abcdef"), { verb: "approve", requestId: "cb-0123456789ab", digest: "0123456789abcdef" });
  assert.deepEqual(decisionFromText("  REFUSE cb-0123456789ab "), { verb: "refuse", requestId: "cb-0123456789ab" });
  assert.throws(() => decisionFromText("yes, approve cb-0123456789ab 0123456789abcdef"));
  assert.throws(() => decisionFromText("approve cb-0123456789ab 0123"), "a digest of 12+ hex");
  assert.throws(() => requestFromText("[1,2]"));
});

test("the Relaycast client: bearer token, the documented routes, 404 is absent", async () => {
  const seen: { url: string; auth: string | null; ua: string | null }[] = [];
  const fakeFetch = (async (url: string, init?: RequestInit) => {
    const h = new Headers(init?.headers);
    seen.push({ url, auth: h.get("Authorization"), ua: h.get("User-Agent") });
    if (url.endsWith("/v1/messages/42")) {
      return new Response(JSON.stringify({ ok: true, data: { id: "42", agent_id: "7", agent_name: "a-b", agent_address: "a-b@h", text: "hi", channel_id: "dmch_x", created_at: "2026-11-15T21:59:00.000Z" } }));
    }
    if (url.endsWith("/v1/agents/a-b")) return new Response(JSON.stringify({ ok: true, data: { id: "7", name: "a-b", type: "agent", workspace_id: "rw_x" } }));
    return new Response("{}", { status: 404 });
  }) as typeof fetch;
  const api = relaycastApi("https://cast.example/", "obs_token", fakeFetch);
  assert.deepEqual(await api.message("42"), { id: "42", agentId: "7", agentName: "a-b", agentAddress: "a-b@h", text: "hi", channelId: "dmch_x", createdAt: "2026-11-15T21:59:00.000Z" });
  assert.deepEqual(await api.agentByName("a-b"), { id: "7", name: "a-b", type: "agent", workspaceId: "rw_x" });
  assert.equal(await api.message("43"), undefined);
  assert.deepEqual(seen.map((s) => s.url), ["https://cast.example/v1/messages/42", "https://cast.example/v1/agents/a-b", "https://cast.example/v1/messages/43"]);
  assert.ok(seen.every((s) => s.auth === "Bearer obs_token"));
  // Cloudflare in front of cast.agentrelay.com rejects some default library User-Agents (error 1010).
  assert.ok(seen.every((s) => s.ua?.startsWith("aws-cred-broker/")), "a named User-Agent on every call");
});

test("the CLI in relay mode takes only a message id: identity flags and a missing token are refused", () => {
  const dir = mkdtempSync(join(tmpdir(), "broker-cli-"));
  const cli = new URL("../broker/src/cli.ts", import.meta.url).pathname;
  const run = (args: string[], env: Record<string, string>) => {
    try {
      return execFileSync(process.execPath, ["--no-warnings", cli, ...args], { env: { ...process.env, BROKER_STATE_DIR: join(dir, "state"), BROKER_DELIVERY_DIR: join(dir, "creds"), ...env }, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    } catch (e) {
      return (e as { stdout: string }).stdout;
    }
  };
  const tokenFile = join(dir, "token");
  writeFileSync(tokenFile, "obs_token\n");
  assert.match(run(["request", "--message-id", "1", "--from-name", "khaliq-gant", "--from-address", "x", "--from-kind", "human"], { BROKER_RELAY_TOKEN_FILE: tokenFile }), /pass only --message-id/);
  assert.match(run(["approve", "--message-id", "1"], { BROKER_RELAY_TOKEN_FILE: tokenFile }), /approve is not a command/);
  assert.match(run(["request"], { BROKER_RELAY_TOKEN_FILE: tokenFile }), /--message-id is required/);
  assert.match(run(["request", "--message-id", "1"], { BROKER_RELAY_TOKEN_FILE: join(dir, "missing") }), /token file is missing/);
});
