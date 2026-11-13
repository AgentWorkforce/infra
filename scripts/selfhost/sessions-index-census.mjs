// Read-only census of the Sessions (HoopDb) adopt-or-create index steps, for
// scripts/selfhost/agent-relay-upgrade.sh. It runs inside a one-off pod cloned
// from the deployed hoopdb-migrate Job (same image, HOOPDB_URL Secret, CA and
// ServiceAccount), so it connects exactly as the migrator does. It never writes:
// one READ ONLY transaction, a 30 s statement timeout and a 5 s lock timeout.
//
// For every step below that the migration ledger has not recorded, and each
// index it declares, it reports the index state (adoptable, not_ready, mismatch
// or absent) and, for an absent index, the size of its table: the planner's
// estimate (pg_class.reltuples) and, when that is small or unknown, an exact
// count bounded at limit+1 rows with row_security off (an error, never a
// smaller number, if row-level security applies to this role).
//
// Output: one line "INDEX_CENSUS <json>" on success; "INDEX_CENSUS_ERROR <code>
// <message>" and exit 1 otherwise. No connection string is printed.
//
// STEPS mirrors ADOPTABLE_INDEXES in the Sessions source
// (src/hoopdb/migration-sentinels.ts) for the Sessions image this infra release
// pins, byte for byte. If it falls behind, the migrator's own read-only
// preflight still refuses a populated table before any write.
import { createRequire } from "node:module";

export const STEPS = [
  {
    step: "upstream:20261105044020_claim_bootstrap_org_indexes.sql",
    packet: "docs/packets/claim-bootstrap-org-index-packet-20261108.md",
    indexes: [
      ["ingest_history_mask_pages_org_id_idx", "ingest_history_mask_pages", "btree (org_id)"],
      ["ingest_history_plans_org_id_idx", "ingest_history_plans", "btree (org_id, workspace_id, user_id)"],
      ["ingest_seed_captures_org_id_idx", "ingest_seed_captures", "btree (org_id)"],
      ["ingest_publication_attempts_org_id_idx", "ingest_publication_attempts", "btree (org_id, workspace_id, user_id)"],
      ["ingest_publication_generations_org_id_idx", "ingest_publication_generations", "btree (org_id, workspace_id, user_id)"],
      ["ingest_stage_intents_org_id_idx", "ingest_stage_intents", "btree (org_id, workspace_id, user_id)"],
      ["ingest_custody_records_org_id_idx", "ingest_custody_records", "btree (org_id, workspace_id, user_id)"],
      ["ingest_lazy_native_slots_org_id_idx", "ingest_lazy_native_slots", "btree (org_id)"],
    ],
  },
  {
    step: "upstream:20261105044040_buffered_stages_session_first.sql",
    packet: "docs/handoffs/buffered-stages-session-first-044040/operator-packet.md",
    indexes: [
      ["ingest_claim_attempts_records_gin_idx", "ingest_claim_attempts", "gin (records jsonb_path_ops)"],
    ],
  },
  {
    step: "upstream:20261105047000_coordination_fact_readers.sql",
    packet: "see the Sessions runbook (out-of-band index prebuild)",
    indexes: [
      ["session_event_facts_coordination_writes_idx", "session_event_facts",
        "btree (org_id, workspace_id, ts, row_id) WHERE (cardinality(files_touched) > 0)"],
      ["session_output_facts_coordination_outcomes_idx", "session_output_facts",
        "btree (org_id, workspace_id, ts, row_id) WHERE (fact_kind = ANY (ARRAY['commit'::text, 'outcome'::text]))"],
    ],
  },
  {
    step: "upstream:20261105058000_operator_user_erase_indexes.sql",
    packet: "docs/packets/operator-user-erase-index-packet.md",
    indexes: [
      ["ingest_receipt_ord_seats_key_sha256_idx", "ingest_receipt_ord_seats", "btree (key_sha256)"],
      ["ingest_receipt_record_heads_winner_key_sha256_idx", "ingest_receipt_record_heads", "btree (winner_key_sha256)"],
      ["ingest_lazy_native_slots_current_seat_key_idx", "ingest_lazy_native_slots", "btree (current_seat_key)"],
      ["ingest_lazy_ack_decisions_native_key_sha256_idx", "ingest_lazy_ack_decisions", "btree (native_key_sha256)"],
      ["ingest_lazy_ack_decisions_seat_key_sha256_idx", "ingest_lazy_ack_decisions", "btree (seat_key_sha256)"],
      ["ingest_stage_intents_parent_stage_token_idx", "ingest_stage_intents",
        "btree (parent_stage_token) WHERE (parent_stage_token IS NOT NULL)"],
      ["ingest_stage_intents_gc_replacement_stage_token_idx", "ingest_stage_intents",
        "btree (gc_replacement_stage_token) WHERE (gc_replacement_stage_token IS NOT NULL)"],
      ["ingest_stage_intents_batch_idx", "ingest_stage_intents", "btree (org_id, workspace_id, origin_id, batch_id)"],
      ["ingest_buffer_outbox_active_stage_token_idx", "ingest_buffer_outbox",
        "btree (active_stage_token) WHERE (active_stage_token IS NOT NULL)"],
      ["ingest_history_plans_stage_token_idx", "ingest_history_plans", "btree (stage_token)"],
      ["ingest_lazy_native_slots_unowned_origin_idx", "ingest_lazy_native_slots",
        "btree (org_id, workspace_id, origin_id) WHERE (current_owner IS NULL)"],
      ["ingest_receipt_seats_key_material_user_idx", "ingest_receipt_seats",
        "btree (((key_material ->> 3)), ((key_material ->> 4)), ((key_material ->> 5)))"],
      ["ingest_receipt_seats_key_material_origin_idx", "ingest_receipt_seats",
        "btree (((key_material ->> 3)), ((key_material ->> 4)), ((key_material ->> 6)))"],
      ["ingest_receipt_record_heads_key_material_user_idx", "ingest_receipt_record_heads",
        "btree (((key_material ->> 3)), ((key_material ->> 4)), ((key_material ->> 5)))"],
      ["ingest_receipt_record_heads_key_material_origin_idx", "ingest_receipt_record_heads",
        "btree (((key_material ->> 3)), ((key_material ->> 4)), ((key_material ->> 6)))"],
      ["ingest_receipt_ord_seats_candidate_key_idx", "ingest_receipt_ord_seats", "btree (candidate_key_sha256)"],
    ],
  },
];

/** The exact pg_get_indexdef the migration expects for an index. */
export const expectedDef = (name, table, body) =>
  `CREATE INDEX ${name} ON sessions.${table} USING ${body}`;

const IDENT = /^[a-z_][a-z0-9_]*$/;

export async function census(client, limit) {
  const q = async (text, params) => (await client.query(text, params)).rows;
  await client.query("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY");
  try {
    await client.query("SET LOCAL statement_timeout = '30s'");
    await client.query("SET LOCAL lock_timeout = '5s'");
    const [{ schema }] = await q("SELECT to_regnamespace('sessions') IS NOT NULL AS schema");
    const [{ ledger }] = await q("SELECT to_regclass('sessions.__96bulls_migrations') IS NOT NULL AS ledger");
    if (!schema || !ledger) throw Object.assign(new Error("no sessions migration ledger in this database"), { code: "no_ledger" });
    const applied = new Set(
      (await q("SELECT name FROM sessions.__96bulls_migrations WHERE name = ANY($1)", [STEPS.map((s) => s.step)])).map((r) => r.name),
    );
    const tables = new Map();
    const steps = [];
    for (const s of STEPS) {
      const step = { step: s.step, packet: s.packet, applied: applied.has(s.step), indexes: [] };
      steps.push(step);
      if (step.applied) continue;
      for (const [name, table, body] of s.indexes) {
        if (!IDENT.test(name) || !IDENT.test(table)) throw new Error(`unexpected identifier ${name} ${table}`);
        const [{ table_exists }] = await q("SELECT to_regclass($1) IS NOT NULL AS table_exists", [`sessions.${table}`]);
        const rels = await q(
          `SELECT c.relkind, i.indrelid = to_regclass($2) AS on_table, i.indisvalid, i.indisready, i.indislive,
                  pg_get_indexdef(c.oid) AS def,
                  EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = c.oid) AS backs_constraint
             FROM pg_class c LEFT JOIN pg_index i ON i.indexrelid = c.oid
            WHERE c.relnamespace = 'sessions'::regnamespace AND c.relname = $1`,
          [name, `sessions.${table}`],
        );
        let state = "absent";
        if (rels.length) {
          const r = rels[0];
          if (r.relkind !== "i" || !r.on_table || r.backs_constraint || r.def !== expectedDef(name, table, body)) state = "mismatch";
          else if (!(r.indisvalid && r.indisready && r.indislive)) state = "not_ready";
          else state = "adoptable";
        }
        step.indexes.push({ name, table: `sessions.${table}`, state, table_exists });
        if (state === "absent" && table_exists) tables.set(table, null);
      }
    }
    for (const table of tables.keys()) {
      const [{ estimate }] = await q("SELECT c.reltuples::bigint AS estimate FROM pg_class c WHERE c.oid = to_regclass($1)", [`sessions.${table}`]);
      const est = Number(estimate);
      const t = { estimate: est, rows: est, exact: false };
      // An unknown (-1, never analyzed) or small estimate gets an exact count, bounded at limit+1.
      if (est < 0 || est <= 2 * limit) {
        await client.query("SET LOCAL row_security = off");
        const [{ n }] = await q(`SELECT count(*)::bigint AS n FROM (SELECT 1 FROM sessions.${table} LIMIT $1) s`, [limit + 1]);
        t.rows = Number(n);
        t.exact = t.rows <= limit;
      }
      tables.set(table, t);
    }
    for (const step of steps)
      for (const x of step.indexes) {
        const t = tables.get(x.table.slice("sessions.".length));
        if (x.state === "absent" && x.table_exists && t) Object.assign(x, { rows: t.rows, exact: t.exact, estimate: t.estimate });
      }
    return { limit, steps };
  } finally {
    await client.query("ROLLBACK").catch(() => {});
  }
}

if (import.meta.main ?? process.argv[1]?.endsWith("sessions-index-census.mjs")) {
  const limit = Number(process.env.INDEX_CENSUS_LIMIT || "1000000");
  // The Sessions image keeps its dependencies under /app (WORKDIR); resolve pg there.
  const pg = createRequire(process.env.INDEX_CENSUS_REQUIRE_FROM || "/app/package.json")("pg");
  const client = new pg.Client({ connectionString: process.env.HOOPDB_URL, application_name: "agent-relay-upgrade-index-census" });
  try {
    if (!Number.isSafeInteger(limit) || limit < 0) throw Object.assign(new Error("INDEX_CENSUS_LIMIT must be a non-negative integer"), { code: "bad_limit" });
    if (!process.env.HOOPDB_URL) throw Object.assign(new Error("HOOPDB_URL is not set"), { code: "no_url" });
    await client.connect();
    console.log(`INDEX_CENSUS ${JSON.stringify(await census(client, limit))}`);
    await client.end();
  } catch (e) {
    const msg = String(e?.message ?? e).replace(/postgres(ql)?:\/\/\S+/gi, "<url>").slice(0, 300);
    console.log(`INDEX_CENSUS_ERROR ${e?.code ?? "error"} ${msg}`);
    await client.end().catch(() => {});
    process.exit(1);
  }
}
