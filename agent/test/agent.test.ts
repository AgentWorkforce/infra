/**
 * The host this folder defines: user data under EC2's limit with no secret
 * values, the AWS admin role wired in, the AMI pinned, and every credential a
 * named SSM parameter under /infra-ops/<stage>/.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import { EC2_USER_DATA_ENCODED_LIMIT, RELAY_SESSIONS_KIT_FILES, WORKER_KIT_FILES, fileReader, hostRolePolicy, hostTemplate, userDataBase64 } from "@agentworkforce/layered-agent";
import agent from "../agent.config.ts";

const read = fileReader(fileURLToPath(new URL("..", import.meta.url)));
const ACCOUNT = "500268966557";

test("user data: under EC2's limit, every kit and lane file, no secret values", () => {
  const encoded = userDataBase64(agent, read);
  assert.ok(encoded.length < EC2_USER_DATA_ENCODED_LIMIT - 500, `user data is ${encoded.length} bytes encoded`);
  const script = gunzipSync(Buffer.from(encoded, "base64")).toString("utf8");
  const optional: readonly string[] = ["headless.py", "delegation.md", ...WORKER_KIT_FILES, ...RELAY_SESSIONS_KIT_FILES];
  for (const f of agent.files) {
    const shipped = script.includes(`cat > /opt/agent-host/${f.name} <<'`);
    assert.equal(shipped, !(f.source === "kit" && optional.includes(f.name)), f.name);
  }
  assert.doesNotMatch(script, /sk-ant-|ghp_|ghs_|gho_|BEGIN [A-Z ]*PRIVATE KEY|"private_key"/);
});

test("the AMI is pinned", () => {
  const t = hostTemplate(agent, userDataBase64(agent, read));
  assert.deepEqual(t.Parameters.AmiId, { Type: "AWS::EC2::Image::Id", Default: "ami-08cf17e3856f70154" });
});

test("names, secrets and the admin role", () => {
  assert.equal(agent.names.role, `layered-agent-infra-ops-${agent.input.stage}`);
  assert.equal(agent.names.platformPrefix, `/relaycast-agent-host/${agent.input.stage}`);
  for (const s of agent.input.secrets ?? []) assert.match(s.param, /^[a-z0-9-]+$/, `${s.envVar} names a parameter under /infra-ops/<stage>/`);
  const gcp = agent.secrets.find((s) => s.envVar === "GCP_SA_KEY_PARAM")!;
  assert.equal(gcp.exportAs, undefined, "the GCP key is JSON: a file, never secrets.env");
  assert.equal(agent.input.awsAdmin, true);
  assert.deepEqual(agent.input.repos, ["AgentWorkforce/infra"]);
});

test("with an account id: the host may assume exactly its admin role, and the env file names it", async () => {
  const { defineLayeredAgent } = await import("@agentworkforce/layered-agent");
  const a = defineLayeredAgent({ ...agent.input, accountId: ACCOUNT });
  const admin = `arn:aws:iam::${ACCOUNT}:role/layered-agent-admin-infra-ops-${a.input.stage}`;
  const sts = hostRolePolicy(a, ACCOUNT).Statement.filter((s) => s.Action.some((x) => x.startsWith("sts:")));
  assert.deepEqual(sts.map((s) => s.Resource), [[admin]]);
  assert.match(a.envFile, new RegExp(`^AWS_ADMIN_ROLE_ARN=${admin}$`, "m"));
});

test("no lane script passes a secret on a sudo command line (sudo logs it to the journal)", () => {
  for (const f of ["setup-lane.sh", "load-secrets-lane.sh"]) {
    const text = readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
    for (const line of text.split("\n").filter((l) => /\bsudo\b/.test(l) && !/^\s*#/.test(l))) {
      assert.doesNotMatch(line, /\b[A-Z_]*(SECRET|TOKEN|PASSWORD|API_KEY|_KEY|AZ_S)[A-Z_]*=/, `${f}: ${line.trim()}`);
      assert.doesNotMatch(line, /\$\(val [A-Z_]*(SECRET|TOKEN|KEY)/, `${f}: ${line.trim()}`);
    }
  }
});
