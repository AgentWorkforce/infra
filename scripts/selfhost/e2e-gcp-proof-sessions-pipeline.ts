// Sessions Pipeline probe for e2e-gcp-proof.sh.
//
// Runs inside the existing bulls96-alleyoop-ingest pod (default-deny
// namespace; this pod already reaches HoopDb, the Locker bucket and its own
// ingest on loopback) with the image's own code:
//
//   bun run e2e-gcp-proof-sessions-pipeline.ts push   <marker> <machineId>  < assertion
//   bun run e2e-gcp-proof-sessions-pipeline.ts verify <marker> <sessionId> [timeoutSec]
//   bun run e2e-gcp-proof-sessions-pipeline.ts verify-offline <marker> <sessionId> [timeoutSec]
// Both verify modes require E2E_PIPELINE_USER_ID; verify-offline also requires
// exact WORKSPACE_ID and
// excludes only model summary stages/objects; other stage errors still fail.
//
// `push` writes one marked Claude transcript and a minimal Concourse catalogue
// under /tmp, then runs one real courier pass (src/alleyoop/courier.ts) against
// the ingest on 127.0.0.1 with the origin-bound RelayAuth assertion read from
// stdin. `verify` polls HoopDb and the Locker until the workers have processed
// it. Output is PROOF lines with non-secret identifiers only; the assertion,
// HOOPDB_URL and transcript text are never printed.

import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { pathToFileURL } from "node:url";
import { zstdDecompressSync } from "node:zlib";

const [mode, marker, arg3, arg4] = process.argv.slice(2);
const ORG = process.env.TENANT_ORG_ID ?? "";
const proof = (result: string, check: string, detail: string) =>
  console.log(`PROOF|${result}|${check}|${detail.replace(/[|\n\r]/g, " ")}`);

// Shape-only fake (AWS's documented example key). Technical Foul must scrub it
// before storage; the marker itself must survive.
const FAKE_SECRET = "AKIAIOSFODNN7EXAMPLE";

function transcript(sessionId: string, cwd: string, at: Date): string {
  const t = (s: number) => new Date(at.getTime() + s * 1000).toISOString();
  const lines = [
    { type: "permission-mode", permissionMode: "default", sessionId },
    { parentUuid: null, isSidechain: false, promptId: "p-1", type: "user", message: { role: "user", content: `E2E ${marker}: summarise the deploy checklist. AWS_ACCESS_KEY_ID=${FAKE_SECRET}` }, uuid: "u-user-1", timestamp: t(0), cwd, sessionId, version: "2.1.96" },
    { parentUuid: "u-user-1", isSidechain: false, message: { model: "claude-sonnet-4-6", id: `msg_${marker}_1`, type: "message", role: "assistant", content: [{ type: "text", text: `Checklist for ${marker} reviewed.` }, { type: "tool_use", id: "tu_1", name: "Bash", input: { command: "echo ok" } }], stop_reason: "tool_use", stop_sequence: null, usage: { input_tokens: 120, output_tokens: 40 } }, uuid: "u-asst-1", timestamp: t(5), cwd, sessionId, type: "assistant", version: "2.1.96" },
    { parentUuid: "u-asst-1", isSidechain: false, type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "tu_1", content: "ok" }] }, uuid: "u-user-2", timestamp: t(6), cwd, sessionId, version: "2.1.96" },
    { parentUuid: "u-user-2", isSidechain: false, message: { model: "claude-sonnet-4-6", id: `msg_${marker}_2`, type: "message", role: "assistant", content: [{ type: "text", text: "Done." }], stop_reason: "end_turn", stop_sequence: null, usage: { input_tokens: 200, output_tokens: 12 } }, uuid: "u-asst-2", timestamp: t(9), cwd, sessionId, type: "assistant", version: "2.1.96" },
  ];
  return lines.map((l) => JSON.stringify(l)).join("\n") + "\n";
}

async function push() {
  const machineId = arg3!;
  const token = (await new Response(Bun.stdin.stream()).text()).trim();
  if (!token) throw new Error("no assertion on stdin");
  const dir = `/tmp/e2e-${marker}`;
  await rm(dir, { recursive: true, force: true });
  const cwd = "/workspace/e2e";
  const project = join(dir, "home/.claude/projects/-workspace-e2e");
  await mkdir(project, { recursive: true });
  const sessionId = randomUUID();
  const rawPath = join(project, `${sessionId}.jsonl`);
  const at = new Date(Date.now() - 5 * 60_000);
  await writeFile(rawPath, transcript(sessionId, cwd, at));

  // The courier reads only these columns of Concourse's `sessions` table.
  const dbPath = join(dir, "history.db");
  const { DatabaseSync } = await import("node:sqlite");
  const db = new DatabaseSync(dbPath);
  db.exec("CREATE TABLE sessions (session_id TEXT, source TEXT, raw_path TEXT, first_activity_ms INTEGER, last_activity_ms INTEGER, cwd TEXT, agent_version TEXT)");
  db.prepare("INSERT INTO sessions VALUES (?, 'claude', ?, ?, ?, ?, '2.1.96')").run(sessionId, rawPath, at.getTime(), at.getTime() + 9000, cwd);
  db.close();

  Object.assign(process.env, {
    CONCOURSE_DB: dbPath,
    COURIER_STATE: join(dir, "courier-state.json"),
    INGEST_URL: `http://127.0.0.1:${process.env.INGEST_PORT ?? "8080"}`,
    USER_ID: process.env.E2E_PIPELINE_USER_ID || `e2e-${marker}`,
    MACHINE_ID: machineId,
    COURIER_START_MODE: "all",
    COURIER_CLOSE_AFTER_MINUTES: "0",
    COURIER_ALLOW_FIXED_TOKEN: "1",
    ALLEYOOP_TOKEN: token,
    OTEL_SERVICE_NAME: "alleyoop-courier",
  });
  const courier = await import("/app/src/alleyoop/courier.ts");
  const result = await courier.runCourierOnce(courier.configFromEnv());
  delete process.env.ALLEYOOP_TOKEN;
  const ok = result.uploaded >= 1 && result.chunks >= 1;
  proof(ok ? "PASS" : "FAIL", "pipeline.courier_push", `session=${sessionId} machine=${machineId} sessions=${result.sessions} uploaded=${result.uploaded} chunks=${result.chunks}`);
  await rm(dir, { recursive: true, force: true });
  console.log(`SESSION_ID=${sessionId}`);
  if (!ok) process.exitCode = 1;
}

export async function verify(summariesRequired = true, dependencies?: any) {
  const sessionId = arg3!;
  const deadline = Date.now() + Number(arg4 ?? "300") * 1000;
  const { openHoopDb } = dependencies ?? await import("/app/src/shared/db.ts");
  const { lockerStore } = dependencies ?? await import("/app/src/shared/locker.ts");
  const { objectKey, readAll } = dependencies ?? await import("/app/src/shared/vendor.ts");
  let db: ReturnType<typeof openHoopDb> | undefined;
  let failed = 0;
  const check = (ok: boolean, name: string, detail: string) => {
    proof(ok ? "PASS" : "FAIL", name, detail);
    if (!ok) failed += 1;
  };
  try {
    if (!ORG || !marker || !sessionId || (!summariesRequired && !process.env.WORKSPACE_ID))
      throw new Error("missing exact tenant/session identity");
    db = openHoopDb();
    // `kinds` is "long:<status>,short:<status>" (string_agg of kind:status).
    const summaryStatus = (kinds: string | null, kind: string) =>
      (kinds ?? "").split(",").find((entry) => entry.startsWith(`${kind}:`))?.slice(kind.length + 1);
    type Row = { state: string; manifest_key: string; kinds: string | null; su: string | null; trace: string | null; index_user: string; derived_user: string };
    let row: Row | undefined;
    while (Date.now() < deadline) {
      const { rows } = await db.query<Row>(
        `SELECT i.state, i.manifest_key, i.user_id AS index_user,
                (SELECT user_id FROM sessions.session_index_ext e WHERE e.org_id=i.org_id AND e.workspace_id=i.workspace_id AND e.harness=i.harness AND e.session_id=i.session_id AND e.machine_id=i.machine_id) AS derived_user,
                (SELECT string_agg(kind || ':' || status, ',' ORDER BY kind) FROM sessions.session_summaries s
                  WHERE s.org_id=i.org_id AND s.workspace_id=i.workspace_id AND s.harness=i.harness AND s.session_id=i.session_id AND s.machine_id=i.machine_id) AS kinds,
                (SELECT session_uuid::text FROM sessions.session_index_ext e
                  WHERE e.org_id=i.org_id AND e.workspace_id=i.workspace_id AND e.harness=i.harness AND e.session_id=i.session_id AND e.machine_id=i.machine_id) AS su,
                (SELECT last_trace_id::text FROM sessions.session_index_ext e
                  WHERE e.org_id=i.org_id AND e.workspace_id=i.workspace_id AND e.harness=i.harness AND e.session_id=i.session_id AND e.machine_id=i.machine_id) AS trace
           FROM sessions.session_index i WHERE i.org_id = $1 AND i.session_id = $2 AND ($3::text IS NULL OR i.workspace_id::text=$3::text)`,
        [ORG, sessionId, process.env.WORKSPACE_ID || null],
      );
      row = rows[0];
      // Every summary status (ready, disabled, quarantined, empty, unsupported)
      // is terminal, so stop once both kinds exist and the referee has
      // classified the session; whether they succeeded is checked below.
      if (row && row.state !== "unknown" && row.su && (!summariesRequired || (summaryStatus(row.kinds, "long") && summaryStatus(row.kinds, "short")))) break;
      await new Promise((r) => setTimeout(r, 5000));
    }
    check(!!row?.su, "pipeline.hoopdb_indexer", `session=${sessionId} session_uuid=${row?.su ?? "none"} trace=${row?.trace ?? "none"}`);
    if (!row?.su) return;
    check(!!process.env.E2E_PIPELINE_USER_ID && row.index_user === process.env.E2E_PIPELINE_USER_ID
      && row.derived_user === process.env.E2E_PIPELINE_USER_ID, "pipeline.owner_attribution", "ingest and derived index match the real signed-in owner");
    check(["active", "done", "abandoned"].includes(row.state), "pipeline.referee_state", `state=${row.state}`);
    const verdicts = await db.query<{ state: string; rule: string }>(
      "SELECT state, rule FROM sessions.session_verdicts WHERE session_uuid = $1::uuid ORDER BY revision DESC, classified_at DESC, id DESC", [row.su]);
    // The latest verdict is a successful classification only when it names a
    // real lifecycle state; `unknown` is the referee's could-not-classify result.
    check(["active", "done", "abandoned"].includes(verdicts.rows[0]?.state ?? ""), "pipeline.referee_verdict", `verdicts=${verdicts.rows.length} ${verdicts.rows[0] ? `${verdicts.rows[0].state}/${verdicts.rows[0].rule}` : ""}`);
    // Bob Costas succeeded only when both summaries are `ready` (a pointer to
    // an encrypted Locker object); disabled/quarantined/empty/unsupported are
    // terminal non-success outcomes.
    if (summariesRequired) check(summaryStatus(row.kinds, "long") === "ready" && summaryStatus(row.kinds, "short") === "ready",
      "pipeline.bob_costas_summaries", `summaries=${row.kinds ?? "none"}`);
    check(!!row.trace, "pipeline.trace", "indexed session has a non-null processing trace");
    if (!row.trace) return;
    const events = await db.query<{ stage: string; status: string }>(
      "SELECT DISTINCT stage, status FROM sessions.pipeline_events WHERE org_id = $1 AND trace_id = $2::uuid ORDER BY stage", [ORG, row.trace]);
    const ok = events.rows.filter((e) => e.status === "ok").map((e) => e.stage);
    const requiredStages = ["object-landed", "session-indexed", "status-classify", ...(summariesRequired ? ["summary-short", "summary-long"] : [])];
    check(requiredStages.every((s) => ok.includes(s)) && !events.rows.some(e => e.status !== "ok" && (summariesRequired || !["summary-short", "summary-long"].includes(e.stage))), "pipeline.events", `ok_stages=${ok.join(",")} other=${events.rows.filter((e) => e.status !== "ok").map((e) => `${e.stage}:${e.status}`).join(",") || "none"}`);
    const dlq = await db.query<{ c: string }>(
      "SELECT count(*)::text AS c FROM sessions.pipeline_dead_letters WHERE org_id = $1 AND trace_id = $2::uuid", [ORG, row.trace]).catch(() => ({ rows: [{ c: "n/a" }] }));
    check(dlq.rows[0]?.c === "0", "pipeline.no_dead_letters", `dead_letters_for_trace=${dlq.rows[0]?.c}`);

    const raw = lockerStore();
    const prefix = row.manifest_key.replace(/\/manifest\.json$/, "/raw");
    const listing = await raw.store.list(objectKey(prefix));
    let text = "";
    for (const obj of listing.items) text += zstdDecompressSync(Buffer.from(await readAll(await raw.store.get(obj.key)))).toString("utf8");
    const head = await raw.store.head(objectKey(row.manifest_key));
    const summaryObjects = await raw.store.list(objectKey(row.manifest_key.replace(/\/manifest\.json$/, "/summary")));
    check(listing.items.length > 0 && text.includes(marker!) && (!summariesRequired || summaryObjects.items.length >= 2) && head?.metadata?.["session-uuid"] === row.su, "pipeline.bucket_objects",
      `provider=${raw.provider} raw_chunks=${listing.items.length} summary_objects=${summaryObjects.items.length} manifest_meta_session_uuid_matches=${head?.metadata?.["session-uuid"] === row.su}`);
    check(listing.items.length > 0 && text.includes(marker!) && !text.includes(FAKE_SECRET), "pipeline.technical_foul_scrub", `raw_chunks=${listing.items.length} marker_present=${text.includes(marker!)} fake_secret_in_stored_chunks=${text.includes(FAKE_SECRET)}`);
    console.log(`TRACE_ID=${row.trace}`);
    console.log(`SESSION_UUID=${row.su}`);
  } finally {
    if (db) await db.end();
    if (failed) process.exitCode = 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
try {
  if (mode === "push") await push();
  else if (mode === "verify") await verify();
  else if (mode === "verify-offline") await verify(false);
  else throw new Error(`unknown mode ${mode}`);
} catch (error) {
  proof("FAIL", `pipeline.${mode}`, `error=${(error as Error).name || "Error"}`);
  process.exitCode = 1;
}
}
