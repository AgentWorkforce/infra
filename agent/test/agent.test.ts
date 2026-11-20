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
import { AGENT_CARD_FILE, DELEGATION_KIT_FILES, EC2_USER_DATA_ENCODED_LIMIT, ISSUE_WATCH_FILE, ISSUE_WATCH_KIT_FILES, RELAY_SESSIONS_KIT_FILES, STEWARDSHIP_FILE, STEWARDSHIP_KIT_FILES, renderIssueWatch, renderStewardship, stewardship, WORKER_KIT_FILES, fileReader, hostRolePolicy, hostTemplate, renderAgentCard, userDataBase64 } from "@agentworkforce/layered-agent";
import agent from "../agent.config.ts";

const read = fileReader(fileURLToPath(new URL("..", import.meta.url)));
const ACCOUNT = "500268966557";

test("user data: under EC2's limit, every kit and lane file, no secret values", () => {
  const encoded = userDataBase64(agent, read);
  assert.ok(encoded.length < EC2_USER_DATA_ENCODED_LIMIT - 500, `user data is ${encoded.length} bytes encoded`);
  const script = gunzipSync(Buffer.from(encoded, "base64")).toString("utf8");
  // The kit's own list of files that ride the hot update (it does not export it): ledger.py since 0.1.28.
  const optional: readonly string[] = ["headless.py", "ledger.py", "delegation.md", "orchestration.md", ...DELEGATION_KIT_FILES, ...WORKER_KIT_FILES, ...RELAY_SESSIONS_KIT_FILES, ...ISSUE_WATCH_KIT_FILES, ...STEWARDSHIP_KIT_FILES];
  for (const f of agent.files) {
    const shipped = script.includes(`cat > /opt/agent-host/${f.name} <<'`);
    // The generated card, issue-watch and stewardship files travel by hot update, never in user data.
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

test("with an account id: the host may assume exactly its admin role and the credential broker's role, and the env file names both", async () => {
  const { defineLayeredAgent } = await import("@agentworkforce/layered-agent");
  const a = defineLayeredAgent({ ...agent.input, accountId: ACCOUNT });
  const admin = `arn:aws:iam::${ACCOUNT}:role/layered-agent-admin-infra-ops-${a.input.stage}`;
  const broker = `arn:aws:iam::${ACCOUNT}:role/agent-cred-broker`;
  const sts = hostRolePolicy(a, ACCOUNT).Statement.filter((s) => s.Action.some((x) => x.startsWith("sts:")));
  assert.deepEqual(sts.map((s) => s.Resource), [[admin], [broker]]);
  assert.deepEqual(sts.map((s) => s.Action), [["sts:AssumeRole"], ["sts:AssumeRole"]]);
  assert.match(a.envFile, new RegExp(`^AWS_ADMIN_ROLE_ARN=${admin}$`, "m"));
  assert.match(a.envFile, new RegExp(`^CRED_BROKER_ROLE_ARN=${broker}$`, "m"));
  assert.equal(agent.input.credentialBroker, true);
});

test("the credential broker ships pinned: broker.ref is one exact commit, installed root-owned, run only as credbroker", () => {
  assert.ok(agent.input.laneFiles.includes("broker.ref"));
  const ref = readFileSync(new URL("../broker.ref", import.meta.url), "utf8");
  assert.match(ref, /^[0-9a-f]{40}\n$/, "a full commit sha, nothing else");
  const lane = readFileSync(new URL("../setup-lane.sh", import.meta.url), "utf8");
  // Fetched by exact commit and checked: never a branch, never main.
  assert.match(lane, /fetch -q --depth 1 https:\/\/github\.com\/AgentWorkforce\/infra\.git "\$ref"/);
  assert.match(lane, /rev-parse FETCH_HEAD\)" = "\$ref" \]/);
  assert.doesNotMatch(lane, /infra\.git (main|HEAD)\b/);
  // Root-owned, read-only code; the agent user may run exactly the broker as credbroker.
  assert.match(lane, /install -m 0644 -o root -g root "\$tmp\/out\/agent\/broker\/src\/"\*\.ts/);
  // Relay mode only: request and decide take a message id; no bare approve/refuse, no identity flags.
  assert.match(lane, /'agent ALL=\(credbroker\) NOPASSWD: %s request \*, %s decide \*, %s whois \*, %s sweep, %s verify-audit, %s ship-audit\\n'/);
  // Audit shipping: a credbroker-only timer, the group Terraform grants, off whenever the sudo rule is.
  assert.match(lane, /^BROKER_AUDIT_LOG_GROUP=\/aws-cred-broker\/audit$/m);
  // The group's region, not the host's (the host runs in us-west-2; Terraform made the group in us-east-1).
  assert.match(lane, /^BROKER_AUDIT_LOG_REGION=us-east-1$/m);
  assert.match(lane, /export BROKER_AUDIT_LOG_GROUP=%s BROKER_AUDIT_LOG_REGION=%s /);
  assert.match(lane, /User=credbroker\\nGroup=credbroker\\nExecStart=\/usr\/local\/libexec\/aws-cred-broker ship-audit/);
  assert.match(lane, /rm -f \/etc\/sudoers\.d\/aws-cred-broker\n  systemctl disable --now aws-cred-broker-ship-audit\.timer/);
  const sudoers = lane.split("\n").find((l) => l.includes("NOPASSWD"))!;
  assert.doesNotMatch(sudoers, /approve|refuse/, "decisions only through decide, verified against Relay");
  assert.match(lane, /visudo -cf \/etc\/sudoers\.d\/aws-cred-broker\.new/);
  // The broker role's profile belongs to credbroker, never the agent user.
  const agentConfig = lane.slice(lane.indexOf('sudo -H -u agent env ROLE="$AWS_ADMIN_ROLE_ARN"'), lane.indexOf("# The AWS credential broker"));
  assert.doesNotMatch(agentConfig, /aws-cred-broker|CRED_BROKER/);
  assert.match(lane, /sudo -H -u credbroker env ROLE="\$CRED_BROKER_ROLE_ARN"/);
  // Relay mode is on: the wrapper names the token file and the broker's Relay identity, and the
  // token goes from SSM to a credbroker-only 0600 file (never secrets.env, never printed).
  assert.match(lane, /export BROKER_RELAY_TOKEN_FILE=%s\/relay-observer-token BROKER_RELAY_API=https:\/\/cast\.agentrelay\.com BROKER_RELAY_NAME=%s/);
  assert.match(lane, /--name "\$RELAY_OBSERVER_TOKEN_PARAM" --query Parameter\.Value --output text > "\$tok_tmp"/);
  assert.match(lane, /install -m 0600 -o credbroker -g credbroker "\$tok_tmp" "\$BROKER_HOME\/relay-observer-token"/);
  // Fail closed on a failed upgrade: unless current is exactly the pin, the sudo rule is removed
  // (an older broker that predates Relay verification is never reachable).
  assert.match(lane, /readlink \/opt\/aws-cred-broker\/current 2>\/dev\/null\)" != "\/opt\/aws-cred-broker\/\$broker_ref" \]; then\n  rm -f \/etc\/sudoers\.d\/aws-cred-broker/);
  const token = agent.secrets.find((s) => s.envVar === "RELAY_OBSERVER_TOKEN_PARAM")!;
  assert.ok(token, "the observer token is a lane secret");
  assert.equal(token.exportAs, undefined, "never exported to secrets.env");
  // The lead passes only the message id; it never builds identity flags or approves itself.
  const prompt = readFileSync(new URL("../lead-prompt.md", import.meta.url), "utf8");
  assert.match(prompt, /aws-cred-broker request --message-id ID/);
  assert.match(prompt, /aws-cred-broker decide --message-id ID/);
  // Every agent's how-to exists and the card points at it.
  const howto = readFileSync(new URL("../broker/AGENTS.md", import.meta.url), "utf8");
  assert.match(howto, /client\.ts keygen --name/);
  assert.match(howto, /DM `layered-infra-ops`/);
  assert.match(agent.input.card!.skills.find((s) => s.id === "aws-credentials")!.description, /agent\/broker\/AGENTS\.md/);
  assert.doesNotMatch(prompt, /--from-name|--from-kind|aws-cred-broker approve/);
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
    "aws-credentials",
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
  assert.deepEqual(agent.files.filter((f) => f.source === "generated"), [{ name: AGENT_CARD_FILE, source: "generated" }, { name: ISSUE_WATCH_FILE, source: "generated" }, { name: STEWARDSHIP_FILE, source: "generated" }]);
  const script = gunzipSync(Buffer.from(userDataBase64(agent, read), "base64")).toString("utf8");
  assert.ok(!script.includes(`cat > /opt/agent-host/${AGENT_CARD_FILE}`), "the card never rides in user data");
});

test("new-issue and new-PR watch: this repo, to khaliq-gant, generated and kept out of user data", () => {
  assert.deepEqual(agent.input.issueWatch, { repos: ["AgentWorkforce/infra"], notify: "khaliq-gant" });
  assert.equal(agent.generated[ISSUE_WATCH_FILE], renderIssueWatch(agent.input.issueWatch!));
  // Since kit 0.1.29 a watch covers pull requests too unless it sets pullRequests: false.
  const watch = JSON.parse(agent.generated[ISSUE_WATCH_FILE]!) as { notify: string[]; pullRequests: boolean; globs: string[] };
  assert.deepEqual(watch.notify, ["khaliq-gant"]);
  assert.equal(watch.pullRequests, true);
  assert.deepEqual(watch.globs, ["/github/repos/AgentWorkforce/infra/issues/**", "/github/repos/AgentWorkforce/infra/pulls/**"]);
  const script = gunzipSync(Buffer.from(userDataBase64(agent, read), "base64")).toString("utf8");
  assert.ok(!script.includes(`cat > /opt/agent-host/${ISSUE_WATCH_FILE}`), "the watch never rides in user data");
});

test("repo stewardship: the kit's default for this repo, generated and kept out of user data", () => {
  assert.equal(agent.input.stewardship, undefined, "the default: on, this repo, the kit's stale thresholds");
  const steward = stewardship(agent.input)!;
  assert.deepEqual(steward.repos, ["AgentWorkforce/infra"]);
  // The explicit issueWatch above replaces stewardship's own watch, so khaliq-gant stays the one notified.
  assert.deepEqual(steward.owners, []);
  assert.equal(agent.generated[STEWARDSHIP_FILE], renderStewardship(steward));
  for (const name of STEWARDSHIP_KIT_FILES) assert.ok(agent.files.some((f) => f.name === name && f.source === "kit"), name);
  const script = gunzipSync(Buffer.from(userDataBase64(agent, read), "base64")).toString("utf8");
  assert.ok(!script.includes(`cat > /opt/agent-host/${STEWARDSHIP_FILE}`), "stewardship never rides in user data");
});
