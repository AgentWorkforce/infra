/**
 * The "encrypted" delivery: credentials sealed to the requester's own X25519
 * key, returned in the reply, never stored, and opened only on the
 * requester's machine (client.ts).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
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

/** A fake aws CLI that answers sts get-caller-identity with ARN (and checks the credentials came in its environment). */
function fakeAws(arn: string): string {
  const bin = mkdtempSync(join(tmpdir(), "fake-aws-"));
  const acct = arn.split(":")[4];
  writeFileSync(join(bin, "aws"), `#!/bin/sh\n[ "$AWS_SECRET_ACCESS_KEY" = "${SECRET}" ] || { echo "no creds in env" >&2; exit 3; }\necho '{"Account":"${acct}","Arn":"${arn}"}'\n`);
  chmodSync(join(bin, "aws"), 0o755);
  return bin;
}

function client(dir: string, bin: string) {
  const cli = new URL("../broker/src/client.ts", import.meta.url).pathname;
  return (args: string[], input?: string) => {
    try {
      return { ok: true, out: execFileSync(process.execPath, ["--no-warnings", cli, ...args, "--dir", dir], { encoding: "utf8", input, env: { ...process.env, PATH: `${bin}:${process.env.PATH}` }, stdio: ["pipe", "pipe", "pipe"] }) };
    } catch (e) {
      return { ok: false, out: String((e as { stderr: string }).stderr) };
    }
  };
}

const plaintext = JSON.stringify({ Version: 1, AccessKeyId: "ASIAFAKE", SecretAccessKey: SECRET, SessionToken: TOKEN, Expiration: "2026-11-16T00:00:00Z" });
const replyFor = (publicKey: string, id = "cb-0123456789ab") => JSON.stringify({ requestId: id, outcome: "issued", expiration: "2026-11-16T00:00:00Z", delivery: { kind: "encrypted", ref: "inline", envelope: seal(plaintext, publicKey, id) } });

test("client.ts: keygen, then open checks the credentials with AWS, writes a 0600 file once and burns the key", () => {
  const dir = mkdtempSync(join(tmpdir(), "broker client "));
  const run = client(dir, fakeAws("arn:aws:sts::500268966557:assumed-role/agent-broker-elevated/legacy-copy"));
  const publicKey = run(["keygen", "--name", "neon-edges"]).out.trim();
  assert.equal(Buffer.from(publicKey, "base64").length, 32);
  assert.equal(statSync(join(dir, "keys", "neon-edges.key")).mode & 0o777, 0o600);
  assert.match(run(["open", "--name", "neon-edges"], replyFor(publicKey)).out, /--account/, "the expected account is required");
  const r = run(["open", "--name", "neon-edges", "--account", "500268966557"], replyFor(publicKey));
  assert.ok(r.ok, r.out);
  assert.ok(!r.out.includes(SECRET), "never prints a credential");
  assert.match(r.out, /verified: arn:aws:sts::500268966557:assumed-role\/agent-broker-elevated\/legacy-copy/);
  const file = join(dir, "creds", "cb-0123456789ab.json");
  assert.ok(r.out.includes(`credential_process = cat "${file}"`), "quoted: the directory has a space in it");
  assert.equal(statSync(file).mode & 0o777, 0o600);
  assert.equal(JSON.parse(readFileSync(file, "utf8")).SecretAccessKey, SECRET);
  assert.ok(!existsSync(join(dir, "keys", "neon-edges.key")), "single-use key deleted");
});

test("client.ts: credentials for another account or a non-broker role are refused and never saved", () => {
  for (const arn of ["arn:aws:sts::999999999999:assumed-role/agent-broker-elevated/legacy-copy", "arn:aws:sts::500268966557:assumed-role/layered-agent-admin-infra-ops-dev/x"]) {
    const dir = mkdtempSync(join(tmpdir(), "broker-client-"));
    const run = client(dir, fakeAws(arn));
    const publicKey = run(["keygen", "--name", "legacy"]).out.trim();
    const r = run(["open", "--name", "legacy", "--account", "500268966557"], replyFor(publicKey));
    assert.equal(r.ok, false, arn);
    assert.match(r.out, /refused/);
    assert.ok(!existsSync(join(dir, "creds", "cb-0123456789ab.json")), "not saved");
  }
});

test("client.ts: an existing output file is never overwritten", () => {
  const dir = mkdtempSync(join(tmpdir(), "broker-client-"));
  const run = client(dir, fakeAws("arn:aws:sts::500268966557:assumed-role/agent-broker-elevated/x"));
  mkdirSync(join(dir, "creds"), { recursive: true });
  writeFileSync(join(dir, "creds", "cb-0123456789ab.json"), "old");
  const publicKey = run(["keygen", "--name", "again"]).out.trim();
  assert.equal(run(["open", "--name", "again", "--account", "500268966557"], replyFor(publicKey)).ok, false);
  assert.equal(readFileSync(join(dir, "creds", "cb-0123456789ab.json"), "utf8"), "old");
});

test("a truncated GCM tag is refused", () => {
  const kp = newKeyPair();
  const env = seal("x", kp.publicKey, "cb-0123456789ab");
  assert.throws(() => open({ ...env, tag: Buffer.from(env.tag, "base64").subarray(0, 4).toString("base64") }, kp.privateKey, "cb-0123456789ab"), /16 bytes/);
});
