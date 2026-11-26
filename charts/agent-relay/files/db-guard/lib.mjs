// Agent Relay database checks shared by the databaseGuard hook (check.mjs)
// and helm test (status.mjs).
//
// Runs as a Helm pre-install/pre-upgrade hook in the relaycast-self-host
// image, mounted under /opt/relaycast so `@relaycast/engine` resolves from the
// image's own node_modules. The identity rules are relaycast's verifyIdentity
// (packages/engine/src/adapters/postgres/identity.ts): the single source of
// truth. Relaycast's own logins get every check in their mode (owner or
// runtime); every other service's login gets the checks that hold for any
// service login, whatever its database:
//   session_user, current_user, login, not_superuser, not_createrole,
//   not_createdb, not_replication, not_bypassrls, no_privileged_memberships
// TLS uses relaycast's postgresTlsOptions (verify-full against each
// component's own CA).
//
// Read-only: one connection per URL, catalog queries only. Prints one line
// per URL, then the problems; exits 1 when any URL fails. Never prints a URL
// or password.
//
// Input: $DB_GUARD_TARGETS (JSON file written by the chart), the Secrets
// mounted at /db-guard/secrets/<secret>/<key>, and each target's CA at its caFile.
import { readFileSync, existsSync } from "node:fs";
import pg from "pg";
import {
  postgresTlsOptions,
  verifyIdentity,
} from "@relaycast/engine/adapters/postgres";

const SERVICE_CHECKS = new Set([
  "session_user",
  "current_user",
  "login",
  "not_superuser",
  "not_createrole",
  "not_createdb",
  "not_replication",
  "not_bypassrls",
  "no_privileged_memberships",
]);
const MASTER_CHECKS = new Set([
  "not_superuser",
  "not_createrole",
  "not_createdb",
  "not_replication",
  "not_bypassrls",
  "no_privileged_memberships",
]);
export const POINTER =
  "Run scripts/selfhost/configure-rds.sh, which creates the logins and writes these Secrets, " +
  "or see docs/self-hosted-rds-manual-setup.md §1.3 " +
  "(https://agentrelay.com/docs/self-hosting/troubleshooting#database-logins).";
const SESSIONS_READERS = new Set(["HoopDb runtime", "read API", "ingest edge", "search indexer runtime"]);
const RELAYCAST_ROLES = { owner: "relaycast_owner", runtime: "relaycast_runtime" };

const env = process.env;
export const targets = JSON.parse(readFileSync(env.DB_GUARD_TARGETS, "utf8"));
const masters = new Set(
  JSON.parse(env.DB_GUARD_MASTER_LOGINS || "[]").map((m) => String(m).toLowerCase()),
);
const secretsDir = env.DB_GUARD_SECRETS_DIR || "/db-guard/secrets";
const connectTimeoutMs = Number(env.DB_GUARD_CONNECT_TIMEOUT_MS || 10000);
const sslmodeOverride = env.DB_GUARD_SSLMODE; // tests only: "disable"

// Each target's CA is the one its own component verifies with (t.caFile);
// DB_GUARD_CA is a fallback for callers that pass one bundle.
const caCache = new Map();
export function caFor(t) {
  const file = t.caFile || env.DB_GUARD_CA;
  if (!file) return null;
  if (!caCache.has(file)) caCache.set(file, existsSync(file) ? readFileSync(file, "utf8") : null);
  return caCache.get(file);
}

/** URL from the mounted Secret value, or a problem string. */
function readUrl(t) {
  const file = `${secretsDir}/${t.secret}/${t.key}`;
  if (!existsSync(file)) {
    return { skip: t.external, problem: `Secret ${t.secret} or its key ${t.key} does not exist` };
  }
  const raw = readFileSync(file, "utf8").trim();
  if (t.format === "json") {
    if (/^postgres(ql)?:\/\//.test(raw)) {
      return { problem: `holds a bare URL; it must be JSON {"${t.field}":"postgresql://..."}` };
    }
    try {
      const obj = JSON.parse(raw);
      if (typeof obj?.[t.field] !== "string") throw new Error();
      return { url: obj[t.field].trim() };
    } catch {
      return { problem: `is not JSON with a "${t.field}" field` };
    }
  }
  if (raw.startsWith("{")) return { problem: "holds JSON; it must be a bare postgresql:// URL" };
  return { url: raw };
}

function parse(url) {
  let u;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  if (!/^postgres(ql)?:$/.test(u.protocol) || !u.hostname || !u.username) return null;
  return {
    host: u.hostname.replace(/^\[|\]$/g, ""),
    port: Number(u.port || 5432),
    database: decodeURIComponent(u.pathname.replace(/^\//, "")) || "postgres",
    user: decodeURIComponent(u.username),
    password: decodeURIComponent(u.password),
  };
}

/** Plain-language reason for a connection error (no URL or password). */
function connectProblem(err, c, t) {
  const code = err?.code;
  if (code === "28P01")
    return `login "${c.user}" was refused (password authentication failed): the login does not exist on ${c.host}, or its password differs from the Secret`;
  if (code === "28000" && /not permitted to log in/.test(err.message))
    return `login "${c.user}" exists but cannot log in (NOLOGIN)` +
      (t.activatedLater ? "; rds-setup.sh post activates it after the HoopDb migration" : "");
  if (code === "28000")
    return `login "${c.user}" was refused by the server (${err.message}); check pg_hba / RDS parameter rds.force_ssl and the login`;
  if (code === "3D000") return `database "${c.database}" does not exist on ${c.host}`;
  if (code === "42704" || /role .* does not exist/.test(err?.message ?? ""))
    return `role "${c.user}" does not exist: the database logins haven't been created`;
  if (["ENOTFOUND", "EAI_AGAIN"].includes(code)) return `host ${c.host} does not resolve from the cluster`;
  if (["ECONNREFUSED", "ETIMEDOUT", "EHOSTUNREACH", "ECONNRESET"].includes(code) || /timeout/i.test(err?.message ?? ""))
    return `cannot reach ${c.host}:${c.port} from the cluster (${code ?? err.message}); check the RDS security group and network policies`;
  if (/certificate|self[- ]signed|altname|CERT_/i.test(`${code} ${err?.message}`))
    return `TLS verification of ${c.host} failed (${code ?? err.message}); the CA bundle (${t.ca?.kind ?? ""} ${t.ca?.name ?? "unset"}) must be the bundle for this database, e.g. the RDS bundle for its region`;
  return `connection failed (${code ?? "error"}: ${err?.message ?? err})`;
}

async function checkTarget(t, opts = {}) {
  const label = `${t.secret}: ${t.key}`;
  const r = readUrl(t);
  if (r.problem) return r.skip ? { label, status: "skip", detail: `${r.problem} (managed by externalSecrets; checked next run)` } : { label, status: "FAIL", detail: r.problem };
  const c = parse(r.url);
  if (!c) return { label, status: "FAIL", detail: "is not a postgres:// URL with a host and a login" };
  if (masters.has(c.user.toLowerCase()) && !t.allowMaster) {
    return { label, status: "FAIL", login: c.user, detail: `logs in as "${c.user}" (a database master/administrator login). Each service needs its own login` };
  }
  const ca = caFor(t);
  if (!ca && sslmodeOverride !== "disable") {
    return { label, status: "skip", login: c.user, detail: `no CA bundle mounted (${t.ca?.kind ?? "CA"} ${t.ca?.name ?? "unset"}); live privileges not checked` };
  }
  const ssl = sslmodeOverride === "disable" ? false : postgresTlsOptions({ host: c.host, ca });
  const client = new pg.Client({
    host: c.host, port: c.port, database: c.database, user: c.user, password: c.password,
    ssl, connectionTimeoutMillis: connectTimeoutMs, query_timeout: 30000,
    application_name: "agent-relay-db-guard",
  });
  client.on("error", () => {});
  try {
    await client.connect();
  } catch (err) {
    return { label, status: "FAIL", login: c.user, detail: connectProblem(err, c, t) };
  }
  try {
    const mode = t.relaycast || "runtime";
    const expectedRole = t.relaycast ? RELAYCAST_ROLES[t.relaycast] : c.user;
    const result = await verifyIdentity(client, { expectedRole, mode, schema: "public" });
    if (opts.sessionsUsage && SESSIONS_READERS.has(t.role)) {
      // After the HoopDb migration, these logins need USAGE on sessions, which
      // rds-setup.sh post grants; without it the workload crash-loops with
      // "permission denied for schema sessions". Status only: before post this
      // is expected, so the install hook must not block on it.
      const row = (await client.query(
        `SELECT n.oid IS NOT NULL AS present,
                CASE WHEN n.oid IS NULL THEN NULL ELSE pg_catalog.has_schema_privilege(current_user, n.oid, 'USAGE') END AS usage
         FROM (SELECT 1) one LEFT JOIN pg_catalog.pg_namespace n ON n.nspname = 'sessions'`,
      )).rows[0];
      if (row.present && !row.usage)
        return {
          label, status: "FAIL", login: c.user,
          summary: `logs in as "${c.user}", which has no USAGE on schema sessions (the "permission denied for schema sessions" crash loop)`,
          detail: `logs in as "${c.user}", which has no USAGE on schema sessions (the "permission denied for schema sessions" crash loop): run rds-setup.sh post (configure-rds.sh does it), then delete the failed search-indexer-bootstrap Job and run helm upgrade again`,
        };
    }
    const failed = result.checks.filter((k) => !k.ok && (t.relaycast || SERVICE_CHECKS.has(k.name)));
    if (failed.length === 0) return { label, status: "ok", login: c.user, detail: t.relaycast ? `relaycast ${mode} identity` : "dedicated service login" };
    if (t.allowMaster && failed.every((k) => MASTER_CHECKS.has(k.name)))
      return { label, status: "ok", login: c.user, detail: "administrator login (legacy master-owner HoopDb layout)" };
    const attrs = failed.filter((k) => MASTER_CHECKS.has(k.name) && k.name !== "no_privileged_memberships")
      .map((k) => k.detail.replace(/^role has /, ""));
    const reach = failed.find((k) => k.name === "no_privileged_memberships");
    const powers = [
      ...(attrs.length ? [`has ${attrs.join(", ")}`] : []),
      ...(reach ? [reach.detail.replace(/^can reach privileged role\(s\)/, "can reach privileged role")] : []),
    ];
    const summary = powers.length
      ? `logs in as "${c.user}", which ${powers.join(" and ")}: a database master/administrator login. Each service needs its own login`
      : `logs in as "${c.user}", which is not a correctly scoped ${t.relaycast ? `relaycast ${mode}` : "service"} login`;
    return {
      label, status: "FAIL", login: c.user, summary,
      detail: `${summary} (failed: ${failed.map((k) => `${k.name}: ${k.detail}`).join("; ")})`,
    };
  } catch (err) {
    return { label, status: "FAIL", login: c.user, detail: `privilege query failed (${err?.code ?? ""} ${err?.message ?? err})` };
  } finally {
    await client.end().catch(() => {});
  }
}

/** Every target's result: {label, status: ok|FAIL|skip, login?, detail, summary?}. */
export async function checkTargets(opts = {}) {
  const results = [];
  for (const t of targets) results.push(await checkTarget(t, opts));

  // Different jobs must not share one login (relaycast's check cannot see this).
  const byLogin = new Map();
  for (const [i, r] of results.entries()) {
    if (!r.login) continue;
    const prev = byLogin.get(r.login);
    if (prev && targets[prev.i].role !== targets[i].role && r.status !== "FAIL") {
      r.status = "FAIL";
      r.detail = `${prev.label} also logs in as "${r.login}"; the ${targets[prev.i].role} and the ${targets[i].role} need different logins`;
    } else if (!prev) byLogin.set(r.login, { i, label: r.label });
  }
  return results;
}
