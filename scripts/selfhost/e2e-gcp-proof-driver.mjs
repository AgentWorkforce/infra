// In-cluster driver for e2e-gcp-proof.sh.
//
// Runs inside the relay-control pod (the only agent-relay workload whose
// NetworkPolicy reaches Relaycast, RelayHistory, and RelayAuth) with Node's
// built-in fetch. The `sessions` and `admin` phases instead run on the
// operator's machine with E2E_API_URL set to the public dashboard origin, so
// they exercise the same /cloud/api path the browser uses. Usage:
//
//   node e2e-gcp-proof-driver.mjs <phase>   < state.json  > result.json
//
// stdin is the JSON state from the previous phase plus `secrets`, which the
// caller injects on every call and which is never written back. stdout is one
// JSON object `{ state, proofs }`. `state` holds test-workspace credentials
// and is kept by the caller in a mode-0600 file; `proofs` holds only curated,
// non-secret details. Nothing here logs a token, key, or response body.

import { createHash, createPublicKey, randomBytes, randomUUID, verify as cryptoVerify } from "node:crypto";
import { readFileSync } from "node:fs";

const RELAYCAST = process.env.E2E_RELAYCAST_URL ?? "http://relaycast:8787";
const HISTORY = process.env.E2E_RELAYHISTORY_URL ?? "http://relayhistory:8080";
const API = process.env.E2E_API_URL ?? "http://localhost:3000";
const RELAYAUTH = process.env.E2E_RELAYAUTH_URL ?? "http://relayauth.relayauth.svc:8787";
const BOOTSTRAP_FILE = "/var/run/agent-relay/secrets/selfhost-bootstrap-token";
const RELAYAUTH_KEY_FILE = "/var/run/agent-relay/secrets/relayauth-api-key";
const SOURCE = "claude";

const phase = process.argv[2];
const input = JSON.parse(readFileSync(0, "utf8") || "{}");
const secrets = input.secrets ?? {};
delete input.secrets;
const state = input;
const proofs = [];

function proof(result, check, detail) {
  proofs.push({ result, check, detail: String(detail) });
}
const pass = (check, detail) => proof("PASS", check, detail);
const fail = (check, detail) => proof("FAIL", check, detail);

class CheckError extends Error {}
function must(condition, message) {
  if (!condition) throw new CheckError(message);
}

const sha256 = (text) => createHash("sha256").update(text, "utf8").digest("hex");

async function call(method, url, { token, headers = {}, body, timeoutMs = 20_000 } = {}) {
  const response = await fetch(url, {
    method,
    redirect: "manual",
    signal: AbortSignal.timeout(timeoutMs),
    headers: {
      accept: "application/json",
      ...(body === undefined ? {} : { "content-type": "application/json" }),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...headers,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  // `text` is kept only for leak checks (does a body contain a value it must
  // never return); it is never logged or written to the state.
  return { status: response.status, json, text };
}

// Relaycast wraps payloads as { ok, data }.
const rcData = (response) => response.json?.data ?? response.json;

function errorCode(response) {
  const error = response.json?.error;
  if (typeof error === "string") return error;
  if (error && typeof error.code === "string") return error.code;
  return "none";
}

// ---------------------------------------------------------------- bootstrap

const bootstrapToken = () => readFileSync(BOOTSTRAP_FILE, "utf8").trim();
const INTERNAL_TOKEN_FILE = "/var/run/agent-relay/secrets/selfhost-internal-token";

// Every control-plane resource a phase creates in workspace A is recorded in
// the state *before* any assertion can fail, so the cleanup phase (case 15,
// or the shell's EXIT trap on interruption) can remove it even when the phase
// that created it failed. Kinds: flows (id), envVars (name),
// enrollmentTokens (id), workerNames (name).
function track(kind, value) {
  state.resources ??= {};
  state.resources[kind] ??= [];
  if (!state.resources[kind].includes(value)) state.resources[kind].push(value);
}
function untrack(kind, value) {
  if (state.resources?.[kind]) state.resources[kind] = state.resources[kind].filter((item) => item !== value);
}

// Feature detection, so the proof also runs against a control plane without
// the newer APIs: a feature is present when /openapi.yaml declares its route
// or the route exists (an unknown route answers 404 not_found; a known one
// answers 401 to an anonymous call). A present feature that is broken still
// fails its case; only an absent one is skipped.
async function detectCapabilities() {
  const spec = await call("GET", `${API}/openapi.yaml`, { headers: { accept: "application/yaml" } });
  const declared = (path) => spec.status === 200 && spec.text.includes(`\n  ${path}:`);
  const routed = async (path) => {
    const response = await call("GET", `${API}${path}`);
    return !(response.status === 404 && errorCode(response) === "not_found");
  };
  const probe = randomUUID();
  const capabilities = {
    sessions: declared("/cloud/api/v1/workspaces/{workspaceId}/sessions/activity") ||
      await routed(`/cloud/api/v1/workspaces/${probe}/sessions/activity?first=2020-01-01&last=2020-01-01`),
    admin: declared("/api/v1/workspaces/{workspaceId}/secrets") ||
      await routed(`/api/v1/workspaces/${probe}/secrets`),
    flows: declared("/api/v1/workers/enrollment-tokens") ||
      await routed("/api/v1/workers/enrollment-tokens"),
  };
  return { capabilities, openapi: spec.status };
}

// The control plane holds exactly one organization per installation. The
// proof reuses it and adds two uniquely named test workspaces to it.
async function installationOrganization(bootstrap) {
  const orgs = await call("GET", `${API}/api/v1/organizations`, { token: bootstrap });
  must(orgs.status === 200 && Array.isArray(orgs.json?.organizations), `organizations list status=${orgs.status}`);
  must(orgs.json.organizations.length === 1, `organizations=${orgs.json.organizations.length} expected exactly 1`);
  const org = orgs.json.organizations[0];
  const members = await call("GET", `${API}/api/v1/organizations/${org.id}/memberships`, { token: bootstrap });
  must(members.status === 200 && Array.isArray(members.json?.memberships), `memberships status=${members.status}`);
  const owners = members.json.memberships
    .filter((member) => member.role === "owner")
    .map((member) => member.userId)
    .sort();
  must(owners.length > 0, "the organization has no owner");
  return { organizationId: org.id, organizationName: org.name, ownerUserId: owners[0], members: members.json.memberships.length };
}

// Device authorization exactly as Desktop does it, approved by the bootstrap
// bearer on behalf of the organization owner for one workspace.
async function deviceLogin(bootstrap, userId, workspaceId, clientName) {
  const start = await call("POST", `${API}/api/v1/auth/device/start`, { body: { client_name: clientName } });
  must(start.status === 201, `device start status=${start.status}`);
  const approve = await call("POST", `${API}/api/v1/auth/device/approve`, {
    token: bootstrap,
    body: { action: "approve", user_code: start.json.user_code, user_id: userId, workspace_id: workspaceId },
  });
  must(approve.status === 200, `device approve status=${approve.status} error=${errorCode(approve)}`);
  const tokens = await call("POST", `${API}/api/v1/auth/device/token`, { body: { device_code: start.json.device_code } });
  must(tokens.status === 200 && tokens.json?.access_token, `device token status=${tokens.status}`);
  return tokens.json;
}

// Relaycast workspaces are created in-cluster through POST /internal/workspaces
// (the public edge denies /internal and /v1/workspaces). The SQLite server
// and the durable-actors gateway share that contract; the gateway's create
// spawns a workspace actor and can take ~100s, so the timeout comes from the
// caller (--relaycast-create-timeout, default 180s).
async function checkRelaycastInternal() {
  const capabilities = await call("GET", `${RELAYCAST}/internal/capabilities`, { token: secrets.relaycastInternalSecret });
  must(capabilities.status === 200, `relaycast /internal/capabilities status=${capabilities.status} error=${errorCode(capabilities)} (mode=${state.relaycast?.mode})`);
  const admin = rcData(capabilities)?.workspace_admin;
  must(!admin || admin.create !== false, "relaycast reports workspace_admin.create=false");
  // Cleanup deletes what bootstrap creates, so a Relaycast that cannot
  // delete workspaces is refused before anything is created.
  // (Only when cleanup is on: --no-cleanup keeps the workspaces anyway.)
  must(!admin || admin.delete !== false || state.cleanup === false,
    "relaycast reports workspace_admin.delete=false; the run could not clean up its workspaces (use --no-cleanup to keep them)");
  return admin ? `create=${admin.create} delete=${admin.delete}` : "workspace_admin=unreported";
}

async function createRelaycastWorkspace(label) {
  const timeoutMs = state.relaycast?.createTimeoutMs ?? 180_000;
  const started = Date.now();
  let rc;
  try {
    rc = await call("POST", `${RELAYCAST}/internal/workspaces`, {
      token: secrets.relaycastInternalSecret,
      body: { name: `e2e-${state.marker}-${label}` },
      timeoutMs,
    });
  } catch (error) {
    // The create may still commit server-side; Relaycast has no lookup by
    // name, so name the possible orphan for manual removal.
    throw new CheckError(`relaycast internal create (${label}) failed after ${Date.now() - started}ms: ${error?.name === "TimeoutError" ? `timeout ${timeoutMs}ms` : error?.message}; a workspace named e2e-${state.marker}-${label} may exist and need manual deletion`);
  }
  const ms = Date.now() - started;
  must(rc.status === 201, `relaycast internal create (${label}) status=${rc.status} error=${errorCode(rc)} after ${ms}ms`);
  const workspace = rcData(rc);
  // Record the id for cleanup as soon as the 201 names it, before any
  // further validation can fail.
  if (rc.status === 201 && typeof workspace?.workspace_id === "string" && workspace.workspace_id.length > 0) {
    state[label] = { relaycastWorkspaceId: workspace.workspace_id };
  }
  must(typeof workspace?.workspace_id === "string" && workspace.workspace_id.length > 0, `relaycast create (${label}) returned no workspace id`);
  must(typeof workspace.api_key === "string" && workspace.api_key.length >= 16, `relaycast create (${label}) returned no workspace key`);
  return { workspaceId: workspace.workspace_id, apiKey: workspace.api_key, ms };
}

async function createTenant(label, org, rcWorkspace) {
  const bootstrap = bootstrapToken();
  const marker = state.marker;
  const rcKey = rcWorkspace.apiKey;

  const ws = await call("POST", `${API}/api/v1/organizations/${org.organizationId}/workspaces`, {
    token: bootstrap,
    body: {
      name: `e2e-${marker}-${label}`,
      relaycastWorkspaceId: rcWorkspace.workspaceId,
      relaycastApiKey: rcKey,
    },
  });
  must(ws.status === 201, `workspace create status=${ws.status} error=${errorCode(ws)}`);
  must(ws.json?.organizationId === org.organizationId, "workspace was created in another organization");

  const tenant = {
    relaycastWorkspaceId: rcWorkspace.workspaceId,
    relaycastCreateMs: rcWorkspace.ms,
    relaycastKey: rcKey,
    organizationId: org.organizationId,
    ownerUserId: org.ownerUserId,
    workspaceId: ws.json.id,
    workspaceName: ws.json.name,
  };
  // The workspace already exists. Preserve its cleanup identity even when
  // the following device login fails before returning a token.
  state[label] = tenant;
  const tokens = await deviceLogin(bootstrap, org.ownerUserId, ws.json.id, `e2e-${marker}-${label}`);
  return {
    ...tenant,
    accessToken: tokens.access_token,
    refreshToken: tokens.refresh_token,
    scope: tokens.scope,
  };
}

async function phaseBootstrap() {
  state.marker = state.marker ?? `e2e${Date.now().toString(36)}${randomBytes(3).toString("hex")}`;
  state.startedAt = new Date().toISOString();
  const bootstrap = bootstrapToken();
  const org = await installationOrganization(bootstrap);
  state.org = { organizationId: org.organizationId, ownerUserId: org.ownerUserId };
  pass("bootstrap.organization", `org=${org.organizationId} name=${JSON.stringify(org.organizationName)} owner=${org.ownerUserId} members=${org.members}`);

  // A second organization is refused, and the installation still has one.
  const second = await call("POST", `${API}/api/v1/organizations`, {
    token: bootstrap,
    body: {
      name: `e2e-${state.marker}-second-org`,
      ownerEmail: `e2e-${state.marker}-second@${state.emailDomain}`,
      ownerName: "E2E Second",
    },
  });
  must(second.status === 409 && errorCode(second) === "organization_already_configured",
    `second organization create status=${second.status} error=${errorCode(second)}`);
  const after = await installationOrganization(bootstrap);
  must(after.organizationId === org.organizationId, "the installation organization changed");
  pass("bootstrap.single_organization", `second_org_create=${second.status} error=${errorCode(second)} organizations=1`);

  const detected = await detectCapabilities();
  state.capabilities = detected.capabilities;
  pass("bootstrap.capabilities", `openapi=${detected.openapi} ${Object.entries(detected.capabilities).map(([k, v]) => `${k}=${v}`).join(" ")}`);

  const rcMode = await checkRelaycastInternal();
  // Both Relaycast workspaces are created concurrently; each is recorded for
  // cleanup as soon as it exists, even if the other create fails.
  const created = await Promise.allSettled(["a", "b"].map(async (label) => {
    return createRelaycastWorkspace(label);
  }));
  const failed = created.find((result) => result.status === "rejected");
  if (failed) throw failed.reason;
  pass("bootstrap.relaycast_workspaces", `mode=${state.relaycast?.mode} ${rcMode} create_ms=${created.map((result) => result.value.ms).join(",")}`);
  for (const [index, label] of ["a", "b"].entries()) {
    const tenant = await createTenant(label, org, created[index].value);
    state[label] = tenant;
    pass(
      `bootstrap.tenant_${label}`,
      `relaycast_ws=${tenant.relaycastWorkspaceId} org=${tenant.organizationId} workspace=${tenant.workspaceId} name=${tenant.workspaceName} owner=${tenant.ownerUserId} scope=${tenant.scope.replace(/ /g, ",")}`,
    );
    const who = await call("GET", `${API}/api/v1/auth/whoami`, { token: tenant.accessToken });
    must(
      who.status === 200 && who.json?.currentWorkspace?.id === tenant.workspaceId &&
        who.json?.currentOrganization?.id === org.organizationId,
      `whoami status=${who.status}`,
    );
    const resolved = await call("GET", `${API}/api/v1/workspaces/${tenant.workspaceId}/resolve`, {
      token: tenant.accessToken,
    });
    must(resolved.status === 200, `resolve status=${resolved.status}`);
    must(
      resolved.json.relaycastWorkspaceId === tenant.relaycastWorkspaceId &&
        resolved.json.relaycastApiKey === tenant.relaycastKey,
      "resolve returned a different Relaycast workspace or no key",
    );
    // The key Desktop actually uses is the one the control plane returns.
    tenant.relaycastKey = resolved.json.relaycastApiKey;
    pass(
      `bootstrap.resolve_${label}`,
      `whoami_workspace_matches=true whoami_org_matches=true relaycast_url=${resolved.json.urls?.relaycastUrl}`,
    );
  }
  const listed = await call("GET", `${API}/api/v1/organizations/${org.organizationId}/workspaces`, { token: bootstrap });
  must(listed.status === 200 && Array.isArray(listed.json?.workspaces), `workspace list status=${listed.status}`);
  const ids = listed.json.workspaces.map((workspace) => workspace.id);
  must(ids.includes(state.a.workspaceId) && ids.includes(state.b.workspaceId), "org workspace list is missing a test workspace");
  pass("bootstrap.workspaces_listed", `org_workspaces=${ids.length} contains_a_and_b=true`);

  await checkMembershipGate(bootstrap, org);
}

// Device approval is gated on organization membership (per org), and a user
// token can only approve for the workspace it is bound to.
async function checkMembershipGate(bootstrap, org) {
  const startCode = async (name) => {
    const start = await call("POST", `${API}/api/v1/auth/device/start`, { body: { client_name: name } });
    must(start.status === 201, `device start status=${start.status}`);
    return start.json;
  };
  const approveAs = (code, userId, workspaceId, token = bootstrap) =>
    call("POST", `${API}/api/v1/auth/device/approve`, {
      token,
      body: { action: "approve", user_code: code.user_code, workspace_id: workspaceId, ...(userId ? { user_id: userId } : {}) },
    });

  // 1. A user id that never existed.
  const ghostCode = await startCode(`e2e-${state.marker}-ghost`);
  const ghost = await approveAs(ghostCode, randomUUID(), state.a.workspaceId);
  must(ghost.status === 403 && errorCode(ghost) === "not_member", `unknown user approve status=${ghost.status} error=${errorCode(ghost)}`);

  // 2. A real user whose membership was removed: add, remove, then approve.
  const email = `e2e-${state.marker}-outsider@${state.emailDomain}`;
  const added = await call("POST", `${API}/api/v1/organizations/${org.organizationId}/memberships`, {
    token: bootstrap,
    body: { email, name: `E2E Outsider ${state.marker}`, role: "member" },
  });
  must(added.status === 200 && typeof added.json?.userId === "string", `membership add status=${added.status} error=${errorCode(added)}`);
  const outsider = added.json.userId;
  const removed = await call("DELETE", `${API}/api/v1/organizations/${org.organizationId}/memberships/${outsider}`, { token: bootstrap });
  must(removed.status === 204, `membership remove status=${removed.status} error=${errorCode(removed)}`);
  const members = await call("GET", `${API}/api/v1/organizations/${org.organizationId}/memberships`, { token: bootstrap });
  must(members.status === 200 && !members.json.memberships.some((m) => m.userId === outsider), "removed user is still listed as a member");
  const outsiderCode = await startCode(`e2e-${state.marker}-outsider`);
  const refused = await approveAs(outsiderCode, outsider, state.a.workspaceId);
  must(refused.status === 403 && errorCode(refused) === "not_member", `non-member approve status=${refused.status} error=${errorCode(refused)}`);
  const pending = await call("POST", `${API}/api/v1/auth/device/token`, { body: { device_code: outsiderCode.device_code } });
  must(pending.status === 400 && errorCode(pending) === "authorization_pending",
    `non-member device poll status=${pending.status} error=${errorCode(pending)}`);
  state.outsider = { userId: outsider };

  // 3. A's user token approving a code for workspace B.
  const crossCode = await startCode(`e2e-${state.marker}-cross`);
  const cross = await approveAs(crossCode, null, state.b.workspaceId, state.a.accessToken);
  must(cross.status === 404 && errorCode(cross) === "workspace_not_found", `A approving for B status=${cross.status} error=${errorCode(cross)}`);

  // Deny the leftover codes so nothing stays pending, and confirm a denied
  // code never yields a token.
  for (const code of [ghostCode, outsiderCode, crossCode]) {
    const denied = await call("POST", `${API}/api/v1/auth/device/approve`, {
      token: bootstrap,
      body: { action: "deny", user_code: code.user_code, user_id: org.ownerUserId, workspace_id: state.a.workspaceId },
    });
    must(denied.status === 200 && denied.json?.status === "denied", `deny leftover code status=${denied.status}`);
  }
  const deniedPoll = await call("POST", `${API}/api/v1/auth/device/token`, { body: { device_code: outsiderCode.device_code } });
  must(deniedPoll.status === 400 && !deniedPoll.json?.access_token, `denied code poll status=${deniedPoll.status}`);
  pass(
    "bootstrap.membership_gate",
    `unknown_user=${ghost.status}/${errorCode(ghost)} removed_member=${refused.status}/${errorCode(refused)} removed_member_poll=${errorCode(pending)} a_token_for_b=${cross.status}/${errorCode(cross)} denied_poll=${errorCode(deniedPoll)} outsider=${outsider}`,
  );
}

// ---------------------------------------------------------------- messaging

async function registerAgent(tenant, name) {
  const response = await call("POST", `${RELAYCAST}/v1/agents`, {
    token: tenant.relaycastKey,
    body: { name, type: "agent", metadata: { e2e: state.marker } },
  });
  must(response.status === 201 || response.status === 200, `register ${name} status=${response.status} error=${errorCode(response)}`);
  const data = rcData(response);
  must(typeof data.token === "string", `register ${name} returned no agent token`);
  return { id: data.id, name: data.name, token: data.token };
}

async function rosterNames(tenant) {
  const response = await call("GET", `${RELAYCAST}/v1/agents`, { token: tenant.relaycastKey });
  must(response.status === 200, `roster status=${response.status}`);
  const list = rcData(response);
  const agents = Array.isArray(list) ? list : list?.agents ?? list?.items ?? [];
  return agents.map((agent) => agent.name);
}

async function dmThread(agent, peerName) {
  const conversations = await call("GET", `${RELAYCAST}/v1/dm/conversations`, { token: agent.token });
  must(conversations.status === 200, `conversations status=${conversations.status}`);
  const list = rcData(conversations);
  const items = Array.isArray(list) ? list : list?.conversations ?? list?.items ?? [];
  const match = items.find((conversation) =>
    JSON.stringify(conversation.participants ?? conversation.members ?? conversation).includes(peerName),
  );
  must(match, `no DM conversation with ${peerName}`);
  const conversationId = match.id ?? match.conversation_id;
  const messages = await call("GET", `${RELAYCAST}/v1/dm/${conversationId}/messages?limit=50`, {
    token: agent.token,
  });
  must(messages.status === 200, `dm messages status=${messages.status}`);
  const body = rcData(messages);
  const list2 = Array.isArray(body) ? body : body?.messages ?? body?.items ?? [];
  return { conversationId, messages: list2 };
}

const messageText = (message) => message.text ?? message.content ?? message.body ?? "";

async function phaseMessaging() {
  const tenant = state.a;
  const names = [`e2e-${state.marker}-alpha`, `e2e-${state.marker}-beta`];
  const alpha = await registerAgent(tenant, names[0]);
  const beta = await registerAgent(tenant, names[1]);
  state.agents = { alpha, beta };
  pass("messaging.register", `agents=${alpha.id},${beta.id}`);

  const roster = await rosterNames(tenant);
  must(names.every((name) => roster.includes(name)), "roster is missing a registered agent");
  pass("messaging.roster", `roster_size=${roster.length} contains_both=true`);

  const pingText = `${state.marker} ping from alpha`;
  const ping = await call("POST", `${RELAYCAST}/v1/dm`, {
    token: alpha.token,
    body: { to: beta.name, text: pingText },
  });
  must(ping.status === 200 || ping.status === 201, `send ping status=${ping.status} error=${errorCode(ping)}`);
  const pingId = rcData(ping)?.id ?? rcData(ping)?.message_id ?? rcData(ping)?.message?.id;

  const betaView = await dmThread(beta, alpha.name);
  must(betaView.messages.some((m) => messageText(m) === pingText), "beta did not receive the ping");
  pass("messaging.a_to_b", `conversation=${betaView.conversationId} message=${pingId ?? "n/a"}`);

  const replyText = `${state.marker} reply from beta`;
  const reply = await call("POST", `${RELAYCAST}/v1/dm`, {
    token: beta.token,
    body: { to: alpha.name, text: replyText },
  });
  must(reply.status === 200 || reply.status === 201, `send reply status=${reply.status} error=${errorCode(reply)}`);
  const replyId = rcData(reply)?.id ?? rcData(reply)?.message_id ?? rcData(reply)?.message?.id;

  const alphaView = await dmThread(alpha, beta.name);
  must(alphaView.conversationId === betaView.conversationId, "reply landed in a different conversation");
  must(alphaView.messages.some((m) => messageText(m) === replyText), "alpha did not receive the reply");
  pass("messaging.b_to_a_same_conversation", `conversation=${alphaView.conversationId} message=${replyId ?? "n/a"}`);

  state.dm = { conversationId: alphaView.conversationId, pingText, replyText, pingId, replyId };
  await checkMessageHistory("messaging.history");
}

async function checkMessageHistory(check) {
  const { alpha, beta } = state.agents;
  for (const [agent, peer] of [[alpha, beta], [beta, alpha]]) {
    const view = await dmThread(agent, peer.name);
    must(view.conversationId === state.dm.conversationId, `${agent.name} sees another conversation`);
    const texts = view.messages.map(messageText);
    const iPing = texts.indexOf(state.dm.pingText);
    const iReply = texts.indexOf(state.dm.replyText);
    must(iPing >= 0 && iReply >= 0, `${agent.name} history is missing a message`);
  }
  pass(check, `conversation=${state.dm.conversationId} both_agents_see_ping_and_reply=true`);
}

// ---------------------------------------------------------------- history

async function historySession(tenant, mode) {
  const response = await call("POST", `${API}/api/v1/workspaces/${tenant.workspaceId}/relayhistory/session`, {
    token: tenant.accessToken,
    body: { mode, label: `e2e-${state.marker}` },
  });
  must(
    response.status === 200 && typeof response.json?.accessToken === "string",
    `relayhistory/session(${mode}) status=${response.status} error=${errorCode(response)} stage=${response.json?.stage ?? "none"} upstream=${response.json?.upstreamStatus ?? "none"}`,
  );
  return response.json;
}

function accountId(tenant) {
  return `relayhistory:${sha256(JSON.stringify([tenant.organizationId, tenant.workspaceId]))}`;
}

function buildBatch() {
  const marker = state.marker;
  const sessionId = state.session.sessionId;
  const origin = state.session.originId;
  const now = Date.parse(state.startedAt);
  const project = "/e2e/gcp-proof";
  const base = { git_branch: null, project, session_id: sessionId, source: SOURCE };
  const sessionEvent = (id, role, text, ts) => ({
    ...base,
    agent_id: null, agent_version: null, call_index: null, cwd: project, error_signal: null,
    event_index: id, event_source: "provider", event_uid: `${sessionId}-message-${id}:0`, id,
    is_meta: 0, is_sidechain: 0, kind: "text", message_id: `${sessionId}-message-${id}`, model: null,
    parent_id: null, payload_bytes: null, payload_hash: null, payload_truncated: 0,
    project_key: null, project_key_method: null, provider: "anthropic", provider_message_id: null,
    raw_facts_version: 2, raw_kind: role, request_id: null, request_span: null,
    result_status: "completed", role, stop_reason: null, subagent_session_id: null, text,
    token_json: null, tool_use_id: null, ts_ms: ts, turn_id: `turn-${id}`,
  });
  const payloads = [
    ["session", {
      agent_version: null, cwd: project, discovery_state: "full", first_activity_ms: now,
      first_prompt: `${marker} first prompt`, git_branch: null, initial_commit: null,
      last_activity_ms: now + 2000, last_assistant_text: `${marker} assistant answer`,
      models_json: null, originator: null, parser_version: 1, project_key: null,
      project_key_method: null, repo_url: null, session_id: sessionId, source: SOURCE,
      source_stamp: null, workspace_roots_json: null,
    }],
    ["history", { ...base, id: 1, prompt: `${marker} first prompt`, prompt_hash: sha256(marker).slice(0, 16), timestamp_ms: now }],
    ["session_event", sessionEvent(1, "user", `${marker} first prompt`, now)],
    ["session_event", sessionEvent(2, "assistant", `${marker} assistant answer`, now + 1000)],
    ["tool_call", {
      args_json: JSON.stringify({ path: `${project}/README.md` }), id: 1, is_error: 0,
      message_id: `${sessionId}-message-2`, name: "Read", session_id: sessionId, source: SOURCE,
      target: "README.md", tool_use_id: `${sessionId}-tool-1`, ts_ms: now + 1500,
    }],
  ];
  const records = payloads.map(([kind, payload], index) => {
    const recordId = sha256(`${origin}:${kind}:${sessionId}:${index}`);
    const revisionId = sha256(`${recordId}:1:${JSON.stringify(payload)}`);
    return {
      kind, operation: "upsert", origin_id: origin, payload, record_id: recordId,
      revision: 1, revision_id: revisionId, schema_version: 1, session_id: sessionId, source: SOURCE,
    };
  });
  return {
    protocolVersion: 1,
    batch: {
      account_id: accountId(state.a),
      batch_id: sha256(`${origin}:batch:1`).slice(0, 32),
      destination_id: "relayhistory",
      generation: 1,
      instance_id: `e2e-${marker}`,
      job_id: sha256(`${origin}:job:1`).slice(0, 32),
      mapping_version: "relayhistory-delivery-v1",
      origin_id: origin,
      records,
      schema_version: 1,
    },
  };
}

async function eventsDirect(token, tenant, sessionId) {
  const params = new URLSearchParams({ workspace: tenant.workspaceId, source: SOURCE, order: "asc", limit: "1000" });
  return call("GET", `${HISTORY}/v1/sessions/${encodeURIComponent(sessionId)}/events?${params}`, { token });
}

function markerEvents(events) {
  return (events ?? []).filter((event) => JSON.stringify(event).includes(state.marker));
}

// The event content RelayHistory projects from each record kind (the delivery
// projection: history -> prompt, session_event -> text, tool_call -> "name
// target"). The `session` record updates the catalogue and projects no event.
function expectedProjection() {
  const content = ({ kind, payload }) => {
    if (kind === "history") return payload.prompt;
    if (kind === "session_event") return payload.text;
    if (kind === "tool_call") return [payload.name, payload.target].filter(Boolean).join(" ");
    return null;
  };
  return buildBatch().batch.records.map(content).filter((text) => text !== null).sort();
}

function projectionMatches(events) {
  const actual = events.map((event) => event.content ?? "").sort();
  return JSON.stringify(actual) === JSON.stringify(expectedProjection());
}

// A read that must not return the given session's events passes only on a
// successful response without them or an explicit denial/not-found; a server
// error, a redirect or an unparseable body proves nothing.
function absentOrDenied(response, extract, denied = [403, 404]) {
  if (denied.includes(response.status)) return { ok: true, leaked: 0 };
  if (response.status !== 200 || !response.json) return { ok: false, leaked: null };
  const leaked = extract(response.json);
  return { ok: leaked === 0, leaked };
}
const eventLeaks = (json) => markerEvents(json.events).length;

async function phaseDelivery() {
  state.session = {
    sessionId: `e2e-${state.marker}-session`,
    originId: sha256(`origin:${state.marker}`).slice(0, 32),
  };
  const sync = await historySession(state.a, "sync");
  pass("delivery.session_token", `base_url=${sync.baseUrl} scopes=${(sync.scopes ?? []).join(",")}`);
  const request = buildBatch();

  const limits = await call("GET", `${HISTORY}/v1/delivery/limits`, { token: sync.accessToken });
  must(limits.status === 200, `delivery limits status=${limits.status}`);

  const first = await call("POST", `${HISTORY}/v1/delivery/batches`, { token: sync.accessToken, body: request });
  must(first.status === 200, `first delivery status=${first.status} error=${errorCode(first)}`);
  const receipt = first.json;
  const submitted = request.batch.records.map((record) => record.revision_id);
  must(receipt.acceptanceLevel === "durable", `acceptanceLevel=${receipt.acceptanceLevel}`);
  must(
    JSON.stringify(receipt.acceptedRevisionIds) === JSON.stringify(submitted),
    "receipt does not list every submitted revision in order",
  );
  must(typeof receipt.receiptId === "string", "receipt has no receiptId");
  state.session.batchId = request.batch.batch_id;
  state.session.receiptId = receipt.receiptId;
  state.session.records = submitted.length;
  pass(
    "delivery.first",
    `batch=${receipt.batchId} receipt=${receipt.receiptId} accepted=${receipt.acceptedRevisionIds.length} level=${receipt.acceptanceLevel}`,
  );

  // Retry the identical batch as Desktop does after losing the first response.
  const retry = await call("POST", `${HISTORY}/v1/delivery/batches`, { token: sync.accessToken, body: request });
  must(retry.status === 200, `retry delivery status=${retry.status} error=${errorCode(retry)}`);
  must(retry.json.receiptId === receipt.receiptId, "retry returned a different receipt");
  must(
    JSON.stringify(retry.json.acceptedRevisionIds) === JSON.stringify(submitted),
    "retry accepted a different revision set",
  );
  pass("delivery.retry_same_receipt", `receipt=${retry.json.receiptId}`);

  const records = await call(
    "GET",
    `${HISTORY}/v1/delivery/records?${new URLSearchParams({ session_id: state.session.sessionId, source: SOURCE })}`,
    { token: sync.accessToken, headers: { "X-RelayHistory-Expected-Account": accountId(state.a) } },
  );
  const recordCount = Array.isArray(records.json?.records) ? records.json.records.length : null;

  must(records.status === 200, `delivery records status=${records.status} error=${errorCode(records)}`);
  must(recordCount === submitted.length, `retained delivery records=${recordCount} expected=${submitted.length}`);
  const events = await eventsDirect(sync.accessToken, state.a, state.session.sessionId);
  must(events.status === 200, `events status=${events.status}`);
  const projected = markerEvents(events.json.events);
  const ids = projected.map((event) => event.eventId);
  must(new Set(ids).size === ids.length, "duplicate projected events after retry");
  const expected = expectedProjection();
  must(
    projected.length === expected.length && projectionMatches(projected),
    `projected events=${projected.length} expected=${expected.length} content_matches=${projectionMatches(projected)}`,
  );
  state.session.projectedEvents = projected.length;
  pass(
    "delivery.single_projection",
    `projected_events=${projected.length} expected=${expected.length} content_matches=true unique=${new Set(ids).size} retained_records=${recordCount}`,
  );

  // Conversation turns are a separate RelayHistory stream (Desktop's session
  // handoff writes them); the delivery batch does not create them. Ingest two
  // so the sessions API transcript case has turns to read.
  const turns = await call("POST", `${HISTORY}/v1/sessions/${encodeURIComponent(state.session.sessionId)}/turns`, {
    token: sync.accessToken,
    body: { sessionOwner: `e2e-${state.marker}`, turns: expectedTurns() },
  });
  must(turns.status === 200 && turns.json?.accepted === 2, `turn ingest status=${turns.status} accepted=${turns.json?.accepted}`);
  pass("delivery.turns", `accepted=${turns.json.accepted}`);
}

function expectedTurns() {
  const now = Date.parse(state.startedAt);
  const turn = (turnIndex, role, content, ts) => ({
    turnIndex, role, content, actorName: `e2e-${state.marker}`, actorRole: "owner",
    metadata: { nativeCli: SOURCE }, ts: new Date(ts).toISOString(),
  });
  return [
    turn(0, "user", `${state.marker} first prompt`, now),
    turn(1, "assistant", `${state.marker} assistant answer`, now + 1000),
  ];
}

// ---------------------------------------------------------------- reads

async function dashboardList(tenant, workspaceId, query) {
  const params = new URLSearchParams(query ? { q: query } : {});
  return call("GET", `${API}/cloud/api/v1/workspaces/${workspaceId}/sessions${query ? `?${params}` : ""}`, {
    token: tenant.accessToken,
  });
}

async function dashboardEvents(tenant, workspaceId, sessionId) {
  return call(
    "GET",
    `${API}/cloud/api/v1/workspaces/${workspaceId}/sessions/${encodeURIComponent(sessionId)}/events?source=${SOURCE}`,
    { token: tenant.accessToken },
  );
}

async function readsPresent(prefix) {
  const { sessionId } = state.session;
  const list = await dashboardList(state.a, state.a.workspaceId);
  must(list.status === 200, `dashboard list status=${list.status} error=${errorCode(list)}`);
  must(list.json.items.some((item) => item.sessionId === sessionId), "dashboard list does not include the session");
  pass(`${prefix}.dashboard_list`, `items=${list.json.items.length} contains_session=true`);

  const replay = await dashboardEvents(state.a, state.a.workspaceId, sessionId);
  must(replay.status === 200, `dashboard replay status=${replay.status} error=${errorCode(replay)}`);
  const replayed = markerEvents(replay.json.events);
  must(
    replayed.length === state.session.projectedEvents && projectionMatches(replayed),
    `dashboard replay events=${replayed.length} expected=${state.session.projectedEvents} content_matches=${projectionMatches(replayed)}`,
  );
  pass(`${prefix}.dashboard_replay`, `events=${replayed.length}`);

  const search = await dashboardList(state.a, state.a.workspaceId, state.marker);
  must(search.status === 200, `dashboard search status=${search.status}`);
  must(search.json.items.some((item) => item.sessionId === sessionId), "dashboard search does not find the marker");
  pass(`${prefix}.dashboard_search`, `matches=${search.json.items.length}`);

  const read = await historySession(state.a, "read");
  const direct = await call(
    "GET",
    `${HISTORY}/v1/sessions?${new URLSearchParams({ workspace: state.a.workspaceId, q: state.marker, limit: "50" })}`,
    { token: read.accessToken },
  );
  must(direct.status === 200, `relayhistory search status=${direct.status}`);
  must(direct.json.sessions.some((item) => item.sessionId === sessionId), "relayhistory search does not find the marker");
  const directEvents = await eventsDirect(read.accessToken, state.a, sessionId);
  const directReplayed = directEvents.status === 200 ? markerEvents(directEvents.json?.events) : [];
  must(directReplayed.length === state.session.projectedEvents && projectionMatches(directReplayed),
    `relayhistory replay status=${directEvents.status} events=${directReplayed.length} expected=${state.session.projectedEvents}`);
  pass(`${prefix}.relayhistory_direct`, `search_matches=${direct.json.sessions.length} replay_events=${state.session.projectedEvents}`);
}

async function phaseReads() {
  await readsPresent("reads");
}

// ---------------------------------------------------------------- isolation

const utcDay = (iso) => new Date(iso).toISOString().slice(0, 10);
const today = () => new Date().toISOString().slice(0, 10);
const isoEnvName = () => `E2E_ISO_${state.marker.toUpperCase()}`;

// The deterministic smoke flow: two shell steps, no agents, marker in output.
function smokeFlowSource(name) {
  return [
    "version: '1.0'",
    `name: ${name}`,
    "description: e2e-gcp-proof deterministic smoke flow",
    "swarm:",
    "  pattern: pipeline",
    "  timeoutMs: 120000",
    "workflows:",
    "  - name: main",
    "    steps:",
    "      - name: generate",
    "        type: deterministic",
    `        command: printf '${state.marker} step one\\nvalue=42\\n'`,
    "        captureOutput: true",
    "        failOnError: true",
    "      - name: transform",
    "        type: deterministic",
    "        dependsOn: [generate]",
    "        command: echo \"{{steps.generate.output}}\" | tr '[:lower:]' '[:upper:]'",
    "",
  ].join("\n");
}

// Every workspace-scoped control-plane route B might aim at A's workspace or
// A's resources. Each must answer 404, exactly as for a workspace that does
// not exist, so B learns nothing.
function crossWorkspaceProbes(a, flowId) {
  const ws = `/api/v1/workspaces/${a.workspaceId}`;
  const sessions = `/cloud/api/v1/workspaces/${a.workspaceId}/sessions`;
  const sid = encodeURIComponent(state.session.sessionId);
  const day = utcDay(state.startedAt);
  // [name, capability, method, path, body]; "core" routes exist on every
  // control plane this proof supports.
  return [
    ["sessions.list", "core", "GET", sessions],
    ["sessions.list_filtered", "core", "GET", `${sessions}?source=${SOURCE}&q=${state.marker}`],
    ["sessions.events", "core", "GET", `${sessions}/${sid}/events?source=${SOURCE}`],
    ["sessions.turns", "sessions", "GET", `${sessions}/${sid}/turns?source=${SOURCE}`],
    ["sessions.timing", "sessions", "GET", `${sessions}/${sid}/timing?source=${SOURCE}`],
    ["sessions.catalog", "sessions", "GET", `${sessions}/${sid}/catalog?source=${SOURCE}`],
    ["sessions.search", "sessions", "GET", `${sessions}/search?q=${state.marker}`],
    ["sessions.activity", "sessions", "GET", `${sessions}/activity?first=${day}&last=${today()}`],
    ["sessions.output", "sessions", "GET", `${sessions}/output?first=${day}&last=${today()}`],
    ["history.session", "core", "POST", `${ws}/relayhistory/session`, { mode: "read" }],
    ["settings.resolve", "core", "GET", `${ws}/resolve`],
    ["settings.runtime_get", "core", "GET", `${ws}/runtime`],
    ["settings.runtime_put", "core", "PUT", `${ws}/runtime`, { runtime: { e2e: state.marker } }],
    ["env.list", "admin", "GET", `${ws}/secrets`],
    ["env.create", "admin", "POST", `${ws}/secrets`, { name: isoEnvName(), value: `cross-${state.marker}` }],
    ["env.get", "admin", "GET", `${ws}/secrets/${isoEnvName()}`],
    ["env.delete", "admin", "DELETE", `${ws}/secrets/${isoEnvName()}`],
    ["settings.integrations", "admin", "GET", `${ws}/integrations`],
    ["settings.integration_providers", "admin", "GET", `${ws}/integrations/providers`],
    ["settings.api_tokens_list", "admin", "GET", `${ws}/deployment-api-tokens`],
    ["settings.api_tokens_create", "admin", "POST", `${ws}/deployment-api-tokens`, { label: `e2e-${state.marker}-cross` }],
    ["settings.audit", "admin", "GET", `${ws}/admin/audit`],
    ["flows.get", "flows", "GET", `/api/v1/flows/${flowId}`],
    ["flows.patch", "flows", "PATCH", `/api/v1/flows/${flowId}`, { name: `e2e-${state.marker}-hijack` }],
    ["flows.invoke", "flows", "POST", `/api/v1/flows/${flowId}/invoke`, {}],
    ["flows.delete", "flows", "DELETE", `/api/v1/flows/${flowId}`],
    ["flows.run_in_a", "flows", "POST", "/api/v1/workflows/run", { workspaceId: a.workspaceId, workflow: smokeFlowSource("x"), fileType: "yaml" }],
    ["flows.enroll_in_a", "flows", "POST", "/api/v1/workers/enrollment-tokens", { workspaceId: a.workspaceId, name: `e2e-${state.marker}-cross` }],
  ].filter(([, capability]) => capability === "core" || state.capabilities?.[capability]);
}

// sha256 of A's variable as the runtime would receive it, read through the
// in-cluster /internal route with the service token mounted in this pod.
// Returns null when the token is not mounted. Never returns the value.
async function runtimeValueHash(workspaceId, name) {
  let token;
  try {
    token = readFileSync(INTERNAL_TOKEN_FILE, "utf8").trim();
  } catch {
    return null;
  }
  const response = await call("GET", `${API}/internal/v1/workspaces/${workspaceId}/environment`, { token });
  must(response.status === 200 && response.json?.env && typeof response.json.env === "object",
    `internal environment read status=${response.status}`);
  const value = response.json.env[name];
  return typeof value === "string" ? sha256(value) : "absent";
}

async function phaseIsolation() {
  const { sessionId } = state.session;
  const a = state.a;
  const b = state.b;
  const caps = state.capabilities ?? {};
  const isoValue = randomBytes(18).toString("base64url");
  let flowId = randomUUID();
  let envBefore = null;

  // A owns a flow and an env var; B must not see or touch either.
  if (caps.flows) {
    const flow = await call("POST", `${API}/api/v1/flows`, {
      token: a.accessToken,
      body: { name: `e2e-${state.marker}-isolation`, source: smokeFlowSource(`e2e-${state.marker}-isolation`) },
    });
    if (flow.json?.flow?.id) track("flows", flow.json.flow.id);
    must(flow.status === 201 && flow.json?.flow?.id, `A flow create status=${flow.status} error=${errorCode(flow)}`);
    flowId = flow.json.flow.id;
  }
  if (caps.admin) {
    track("envVars", isoEnvName());
    const env = await call("POST", `${API}/api/v1/workspaces/${a.workspaceId}/secrets`, {
      token: a.accessToken,
      body: { name: isoEnvName(), value: isoValue },
    });
    must(env.status === 201, `A env create status=${env.status} error=${errorCode(env)}`);
    envBefore = env.json;
  }

  const results = [];
  for (const [name, , method, path, body] of crossWorkspaceProbes(a, flowId)) {
    const response = await call(method, `${API}${path}`, { token: b.accessToken, body });
    must(response.status === 404, `B ${name} on A status=${response.status} error=${errorCode(response)}`);
    must(!response.text.includes(isoValue) && !response.text.includes(state.marker),
      `B ${name} on A leaked A's data in a 404 body`);
    results.push(name);
  }
  pass("isolation.control_plane_routes", `b_on_a_404=${results.length}/${results.length} (${results.join(",")}) capabilities=${Object.entries(caps).filter(([, v]) => v).map(([k]) => k).join(",") || "core"}`);

  // B's own views do not contain A's resources, and B's attempts changed
  // nothing in A.
  const unchanged = [];
  if (caps.flows) {
    const bFlows = await call("GET", `${API}/api/v1/flows`, { token: b.accessToken });
    must(bFlows.status === 200 && Array.isArray(bFlows.json?.flows), `B flow list status=${bFlows.status}`);
    must(!bFlows.json.flows.some((item) => item.id === flowId), "B's flow list contains A's flow");
    const bRuns = await call("GET", `${API}/api/v1/workflows/runs`, { token: b.accessToken });
    must(bRuns.status === 200 && Array.isArray(bRuns.json?.runs), `B run list status=${bRuns.status}`);
    must(bRuns.json.runs.length === 0, `B's run list has ${bRuns.json.runs.length} runs`);
    const aFlow = await call("GET", `${API}/api/v1/flows/${flowId}`, { token: a.accessToken });
    must(aFlow.status === 200 && aFlow.json?.flow?.name === `e2e-${state.marker}-isolation`, `A flow after B status=${aFlow.status} renamed=${aFlow.json?.flow?.name !== `e2e-${state.marker}-isolation`}`);
    must(Array.isArray(aFlow.json.recentRuns) && aFlow.json.recentRuns.length === 0, "B's invoke created a run of A's flow");
    const aEnroll = await call("GET", `${API}/api/v1/workers/enrollment-tokens`, { token: a.accessToken });
    must(aEnroll.status === 200 && !aEnroll.text.includes(`e2e-${state.marker}-cross`), `A enrollment tokens after B status=${aEnroll.status}`);
    unchanged.push("b_flows=0", "b_runs=0", "a_flow_name_unchanged=true", "a_flow_runs=0", "no_cross_enrollment=true");
  }
  if (caps.admin) {
    const bEnv = await call("GET", `${API}/api/v1/workspaces/${b.workspaceId}/secrets`, { token: b.accessToken });
    must(bEnv.status === 200 && Array.isArray(bEnv.json?.data?.items), `B env list status=${bEnv.status}`);
    must(!bEnv.json.data.items.some((item) => item.name === isoEnvName()), "B's env list contains A's variable");
    const bEnvItem = await call("GET", `${API}/api/v1/workspaces/${b.workspaceId}/secrets/${isoEnvName()}`, { token: b.accessToken });
    must(bEnvItem.status === 404, `B reading A's variable name in its own workspace status=${bEnvItem.status}`);
    const aEnv = await call("GET", `${API}/api/v1/workspaces/${a.workspaceId}/secrets/${isoEnvName()}`, { token: a.accessToken });
    must(aEnv.status === 200 && aEnv.json?.name === isoEnvName(), `A env after B status=${aEnv.status}`);
    // Same mask and same last-update stamp as right after A created it, and,
    // where the service token is mounted, the very value the runtime gets.
    must(aEnv.json.maskedValue === envBefore.maskedValue, "A's variable mask changed after B's probes");
    for (const field of ["updatedAt", "updatedBy", "setBy"]) {
      if (field in envBefore) must(aEnv.json[field] === envBefore[field], `A's variable ${field} changed after B's probes`);
    }
    const valueHash = await runtimeValueHash(a.workspaceId, isoEnvName());
    if (valueHash !== null) must(valueHash === sha256(isoValue), "A's variable value changed after B's probes");
    const aTokens = await call("GET", `${API}/api/v1/workspaces/${a.workspaceId}/deployment-api-tokens`, { token: a.accessToken });
    must(aTokens.status === 200 && !aTokens.text.includes(`e2e-${state.marker}-cross`), `A api tokens after B status=${aTokens.status}`);
    unchanged.push(`b_env=${bEnv.json.data.items.length}`, "a_env_mask_unchanged=true", `a_env_value=${valueHash === null ? "not_checked_no_internal_token" : "hash_unchanged"}`, "no_cross_api_tokens=true");
  }
  const aRuntime = await call("GET", `${API}/api/v1/workspaces/${a.workspaceId}/runtime`, { token: a.accessToken });
  must(aRuntime.status === 200 && !JSON.stringify(aRuntime.json).includes(state.marker), "B's runtime write reached A");
  unchanged.push("a_runtime_untouched=true");
  pass("isolation.a_unchanged", unchanged.join(" "));

  if (caps.flows) {
    const delFlow = await call("DELETE", `${API}/api/v1/flows/${flowId}`, { token: a.accessToken });
    must(delFlow.status === 200, `A flow cleanup status=${delFlow.status}`);
    untrack("flows", flowId);
  }
  if (caps.admin) {
    const delEnv = await call("DELETE", `${API}/api/v1/workspaces/${a.workspaceId}/secrets/${isoEnvName()}`, { token: a.accessToken });
    must(delEnv.status === 200, `A env cleanup status=${delEnv.status}`);
    untrack("envVars", isoEnvName());
  }

  const ownSearch = await dashboardList(b, b.workspaceId, state.marker);
  must(ownSearch.status === 200, `B own search status=${ownSearch.status}`);
  must(!ownSearch.json.items.some((item) => item.sessionId === sessionId), "B's own workspace search returned A's session");
  const ownReplay = await dashboardEvents(b, b.workspaceId, sessionId);
  const own = absentOrDenied(ownReplay, eventLeaks, [404]);
  must(own.ok, `B's own workspace replay of A's session status=${ownReplay.status} leaked_events=${own.leaked ?? "unknown"}`);
  pass("isolation.b_workspace_views", `search_matches=${ownSearch.json.items.length} replay_status=${ownReplay.status} leaked_events=0`);

  const bRead = await historySession(state.b, "sync");
  const forged = await call(
    "GET",
    `${HISTORY}/v1/sessions?${new URLSearchParams({ workspace: state.a.workspaceId, q: state.marker })}`,
    { token: bRead.accessToken },
  );
  const forgedList = absentOrDenied(forged, (json) => (json.sessions ?? []).filter((item) => item.sessionId === sessionId).length);
  must(forgedList.ok, `B's RelayHistory token listing A's workspace status=${forged.status} leaked_sessions=${forgedList.leaked ?? "unknown"}`);
  const forgedEvents = await eventsDirect(bRead.accessToken, state.a, sessionId);
  const forgedReplay = absentOrDenied(forgedEvents, eventLeaks);
  must(forgedReplay.ok, `B's RelayHistory token replaying A's session status=${forgedEvents.status} leaked_events=${forgedReplay.leaked ?? "unknown"}`);
  const forgedDelivery = await call("POST", `${HISTORY}/v1/delivery/batches`, {
    token: bRead.accessToken,
    body: buildBatch(),
  });
  must(forgedDelivery.status === 403, `B delivering with A's account_id status=${forgedDelivery.status}`);
  pass(
    "isolation.relayhistory_direct",
    `b_list_with_a_workspace=${forged.status} b_events_with_a_workspace=${forgedEvents.status} b_deliver_as_a=${forgedDelivery.status}`,
  );

  // Relaycast tenant isolation: B's workspace key sees none of A's agents and
  // cannot read A's DM conversation.
  const bRoster = await rosterNames(state.b);
  must(!bRoster.some((name) => name.includes(state.marker)), "B's roster contains A's agents");
  const bAgent = await registerAgent(state.b, `e2e-${state.marker}-gamma`);
  const crossDm = await call("GET", `${RELAYCAST}/v1/dm/${state.dm.conversationId}/messages`, { token: bAgent.token });
  const crossDmRead = absentOrDenied(crossDm, (json) => (JSON.stringify(json).includes(state.marker) ? 1 : 0));
  must(crossDmRead.ok, `B's agent reading A's DM conversation status=${crossDm.status} leaked=${crossDmRead.leaked ?? "unknown"}`);
  const crossSend = await call("POST", `${RELAYCAST}/v1/dm`, {
    token: bAgent.token,
    body: { to: state.agents.alpha.name, text: `${state.marker} cross-tenant` },
  });
  must(crossSend.status >= 400 && crossSend.status < 500, `B's agent DMed A's agent status=${crossSend.status}`);
  pass("isolation.relaycast", `b_roster_size=${bRoster.length} b_read_a_dm=${crossDm.status} b_dm_a_agent=${crossSend.status}`);
}

// ---------------------------------------------------------------- sessions API

// Runs on the operator's machine against the public dashboard origin
// (E2E_API_URL=https://<base>), i.e. through the GCE edge and the same
// /cloud/api prefix the SPA uses.
async function phaseSessions() {
  const a = state.a;
  const { sessionId } = state.session;
  const base = `${API}/cloud/api/v1/workspaces/${a.workspaceId}/sessions`;
  const sid = encodeURIComponent(sessionId);
  const get = (path, token = a.accessToken) => call("GET", `${base}${path}`, { token });
  const has = (response) => response.json.items.some((item) => item.sessionId === sessionId);

  const anonymous = await call("GET", base);
  must(anonymous.status === 401, `anonymous list status=${anonymous.status}`);

  const list = await get("");
  must(list.status === 200 && Array.isArray(list.json?.items), `list status=${list.status} error=${errorCode(list)}`);
  const item = list.json.items.find((entry) => entry.sessionId === sessionId);
  must(item, "list does not include the delivered session");
  must(item.source === SOURCE, `list item source=${item.source}`);
  must(Array.isArray(list.json.members) && list.json.members.some((m) => m.id === a.ownerUserId), "list members do not include the owner");
  pass("sessions.list", `items=${list.json.items.length} contains_session=true source=${item.source} members=${list.json.members.length} anonymous=${anonymous.status}`);

  // Filters: each one must keep the session when it matches and drop it when
  // it does not.
  const since = new Date(Date.parse(state.startedAt) - 3_600_000).toISOString();
  const until = new Date(Date.now() + 3_600_000).toISOString();
  const future = new Date(Date.now() + 86_400_000).toISOString();
  const past = new Date(Date.parse(state.startedAt) - 7 * 86_400_000).toISOString();
  const filters = [
    ["source_match", `?source=${SOURCE}`, true],
    ["source_other", "?source=codex", false],
    ["window_match", `?since=${encodeURIComponent(since)}&until=${encodeURIComponent(until)}`, true],
    ["window_future", `?since=${encodeURIComponent(future)}`, false],
    ["window_past", `?until=${encodeURIComponent(past)}`, false],
    ["q_match", `?q=${state.marker}`, true],
    ["q_other", `?q=${state.marker}zz-no-such-text`, false],
  ];
  // The fixture session carries a project, so the list must expose it.
  must(typeof item.project?.name === "string" && item.project.name.length > 0, "list item is missing the fixture project");
  filters.push(["project_match", `?project=${encodeURIComponent(item.project.name)}`, true]);
  filters.push(["project_other", `?project=${encodeURIComponent(`/e2e/${state.marker}-other`)}`, false]);
  const filterDetail = [];
  for (const [name, query, expected] of filters) {
    const response = await get(query);
    must(response.status === 200 && Array.isArray(response.json?.items), `filter ${name} status=${response.status} error=${errorCode(response)}`);
    must(has(response) === expected, `filter ${name} contains_session=${has(response)} expected=${expected}`);
    filterDetail.push(`${name}=${expected ? "kept" : "dropped"}`);
  }
  const bad = await get("?limit=5");
  must(bad.status === 400, `limit without ranking status=${bad.status}`);
  pass("sessions.filters", `${filterDetail.join(" ")} invalid_param=${bad.status}`);

  // Transcript: events (replay) and turns.
  const events = await get(`/${sid}/events?source=${SOURCE}`);
  must(events.status === 200 && Array.isArray(events.json?.events), `events status=${events.status} error=${errorCode(events)}`);
  const replayed = markerEvents(events.json.events);
  must(replayed.length === state.session.projectedEvents && projectionMatches(replayed),
    `events=${replayed.length} expected=${state.session.projectedEvents} content_matches=${projectionMatches(replayed)}`);
  const ordered = events.json.events.every((event, index, all) => index === 0 || Date.parse(all[index - 1].ts) <= Date.parse(event.ts));
  must(ordered, "events are not in time order");
  // order=desc&limit=2 must return the transcript's last two events. The
  // control plane re-sorts a page ascending for display, so compare sets.
  const desc = await get(`/${sid}/events?source=${SOURCE}&order=desc&limit=2`);
  must(desc.status === 200 && Array.isArray(desc.json?.events) && desc.json.events.length === 2,
    `events limit=2 status=${desc.status} count=${desc.json?.events?.length}`);
  const lastTwo = events.json.events.slice(-2).map((event) => event.eventId).sort();
  const descIds = desc.json.events.map((event) => event.eventId).sort();
  must(JSON.stringify(descIds) === JSON.stringify(lastTwo), "order=desc&limit=2 did not return the last two events");
  const asc = await get(`/${sid}/events?source=${SOURCE}&order=asc&limit=2`);
  const firstTwo = events.json.events.slice(0, 2).map((event) => event.eventId).sort();
  must(asc.status === 200 && JSON.stringify(asc.json.events.map((event) => event.eventId).sort()) === JSON.stringify(firstTwo),
    "order=asc&limit=2 did not return the first two events");
  const turns = await get(`/${sid}/turns?source=${SOURCE}`);
  must(turns.status === 200 && Array.isArray(turns.json?.turns), `turns status=${turns.status} error=${errorCode(turns)}`);
  const got = turns.json.turns.map((turn) => `${turn.turnIndex}:${turn.role}:${turn.content}`);
  const want = expectedTurns().map((turn) => `${turn.turnIndex}:${turn.role}:${turn.content}`);
  must(JSON.stringify(got) === JSON.stringify(want), `turns=${turns.json.turns.length} expected=${want.length} content_matches=false`);
  const timing = await get(`/${sid}/timing?source=${SOURCE}`);
  must(timing.status === 200 && "timing" in (timing.json ?? {}), `timing status=${timing.status} error=${errorCode(timing)}`);
  const catalog = await get(`/${sid}/catalog?source=${SOURCE}`);
  must(catalog.status === 200 && Array.isArray(catalog.json?.children), `catalog status=${catalog.status} error=${errorCode(catalog)}`);
  pass("sessions.transcript", `events=${replayed.length} ordered=true desc_limit_is_last_two=true asc_limit_is_first_two=true turns=${turns.json.turns.length} turns_match=true timing=${timing.json.timing ? "present" : "null"} catalog=${catalog.status}`);

  // Search (event-level matches with citation paths).
  const search = await get(`/search?q=${state.marker}`);
  must(search.status === 200 && Array.isArray(search.json?.matches), `search status=${search.status} error=${errorCode(search)}`);
  const hits = search.json.matches.filter((match) => match.sessionId === sessionId);
  must(hits.length > 0, "search does not find the marker");
  must(hits.every((match) => typeof match.citationPath === "string" && match.citationPath.includes(sid)), "search match has no citation path");
  const miss = await get(`/search?q=${state.marker}zz-no-such-text`);
  must(miss.status === 200 && !miss.json.matches.some((match) => match.sessionId === sessionId), `search miss status=${miss.status}`);
  const noQ = await get("/search");
  must(noQ.status === 400, `search without q status=${noQ.status}`);
  pass("sessions.search", `matches=${hits.length} citation=true miss_dropped=true missing_q=${noQ.status}`);

  // Activity: the session's day counts it under its source.
  const day = utcDay(state.startedAt);
  const activity = await get(`/activity?first=${day}&last=${today()}`);
  must(activity.status === 200 && Array.isArray(activity.json?.days), `activity status=${activity.status} error=${errorCode(activity)}`);
  const row = activity.json.days.find((entry) => entry.date === day);
  must(row && row.conversations >= 1 && (row.bySource?.[SOURCE] ?? 0) >= 1,
    `activity ${day} conversations=${row?.conversations} ${SOURCE}=${row?.bySource?.[SOURCE]}`);
  const filtered = await get(`/activity?first=${day}&last=${today()}&q=${state.marker}zz-no-such-text`);
  must(filtered.status === 200 && Array.isArray(filtered.json?.days), `activity q status=${filtered.status}`);
  const filteredTotal = filtered.json.days.reduce((sum, entry) => sum + entry.conversations, 0);
  must(filteredTotal === 0, `activity with a non-matching q counted ${filteredTotal}`);
  const backwards = await get(`/activity?first=${today()}&last=${day === today() ? "2000-01-01" : day}`);
  must(backwards.status === 400, `activity reversed range status=${backwards.status}`);
  pass("sessions.activity", `day=${day} conversations=${row.conversations} ${SOURCE}=${row.bySource[SOURCE]} non_matching_q_total=0 reversed_range=${backwards.status}`);

  // B's token on every one of these A routes, through the public edge.
  const crossPaths = ["", `/${sid}/events?source=${SOURCE}`, `/${sid}/turns?source=${SOURCE}`, `/${sid}/timing?source=${SOURCE}`,
    `/${sid}/catalog?source=${SOURCE}`, `/search?q=${state.marker}`, `/activity?first=${day}&last=${today()}`,
    `/output?first=${day}&last=${today()}`];
  for (const path of crossPaths) {
    const response = await get(path, state.b.accessToken);
    must(response.status === 404, `B on A ${path || "/"} status=${response.status}`);
  }
  pass("sessions.cross_workspace", `b_on_a_404=${crossPaths.length}/${crossPaths.length}`);
}

// ---------------------------------------------------------------- admin

// Also runs against the public origin. The value is generated here, kept in
// memory only, and checked never to appear in any response body.
async function phaseAdmin() {
  const a = state.a;
  const base = `${API}/cloud/api/v1/workspaces/${a.workspaceId}/secrets`;
  const name = `E2E_ADMIN_${state.marker.toUpperCase()}`;
  const value = `e2e-${randomBytes(24).toString("base64url")}`;
  const rotated = `e2e-${randomBytes(24).toString("base64url")}`;
  const clean = (response) => !response.text.includes(value) && !response.text.includes(rotated) &&
    !response.text.includes(value.slice(4, 20)) && !response.text.includes(rotated.slice(4, 20));
  const maskOk = (masked, plain) =>
    typeof masked === "string" && masked !== plain && /^.{2}\*{4,}.{2}$/.test(masked) &&
    masked.length === plain.length && masked.slice(-2) === plain.slice(-2);
  const bodies = [];

  track("envVars", name);
  const created = await call("POST", base, { token: a.accessToken, body: { name, value } });
  bodies.push(["create", created]);
  must(created.status === 201 && created.json?.name === name, `create status=${created.status} error=${errorCode(created)}`);
  must(!("value" in created.json) && maskOk(created.json.maskedValue, value), "create response is not masked");

  const list = await call("GET", base, { token: a.accessToken });
  bodies.push(["list", list]);
  must(list.status === 200 && Array.isArray(list.json?.data?.items), `list status=${list.status}`);
  const listed = list.json.data.items.find((entry) => entry.name === name);
  must(listed && maskOk(listed.maskedValue, value) && !("value" in listed), "list entry missing or not masked");

  const item = await call("GET", `${base}/${name}`, { token: a.accessToken });
  bodies.push(["get", item]);
  must(item.status === 200 && maskOk(item.json?.maskedValue, value) && !("value" in item.json), `get status=${item.status}`);

  const updated = await call("POST", base, { token: a.accessToken, body: { name, value: rotated } });
  bodies.push(["update", updated]);
  must(updated.status === 200 && maskOk(updated.json?.maskedValue, rotated), `update status=${updated.status} error=${errorCode(updated)}`);

  const invalid = await call("POST", base, { token: a.accessToken, body: { name: "PATH", value: "x" } });
  must(invalid.status === 400, `reserved name status=${invalid.status}`);

  const anonymous = await call("GET", base);
  must(anonymous.status === 401, `anonymous list status=${anonymous.status}`);

  const deleted = await call("DELETE", `${base}/${name}`, { token: a.accessToken });
  bodies.push(["delete", deleted]);
  must(deleted.status === 200, `delete status=${deleted.status}`);
  untrack("envVars", name);
  const gone = await call("GET", `${base}/${name}`, { token: a.accessToken });
  must(gone.status === 404, `get after delete status=${gone.status}`);
  const after = await call("GET", base, { token: a.accessToken });
  bodies.push(["list_after", after]);
  must(after.status === 200 && !after.json.data.items.some((entry) => entry.name === name), "list still contains the deleted variable");

  const audit = await call("GET", `${API}/cloud/api/v1/workspaces/${a.workspaceId}/admin/audit`, { token: a.accessToken });
  bodies.push(["audit", audit]);
  must(audit.status === 200 && Array.isArray(audit.json?.events), `audit status=${audit.status}`);
  const actions = audit.json.events.filter((event) => JSON.stringify(event).includes(name)).map((event) => event.action).sort();
  for (const action of ["env_var.create", "env_var.delete", "env_var.update"]) {
    must(actions.includes(action), `audit is missing ${action}`);
  }

  for (const [label, response] of bodies) must(clean(response), `${label} response contains the plaintext value`);
  pass("admin.env_var", `create=${created.status} list_masked=true get_masked=true update=${updated.status} reserved_name=${invalid.status} anonymous=${anonymous.status} delete=${deleted.status} get_after_delete=${gone.status} audit=${actions.join(",")} plaintext_in_bodies=0/${bodies.length}`);
}

// In-cluster: the /internal runtime routes exist behind the edge and refuse
// anything but a service/worker credential.
async function phaseAdminInternal() {
  const url = `${API}/internal/v1/workspaces/${state.a.workspaceId}/environment`;
  const anonymous = await call("GET", url);
  const user = await call("GET", url, { token: state.a.accessToken });
  const forged = await call("GET", url, { token: "sh_wrk_forged" });
  must(anonymous.status === 401 && user.status === 401 && forged.status === 401,
    `internal environment anonymous=${anonymous.status} user_token=${user.status} forged_worker=${forged.status}`);
  pass("admin.internal_requires_service_credential", `anonymous=${anonymous.status} user_token=${user.status} forged_worker=${forged.status}`);
}

// ---------------------------------------------------------------- flows

const workerName = () => `e2e-${state.marker}-worker`;

async function phaseFlowsEnroll() {
  const a = state.a;
  state.flows = { workerName: workerName() };
  track("workerNames", workerName());
  const enroll = await call("POST", `${API}/api/v1/workers/enrollment-tokens`, {
    token: a.accessToken,
    body: { workspaceId: a.workspaceId, name: workerName(), expiresInMinutes: 30 },
  });
  if (enroll.json?.id) {
    state.flows.enrollmentTokenId = enroll.json.id;
    track("enrollmentTokens", enroll.json.id);
  }
  must(enroll.status === 200 && typeof enroll.json?.token === "string" && enroll.json.token.length >= 20,
    `enrollment token status=${enroll.status} error=${errorCode(enroll)}`);
  must(typeof enroll.json.registerCommand === "string" && enroll.json.registerCommand.includes("cloud worker register"), "no register command");
  const listed = await call("GET", `${API}/api/v1/workers/enrollment-tokens`, { token: a.accessToken });
  must(listed.status === 200 && Array.isArray(listed.json?.tokens), `enrollment list status=${listed.status}`);
  must(listed.json.tokens.some((token) => token.id === enroll.json.id), "enrollment token not listed");
  must(!listed.text.includes(enroll.json.token), "enrollment token list returns the plaintext token");
  // B cannot see or revoke A's token.
  const bList = await call("GET", `${API}/api/v1/workers/enrollment-tokens`, { token: state.b.accessToken });
  must(bList.status === 200 && !bList.json.tokens.some((token) => token.id === enroll.json.id), `B enrollment list status=${bList.status}`);
  const bRevoke = await call("DELETE", `${API}/api/v1/workers/enrollment-tokens/${enroll.json.id}`, { token: state.b.accessToken });
  must(bRevoke.status === 404, `B revoking A's enrollment token status=${bRevoke.status}`);
  state.enrollmentToken = enroll.json.token;
  pass("flows.enrollment_token", `id=${enroll.json.id} expires=${enroll.json.expiresAt} listed=true plaintext_listed=false b_list_contains=false b_revoke=${bRevoke.status}`);
}

async function phaseFlowsRun() {
  const a = state.a;
  const flows = state.flows;
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  // The Pod prints its "registered" line before `worker start` connects, so
  // wait for the worker to come online (heartbeat/queue) before invoking.
  let worker = null;
  const onlineBy = Date.now() + Number(process.env.E2E_WORKER_ONLINE_MS ?? 180_000);
  for (;;) {
    const workers = await call("GET", `${API}/api/v1/workers`, { token: a.accessToken });
    must(workers.status === 200 && Array.isArray(workers.json?.workers), `worker list status=${workers.status}`);
    worker = workers.json.workers.find((entry) => entry.name === flows.workerName) ?? null;
    if (worker) flows.workerId = worker.id;
    if (worker?.status === "online" || Date.now() >= onlineBy) break;
    await sleep(3_000);
  }
  must(worker, "the e2e worker is not registered in workspace A");
  must(worker.status === "online", `worker status=${worker.status} after waiting for online`);
  const bWorker = await call("GET", `${API}/api/v1/workers/${worker.id}`, { token: state.b.accessToken });
  must(bWorker.status === 404, `B reading A's worker status=${bWorker.status}`);
  const reuse = await call("POST", `${API}/api/v1/workers/register`, {
    body: { enrollmentToken: secrets.enrollmentToken, name: `${flows.workerName}-reuse` },
  });
  must(typeof secrets.enrollmentToken === "string" && secrets.enrollmentToken.length > 0, "the caller did not pass the enrollment token back");
  must(reuse.status >= 400 && reuse.status < 500, `reusing the enrollment token status=${reuse.status}`);
  pass("flows.worker_registered", `worker=${worker.id} name=${worker.name} status=${worker.status} b_get=${bWorker.status} token_reuse=${reuse.status}`);

  const flowName = `e2e-${state.marker}-smoke`;
  const flow = await call("POST", `${API}/api/v1/flows`, {
    token: a.accessToken,
    body: { name: flowName, description: "e2e-gcp-proof", source: smokeFlowSource(flowName) },
  });
  if (flow.json?.flow?.id) {
    flows.flowId = flow.json.flow.id;
    track("flows", flows.flowId);
  }
  must(flow.status === 201 && flow.json?.flow?.id, `flow create status=${flow.status} error=${errorCode(flow)}`);
  const invoked = await call("POST", `${API}/api/v1/flows/${flows.flowId}/invoke`, {
    token: a.accessToken,
    body: { runtime: { id: "worker", config: { workerId: worker.id } } },
  });
  must(invoked.status === 201 && invoked.json?.runId, `invoke status=${invoked.status} error=${errorCode(invoked)}`);
  const runId = invoked.json.runId;
  flows.runId = runId;

  let run = null;
  const deadline = Date.now() + Number(process.env.E2E_FLOW_RUN_TIMEOUT_MS ?? 300_000);
  while (Date.now() < deadline) {
    const response = await call("GET", `${API}/api/v1/workflows/runs/${runId}`, { token: a.accessToken });
    must(response.status === 200, `run get status=${response.status}`);
    run = response.json;
    if (["completed", "failed", "cancelled"].includes(run.status)) break;
    await sleep(3_000);
  }
  must(run?.status === "completed", `run ${runId} status=${run?.status} error=${run?.error ?? "none"}`);
  pass("flows.run_completed", `run=${runId} status=${run.status} worker=${run.workerName ?? run.workerId ?? "n/a"} exit=${run.exitCode ?? "n/a"} duration_ms=${run.durationMs ?? "n/a"}`);

  const events = await call("GET", `${API}/api/v1/workflows/runs/${runId}/events?limit=100`, { token: a.accessToken });
  must(events.status === 200 && Array.isArray(events.json?.events), `events status=${events.status}`);
  const types = events.json.events.map((event) => event.eventType);
  const expected = ["run.queued", "run.assigned", "run.acknowledged", "run.running", "run.completed"];
  let cursor = -1;
  for (const type of expected) {
    const index = types.indexOf(type, cursor + 1);
    must(index > cursor, `run events are missing ${type} in order (have ${types.join(",")})`);
    cursor = index;
  }
  const steps = await call("GET", `${API}/api/v1/workflows/runs/${runId}/steps`, { token: a.accessToken });
  must(steps.status === 200 && Array.isArray(steps.json?.steps), `steps status=${steps.status}`);
  const stepStatus = Object.fromEntries(steps.json.steps.map((step) => [step.stepName, step.status]));
  must(stepStatus.generate === "completed" && stepStatus.transform === "completed",
    `steps source=${steps.json.source} statuses=${JSON.stringify(stepStatus)}`);
  const logs = await call("GET", `${API}/api/v1/workflows/runs/${runId}/logs`, { token: a.accessToken });
  must(logs.status === 200 && typeof logs.json?.content === "string" && typeof logs.json?.available === "boolean" && logs.json.done === true,
    `logs status=${logs.status} done=${logs.json?.done}`);
  if (logs.json.available) must(logs.json.content.includes(state.marker), "runner log does not contain the step output");
  const definition = await call("GET", `${API}/api/v1/workflows/runs/${runId}/workflow`, { token: a.accessToken });
  must(definition.status === 200 && definition.json?.workflow === smokeFlowSource(flowName), `run workflow status=${definition.status}`);
  const artifacts = await call("GET", `${API}/api/v1/workflows/runs/${runId}/artifacts`, { token: a.accessToken });
  must(artifacts.status === 200 && Array.isArray(artifacts.json?.artifacts), `artifacts status=${artifacts.status}`);
  pass("flows.run_readable", `events=${types.join(">")} steps_source=${steps.json.source} steps=${Object.entries(stepStatus).map(([k, v]) => `${k}:${v}`).join(",")} logs_available=${logs.json.available} log_bytes=${logs.json.totalSize} definition_matches=true artifacts=${artifacts.json.artifacts.length}`);

  // B cannot read any of it.
  const crossPaths = ["", "/events", "/steps", "/logs", "/workflow", "/artifacts"];
  for (const path of crossPaths) {
    const response = await call("GET", `${API}/api/v1/workflows/runs/${runId}${path}`, { token: state.b.accessToken });
    must(response.status === 404, `B reading A's run${path} status=${response.status}`);
  }
  const bCancel = await call("POST", `${API}/api/v1/workflows/runs/${runId}/retry`, { token: state.b.accessToken, body: {} });
  must(bCancel.status === 404, `B retrying A's run status=${bCancel.status}`);
  pass("flows.run_isolated", `b_on_a_run_404=${crossPaths.length + 1}/${crossPaths.length + 1}`);
}

async function phaseFlowsCleanup() {
  const a = state.a;
  const flows = state.flows ?? {};
  const done = [];
  // Registration can succeed even when the run later fails before the id is
  // saved, so look the worker up by its unique name when needed.
  let workerId = flows.workerId;
  if (!workerId && flows.workerName) {
    const workers = await call("GET", `${API}/api/v1/workers`, { token: a.accessToken });
    must(workers.status === 200 && Array.isArray(workers.json?.workers), `worker list status=${workers.status}`);
    workerId = workers.json.workers.find((entry) => entry.name === flows.workerName)?.id;
  }
  if (workerId) {
    const revoked = await call("DELETE", `${API}/api/v1/workers/${workerId}`, { token: a.accessToken });
    must(revoked.status === 200 && revoked.json?.status === "revoked", `worker revoke status=${revoked.status} result=${revoked.json?.status}`);
    const after = await call("GET", `${API}/api/v1/workers/${workerId}`, { token: a.accessToken });
    must(after.status === 200 && after.json?.worker?.status === "revoked", `worker after revoke status=${after.status} worker_status=${after.json?.worker?.status}`);
    done.push(`worker=${workerId}:revoked`);
  }
  if (flows.workerName) untrack("workerNames", flows.workerName);
  if (flows.enrollmentTokenId) {
    // A used token can no longer be revoked (404); an unused one (the worker
    // never registered) must be.
    const revoked = await call("DELETE", `${API}/api/v1/workers/enrollment-tokens/${flows.enrollmentTokenId}`, { token: a.accessToken });
    must(revoked.status === (workerId ? 404 : 200), `enrollment token revoke status=${revoked.status} worker_registered=${Boolean(workerId)}`);
    untrack("enrollmentTokens", flows.enrollmentTokenId);
    done.push(`enrollment_token=${workerId ? "used" : "revoked"}`);
  }
  if (flows.flowId) {
    const deleted = await call("DELETE", `${API}/api/v1/flows/${flows.flowId}`, { token: a.accessToken });
    must(deleted.status === 200, `flow delete status=${deleted.status}`);
    const gone = await call("GET", `${API}/api/v1/flows/${flows.flowId}`, { token: a.accessToken });
    must(gone.status === 404, `flow get after delete status=${gone.status}`);
    untrack("flows", flows.flowId);
    done.push("flow=deleted");
  }
  pass("flows.cleanup", done.join(" ") || "nothing to clean");
}

// ---------------------------------------------------------------- durability

async function phaseDurabilityHistory() {
  await readsPresent("durability.history");
}

async function phaseDurabilityRelaycast() {
  const roster = await rosterNames(state.a);
  must(
    [state.agents.alpha.name, state.agents.beta.name].every((name) => roster.includes(name)),
    "roster lost an agent across restart",
  );
  pass("durability.relaycast_roster", `roster_size=${roster.length} contains_both=true`);
  await checkMessageHistory("durability.relaycast_messages");
  // Agent tokens issued before the restart still authenticate.
  const me = await call("GET", `${RELAYCAST}/v1/agent`, { token: state.agents.alpha.token });
  must(me.status === 200, `agent token after restart status=${me.status}`);
  pass("durability.relaycast_agent_token", `status=${me.status}`);
}

// ---------------------------------------------------------------- auth

function jwtParts(token) {
  const raw = token.replace(/^relay_(ag|pa|ws|id)_/, "");
  const [header, payload] = raw.split(".");
  return {
    header: JSON.parse(Buffer.from(header, "base64url").toString("utf8")),
    payload: JSON.parse(Buffer.from(payload, "base64url").toString("utf8")),
  };
}

async function phaseAuth() {
  const jwks = await call("GET", `${RELAYAUTH}/.well-known/jwks.json`);
  must(jwks.status === 200 && Array.isArray(jwks.json?.keys) && jwks.json.keys.length > 0, `jwks status=${jwks.status}`);
  const kids = jwks.json.keys.map((key) => key.kid);
  pass("auth.jwks", `keys=${kids.length} algs=${[...new Set(jwks.json.keys.map((k) => k.alg))].join(",")}`);

  // A control-plane-issued RelayHistory session must authenticate at
  // RelayHistory; a tampered one must not.
  const session = await historySession(state.a, "sync");
  const ok = await call("GET", `${HISTORY}/v1/delivery/limits`, { token: session.accessToken });
  must(ok.status === 200, `issued RelayHistory token status=${ok.status}`);
  const bogus = await call("GET", `${HISTORY}/v1/delivery/limits`, { token: `${session.accessToken.slice(0, -4)}AAAA` });
  must(bogus.status === 401, `tampered RelayHistory token status=${bogus.status}`);
  const none = await call("GET", `${HISTORY}/v1/delivery/limits`);
  must(none.status === 401, `anonymous RelayHistory status=${none.status}`);
  let kidDetail = "opaque_token";
  try {
    const parts = jwtParts(session.accessToken);
    kidDetail = `jwt_kid_in_jwks=${kids.includes(parts.header.kid)} aud=${parts.payload.aud}`;
  } catch {
    // RelayHistory session tokens may be opaque; the assertion check below
    // covers the RelayAuth signature path.
  }
  pass("auth.relayhistory_token", `issued=${ok.status} tampered=${bogus.status} anonymous=${none.status} ${kidDetail}`);

  // Mint the same RelayAuth assertion the control plane mints, verify its
  // RS256 signature against the served JWKS here, then exchange it at
  // RelayHistory. The RelayAuth API key is read from the pod's own mount.
  const relayauthKey = readFileSync(RELAYAUTH_KEY_FILE, "utf8").trim();
  const historyOrigin = session.baseUrl;
  const minted = await call("POST", `${RELAYAUTH}/v1/tokens/relayhistory-assertion`, {
    headers: { "x-api-key": relayauthKey },
    body: {
      orgId: state.a.organizationId,
      workspaceId: state.a.workspaceId,
      sponsorId: state.a.ownerUserId,
      scopes: ["rth:read"],
      expiresIn: 60,
      historyOrigin,
      metadata: { productId: "selfhost-control-plane", purpose: "relayhistory-login", requestedMode: "read", grantedMode: "read", label: `e2e-${state.marker}` },
    },
  });
  must(minted.status === 200 || minted.status === 201, `relayauth assertion status=${minted.status}`);
  const assertion = minted.json.accessToken;
  const raw = assertion.replace(/^relay_(ag|pa|ws|id)_/, "");
  const [h64, p64, s64] = raw.split(".");
  const header = JSON.parse(Buffer.from(h64, "base64url").toString("utf8"));
  const claims = JSON.parse(Buffer.from(p64, "base64url").toString("utf8"));
  const jwk = jwks.json.keys.find((key) => key.kid === header.kid);
  must(jwk, "assertion kid is not in the JWKS");
  const signatureOk = cryptoVerify(
    "RSA-SHA256",
    Buffer.from(`${h64}.${p64}`),
    createPublicKey({ key: jwk, format: "jwk" }),
    Buffer.from(s64, "base64url"),
  );
  must(signatureOk, "assertion signature does not verify against the JWKS");
  must(
    claims.org === state.a.organizationId && claims.wks === state.a.workspaceId &&
      (claims.aud === historyOrigin || (Array.isArray(claims.aud) && claims.aud[0] === historyOrigin)),
    "assertion claims do not match the tenant",
  );
  const exchanged = await call("POST", `${HISTORY}/v1/cli/login`, { body: { agentRelayToken: assertion } });
  must(exchanged.status === 200 && typeof exchanged.json?.accessToken === "string", `assertion exchange status=${exchanged.status}`);
  const tamperedSig = `${assertion.slice(0, assertion.lastIndexOf(".") + 1)}${Buffer.from(randomBytes(256)).toString("base64url")}`;
  const tamperedExchange = await call("POST", `${HISTORY}/v1/cli/login`, { body: { agentRelayToken: tamperedSig } });
  must(tamperedExchange.status === 401 || tamperedExchange.status === 403, `tampered assertion status=${tamperedExchange.status}`);
  pass(
    "auth.relayauth_assertion",
    `alg=${header.alg} kid_in_jwks=true signature_valid=true aud=${historyOrigin} exchange=${exchanged.status} tampered_exchange=${tamperedExchange.status}`,
  );

  // A structurally valid but unsigned/forged assertion must also fail.
  const forged = await call("POST", `${HISTORY}/v1/cli/login`, {
    body: { agentRelayToken: "eyJhbGciOiJSUzI1NiIsImtpZCI6ImZvcmdlZCJ9.eyJzdWIiOiJ4In0.c2ln" },
  });
  must(forged.status >= 400 && forged.status < 500, `forged assertion status=${forged.status}`);
  pass("auth.relayhistory_rejects_forged_assertion", `status=${forged.status}`);

  // Control-plane access tokens: valid works, revoked/garbage fails.
  const who = await call("GET", `${API}/api/v1/auth/whoami`, { token: state.a.accessToken });
  const garbage = await call("GET", `${API}/api/v1/auth/whoami`, { token: "sh_at_invalid" });
  must(who.status === 200 && garbage.status === 401, `whoami=${who.status} garbage=${garbage.status}`);
  pass("auth.control_plane_token", `valid=${who.status} invalid=${garbage.status}`);

  // The Relaycast workspace key the control plane resolves authenticates at
  // Relaycast; a wrong key does not.
  const rcOk = await call("GET", `${RELAYCAST}/v1/agents`, { token: state.a.relaycastKey });
  const rcBad = await call("GET", `${RELAYCAST}/v1/agents`, { token: `rk_live_${"0".repeat(32)}` });
  must(rcOk.status === 200 && rcBad.status === 401, `relaycast resolved=${rcOk.status} wrong=${rcBad.status}`);
  pass("auth.relaycast_key", `resolved_key=${rcOk.status} wrong_key=${rcBad.status}`);
}

// ---------------------------------------------------------------- erasure

async function phaseErasure() {
  const { sessionId, originId } = state.session;
  const sync = await historySession(state.a, "sync");
  const erase = await call("POST", `${HISTORY}/v1/delivery/sessions/selection`, {
    token: sync.accessToken,
    body: {
      account_id: accountId(state.a),
      origin_id: originId,
      sessions: [{ source: SOURCE, session_id: sessionId }],
      enabled: false,
    },
  });
  must(erase.status === 200, `erase status=${erase.status} error=${errorCode(erase)}`);
  pass("erasure.request", `status=${erase.status} session=${sessionId}`);

  const list = await dashboardList(state.a, state.a.workspaceId);
  must(list.status === 200 && !list.json.items.some((item) => item.sessionId === sessionId), "list still returns the erased session");
  const search = await dashboardList(state.a, state.a.workspaceId, state.marker);
  must(search.status === 200 && !search.json.items.some((item) => item.sessionId === sessionId), "search still returns the erased session");
  const replay = await dashboardEvents(state.a, state.a.workspaceId, sessionId);
  const replayAbsent = absentOrDenied(replay, eventLeaks, [404]);
  must(replayAbsent.ok, `replay after erasure status=${replay.status} events=${replayAbsent.leaked ?? "unknown"}`);
  const read = await historySession(state.a, "read");
  const direct = await call(
    "GET",
    `${HISTORY}/v1/sessions?${new URLSearchParams({ workspace: state.a.workspaceId, q: state.marker })}`,
    { token: read.accessToken },
  );
  must(direct.status === 200 && Array.isArray(direct.json?.sessions), `relayhistory search after erasure status=${direct.status}`);
  must(!direct.json.sessions.some((item) => item.sessionId === sessionId), "relayhistory search still returns it");
  const turns = state.capabilities?.sessions
    ? await call("GET", `${API}/cloud/api/v1/workspaces/${state.a.workspaceId}/sessions/${encodeURIComponent(sessionId)}/turns?source=${SOURCE}`, { token: state.a.accessToken })
    : { status: 404, json: null, text: "" };
  const turnsLeft = turns.status === 200 && Array.isArray(turns.json?.turns) ? turns.json.turns.length : null;
  must(turns.status === 404 || turnsLeft !== null, `turns after erasure status=${turns.status}`);
  // Known RelayHistory gap: session erasure (sessions.set_session_uploads) and
  // the full reset never delete sessions.conversation_turns, so the turns
  // stay readable. Strict by default; --allow-known-gap relayhistory-turns-erasure
  // reports it as SKIP instead, never as PASS.
  if (!state.capabilities?.sessions) {
    proof("SKIP", "erasure.turns_purged", "control plane has no sessions turns route");
  } else if (turns.status === 404 || turnsLeft === 0) {
    pass("erasure.turns_purged", `turns_status=${turns.status} turns_left=0`);
  } else if ((state.allowedGaps ?? []).includes("relayhistory-turns-erasure")) {
    proof("SKIP", "erasure.turns_purged", `KNOWN GAP relayhistory-turns-erasure: turns_left=${turnsLeft} after erasure (allowed by --allow-known-gap)`);
  } else {
    fail("erasure.turns_purged", `turns_left=${turnsLeft} after erasure; RelayHistory erasure does not delete conversation turns`);
  }
  pass("erasure.verified", `list_absent=true search_absent=true replay_status=${replay.status} replay_events=0 relayhistory_status=${direct.status} relayhistory_absent=true`);

  // The receipt survives erasure, so a stale client retry of the original
  // batch must replay that receipt without resurrecting the session.
  const stale = await call("POST", `${HISTORY}/v1/delivery/batches`, { token: sync.accessToken, body: buildBatch() });
  must(stale.status === 200 && stale.json?.receiptId === state.session.receiptId,
    `stale retry status=${stale.status} same_receipt=${stale.json?.receiptId === state.session.receiptId}`);
  const after = await eventsDirect(read.accessToken, state.a, sessionId);
  const afterAbsent = absentOrDenied(after, eventLeaks, [404]);
  must(afterAbsent.ok, `replay after stale retry status=${after.status} events=${afterAbsent.leaked ?? "unknown"}`);
  const afterList = await dashboardList(state.a, state.a.workspaceId, state.marker);
  must(afterList.status === 200 && Array.isArray(afterList.json?.items), `search after stale retry status=${afterList.status}`);
  must(!afterList.json.items.some((item) => item.sessionId === sessionId), "stale retry resurrected the session in search");
  pass("erasure.stale_retry_no_resurrection", `receipt=${stale.json.receiptId} replay_status=${after.status} events_after=0 search_absent=true`);
  state.session.erased = true;
}

// ---------------------------------------------------------------- public

async function phaseIssuePublic() {
  // Hands the caller a short-lived read session so it can repeat an
  // authenticated call through the public ingress from outside the cluster.
  const read = await historySession(state.a, "read");
  state.publicHistoryToken = read.accessToken;
  pass("public.issue_history_session", `base_url=${read.baseUrl}`);
}

async function phaseMintSessionsPipeline() {
  // The sessions-pipeline courier's RelayAuth mode only accepts an HTTPS or loopback
  // RelayAuth URL, so mint the same origin-bound, machine-bound assertion here
  // (RelayAuth is reachable from this pod) and hand it to a fixed-token pass.
  // RelayAuth caps assertions at 60 seconds; the caller uses it immediately.
  const bulls = state.bulls;
  must(bulls?.orgId && bulls?.workspaceId && bulls?.origin && bulls?.machineId, "missing sessions-pipeline tenant parameters");
  const relayauthKey = readFileSync(RELAYAUTH_KEY_FILE, "utf8").trim();
  const minted = await call("POST", `${RELAYAUTH}/v1/tokens/relayhistory-assertion`, {
    headers: { "x-api-key": relayauthKey },
    body: {
      orgId: bulls.orgId,
      workspaceId: bulls.workspaceId,
      machineId: bulls.machineId,
      sponsorId: bulls.userId ?? `e2e-${state.marker}`,
      scopes: ["rth:sync", "rth:read"],
      expiresIn: 60,
      historyOrigin: bulls.origin,
    },
  });
  must(minted.status === 201 && typeof minted.json?.accessToken === "string", `sessions-pipeline assertion mint status=${minted.status}`);
  state.bullsAssertion = minted.json.accessToken;
  pass("pipeline.mint_assertion", `org=${bulls.orgId} workspace=${bulls.workspaceId} machine=${bulls.machineId} aud=${bulls.origin} ttl=60s`);
}

// Removes whatever tracked control-plane resources are still left in A
// (normally none: each phase removes its own). Idempotent: already-gone
// resources (404) count as removed.
async function cleanupResources() {
  const a = state.a;
  const caps = state.capabilities ?? {};
  const removed = [];
  if (!a?.accessToken) return removed;
  // Discover leftovers by the run's unique marker as well as from the tracked
  // list: the tracked list lives in the driver's memory for the length of a
  // phase, so a phase interrupted mid-way never hands it back.
  const prefix = `e2e-${state.marker}`;
  const envTag = state.marker.toUpperCase();
  const list = async (url, pick) => {
    const response = await call("GET", url, { token: a.accessToken });
    must(response.status === 200, `list ${url.replace(API, "")} status=${response.status}`);
    return pick(response.json) ?? [];
  };
  const tracked = (kind) => state.resources?.[kind] ?? [];
  if (caps.flows) {
    const workers = await list(`${API}/api/v1/workers`, (json) => json.workers);
    for (const worker of workers.filter((w) => w.status !== "revoked" &&
      (w.name?.startsWith(prefix) || tracked("workerNames").includes(w.name)))) {
      const revoked = await call("DELETE", `${API}/api/v1/workers/${worker.id}`, { token: a.accessToken });
      must([200, 404].includes(revoked.status), `worker ${worker.id} revoke status=${revoked.status}`);
      removed.push(`worker:${worker.id}`);
    }
    const tokens = await list(`${API}/api/v1/workers/enrollment-tokens`, (json) => json.tokens);
    const tokenIds = new Set([...tracked("enrollmentTokens"),
      ...tokens.filter((t) => t.name?.startsWith(prefix) && t.status !== "used" && t.status !== "revoked").map((t) => t.id)]);
    for (const id of tokenIds) {
      const response = await call("DELETE", `${API}/api/v1/workers/enrollment-tokens/${id}`, { token: a.accessToken });
      must([200, 404].includes(response.status), `enrollment token ${id} revoke status=${response.status}`);
      if (response.status === 200) removed.push(`enrollment_token:${id}`);
    }
    const flows = await list(`${API}/api/v1/flows`, (json) => json.flows);
    const flowIds = new Set([...tracked("flows"), ...flows.filter((f) => f.name?.startsWith(prefix)).map((f) => f.id)]);
    for (const id of flowIds) {
      const response = await call("DELETE", `${API}/api/v1/flows/${id}`, { token: a.accessToken });
      must([200, 404].includes(response.status), `flow ${id} delete status=${response.status}`);
      if (response.status === 200) removed.push(`flow:${id}`);
    }
  }
  if (caps.admin) {
    const vars = await list(`${API}/api/v1/workspaces/${a.workspaceId}/secrets`, (json) => json.data?.items);
    const names = new Set([...tracked("envVars"), ...vars.filter((v) => v.name?.includes(envTag)).map((v) => v.name)]);
    for (const name of names) {
      const response = await call("DELETE", `${API}/api/v1/workspaces/${a.workspaceId}/secrets/${name}`, { token: a.accessToken });
      must([200, 404].includes(response.status), `env var ${name} delete status=${response.status}`);
      if (response.status === 200) removed.push(`env_var:${name}`);
    }
  }
  state.resources = {};
  return removed;
}

// Case 15, and the shell's EXIT trap after an interruption. Every step is
// recorded in state.cleaned so a second invocation only finishes what is left.
// Each step is attempted even when an earlier one fails, so one bad delete
// never leaves the Relaycast workspaces or device sessions behind.
async function step(check, run) {
  try {
    await run();
  } catch (error) {
    fail(check, error instanceof CheckError ? error.message : `unexpected: ${error?.message ?? error}`);
  }
}

async function phaseCleanup() {
  state.cleaned ??= {};
  if (!state.cleaned.resources) {
    await step("cleanup.control_plane_resources", async () => {
      const removed = await cleanupResources();
      state.cleaned.resources = true;
      pass("cleanup.control_plane_resources", removed.length ? `removed=${removed.join(",")}` : "leftover=0");
    });
  }
  for (const label of ["a", "b"]) {
    const tenant = state[label];
    if (!tenant?.relaycastWorkspaceId || state.cleaned[`relaycast_${label}`]) continue;
    await step(`cleanup.relaycast_${label}`, async () => {
    const response = await call("DELETE", `${RELAYCAST}/internal/workspaces/${tenant.relaycastWorkspaceId}`, {
      token: secrets.relaycastInternalSecret,
      timeoutMs: state.relaycast?.createTimeoutMs ?? 180_000,
    });
    must(response.status === 204 || response.status === 200, `delete relaycast workspace ${label} status=${response.status} (mode=${state.relaycast?.mode})`);
    state.cleaned[`relaycast_${label}`] = true;
    pass(`cleanup.relaycast_${label}`, `deleted=${tenant.relaycastWorkspaceId}`);
    });
  }
  // Revoke the device sessions the run minted; revocation covers both the
  // access and the refresh token of the session.
  for (const label of ["a", "b"]) {
    const tenant = state[label];
    if (!tenant?.accessToken || state.cleaned[`tokens_${label}`]) continue;
    await step(`cleanup.tokens_${label}`, async () => {
    const revoked = await call("POST", `${API}/api/v1/auth/token/revoke`, { body: { token: tenant.accessToken } });
    must(revoked.status === 200 && revoked.json?.revoked === true, `revoke ${label} status=${revoked.status}`);
    const who = await call("GET", `${API}/api/v1/auth/whoami`, { token: tenant.accessToken });
    const refresh = await call("POST", `${API}/api/v1/auth/token/refresh`, { body: { refreshToken: tenant.refreshToken } });
    must(who.status === 401 && refresh.status === 403, `after revoke ${label} whoami=${who.status} refresh=${refresh.status}`);
    state.cleaned[`tokens_${label}`] = true;
    pass(`cleanup.tokens_${label}`, `revoked=true whoami_after=${who.status} refresh_after=${refresh.status}`);
    });
  }
  const tracked = ["a", "b"].filter((label) => state[label]?.workspaceId)
    .map((label) => ({ ...state[label], label }));
  if (!tracked.length) return;
  // Historical drivers set this flag even when DELETE was unsupported.
  // Re-verify the rows instead of inheriting that false completion receipt.
  state.cleaned.workspaces = false;
  await step("cleanup.control_plane_workspaces", async () => {
    // The bootstrap bearer can delete every workspace. Before using it,
    // independently bind ALL tracked IDs to this run's unique names/org.
    // Never delete an installation's Default workspace or discover targets
    // by a broad name prefix. Partial bootstrap/cleanup remains retryable.
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    const orgId = state.org?.organizationId;
    must(typeof state.marker === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(state.marker), "workspace cleanup needs this run's marker");
    must(typeof orgId === "string" && uuid.test(orgId), "workspace cleanup needs this run's organization");
    must(new Set(tracked.map((tenant) => tenant.workspaceId)).size === tracked.length, "workspace cleanup has duplicate tracked IDs");
    for (const tenant of tracked) {
      must(uuid.test(tenant.workspaceId), "workspace cleanup has an invalid tracked ID");
      must(!tenant.organizationId || tenant.organizationId === orgId, "tracked workspace organization differs");
      must(!tenant.workspaceName || tenant.workspaceName === `e2e-${state.marker}-${tenant.label}`, "tracked workspace name differs");
    }
    const bootstrap = bootstrapToken();
    const collection = `${API}/api/v1/organizations/${encodeURIComponent(orgId)}/workspaces`;
    const list = async () => {
      const response = await call("GET", collection, { token: bootstrap });
      must(response.status === 200 && Array.isArray(response.json?.workspaces), `workspace list status=${response.status}`);
      return response.json.workspaces;
    };
    const before = await list();
    const ids = new Set(tracked.map((tenant) => tenant.workspaceId));
    const present = tracked.filter((tenant) => before.some((row) => row.id === tenant.workspaceId));
    // Check every present target before sending even the first DELETE.
    for (const tenant of present) {
      const row = before.find((item) => item.id === tenant.workspaceId);
      must(row.name === `e2e-${state.marker}-${tenant.label}`, "refusing to delete a workspace outside this run");
      must(!row.organizationId || row.organizationId === orgId, "listed workspace organization differs");
    }
    const results = [];
    for (const tenant of present) {
      const removed = await call("DELETE", `${collection}/${encodeURIComponent(tenant.workspaceId)}`, { token: bootstrap });
      must(removed.status === 204 || removed.status === 404, `workspace delete ${tenant.label} status=${removed.status}; no forced teardown attempted`);
      results.push(removed.status);
    }
    const after = await list();
    must(before.filter((row) => !ids.has(row.id)).every((row) => after.some((remaining) => remaining.id === row.id && remaining.name === row.name)), "workspace cleanup changed an untracked workspace");
    const left = after.filter((row) => ids.has(row.id));
    if (!left.length) {
      state.cleaned.workspaces = true;
      pass("cleanup.control_plane_workspaces", `delete_attempts=${present.length} verified_absent=${tracked.length} remaining_test=0 other_workspaces_preserved=true; external stores are handled separately`);
    } else if (results.every((status) => status === 404) && left.length === present.length) {
      // Older images still lack DELETE. Preserve the original PENDING gate
      // without claiming cleanup or suppressing a later retry on a new image.
      proof("SKIP", "cleanup.control_plane_workspaces", `workspace DELETE unavailable; retained_test_workspaces=${left.length}; no cleanup completion recorded`);
    } else {
      fail("cleanup.control_plane_workspaces", `workspace delete did not remove every tracked workspace; remaining_test=${left.length}`);
    }
  });
}

const phases = {
  bootstrap: phaseBootstrap,
  messaging: phaseMessaging,
  delivery: phaseDelivery,
  reads: phaseReads,
  isolation: phaseIsolation,
  "durability-history": phaseDurabilityHistory,
  "durability-relaycast": phaseDurabilityRelaycast,
  auth: phaseAuth,
  erasure: phaseErasure,
  "issue-public": phaseIssuePublic,
  "mint-sessions-pipeline": phaseMintSessionsPipeline,
  sessions: phaseSessions,
  admin: phaseAdmin,
  "admin-internal": phaseAdminInternal,
  "flows-enroll": phaseFlowsEnroll,
  "flows-run": phaseFlowsRun,
  "flows-cleanup": phaseFlowsCleanup,
  cleanup: phaseCleanup,
};

try {
  const run = phases[phase];
  if (!run) throw new CheckError(`unknown phase ${phase}`);
  await run();
} catch (error) {
  fail(`${phase}.error`, error instanceof CheckError ? error.message : `unexpected: ${error?.message ?? error}`);
}
process.stdout.write(JSON.stringify({ state, proofs }));
