// Init container of the search indexer: wait until the search bootstrap has
// provisioned what the indexer needs, instead of letting the indexer crash-loop
// with "permission denied for schema sessions" while the bootstrap Job runs
// (the same idea as relaycast's wait-for-migrations).
//
// Connects as the indexer's own runtime login (RELAYHISTORY_PIPELINE_CONSUMER_SECRET)
// and reads only the catalog, so it can't hit the permission error itself:
//   - USAGE on schema sessions, and SELECT/INSERT on sessions.search_consumer_pending
//     and sessions.search_consumer_progress (the bootstrap's service tables);
//   - USAGE on schema search_index, and search_index.transcript_events and
//     projection_state present (the index schema the bootstrap composes).
// Exits 0 when all hold; after SEARCH_BOOTSTRAP_WAIT_SECONDS, exits 1 naming what
// is missing and how to fix it. Never prints the URL or the password.

const REQUIREMENTS = `
WITH s AS (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'sessions'),
     i AS (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'search_index'),
     t AS (SELECT c.oid, n.nspname || '.' || c.relname AS name FROM pg_catalog.pg_class c
           JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
           WHERE (n.nspname, c.relname) IN (('sessions', 'search_consumer_pending'), ('sessions', 'search_consumer_progress'),
                                            ('search_index', 'transcript_events'), ('search_index', 'projection_state')))
SELECT
  COALESCE((SELECT pg_catalog.has_schema_privilege(current_user, oid, 'USAGE') FROM s), false) AS sessions_usage,
  COALESCE((SELECT pg_catalog.has_schema_privilege(current_user, oid, 'USAGE') FROM i), false) AS index_usage,
  ARRAY(SELECT name FROM t ORDER BY 1) AS present,
  ARRAY(SELECT name FROM t WHERE name LIKE 'sessions.%'
        -- A comma list means "any of"; each privilege is needed, so test them apart.
        AND NOT (pg_catalog.has_table_privilege(current_user, oid, 'SELECT')
                 AND pg_catalog.has_table_privilege(current_user, oid, 'INSERT')) ORDER BY 1) AS no_write`;

const TABLES = ["search_index.projection_state", "search_index.transcript_events",
  "sessions.search_consumer_pending", "sessions.search_consumer_progress"];

/** What is still missing, as short phrases; [] when the indexer can start. */
export function missing(row) {
  const out = [];
  if (!row.sessions_usage) out.push("USAGE on schema sessions");
  if (!row.index_usage) out.push("USAGE on schema search_index");
  for (const t of TABLES) if (!(row.present || []).includes(t)) out.push(`table ${t}`);
  for (const t of row.no_write || []) out.push(`SELECT/INSERT on ${t}`);
  return out;
}

export async function waitForBootstrap(query, { waitSeconds, pollSeconds, sleep, now, log }) {
  const deadline = now() + waitSeconds * 1000;
  let last = ["the database"];
  let announced = false;
  for (;;) {
    try {
      last = missing((await query(REQUIREMENTS)).rows[0] || {});
      if (last.length === 0) {
        log("search indexer: the search bootstrap has completed; starting");
        return 0;
      }
    } catch (e) {
      // Not reachable yet, or the login isn't active yet (rds-setup.sh post): keep waiting.
      last = [`a database connection (${String(e && (e.code || e.message) || e).slice(0, 80)})`];
    }
    if (!announced) {
      log(`search indexer: waiting for the search bootstrap (missing: ${last.join(", ")})`);
      announced = true;
    }
    if (now() + pollSeconds * 1000 > deadline) {
      const ns = process.env.POD_NAMESPACE || "<namespace>";
      log(`search indexer: the search bootstrap has not completed after ${waitSeconds}s (missing: ${last.join(", ")}). `
        + `Check the bootstrap Job: kubectl -n ${ns} get jobs | grep search-indexer-bootstrap; if it failed, read its log, `
        + "fix the cause (often OpenSearch reachability, or rds-setup.sh post not run yet), delete the Job and run helm upgrade again.");
      return 1;
    }
    await sleep(pollSeconds * 1000);
  }
}

async function main() {
  const waitSeconds = Number(process.env.SEARCH_BOOTSTRAP_WAIT_SECONDS || 1800);
  const pollSeconds = Number(process.env.SEARCH_BOOTSTRAP_WAIT_POLL_SECONDS || 5);
  let url;
  try {
    url = JSON.parse(process.env.RELAYHISTORY_PIPELINE_CONSUMER_SECRET || "").hoopdb_url;
    if (typeof url !== "string" || !url) throw new Error("missing");
  } catch {
    console.error("search indexer: RELAYHISTORY_PIPELINE_CONSUMER_SECRET must be JSON {\"hoopdb_url\":\"postgresql://...\"}");
    return 1;
  }
  const [{ default: pg }, tls] = await Promise.all([import("pg"), import("/app/src/shared/postgres-tls.ts")]);
  const query = async (sql) => {
    const client = new pg.Client({ connectionString: tls.postgresConnectionString(url), ssl: tls.postgresTlsOptions(),
      application_name: "search-indexer-bootstrap-wait", connectionTimeoutMillis: 10000,
      // A stalled session must not outlive waitSeconds: bound each catalog read too.
      query_timeout: 15000, statement_timeout: 10000 });
    client.on("error", () => {});
    await client.connect();
    try { return await client.query(sql); } finally { await client.end().catch(() => {}); }
  };
  return waitForBootstrap(query, { waitSeconds, pollSeconds, sleep: (ms) => Bun.sleep(ms), now: Date.now,
    log: (m) => console.error(m) });
}

if (import.meta.main) process.exitCode = await main();
