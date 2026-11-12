import { describe, expect, test } from "bun:test";
import {
  isRetryableCatalogRace,
  waitForRuntimeRoleActivation,
} from "../../charts/sessions-pipeline/files/search-indexer-bootstrap-guard.ts";

describe("search indexer bootstrap catalog retry", () => {
  test("accepts only the two observed XX000 catalog race signatures", () => {
    expect(isRetryableCatalogRace('error: tuple concurrently updated\n code: "XX000"')).toBe(true);
    expect(isRetryableCatalogRace("XX000: heapam simple_heap_update: concurrent catalog update")).toBe(true);
  });

  test("does not retry generic internal or non-catalog failures", () => {
    expect(isRetryableCatalogRace("XX000: unrelated internal error")).toBe(false);
    expect(isRetryableCatalogRace("tuple concurrently updated")).toBe(false);
    expect(isRetryableCatalogRace("42501: permission denied")).toBe(false);
  });
});

describe("managed-RDS post ordering", () => {
  test("waits until rds-setup post activates the runtime login", async () => {
    const states = [false, false, true];
    const queries: string[] = [];
    const sleeps: number[] = [];
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
    expect(queries).toHaveLength(3);
    expect(queries[0]).toContain("rolname='search_consumer_runtime'");
    expect(sleeps).toEqual([2000, 2000]);
  });

  test("fails boundedly instead of holding a Job forever", async () => {
    let clock = 0;
    await expect(waitForRuntimeRoleActivation(
      { query: async () => ({ rows: [{ ready: false }] }) },
      3,
      2,
      async milliseconds => { clock += milliseconds; },
      () => clock,
    )).rejects.toThrow("did not become LOGIN before the deadline");
  });
});
