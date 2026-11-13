/**
 * The host this folder defines: user data under EC2's limit with no secret
 * values, the AWS admin role wired in, the AMI pinned, every credential a
 * named SSM parameter under /infra-ops/<stage>/, and the A2A card it publishes.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import { AGENT_CARD_FILE, EC2_USER_DATA_ENCODED_LIMIT, RELAY_SESSIONS_KIT_FILES, WORKER_KIT_FILES, fileReader, hostRolePolicy, hostTemplate, renderAgentCard, userDataBase64 } from "@agentworkforce/layered-agent";
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
    // The generated card file travels by hot update, never in user data.
    assert.equal(shipped, !(f.source === "generated" || (f.source === "kit" && optional.includes(f.name))), f.name);
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

test("the A2A card: renders within the relay's limits, one skill per kind of work, generated and kept out of user data", () => {
  assert.ok(agent.input.relaySessions, "the lead publishes the card with the agent-relay MCP");
  const rendered = renderAgentCard(agent.input.card!);
  const card = JSON.parse(rendered) as { description: string; skills: { id: string; tags?: string[]; examples?: string[] }[]; tags?: string[]; documentation_url?: string; version: string };
  assert.match(card.description, /^layered-infra-ops is AgentWorkforce's infrastructure operator/);
  assert.deepEqual(card.skills.map((s) => s.id), [
    "provision-cloud-resources",
    "cloudflare-dns-and-workers",
    "terraform-helm-changes",
    "rotate-credentials",
    "posthog-setup",
    "investigate-infrastructure",
  ]);
  for (const s of card.skills) {
    assert.ok((s.tags?.length ?? 0) > 0, `${s.id} has tags`);
    assert.ok((s.examples?.length ?? 0) >= 2 && (s.examples?.length ?? 0) <= 4, `${s.id} has 2 to 4 examples`);
  }
  assert.deepEqual(card.tags, ["infra", "aws", "gcp", "azure", "cloudflare", "posthog", "terraform", "helm"]);
  assert.equal(card.documentation_url, "https://github.com/AgentWorkforce/infra");
  assert.match(card.version, /^[0-9a-f]{12}$/);
  assert.equal(agent.generated[AGENT_CARD_FILE], rendered);
  assert.deepEqual(agent.files.filter((f) => f.source === "generated"), [{ name: AGENT_CARD_FILE, source: "generated" }]);
  const script = gunzipSync(Buffer.from(userDataBase64(agent, read), "base64")).toString("utf8");
  assert.ok(!script.includes(`cat > /opt/agent-host/${AGENT_CARD_FILE}`), "the card never rides in user data");
});
