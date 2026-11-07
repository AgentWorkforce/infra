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
  }), error => error.message === "first-boot organization/Default workspace not ready after 120s");
  assert.equal(clock, 4000);
});
