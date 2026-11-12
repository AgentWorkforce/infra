import assert from "node:assert/strict";
import { describe, test } from "node:test";
import {
  executeBootstrapGuard,
  isRetryableCatalogRace,
  waitForRuntimeRoleActivation,
} from "../../charts/sessions-pipeline/files/search-indexer-bootstrap-guard.mjs";

describe("search indexer bootstrap catalog retry", () => {
  test("accepts only the two observed XX000 catalog race signatures", () => {
    assert.equal(isRetryableCatalogRace('error: tuple concurrently updated\n code: "XX000"'), true);
    assert.equal(isRetryableCatalogRace("XX000: heapam simple_heap_update: concurrent catalog update"), true);
  });

  test("does not retry generic internal or non-catalog failures", () => {
    assert.equal(isRetryableCatalogRace("XX000: unrelated internal error"), false);
    assert.equal(isRetryableCatalogRace("tuple concurrently updated"), false);
    assert.equal(isRetryableCatalogRace("42501: permission denied"), false);
  });
});

describe("bootstrap guard orchestration", () => {
  test("holds the migrator lock across an exact retry and always releases it", async () => {
    const calls = [];
    let locked = false;
    let ended = false;
    let attempts = 0;
    const client = {
      connect: async () => { calls.push("connect"); },
      query: async sql => {
        calls.push(sql);
        if (sql.includes("pg_advisory_lock")) locked = true;
        if (sql.includes("pg_advisory_unlock")) locked = false;
        return { rows: [] };
      },
      end: async () => { ended = true; calls.push("end"); },
    };
    const sleeps = [];
    const code = await executeBootstrapGuard(client, {
      waitForRuntimeRole: false,
      roleWaitSeconds: 10,
      rolePollSeconds: 1,
      maxAttempts: 3,
      delaySeconds: 2,
      runBootstrap: async () => {
        assert.equal(locked, true);
        attempts += 1;
        return attempts === 1
          ? { code: 1, output: 'XX000: tuple concurrently updated' }
          : { code: 0, output: "" };
      },
      sleep: async milliseconds => { sleeps.push(milliseconds); },
      now: () => 0,
      log: message => calls.push(message),
    });
    assert.equal(code, 0);
    assert.equal(attempts, 2);
    assert.deepEqual(sleeps, [2000]);
    assert.equal(locked, false);
    assert.equal(ended, true);
    assert.ok(calls.some(call => String(call).includes("pg_advisory_unlock")));
  });

  test("closes the owner connection when the post wait expires before locking", async () => {
    let ended = false;
    const client = {
      connect: async () => {},
      query: async sql => {
        assert.doesNotMatch(sql, /pg_advisory_lock/u);
        return { rows: [{ ready: false }] };
      },
      end: async () => { ended = true; },
    };
    let clock = 0;
    await assert.rejects(executeBootstrapGuard(client, {
      waitForRuntimeRole: true,
      roleWaitSeconds: 1,
      rolePollSeconds: 1,
      maxAttempts: 1,
      delaySeconds: 1,
      runBootstrap: async () => ({ code: 0, output: "" }),
      sleep: async milliseconds => { clock += milliseconds; },
      now: () => clock,
      log: () => {},
    }), /did not become LOGIN before the deadline/u);
    assert.equal(ended, true);
  });
});

describe("managed-RDS post ordering", () => {
  test("waits until rds-setup post activates the runtime login", async () => {
    const states = [false, false, true];
    const queries = [];
    const sleeps = [];
    await waitForRuntimeRoleActivation(
      { query: async (sql) => {
        queries.push(sql);
        return { rows: [{ ready: states.shift() ?? false }] };
      } },
      10,
      2,
      async milliseconds => { sleeps.push(milliseconds); },
      () => 0,
    );
    assert.equal(queries.length, 3);
    assert.match(queries[0], /rolname='search_consumer_runtime'/u);
    assert.deepEqual(sleeps, [2000, 2000]);
  });

  test("fails boundedly instead of holding a Job forever", async () => {
    let clock = 0;
    await assert.rejects(waitForRuntimeRoleActivation(
      { query: async () => ({ rows: [{ ready: false }] }) },
      3,
      2,
      async milliseconds => { clock += milliseconds; },
      () => clock,
    ), /did not become LOGIN before the deadline/u);
  });
});
