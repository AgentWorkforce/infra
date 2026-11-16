#!/usr/bin/env node
/**
 * The requester's side of the "encrypted" delivery, run on the requester's
 * own machine (from a checkout of AgentWorkforce/infra):
 *
 *   node agent/broker/src/client.ts keygen --name RUN
 *     Writes a one-time private key to ~/.aws-broker/keys/RUN.key (0600) and
 *     prints the public key. Put it in the request:
 *     "delivery": {"kind": "encrypted", "publicKey": "<printed key>"}
 *
 *   node agent/broker/src/client.ts open --name RUN < reply.json
 *     Reads the broker's reply (the JSON layered-infra-ops sent back), opens
 *     the envelope with that key, and writes ~/.aws-broker/creds/<request id>.json
 *     (0600, credential_process format). It prints only the path, the profile
 *     snippet and the expiry, never a credential. The private key is deleted:
 *     it is single use.
 *
 * Then: aws --profile broker-RUN … with ~/.aws/config holding
 *   [profile broker-RUN]
 *   credential_process = cat ~/.aws-broker/creds/<request id>.json
 *
 * If a Relay message arrives truncated, take the reply from the full message
 * (agent-relay-probe read REF) instead.
 */
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { newKeyPair, open, type Envelope } from "./envelope.ts";

const { positionals, values } = parseArgs({ allowPositionals: true, options: { name: { type: "string" }, dir: { type: "string" } } });
const root = values.dir ?? join(homedir(), ".aws-broker");
const name = values.name ?? "";
if (!/^[a-z0-9][a-z0-9-]{1,62}$/.test(name)) {
  process.stderr.write("--name must be lowercase letters, digits and hyphens (use the run tag)\n");
  process.exit(2);
}
const keyPath = join(root, "keys", `${name}.key`);

if (positionals[0] === "keygen") {
  mkdirSync(join(root, "keys"), { recursive: true, mode: 0o700 });
  if (existsSync(keyPath)) {
    process.stderr.write(`${keyPath} exists: use it, or delete it to start over\n`);
    process.exit(2);
  }
  const kp = newKeyPair();
  writeFileSync(keyPath, kp.privateKey + "\n", { mode: 0o600, flag: "wx" });
  process.stdout.write(kp.publicKey + "\n");
} else if (positionals[0] === "open") {
  const reply = JSON.parse(readFileSync(0, "utf8")) as { requestId?: string; outcome?: string; reasons?: string[]; expiration?: string; delivery?: { kind?: string; envelope?: Envelope } };
  if (reply.outcome !== "issued" || reply.delivery?.kind !== "encrypted" || !reply.delivery.envelope || !reply.requestId) {
    process.stderr.write(`not an issued encrypted reply: ${reply.outcome ?? "?"} ${(reply.reasons ?? []).join("; ")}\n`);
    process.exit(1);
  }
  if (!/^cb-[0-9a-f]{12}$/.test(reply.requestId)) {
    process.stderr.write("bad request id in the reply\n");
    process.exit(1);
  }
  const plaintext = open(reply.delivery.envelope, readFileSync(keyPath, "utf8").trim(), reply.requestId);
  JSON.parse(plaintext); // a credential_process document, or this throws
  mkdirSync(join(root, "creds"), { recursive: true, mode: 0o700 });
  chmodSync(join(root, "creds"), 0o700);
  const out = join(root, "creds", `${reply.requestId}.json`);
  writeFileSync(out, plaintext + "\n", { mode: 0o600 });
  rmSync(keyPath);
  process.stdout.write(`${out}\n[profile broker-${name}]\ncredential_process = cat ${out}\nexpires ${reply.expiration ?? "?"}\n`);
} else {
  process.stderr.write("usage: client.ts keygen|open --name RUN (see the header of this file)\n");
  process.exit(2);
}
