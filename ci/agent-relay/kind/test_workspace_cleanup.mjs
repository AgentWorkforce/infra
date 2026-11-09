import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import test from "node:test";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const DRIVER = join(ROOT, "scripts/selfhost/e2e-gcp-proof-driver.mjs");
const ORG = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const OTHER = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const MARKER = "owned-cleanup-proof";
const row = (id, name) => ({ id, name, organizationId: ORG });

async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), "kind-owned-cleanup-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  // Only the child process sees this synthetic bootstrap file. The test
  // neither reads an operator credential nor changes production config.
  const preload = join(directory, "bootstrap-fixture.mjs");
  await writeFile(preload, `import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
const original=fs.readFileSync;
fs.readFileSync=function(path,...args){
  if(path==='/var/run/agent-relay/secrets/selfhost-bootstrap-token')return 'synthetic-bootstrap-only-for-local-proof-test';
  return original.call(this,path,...args);
};syncBuiltinESMExports();\n`, { mode: 0o600 });
  let rows = options.rows ?? [row(OTHER, "Default"), row(A, `e2e-${MARKER}-a`), row(B, `e2e-${MARKER}-b`)];
  const deletes = [];
  const server = createServer((req, res) => {
    assert.equal(req.headers.authorization, "Bearer synthetic-bootstrap-only-for-local-proof-test");
    const path = new URL(req.url, "http://localhost").pathname;
    const base = `/api/v1/organizations/${ORG}/workspaces`;
    if (req.method === "GET" && path === base) {
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ workspaces: rows }));
      return;
    }
    if (req.method === "DELETE" && path.startsWith(base + "/")) {
      const id = decodeURIComponent(path.slice(base.length + 1));
      deletes.push(id);
      if (options.mode === "legacy") return res.writeHead(404).end();
      if (options.mode === "in-use") return res.writeHead(409).end();
      if (!rows.some((row) => row.id === id)) return res.writeHead(404).end();
      if (options.mode !== "false-success") rows = rows.filter((row) => row.id !== id);
      return res.writeHead(204).end();
    }
    res.writeHead(500).end();
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const input = {
    marker: MARKER,
    org: { organizationId: ORG },
    a: { organizationId: ORG, workspaceId: A, workspaceName: `e2e-${MARKER}-a` },
    b: { organizationId: ORG, workspaceId: B, workspaceName: `e2e-${MARKER}-b` },
    cleaned: { resources: true },
    ...options.state,
  };
  const child = spawn(process.execPath, ["--import", preload, DRIVER, "cleanup"], {
    env: { ...process.env, E2E_API_URL: `http://127.0.0.1:${server.address().port}` },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let stdout = "", stderr = "";
  child.stdout.setEncoding("utf8").on("data", (text) => { stdout += text; });
  child.stderr.setEncoding("utf8").on("data", (text) => { stderr += text; });
  child.stdin.end(JSON.stringify(input));
  const code = await new Promise((resolve, reject) => { child.on("error", reject); child.on("close", resolve); });
  assert.equal(code, 0, stderr);
  return { ...JSON.parse(stdout), deletes, rows };
}
const check = (result) => result.proofs.find((item) => item.check === "cleanup.control_plane_workspaces");

test("deletes both exact owned workspaces and preserves Default", async (t) => {
  const result = await fixture(t);
  assert.equal(check(result)?.result, "PASS");
  assert.deepEqual(result.deletes, [A, B]);
  assert.deepEqual(result.rows, [row(OTHER, "Default")]);
  assert.equal(result.state.cleaned.workspaces, true);
});

test("an older image stays pending without falsely recording cleanup", async (t) => {
  const result = await fixture(t, { mode: "legacy" });
  assert.equal(check(result)?.result, "SKIP");
  assert.notEqual(result.state.cleaned.workspaces, true);
  assert.equal(result.rows.length, 3);
});

test("preflights every target before deleting any when a tracked ID names another workspace", async (t) => {
  const result = await fixture(t, { rows: [row(OTHER, "Default"), row(A, `e2e-${MARKER}-a`), row(B, "Customer workspace")] });
  assert.equal(check(result)?.result, "FAIL");
  assert.deepEqual(result.deletes, []);
  assert.notEqual(result.state.cleaned.workspaces, true);
});

test("a partial prior cleanup removes only the remaining tracked workspace", async (t) => {
  const result = await fixture(t, { rows: [row(OTHER, "Default"), row(B, `e2e-${MARKER}-b`)] });
  assert.equal(check(result)?.result, "PASS");
  assert.deepEqual(result.deletes, [B]);
  assert.equal(result.state.cleaned.workspaces, true);
});

test("an old completion flag never suppresses verifying and removing leftovers", async (t) => {
  const result = await fixture(t, { state: { cleaned: { resources: true, workspaces: true } } });
  assert.equal(check(result)?.result, "PASS");
  assert.deepEqual(result.deletes, [A, B]);
  assert.deepEqual(result.rows, [row(OTHER, "Default")]);
});

test("a partial bootstrap can clean its one recorded workspace", async (t) => {
  const result = await fixture(t, { rows: [row(OTHER, "Default"), row(A, `e2e-${MARKER}-a`)], state: { b: undefined } });
  assert.equal(check(result)?.result, "PASS");
  assert.deepEqual(result.deletes, [A]);
});

test("a login failure after creation retains the workspace identity for cleanup", async (t) => {
  const source = await readFile(DRIVER, "utf8");
  const start = source.indexOf("async function createTenant(");
  const end = source.indexOf("\nasync function phaseBootstrap(", start);
  assert.ok(start >= 0 && end > start);
  const state = { marker: MARKER, b: { relaycastWorkspaceId: "synthetic-cast-b" } };
  const context = {
    state, API: "http://unused-loopback-fixture", bootstrapToken: () => "synthetic-bootstrap",
    call: async () => ({ status: 201, json: { id: B, organizationId: ORG, name: `e2e-${MARKER}-b` } }),
    must: (value, message) => { if (!value) throw new Error(message); },
    errorCode: () => "none", deviceLogin: async () => { throw new Error("synthetic login failed"); },
  };
  // Execute the actual function with a failed-login dependency; production
  // remains a single-file driver that can be copied into the Control pod.
  vm.runInNewContext(source.slice(start, end), context);
  await assert.rejects(() => context.createTenant("b", { organizationId: ORG, ownerUserId: OTHER },
    { workspaceId: "synthetic-cast-b", apiKey: "synthetic-cast-key-b", ms: 1 }), /synthetic login failed/);
  assert.equal(state.b.workspaceId, B);
  assert.equal(state.b.organizationId, ORG);
  assert.equal(state.b.workspaceName, `e2e-${MARKER}-b`);
  assert.equal(state.b.accessToken, undefined);
  const result = await fixture(t, { state: { b: state.b } });
  assert.equal(check(result)?.result, "PASS");
  assert.deepEqual(result.deletes, [A, B]);
  assert.deepEqual(result.rows, [row(OTHER, "Default")]);
});

test("204 without removal is a failure, never a cleanup pass", async (t) => {
  const result = await fixture(t, { mode: "false-success" });
  assert.equal(check(result)?.result, "FAIL");
  assert.notEqual(result.state.cleaned.workspaces, true);
  assert.equal(result.rows.length, 3);
});

test("Factory refusal remains a failure with no forced teardown", async (t) => {
  const result = await fixture(t, { mode: "in-use" });
  assert.equal(check(result)?.result, "FAIL");
  assert.deepEqual(result.deletes, [A]);
  assert.notEqual(result.state.cleaned.workspaces, true);
  assert.equal(result.rows.length, 3);
});

test("a foreign organization in tracked state refuses before DELETE", async (t) => {
  const result = await fixture(t, { state: { a: { organizationId: OTHER, workspaceId: A } } });
  assert.equal(check(result)?.result, "FAIL");
  assert.deepEqual(result.deletes, []);
});
