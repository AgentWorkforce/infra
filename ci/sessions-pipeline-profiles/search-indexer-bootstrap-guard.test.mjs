import assert from "node:assert/strict";
import { describe, test } from "node:test";
import {
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
