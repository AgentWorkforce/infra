// Agent Relay database privilege check (databaseGuard.privilegeCheck).
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
// TLS uses relaycast's postgresTlsOptions (verify-full against the CA).
//
// Read-only: one connection per URL, catalog queries only. Prints one line
// per URL, then the problems; exits 1 when any URL fails. Never prints a URL
// or password.
//
// Input: $DB_GUARD_TARGETS (JSON file written by the chart), the Secrets
// mounted at /db-guard/secrets/<secret>/<key>, and the CA at $DB_GUARD_CA.
import { readFileSync, existsSync, writeFileSync } from "node:fs";
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
const POINTER =
  "Run scripts/selfhost/configure-rds.sh, which creates the logins and writes these Secrets, " +
  "or see docs/self-hosted-rds-manual-setup.md §1.3 " +
  "(https://agentrelay.com/docs/self-hosting/troubleshooting#database-logins).";
const RELAYCAST_ROLES = { owner: "relaycast_owner", runtime: "relaycast_runtime" };

const env = process.env;
const targets = JSON.parse(readFileSync(env.DB_GUARD_TARGETS, "utf8"));
const masters = new Set(
  JSON.parse(env.DB_GUARD_MASTER_LOGINS || "[]").map((m) => String(m).toLowerCase()),
);
const secretsDir = env.DB_GUARD_SECRETS_DIR || "/db-guard/secrets";
const connectTimeoutMs = Number(env.DB_GUARD_CONNECT_TIMEOUT_MS || 10000);
const sslmodeOverride = env.DB_GUARD_SSLMODE; // tests only: "disable"

let ca = null;
if (env.DB_GUARD_CA && existsSync(env.DB_GUARD_CA)) ca = readFileSync(env.DB_GUARD_CA, "utf8");

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
    return `TLS verification of ${c.host} failed (${code ?? err.message}); the CA bundle (rds-ca ConfigMap) must be the RDS bundle for this region`;
  return `connection failed (${code ?? "error"}: ${err?.message ?? err})`;
}

async function checkTarget(t) {
  const label = `${t.secret}: ${t.key}`;
  const r = readUrl(t);
  if (r.problem) return r.skip ? { label, status: "skip", detail: `${r.problem} (managed by externalSecrets; checked next run)` } : { label, status: "FAIL", detail: r.problem };
  const c = parse(r.url);
  if (!c) return { label, status: "FAIL", detail: "is not a postgres:// URL with a host and a login" };
  if (masters.has(c.user.toLowerCase()) && !t.allowMaster) {
    return { label, status: "FAIL", login: c.user, detail: `logs in as "${c.user}" (a database master/administrator login). Each service needs its own login` };
  }
  if (!ca && sslmodeOverride !== "disable") {
    return { label, status: "skip", login: c.user, detail: "no CA bundle mounted (relaycast.postgresCa); live privileges not checked" };
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

const results = [];
for (const t of targets) results.push(await checkTarget(t));

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

const width = Math.max(...results.map((r) => r.label.length), 10);
console.log("Agent Relay database privilege check (databaseGuard.privilegeCheck)");
for (const r of results) console.log(`  ${r.status.padEnd(4)} ${r.label.padEnd(width)}  ${r.login ? `login=${r.login}  ` : ""}${r.detail}`);
const failures = results.filter((r) => r.status === "FAIL");
if (failures.length === 0) {
  console.log(`ok: ${results.filter((r) => r.status === "ok").length} database login(s) verified`);
  process.exit(0);
}
const message = [
  "AR_DB_LOGIN: the database credentials in this release's Secrets are wrong; the install/upgrade was stopped before any workload changed:",
  ...failures.map((r) => `  - ${r.label} ${r.summary ?? r.detail}.`),
  `${POINTER} Then run helm again.`,
].join("\n");
console.error(message);
try {
  writeFileSync("/dev/termination-log", message.slice(0, 4000));
} catch {}
process.exit(1);
