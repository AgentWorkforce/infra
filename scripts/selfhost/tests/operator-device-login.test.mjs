import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { operatorDeviceLogin } from "../operator-device-login.mjs";

const org = "10000000-0000-4000-8000-000000000001";
const workspace = "20000000-0000-4000-8000-000000000002";
const user = "30000000-0000-4000-8000-000000000003";
const code = "ABCD-EFGH";
const args = (action = "approve") => [action, code, org, workspace, user, "--client", "Desktop", "--host", "laptop"];
function fixture(changes = {}) {
  const calls = [];
  const token = "synthetic-bootstrap-for-test-only";
  const found = { user_code: code, client_name: "Desktop", desktop_host_name: "laptop",
    status: "pending", expires_at: "2030-01-01T00:00:00Z", device_code: "do-not-print" };
  const state = { orgs: [{ id: org, name: "Example" }], ws: [{ id: workspace, name: "Main", runtime: { secret: "do-not-print" } }],
    users: [{ userId: user, email: "owner@example.invalid", role: "owner", secret: "do-not-print" }],
    found, ...changes };
  const request = async (url, init) => {
    assert.equal(new URL(url).origin, "http://127.0.0.1:3000");
    assert.equal(init.redirect, "error");
    assert.equal(init.headers.authorization, `Bearer ${token}`);
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ url, body });
    let response;
    if (url.endsWith("/organizations")) response = { organizations: state.orgs };
    else if (url.endsWith("/memberships")) response = { memberships: state.users };
    else if (url.endsWith("/workspaces")) response = { workspaces: state.ws };
    else if (body?.action === "lookup") response = state.found;
    else response = { status: body?.action === "approve" ? "approved" : "denied", access_token: "do-not-print" };
    return new Response(JSON.stringify(response), { status: 200 });
  };
  return { calls, state, deps: { request, readToken: () => token, port: "3000", now: () => Date.parse("2026-11-08T00:00:00Z") } };
}

test("inventory and lookup expose only selected metadata, never credentials or arbitrary fields", async () => {
  const f = fixture();
  for (const input of [["inventory"], ["lookup", code]]) {
    const result = await operatorDeviceLogin(input, f.deps);
    assert.doesNotMatch(JSON.stringify(result), /synthetic-bootstrap|do-not-print|device_code|runtime/);
  }
  assert(f.calls.every(c => !["approve", "deny"].includes(c.body?.action)));
});

test("approval and denial use explicit verified identities and freshly inspect the pending code", async () => {
  for (const action of ["approve", "deny"]) {
    const f = fixture();
    const result = await operatorDeviceLogin(args(action), f.deps);
    assert.equal(result.status, action === "approve" ? "approved" : "denied");
    assert.equal(f.calls.at(-2).body.action, "lookup");
    assert.deepEqual(f.calls.at(-1).body, { action, user_code: code, user_id: user, workspace_id: workspace });
    assert.doesNotMatch(JSON.stringify(result), /access_token|synthetic-bootstrap|do-not-print/);
  }
});

for (const [label, mutation, expected] of [
  ["wrong organization", f => { f.state.orgs[0].id = workspace; }, "installation_organization_mismatch"],
  ["multiple organizations", f => { f.state.orgs.push({ id: workspace }); }, "installation_organization_mismatch"],
  ["foreign workspace", f => { f.state.ws = []; }, "workspace_mismatch"],
  ["non-member", f => { f.state.users = []; }, "user_not_member"],
  ["unknown member role", f => { f.state.users[0].role = "superadmin"; }, "user_not_member"],
  ["consumed request", f => { f.state.found.status = "consumed"; }, "request_not_pending"],
  ["expired request", f => { f.state.found.expires_at = "2020-01-01T00:00:00Z"; }, "request_expired"],
  ["wrong client", f => { f.state.found.client_name = "Other"; }, "client_mismatch"],
  ["wrong computer", f => { f.state.found.desktop_host_name = "other"; }, "host_mismatch"],
  ["different code returned", f => { f.state.found.user_code = "ZZZZ-ZZZZ"; }, "invalid_control_response"],
  ["malformed expiry", f => { f.state.found.expires_at = "not-a-date"; }, "invalid_control_response"],
]) test(`refuses ${label} before a decision`, async () => {
  const f = fixture(); mutation(f);
  await assert.rejects(operatorDeviceLogin(args(), f.deps), { message: expected });
  assert(!f.calls.some(c => ["approve", "deny"].includes(c.body?.action)));
});

test("browser requests with no host/client require explicit null options", async () => {
  const f = fixture(); f.state.found.client_name = null; f.state.found.desktop_host_name = null;
  const input = [...args().slice(0, 5), "--client-null", "--host-null"];
  assert.equal((await operatorDeviceLogin(input, f.deps)).status, "approved");
});

test("literal dash and shell-looking labels remain exact strings", async () => {
  for (const value of ["-", "user's laptop $(not-a-command)"]) {
    const f = fixture(); f.state.found.client_name = value; f.state.found.desktop_host_name = value;
    const input = [...args().slice(0, 5), "--client", value, "--host", value];
    assert.equal((await operatorDeviceLogin(input, f.deps)).status, "approved");
  }
});

test("ambiguous or missing label selections refuse before reading the bearer", async () => {
  const f = fixture(); f.deps.readToken = () => { throw new Error("must not be read"); };
  for (const tail of [["--client-null"], ["--client-null", "--client", "Desktop", "--host-null"],
    ["--client", "Desktop", "--host-null", "--host-null"], ["--client-null", "--host"]]) {
    await assert.rejects(operatorDeviceLogin([...args().slice(0, 5), ...tail], f.deps), /invalid_arguments/);
  }
  assert.equal(f.calls.length, 0);
});

test("invalid actions, missing identity and unsafe ports are rejected before reading the bearer", async () => {
  const f = fixture(); f.deps.readToken = () => { throw new Error("must not be read"); };
  for (const input of [[], ["start"], ["inventory", "extra"], ["lookup", "bad"], args().slice(0, 6), ["approve", code, "bad", workspace, user, "Desktop", "laptop"]]) {
    await assert.rejects(operatorDeviceLogin(input, f.deps), /invalid_/);
  }
  await assert.rejects(operatorDeviceLogin(["inventory"], { ...f.deps, port: "3000/remote" }), /invalid_local_port/);
  assert.equal(f.calls.length, 0);
});

test("request and response errors do not expose external error text or retry an approval", async () => {
  const f = fixture();
  await assert.rejects(operatorDeviceLogin(["lookup", code], { ...f.deps, request: async () => { throw new Error("SECRET_EXTERNAL_TEXT"); } }), { message: "control_request_failed" });
  await assert.rejects(operatorDeviceLogin(["lookup", code], { ...f.deps, request: async () => new Response("SECRET_EXTERNAL_TEXT", { status: 403 }) }), { message: "control_http_403" });
  await assert.rejects(operatorDeviceLogin(["lookup", code], { ...f.deps, request: async () => new Response("SECRET_EXTERNAL_TEXT", { status: 200 }) }), { message: "invalid_control_response" });
  let decisions = 0;
  const request = async (url, init) => {
    const body = init.body && JSON.parse(init.body);
    if (body?.action === "approve") { decisions++; throw new Error("SECRET_EXTERNAL_TEXT"); }
    return f.deps.request(url, init);
  };
  await assert.rejects(operatorDeviceLogin(args(), { ...f.deps, request }), /control_request_failed/);
  assert.equal(decisions, 1);
});

test("an unexpected decision result is reported once without retry", async () => {
  const f = fixture(); let decisions = 0;
  const request = async (url, init) => {
    const body = init.body && JSON.parse(init.body);
    if (body?.action === "approve") { decisions++; return Response.json({ status: "pending" }); }
    return f.deps.request(url, init);
  };
  await assert.rejects(operatorDeviceLogin(args(), { ...f.deps, request }), /unexpected_decision_result/);
  assert.equal(decisions, 1);
});

test("the real CLI and in-pod stdin entrypoint both emit only a typed refusal", () => {
  const path = new URL("../operator-device-login.mjs", import.meta.url);
  for (const [argv, input] of [
    [[path.pathname, "invalid-action"], undefined],
    [["--input-type=module", "-", "invalid-action"], readFileSync(path, "utf8")],
  ]) {
    const result = spawnSync(process.execPath, argv, { encoding: "utf8", input,
      env: { ...process.env, PORT: "3000", SELFHOST_BOOTSTRAP_TOKEN_FILE: "/no-fixture-credential" } });
    assert.equal(result.status, 1);
    assert.equal(result.stdout, "");
    assert.deepEqual(JSON.parse(result.stderr), { error: "invalid_action" });
  }
});
