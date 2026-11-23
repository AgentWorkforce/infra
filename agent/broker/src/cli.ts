#!/usr/bin/env node
/**
 * The broker's command line, run by layered-infra-ops when a Relay message
 * asks for credentials.
 *
 * Relay mode (the host: BROKER_RELAY_TOKEN_FILE is set). The lead passes only
 * the Relay message id. The broker reads the message from Relaycast and takes
 * the sender and the text from the server (relay.ts):
 *   cli.ts request --message-id M     the message is the request JSON
 *   cli.ts decide  --message-id M     the message is "approve <id> <digest>" or "refuse <id>"
 *   cli.ts sweep
 *   cli.ts verify-audit
 *   cli.ts ship-audit                 copy new audit lines to CloudWatch (ship.ts); a systemd timer runs it every minute
 *   cli.ts whois   --name N          read-only: N's Relay agent id and type (to pin delegatedApprovers[].agentId)
 * Either mode:
 *   cli.ts owner-delegates            read-only: how many owner-delegate grants are live, and what is wrong with the source
 * Identity flags (--from-*), stdin requests and the bare approve/refuse
 * commands are refused in this mode.
 *
 * Local mode (no token file; tests and development only): the identity
 * comes from the flags.
 *   cli.ts request  --from-name N --from-address A --from-kind agent|human [--message-id M] < request.json
 *   cli.ts approve  --request-id ID --digest HEX --from-name N --from-address A --from-kind human [--message-id M]
 *   cli.ts refuse   --request-id ID --from-name N --from-address A --from-kind K [--message-id M]
 *
 * Prints one JSON reply: safe to paste into a Relay message (no credential).
 * Env: BROKER_STATE_DIR, BROKER_DELIVERY_DIR, BROKER_ALLOWLIST, BROKER_AWS_PROFILE,
 * BROKER_RELAY_TOKEN_FILE, BROKER_RELAY_API (default https://cast.agentrelay.com),
 * BROKER_RELAY_NAME (the broker's Relay identity; default layered-infra-ops),
 * BROKER_OWNER_DELEGATES_FILE (the owner's grant file, owner-delegates.ts; default /etc/aws-cred-broker/owner-delegates.json),
 * BROKER_AUDIT_LOG_GROUP (CloudWatch group; unset: shipping off), BROKER_AUDIT_LOG_REGION (the group's
 * region; default AWS_REGION), BROKER_AUDIT_LOG_STREAM (default broker).
 */
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { verifyAudit } from "./audit.ts";
import { Broker } from "./broker.ts";
import { defaultDeliverer } from "./deliver.ts";
import { DEFAULT_OWNER_DELEGATES_FILE, hostFileSource } from "./owner-delegates.ts";
import type { Allowlist, CredentialRequest, Principal } from "./policy.ts";
import { relaycastApi, RelayVerificationError, whois } from "./relay.ts";
import { awsCliLogs, shipAudit, shipDir, type ShipResult } from "./ship.ts";
import { awsCliSts } from "./sts.ts";

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    "from-name": { type: "string" },
    "from-address": { type: "string" },
    "from-kind": { type: "string" },
    "message-id": { type: "string" },
    "request-id": { type: "string" },
    digest: { type: "string" },
    name: { type: "string" },
  },
});

function fail(message: string): never {
  process.stdout.write(JSON.stringify({ requestId: "-", outcome: "denied", reasons: [message] }, null, 2) + "\n");
  process.exit(2);
}

function principal(): Principal {
  const name = values["from-name"];
  const address = values["from-address"];
  const kind = values["from-kind"];
  if (!name || !address || (kind !== "agent" && kind !== "human")) fail("--from-name, --from-address and --from-kind agent|human are required (local mode)");
  return { name, address, kind };
}

const stateDir = process.env.BROKER_STATE_DIR ?? join(homedir(), ".local", "state", "aws-cred-broker");
const allowlistPath = process.env.BROKER_ALLOWLIST ?? fileURLToPath(new URL("../allowlist.json", import.meta.url));
const allowlist = JSON.parse(readFileSync(allowlistPath, "utf8")) as Allowlist;
const tokenFile = process.env.BROKER_RELAY_TOKEN_FILE;
const ownerDelegates = hostFileSource(process.env.BROKER_OWNER_DELEGATES_FILE ?? DEFAULT_OWNER_DELEGATES_FILE, allowlist);
if (positionals[0] === "owner-delegates") {
  // Read-only: no state, no audit, no Relay call. Agent ids and expiries only; the file holds no secret.
  const { grants, problems } = allowlist.ownerDelegates === undefined ? { grants: [], problems: ["owner delegation is off: the allowlist has no ownerDelegates block"] } : ownerDelegates.load(new Date());
  process.stdout.write(JSON.stringify({ source: allowlist.ownerDelegates?.source ?? null, file: ownerDelegates.where, valid: grants.length, grants: grants.map((g) => ({ agentId: g.agentId, expiresAt: g.expiresAt })), problems }, null, 2) + "\n");
  process.exit(0);
}
const broker = new Broker({
  allowlist,
  stateDir,
  ownerDelegates,
  sts: awsCliSts(),
  deliverer: defaultDeliverer(process.env.BROKER_DELIVERY_DIR ?? join(homedir(), ".aws-broker", "creds")),
});

// Audit shipping (ship.ts): on when BROKER_AUDIT_LOG_GROUP names the CloudWatch group.
const auditGroup = process.env.BROKER_AUDIT_LOG_GROUP;
async function ship(): Promise<ShipResult> {
  if (!auditGroup) return { ok: true, shipped: 0, problems: ["audit shipping is off (BROKER_AUDIT_LOG_GROUP is not set)"] };
  // Its own lock (ship.ts), never the state lock: a slow CloudWatch can't hold up a request.
  // The group's region (Terraform's), which needn't be the host's AWS_REGION.
  const region = process.env.BROKER_AUDIT_LOG_REGION ?? process.env.AWS_REGION;
  const sink = awsCliLogs(auditGroup, process.env.BROKER_AUDIT_LOG_STREAM ?? "broker", shipDir(stateDir), undefined, region);
  return shipAudit(broker.auditPath, stateDir, sink);
}

const cmd = positionals[0];
let out: unknown;
if (cmd === "sweep") out = { removed: await broker.sweep() };
else if (cmd === "ship-audit") {
  const r = await ship();
  out = r;
  if (!r.ok) process.exitCode = 1;
}
else if (cmd === "verify-audit") {
  const problems = verifyAudit(broker.auditPath);
  out = { ok: problems.length === 0, problems };
  if (problems.length) process.exitCode = 1;
} else if (tokenFile) {
  // Relay mode: identity and text only from the Relay server.
  if (values["from-name"] || values["from-address"] || values["from-kind"] || values["request-id"] || values.digest) fail("relay mode: pass only --message-id; the broker reads the sender and the text from Relay");
  if (cmd === "whois") {
    // Read-only: no state, no audit, no message; prints the name, agent id and type only.
    if (values["message-id"]) fail("whois takes only --name");
    const name = values.name;
    if (!name) fail("whois: --name is required");
    if (!existsSync(tokenFile)) fail("relay mode: the Relay token file is missing; nothing was done");
    const api = relaycastApi(process.env.BROKER_RELAY_API ?? "https://cast.agentrelay.com", readFileSync(tokenFile, "utf8").trim());
    try {
      process.stdout.write(JSON.stringify(await whois(api, name), null, 2) + "\n");
    } catch (e) {
      fail(e instanceof RelayVerificationError ? e.message : `whois: ${(e as Error).message}`);
    }
    process.exit(0);
  }
  if (values.name) fail("--name is only for whois");
  const messageId = values["message-id"];
  if (!messageId) fail("relay mode: --message-id is required");
  if (!existsSync(tokenFile)) fail("relay mode: the Relay token file is missing, so the sender can't be verified; nothing was done");
  const api = relaycastApi(process.env.BROKER_RELAY_API ?? "https://cast.agentrelay.com", readFileSync(tokenFile, "utf8").trim());
  const brokerName = process.env.BROKER_RELAY_NAME ?? "layered-infra-ops";
  if (cmd === "request") out = await broker.requestViaRelay(api, messageId, brokerName);
  else if (cmd === "decide") out = await broker.decideViaRelay(api, messageId, brokerName);
  else fail(`relay mode: ${cmd ?? "(none)"} is not a command; use request, decide, whois, owner-delegates, sweep, verify-audit or ship-audit`);
} else if (cmd === "whois") fail("whois needs relay mode (BROKER_RELAY_TOKEN_FILE)");
else if (cmd === "request") out = await broker.request(JSON.parse(readFileSync(0, "utf8")) as CredentialRequest, principal(), values["message-id"]);
else if (cmd === "approve") out = await broker.approve(values["request-id"] ?? "", values.digest ?? "", principal(), values["message-id"]);
else if (cmd === "refuse") out = await broker.refuse(values["request-id"] ?? "", principal(), values["message-id"]);
else {
  process.stderr.write("usage: cli.ts request|decide|approve|refuse|owner-delegates|sweep|verify-audit|ship-audit (see the header of this file)\n");
  process.exit(2);
}
process.stdout.write(JSON.stringify(out, null, 2) + "\n");
