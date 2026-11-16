/**
 * The "encrypted" delivery: credentials sealed to the requester's own X25519
 * key, returned in the reply, never stored, and opened only on the
 * requester's machine (client.ts).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Broker } from "../broker/src/broker.ts";
import { defaultDeliverer } from "../broker/src/deliver.ts";
import { newKeyPair, open, seal } from "../broker/src/envelope.ts";
import { decide, type Allowlist, type CredentialRequest, type Principal } from "../broker/src/policy.ts";
import type { StsClient } from "../broker/src/sts.ts";

const allowlist = JSON.parse(readFileSync(new URL("../broker/allowlist.json", import.meta.url), "utf8")) as Allowlist;
const SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYFAKEFAKEKEY";
const TOKEN = "IQoJb3JpZ2luX2VjEFAKE" + "x".repeat(300);
const requester: Principal = { name: "sessions-edges", address: "sessions-edges@linuyc-desktop", kind: "agent" };

test("seal/open: round trip; the wrong key, another request id, or a tampered byte fails", () => {
  const kp = newKeyPair();
  const env = seal('{"Version":1}', kp.publicKey, "cb-0123456789ab");
  assert.equal(open(env, kp.privateKey, "cb-0123456789ab"), '{"Version":1}');
  assert.throws(() => open(env, newKeyPair().privateKey, "cb-0123456789ab"));
  assert.throws(() => open(env, kp.privateKey, "cb-ba9876543210"), "the request id is bound in");
  const bad = { ...env, ct: Buffer.from(Buffer.from(env.ct, "base64").map((b, i) => (i === 0 ? b ^ 1 : b))).toString("base64") };
  assert.throws(() => open(bad, kp.privateKey, "cb-0123456789ab"));
  assert.notEqual(seal("x", kp.publicKey, "cb-0123456789ab").epk, env.epk, "a fresh ephemeral key every time");
});

test("encrypted delivery: the reply holds only ciphertext the requester can open; nothing stored, nothing in the audit", async () => {
  const dir = mkdtempSync(join(tmpdir(), "broker-env-"));
  const sts: StsClient = { async assumeRole(i) { return { accessKeyId: "ASIAFAKE", secretAccessKey: SECRET, sessionToken: TOKEN, expiration: new Date(Date.now() + i.durationSeconds * 1000).toISOString() }; } };
  const broker = new Broker({ allowlist, stateDir: join(dir, "state"), sts, deliverer: defaultDeliverer(join(dir, "creds")) });
  const kp = newKeyPair();
  const req: CredentialRequest = { account: "805532413586", purpose: "neon exit presence check", actions: ["sqs:ListQueues"], durationMinutes: 15, runTag: "neon-edges", delivery: { kind: "encrypted", publicKey: kp.publicKey } };
  const r = await broker.request(req, requester);
  assert.equal(r.outcome, "issued", r.reasons.join("; "));
  assert.equal(r.delivery!.kind, "encrypted");
  const reply = JSON.stringify(r);
  assert.ok(!reply.includes(SECRET) && !reply.includes(TOKEN.slice(0, 30)), "no plaintext credential in the reply");
  const creds = JSON.parse(open(r.delivery!.envelope!, kp.privateKey, r.requestId)) as Record<string, unknown>;
  assert.deepEqual([creds.Version, creds.AccessKeyId, creds.SecretAccessKey], [1, "ASIAFAKE", SECRET]);
  assert.ok(!existsSync(join(dir, "creds")) || readdirSync(join(dir, "creds")).length === 0, "nothing written to disk");
  const audit = readFileSync(broker.auditPath, "utf8");
  assert.ok(!audit.includes(r.delivery!.envelope!.ct) && !audit.includes(SECRET), "the audit has neither the envelope nor the secret");
  assert.match(audit, /"delivery":\{"kind":"encrypted","ref":"inline"\}/);
  const issued = readFileSync(join(dir, "state", "issued", `${r.requestId}.json`), "utf8");
  assert.ok(!issued.includes(r.delivery!.envelope!.ct), "the cleanup record has no envelope");
});

test("a request with a malformed public key is refused", () => {
  for (const publicKey of ["", "not-base64!", Buffer.alloc(31).toString("base64"), Buffer.alloc(33).toString("base64")]) {
    const d = decide({ account: "805532413586", purpose: "neon exit presence check", actions: ["sqs:ListQueues"], durationMinutes: 15, runTag: "neon-edges", delivery: { kind: "encrypted", publicKey } }, requester, allowlist, { namespace: "neon-edges-0a1b2c3d" });
    assert.equal(d.outcome, "deny", publicKey);
    assert.match(d.reasons.join("; "), /publicKey/);
  }
});

test("client.ts: keygen prints a key, open writes a 0600 credential_process file and burns the key", () => {
  const dir = mkdtempSync(join(tmpdir(), "broker-client-"));
  const cli = new URL("../broker/src/client.ts", import.meta.url).pathname;
  const run = (args: string[], input?: string) => execFileSync(process.execPath, ["--no-warnings", cli, ...args, "--dir", dir], { encoding: "utf8", input, stdio: ["pipe", "pipe", "pipe"] });
  const publicKey = run(["keygen", "--name", "neon-edges"]).trim();
  assert.equal(Buffer.from(publicKey, "base64").length, 32);
  assert.equal(statSync(join(dir, "keys", "neon-edges.key")).mode & 0o777, 0o600);
  const plaintext = JSON.stringify({ Version: 1, AccessKeyId: "ASIAFAKE", SecretAccessKey: SECRET, SessionToken: TOKEN, Expiration: "2026-11-16T00:00:00Z" });
  const reply = { requestId: "cb-0123456789ab", outcome: "issued", expiration: "2026-11-16T00:00:00Z", delivery: { kind: "encrypted", ref: "inline", envelope: seal(plaintext, publicKey, "cb-0123456789ab") } };
  const out = run(["open", "--name", "neon-edges"], JSON.stringify(reply));
  assert.ok(!out.includes(SECRET), "never prints a credential");
  assert.match(out, /credential_process = cat .*cb-0123456789ab\.json/);
  const file = join(dir, "creds", "cb-0123456789ab.json");
  assert.equal(statSync(file).mode & 0o777, 0o600);
  assert.equal(JSON.parse(readFileSync(file, "utf8")).SecretAccessKey, SECRET);
  assert.ok(!existsSync(join(dir, "keys", "neon-edges.key")), "single-use key deleted");
});
