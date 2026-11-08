// Execute inside the Control API pod. The bootstrap bearer never leaves it.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

class Refusal extends Error {
  constructor(code) { super(code); this.code = code; }
}
const refuse = code => { throw new Refusal(code); };
const uuid = value => typeof value === "string" && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
const codeValue = value => {
  if (typeof value !== "string" || !/^[A-Z0-9]{4}-[A-Z0-9]{4}$/i.test(value)) refuse("invalid_user_code");
  return value.toUpperCase();
};
const nullable = value => value === "-" ? null : value;
const list = (value, key) => {
  if (!value || !Array.isArray(value[key])) refuse("invalid_control_response");
  return value[key];
};

export async function operatorDeviceLogin(args, {
  request = fetch,
  readToken = () => readFileSync(process.env.SELFHOST_BOOTSTRAP_TOKEN_FILE ||
    "/var/run/agent-relay/secrets/selfhost-bootstrap-token", "utf8").trim(),
  port = process.env.PORT || "3000",
  now = Date.now,
} = {}) {
  const [action, rawCode, orgId, workspaceId, userId, clientName, hostName] = args;
  if (!/^[0-9]{1,5}$/.test(String(port)) || Number(port) < 1 || Number(port) > 65535) refuse("invalid_local_port");
  if (action === "inventory") {
    if (args.length !== 1) refuse("invalid_arguments");
  } else if (action === "lookup") {
    if (args.length !== 2) refuse("invalid_arguments");
    codeValue(rawCode);
  } else if (action === "approve" || action === "deny") {
    if (args.length !== 7 || ![orgId, workspaceId, userId].every(uuid) ||
        !clientName || !hostName) refuse("invalid_arguments");
    codeValue(rawCode);
  } else refuse("invalid_action");

  let token;
  try { token = readToken(); } catch { refuse("bootstrap_credential_unavailable"); }
  if (typeof token !== "string" || !token.trim()) refuse("bootstrap_credential_unavailable");
  const call = async (path, body) => {
    let response;
    try {
      response = await request(`http://127.0.0.1:${port}${path}`, {
        method: body === undefined ? "GET" : "POST",
        redirect: "error", signal: AbortSignal.timeout(10_000),
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
    } catch { refuse("control_request_failed"); }
    if (response.status !== 200) refuse(`control_http_${Number(response.status) || "unknown"}`);
    try { return await response.json(); } catch { refuse("invalid_control_response"); }
  };
  const organizations = async () => list(await call("/api/v1/organizations"), "organizations");
  const members = async id => list(await call(`/api/v1/organizations/${id}/memberships`), "memberships");
  const workspaces = async id => list(await call(`/api/v1/organizations/${id}/workspaces`), "workspaces");
  const lookup = async () => {
    const found = await call("/api/v1/auth/device/approve", { action: "lookup", user_code: codeValue(rawCode) });
    if (found?.user_code !== codeValue(rawCode) ||
        !(found.client_name === null || typeof found.client_name === "string") ||
        !(found.desktop_host_name === null || typeof found.desktop_host_name === "string") ||
        !["pending", "approved", "denied", "consumed", "expired"].includes(found.status) ||
        !Number.isFinite(Date.parse(found.expires_at))) refuse("invalid_control_response");
    return {
      user_code: found.user_code, client_name: found.client_name,
      desktop_host_name: found.desktop_host_name,
      status: found.status, expires_at: found.expires_at,
    };
  };

  if (action === "inventory") {
    const orgs = await organizations();
    if (orgs.length !== 1 || !uuid(orgs[0]?.id)) refuse("installation_organization_ambiguous");
    const id = orgs[0].id;
    const ws = await workspaces(id);
    const users = await members(id);
    if (ws.some(w => !uuid(w?.id)) || users.some(u => !uuid(u?.userId))) refuse("invalid_control_response");
    return {
      organization: { id, name: orgs[0].name },
      workspaces: ws.map(w => ({ id: w.id, name: w.name })),
      members: users.map(u => ({ user_id: u.userId, email: u.email, role: u.role })),
    };
  }
  if (action === "lookup") return lookup();

  const orgs = await organizations();
  if (orgs.length !== 1 || orgs[0]?.id !== orgId) refuse("installation_organization_mismatch");
  if (!(await workspaces(orgId)).some(w => w?.id === workspaceId)) refuse("workspace_mismatch");
  if (!(await members(orgId)).some(u => u?.userId === userId &&
      ["owner", "admin", "member"].includes(u.role))) refuse("user_not_member");
  // Fresh lookup immediately before the atomic server decision. A previous
  // printed lookup alone is never taken as proof that the code is still live.
  const found = await lookup();
  if (found.status !== "pending") refuse("request_not_pending");
  if (Date.parse(found.expires_at) <= now()) refuse("request_expired");
  if (found.client_name !== nullable(clientName)) refuse("client_mismatch");
  if (found.desktop_host_name !== nullable(hostName)) refuse("host_mismatch");
  const decided = await call("/api/v1/auth/device/approve", {
    action, user_code: found.user_code, user_id: userId, workspace_id: workspaceId,
  });
  const expected = action === "approve" ? "approved" : "denied";
  if (decided?.status !== expected) refuse("unexpected_decision_result");
  return { status: expected, organization_id: orgId, workspace_id: workspaceId, user_id: userId };
}

if (process.argv[1] === "-" || (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)) {
  try { console.log(JSON.stringify(await operatorDeviceLogin(process.argv.slice(2)), null, 2)); }
  catch (error) {
    // Never print upstream errors, response bodies, stack traces or credentials.
    console.error(JSON.stringify({ error: error instanceof Refusal ? error.code : "operator_login_failed" }));
    process.exitCode = 1;
  }
}
