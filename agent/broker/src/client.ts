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
 *   node agent/broker/src/client.ts open --name RUN --account ACCOUNT < reply.json
 *     Reads the broker's reply (the JSON layered-infra-ops sent back) and
 *     opens the envelope with that key. Before trusting the credentials, it
 *     checks them with AWS: sts get-caller-identity must name ACCOUNT (the
 *     account you asked for) and an agent-broker-* role session. Encryption
 *     proves only that the envelope was sealed to your key, not that the
 *     broker sealed it, so a relaying lead can't hand you credentials for an
 *     account it controls. It then writes ~/.aws-broker/creds/<request id>.json
 *     (0600, new file only, credential_process format) and prints only the
 *     path, the profile snippet and the expiry, never a credential. The private
 *     key is deleted: it is single use.
 *
 * Then: aws --profile broker-RUN … with ~/.aws/config holding
 *   [profile broker-RUN]
 *   credential_process = cat ~/.aws-broker/creds/<request id>.json
 *
 * If a Relay message arrives truncated, take the reply from the full message
 * (agent-relay-probe read REF) instead.
 */
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { newKeyPair, open, type Envelope } from "./envelope.ts";

const { positionals, values } = parseArgs({ allowPositionals: true, options: { name: { type: "string" }, dir: { type: "string" }, account: { type: "string" } } });
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
  const account = values.account ?? "";
  if (!/^\d{12}$/.test(account)) {
    process.stderr.write("--account (the 12-digit account you requested) is required: the credentials are checked against it\n");
    process.exit(2);
  }
  const plaintext = open(reply.delivery.envelope, readFileSync(keyPath, "utf8").trim(), reply.requestId);
  const doc = JSON.parse(plaintext) as { AccessKeyId?: string; SecretAccessKey?: string; SessionToken?: string };
  // Who are these credentials? Passed to the AWS CLI in its environment, never on a command line.
  const identity = JSON.parse(
    execFileSync("aws", ["sts", "get-caller-identity", "--output", "json"], {
      encoding: "utf8",
      env: { PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: process.env.HOME ?? "", AWS_ACCESS_KEY_ID: doc.AccessKeyId ?? "", AWS_SECRET_ACCESS_KEY: doc.SecretAccessKey ?? "", AWS_SESSION_TOKEN: doc.SessionToken ?? "", AWS_REGION: "us-east-1", AWS_PAGER: "", AWS_CONFIG_FILE: "/dev/null", AWS_SHARED_CREDENTIALS_FILE: "/dev/null" },
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 20_000,
    }),
  ) as { Account?: string; Arn?: string };
  if (identity.Account !== account || !new RegExp(`^arn:aws:sts::${account}:assumed-role/agent-broker-[\\w+=,.@-]+/`).test(identity.Arn ?? "")) {
    rmSync(keyPath);
    process.stderr.write(`refused: these credentials are ${identity.Arn ?? "unknown"}, not an agent-broker role session in ${account}. Not saved; the key is deleted. Report this to Khaliq.\n`);
    process.exit(1);
  }
  mkdirSync(join(root, "creds"), { recursive: true, mode: 0o700 });
  chmodSync(join(root, "creds"), 0o700);
  const out = join(root, "creds", `${reply.requestId}.json`);
  writeFileSync(out, plaintext + "\n", { mode: 0o600, flag: "wx" });
  rmSync(keyPath);
  // Quoted for the AWS CLI's credential_process parser (paths with spaces).
  const quoted = `"${out.replace(/(["\\])/g, "\\$1")}"`;
  process.stdout.write(`${out}\nverified: ${identity.Arn}\n[profile broker-${name}]\ncredential_process = cat ${quoted}\nexpires ${reply.expiration ?? "?"}\n`);
} else {
  process.stderr.write("usage: client.ts keygen|open --name RUN (see the header of this file)\n");
  process.exit(2);
}
