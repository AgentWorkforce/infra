#!/usr/bin/env node
/**
 * The broker's command line, run by layered-infra-ops when a Relay message
 * asks for credentials. The requester (or approver) flags are filled from the
 * Relay envelope the message arrived in, never from the message body.
 *
 *   cli.ts request  --from-name N --from-address A --from-kind agent|human [--message-id M] < request.json
 *   cli.ts approve  --request-id ID --digest HEX --from-name N --from-address A --from-kind human [--message-id M]
 *   cli.ts refuse   --request-id ID --from-name N --from-address A --from-kind K [--message-id M]
 *   cli.ts sweep
 *   cli.ts verify-audit
 *
 * Prints one JSON reply: safe to paste into a Relay message (no credential).
 * Env: BROKER_STATE_DIR, BROKER_DELIVERY_DIR, BROKER_ALLOWLIST, BROKER_AWS_PROFILE.
 */
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { verifyAudit } from "./audit.ts";
import { Broker } from "./broker.ts";
import { defaultDeliverer } from "./deliver.ts";
import type { Allowlist, CredentialRequest, Principal } from "./policy.ts";
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
  },
});

function principal(): Principal {
  const name = values["from-name"];
  const address = values["from-address"];
  const kind = values["from-kind"];
  if (!name || !address || (kind !== "agent" && kind !== "human")) throw new Error("--from-name, --from-address and --from-kind agent|human are required (from the Relay envelope)");
  return { name, address, kind };
}

const stateDir = process.env.BROKER_STATE_DIR ?? join(homedir(), ".local", "state", "aws-cred-broker");
const allowlistPath = process.env.BROKER_ALLOWLIST ?? fileURLToPath(new URL("../allowlist.json", import.meta.url));
const allowlist = JSON.parse(readFileSync(allowlistPath, "utf8")) as Allowlist;
const broker = new Broker({
  allowlist,
  stateDir,
  sts: awsCliSts(),
  deliverer: defaultDeliverer(process.env.BROKER_DELIVERY_DIR ?? join(homedir(), ".aws-broker", "creds")),
});

const cmd = positionals[0];
let out: unknown;
if (cmd === "request") out = await broker.request(JSON.parse(readFileSync(0, "utf8")) as CredentialRequest, principal(), values["message-id"]);
else if (cmd === "approve") out = await broker.approve(values["request-id"] ?? "", values.digest ?? "", principal(), values["message-id"]);
else if (cmd === "refuse") out = await broker.refuse(values["request-id"] ?? "", principal(), values["message-id"]);
else if (cmd === "sweep") out = { removed: await broker.sweep() };
else if (cmd === "verify-audit") {
  const problems = verifyAudit(broker.auditPath);
  out = { ok: problems.length === 0, problems };
  if (problems.length) process.exitCode = 1;
} else {
  process.stderr.write("usage: cli.ts request|approve|refuse|sweep|verify-audit (see the header of this file)\n");
  process.exit(2);
}
process.stdout.write(JSON.stringify(out, null, 2) + "\n");
