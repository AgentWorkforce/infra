// Offline verification after the shared courier fixture uploads a transcript.
// Model summaries and their objects are deliberately outside this contract:
// the kind profile runs BOB_COSTAS_MODEL=off and has no external egress.
import { zstdDecompressSync } from "node:zlib";
import { openHoopDb } from "/app/src/shared/db.ts";
import { lockerStore } from "/app/src/shared/locker.ts";
import { objectKey, readAll } from "/app/src/shared/vendor.ts";

const [marker, sessionId] = process.argv.slice(2);
const org = process.env.TENANT_ORG_ID;
const workspace = process.env.WORKSPACE_ID;
const db = openHoopDb();
let failed = false;
function check(ok: boolean, name: string, detail: string) {
  console.log(`PROOF|${ok ? "PASS" : "FAIL"}|pipeline.${name}|${detail.replace(/[|\n\r]/g, " ")}`);
  if (!ok) failed = true;
}
try {
  if (!org || !workspace || !marker || !sessionId) throw new Error("missing exact tenant/session identity");
  const deadline = Date.now() + 180_000;
  let row: { manifest_key: string; state: string; session_uuid: string; last_trace_id: string; index_user: string; derived_user: string } | undefined;
  while (Date.now() < deadline) {
    const { rows } = await db.query(
      `SELECT i.manifest_key,i.state,e.session_uuid,e.last_trace_id,i.user_id AS index_user,e.user_id AS derived_user
         FROM sessions.session_index i JOIN sessions.session_index_ext e
           USING (org_id,workspace_id,harness,session_id,machine_id)
        WHERE i.org_id=$1 AND i.workspace_id=$2 AND i.session_id=$3`, [org, workspace, sessionId]);
    row = rows[0];
    if (row?.session_uuid && ["active", "done", "abandoned"].includes(row.state)) break;
    await new Promise(r => setTimeout(r, 2000));
  }
  check(!!row?.session_uuid, "hoopdb_indexer", `session=${sessionId} indexed=${!!row?.session_uuid}`);
  if (row?.session_uuid) {
    check(!!process.env.E2E_PIPELINE_USER_ID && row.index_user === process.env.E2E_PIPELINE_USER_ID
          && row.derived_user === process.env.E2E_PIPELINE_USER_ID, "owner_attribution", "ingest and derived index match the real signed-in owner");
    check(["active", "done", "abandoned"].includes(row.state), "referee_state", `state=${row.state}`);
    const verdict = await db.query(
      "SELECT state FROM sessions.session_verdicts WHERE session_uuid=$1::uuid ORDER BY revision DESC,classified_at DESC,id DESC LIMIT 1", [row.session_uuid]);
    check(["active", "done", "abandoned"].includes(verdict.rows[0]?.state), "referee_verdict", `state=${verdict.rows[0]?.state}`);
    const dead = await db.query(
      "SELECT count(*)::int AS count FROM sessions.pipeline_dead_letters WHERE org_id=$1 AND trace_id=$2::uuid", [org, row.last_trace_id]);
    check(dead.rows[0]?.count === 0, "no_dead_letters", `count=${dead.rows[0]?.count}`);
    const locker = lockerStore();
    const objects = await locker.store.list(objectKey(row.manifest_key.replace(/\/manifest\.json$/, "/raw")));
    let transcript = "";
    for (const obj of objects.items) {
      transcript += zstdDecompressSync(Buffer.from(await readAll(await locker.store.get(obj.key)))).toString("utf8");
    }
    const head = await locker.store.head(objectKey(row.manifest_key));
    check(objects.items.length > 0 && transcript.includes(marker) && head?.metadata?.["session-uuid"] === row.session_uuid,
      "bucket_objects", `raw_chunks=${objects.items.length} marker_present=${transcript.includes(marker)} metadata_matches=${head?.metadata?.["session-uuid"] === row.session_uuid}`);
    check(!transcript.includes("AKIAIOSFODNN7EXAMPLE"), "technical_foul_scrub", "example secret absent from stored chunks");
  }
} catch {
  // Never print a DB URL or transcript in proof output.
  check(false, "offline_readback", "database/object verification failed");
} finally {
  await db.end();
  if (failed) process.exitCode = 1;
}
