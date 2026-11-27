import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { missing, waitForBootstrap } from "../../charts/sessions-pipeline/files/search-indexer-bootstrap-wait.mjs";

const READY = { sessions_usage: true, index_usage: true, no_write: [],
  present: ["search_index.projection_state", "search_index.transcript_events", "sessions.search_consumer_pending", "sessions.search_consumer_progress"] };

describe("search indexer bootstrap wait", () => {
  test("names everything the bootstrap has not provided yet", () => {
    assert.deepEqual(missing(READY), []);
    assert.deepEqual(missing({ sessions_usage: false, index_usage: true, present: READY.present, no_write: ["sessions.search_consumer_pending"] }),
      ["USAGE on schema sessions", "SELECT/INSERT on sessions.search_consumer_pending"]);
    assert.ok(missing({}).includes("table sessions.search_consumer_progress"));
  });

  test("waits through connection errors and a half-done bootstrap, then starts", async () => {
    const answers = [new Error("connect ECONNREFUSED"), { rows: [{ ...READY, sessions_usage: false }] }, { rows: [READY] }];
    const logs = []; let t = 0;
    const code = await waitForBootstrap(async () => { const a = answers.shift(); if (a instanceof Error) throw a; return a; },
      { waitSeconds: 60, pollSeconds: 5, sleep: async (ms) => { t += ms; }, now: () => t, log: (m) => logs.push(m) });
    assert.equal(code, 0);
    assert.equal(t, 10000);
    assert.equal(logs.filter((m) => m.includes("waiting for the search bootstrap")).length, 1);
    assert.ok(logs.at(-1).includes("has completed"));
  });

  test("gives up after its deadline naming what is missing and the fix", async () => {
    const logs = []; let t = 0;
    const code = await waitForBootstrap(async () => ({ rows: [{ ...READY, sessions_usage: false }] }),
      { waitSeconds: 20, pollSeconds: 5, sleep: async (ms) => { t += ms; }, now: () => t, log: (m) => logs.push(m) });
    assert.equal(code, 1);
    assert.match(logs.at(-1), /has not completed after 20s \(missing: USAGE on schema sessions\).*get jobs \| grep search-indexer-bootstrap.*helm upgrade again/u);
  });
});
