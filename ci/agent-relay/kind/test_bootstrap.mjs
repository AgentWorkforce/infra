import assert from "node:assert/strict";
import test from "node:test";
import { waitForDefaultWorkspace } from "./bootstrap.mjs";

const ok = body => ({ ok: true, json: async () => body });
test("retries a reset, non-JSON response and unready workspace before success", async () => {
  let clock = 0;
  const replies = [new TypeError("reset with private details"),
    { ok: true, json: async () => { throw new SyntaxError("proxy HTML"); } },
    ok({ organizations: [{ id: "org" }] }), { ok: false },
    ok({ organizations: [{ id: "org" }] }), ok({ workspaces: [{ name: "Default", id: "workspace" }] })];
  const ids = await waitForDefaultWorkspace("test-secret", {
    request: async () => { const value = replies.shift(); if (value instanceof Error) throw value; return value; },
    now: () => clock, sleep: async ms => { clock += ms; },
  });
  assert.deepEqual(ids, { orgId: "org", workspaceId: "workspace" });
  assert.equal(clock, 6000);
  assert.equal(replies.length, 0);
});
test("persistent timeouts exhaust the deadline with a credential-free diagnostic", async () => {
  let clock = 0;
  await assert.rejects(waitForDefaultWorkspace("test-secret", {
    request: async () => { throw new Error("test-secret"); },
    now: () => clock, sleep: async ms => { clock += ms; }, timeoutMs: 4000,
  }), error => error.message === "first-boot organization/workspace not ready after 4s; last HTTP status=none");
  assert.equal(clock, 4000);
});
test("reports the last HTTP status without echoing a response or token", async () => {
  let clock = 0;
  await assert.rejects(waitForDefaultWorkspace("test-secret", {
    request: async () => ({ ok: false, status: 401, body: "test-secret response credentials" }),
    now: () => clock, sleep: async ms => { clock += ms; }, timeoutMs: 2000,
  }), error => {
    assert.match(error.message, /after 2s; last HTTP status=401$/);
    assert.ok(!error.message.includes("test-secret"));
    assert.ok(!error.message.includes("response credentials"));
    return true;
  });
});
test("discovers an explicitly configured first workspace name", async () => {
  const replies = [ok({ organizations: [{ id: "org" }] }), ok({ workspaces: [{ name: "Custom", id: "workspace" }] })];
  assert.deepEqual(await waitForDefaultWorkspace("test-secret", {
    workspaceName: "Custom", request: async () => replies.shift(),
  }), { orgId: "org", workspaceId: "workspace" });
});
