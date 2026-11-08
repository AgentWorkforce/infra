import assert from "node:assert/strict";
import test from "node:test";
import { zstdCompressSync } from "node:zlib";
process.env.TENANT_ORG_ID = "org";
process.env.WORKSPACE_ID = "workspace";
process.env.E2E_PIPELINE_USER_ID = "owner";
process.argv = [process.argv[0], process.argv[1], "verify-offline", "marker", "session", "1"];
const { verify } = await import("../../../scripts/selfhost/e2e-gcp-proof-sessions-pipeline.ts");

async function run(options = {}, summaries = false) {
  const lines = [], queries = [];
  const row = { state: "done", su: "uuid", manifest_key: "sessions/manifest.json", trace: "trace",
    index_user: "owner", derived_user: "owner", kinds: "long:ready,short:ready", ...options.row };
  const db = { end: async () => {}, query: async (sql, params) => {
    queries.push({ sql, params });
    if (sql.includes("session_index i")) return { rows: [row] };
    if (sql.includes("session_verdicts")) return { rows: [{ state: "done" }] };
    if (sql.includes("pipeline_events")) return { rows: options.events ?? ["object-landed", "session-indexed", "status-classify"].map(stage => ({ stage, status: "ok" })) };
    if (sql.includes("pipeline_dead_letters")) return { rows: [{ c: "0" }] };
    throw new Error("unexpected query");
  }};
  const store = {
    list: async key => ({ items: key.endsWith("raw") && !options.empty ? [{ key: "chunk" }] : [] }),
    get: async () => zstdCompressSync(Buffer.from("transcript marker")),
    head: async () => ({ metadata: { "session-uuid": "uuid" } }),
  };
  const log = console.log;
  console.log = line => lines.push(line);
  try {
    await verify(summaries, { openHoopDb: () => db, lockerStore: () => ({ store, provider: "fixture" }),
      objectKey: value => value, readAll: async value => value });
    return { lines, queries, code: process.exitCode ?? 0 };
  } finally {
    console.log = log;
    process.exitCode = 0;
  }
}
test("offline verifier requires all non-model stages and exact workspace/owner", async () => {
  const result = await run();
  assert.equal(result.code, 0);
  assert.ok(result.lines.some(line => line.startsWith("PROOF|PASS|pipeline.events|")));
  assert.deepEqual(result.queries[0].params, ["org", "session", "workspace"]);
  assert.match(result.queries[0].sql, /i\.workspace_id::text=\$3::text/);
  for (const field of ["index_user", "derived_user"]) {
    const wrongOwner = await run({ row: { [field]: "other" } });
    assert.equal(wrongOwner.code, 1);
    assert.ok(wrongOwner.lines.some(line => line.startsWith("PROOF|FAIL|pipeline.owner_attribution|")));
  }
});
test("null trace cannot produce a dead-letter PASS", async () => {
  const result = await run({ row: { trace: null } });
  assert.equal(result.code, 1);
  assert.ok(result.lines.some(line => line.startsWith("PROOF|FAIL|pipeline.trace|")));
  assert.ok(!result.queries.some(query => query.sql.includes("pipeline_dead_letters")));
});
test("missing or failed non-summary processing events fail offline proof", async () => {
  for (const events of [[], [{ stage: "object-landed", status: "error" }],
    [...["object-landed", "session-indexed", "status-classify"].map(stage => ({ stage, status: "ok" })), { stage: "new-non-summary-stage", status: "error" }]]) {
    const result = await run({ events });
    assert.equal(result.code, 1);
    assert.ok(result.lines.some(line => line.startsWith("PROOF|FAIL|pipeline.events|")));
  }
  const requiredOk = ["object-landed", "session-indexed", "status-classify"].map(stage => ({ stage, status: "ok" }));
  const optional = { stage: "file-normalize", status: "skipped", reason: "not_enabled", has_error: false };
  assert.equal((await run({ events: [...requiredOk, optional] })).code, 0);
  for (const invalid of [{ ...optional, reason: "unknown" }, { ...optional, has_error: true },
                         { ...optional, status: "error" }, { ...optional, stage: "unknown-stage" }]) {
    assert.equal((await run({ events: [...requiredOk, invalid] })).code, 1);
  }
  const summariesOff = await run({ events: [
    ...["object-landed", "session-indexed", "status-classify"].map(stage => ({ stage, status: "ok" })),
    { stage: "summary-short", status: "disabled" }, { stage: "summary-long", status: "error" },
  ] });
  assert.equal(summariesOff.code, 0);
});
test("empty raw objects cannot pass the scrub check", async () => {
  const result = await run({ empty: true });
  assert.equal(result.code, 1);
  assert.ok(result.lines.some(line => line.startsWith("PROOF|FAIL|pipeline.technical_foul_scrub|")));
});
test("hosted verification still requires summary events and objects", async () => {
  const result = await run({}, true);
  assert.equal(result.code, 1);
  const notReady = await run({ row: { kinds: "long:disabled,short:ready" } }, true);
  assert.ok(notReady.lines.some(line => line.startsWith("PROOF|FAIL|pipeline.bob_costas_summaries|")));
  const wrongOwner = await run({ row: { index_user: "other" } }, true);
  assert.ok(wrongOwner.lines.some(line => line.startsWith("PROOF|FAIL|pipeline.owner_attribution|")));
  assert.ok(result.lines.some(line => line.startsWith("PROOF|FAIL|pipeline.events|")));
  assert.ok(result.lines.some(line => line.startsWith("PROOF|FAIL|pipeline.bucket_objects|")));
});
