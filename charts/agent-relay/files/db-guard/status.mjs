// Agent Relay install status: `helm test <release> -n <namespace> --logs`.
//
// A slim in-cluster counterpart of scripts/support/diagnose-install.py. Prints
// one table, every row healthy (ok), unhealthy (FAIL) or not applicable /
// not yet known (skip), then HEALTHY or UNHEALTHY; exits 1 when any row
// fails, so `helm test` fails too.
//
//   migrations     the release's Jobs (Kubernetes API; needs the optional
//                  read-only Role, databaseGuard.statusTest.rbac.create)
//   workloads      Deployment ready replicas
//   database       every Secret's database URL: the login connects over
//                  verify-full TLS and passes relaycast's identity rules
//                  (lib.mjs, the same check as the databaseGuard hook)
//   ca             the CA bundle parses and matches the configured sha256
//   pod identity   workloads that use S3 got AWS credentials injected
//   s3, search     the bucket endpoint and OpenSearch answer over HTTPS
//
// Never prints a URL, password or Secret value.
import { readFileSync, existsSync } from "node:fs";
import { createHash, X509Certificate } from "node:crypto";
import https from "node:https";
import { checkTargets, targets, caFor } from "./lib.mjs";

const env = process.env;
const cfg = JSON.parse(env.STATUS_CONFIG || "{}");
const rows = [];
const add = (area, check, status, detail) => rows.push({ area, check, status, detail });

// --- Kubernetes API (read-only Role on jobs, deployments, pods) -------------
const SA = "/var/run/secrets/kubernetes.io/serviceaccount";
function kube(path) {
  return new Promise((resolve, reject) => {
    const req = https.request({
      host: env.KUBERNETES_SERVICE_HOST, port: env.KUBERNETES_SERVICE_PORT || 443, path, method: "GET",
      ca: readFileSync(`${SA}/ca.crt`), headers: { authorization: `Bearer ${readFileSync(`${SA}/token`, "utf8").trim()}` },
      timeout: 10000,
    }, (res) => {
      let body = "";
      res.on("data", (d) => (body += d));
      res.on("end", () => (res.statusCode === 200 ? resolve(JSON.parse(body)) : reject(new Error(`HTTP ${res.statusCode}`))));
    });
    req.on("timeout", () => req.destroy(new Error("timeout")));
    req.on("error", reject);
    req.end();
  });
}
const rbac = existsSync(`${SA}/token`);
const howTo = `set databaseGuard.statusTest.rbac.create=true for this row, or run`;
const ns = encodeURIComponent(cfg.namespace);
const sel = encodeURIComponent(`app.kubernetes.io/instance=${cfg.release}`);

let pods = [];
if (rbac) {
  try { pods = (await kube(`/api/v1/namespaces/${ns}/pods?labelSelector=${sel}`)).items; } catch {}
}
/** The first line a failed Job's Pod left in its termination message. */
function jobCause(job) {
  for (const p of pods.filter((p) => p.metadata.labels?.["job-name"] === job)) {
    for (const c of p.status?.containerStatuses ?? []) {
      const msg = c.state?.terminated?.message ?? c.lastState?.terminated?.message;
      if (msg) return msg.trim().split("\n")[0].replace(/postgres(ql)?:\/\/\S+/giu, "<url>").slice(0, 600);
    }
  }
  return "";
}
if (!rbac) add("migrations", "jobs", "skip", `${howTo}: kubectl -n ${cfg.namespace} get jobs -l app.kubernetes.io/instance=${cfg.release}`);
else try {
  const jobs = (await kube(`/apis/batch/v1/namespaces/${ns}/jobs?labelSelector=${sel}`)).items
    .filter((j) => !/-(db-guard|status)$/.test(j.metadata.name))
    // Scheduled runs (CronJob-owned) are not migrations; their own retries handle failures.
    .filter((j) => !(j.metadata.ownerReferences ?? []).some((o) => o.kind === "CronJob"));
  // Only the newest Job of each kind counts: names end in a content hash.
  const latest = new Map();
  for (const j of jobs) {
    const kind = j.metadata.name.replace(/-[0-9a-f]{8}$/, "");
    const prev = latest.get(kind);
    if (!prev || prev.metadata.creationTimestamp < j.metadata.creationTimestamp) latest.set(kind, j);
  }
  if (latest.size === 0) add("migrations", "jobs", "skip", "no Jobs for this release");
  for (const [kind, j] of [...latest].sort()) {
    const cond = Object.fromEntries((j.status?.conditions ?? []).map((c) => [c.type, c.status]));
    if (cond.Complete === "True") add("migrations", kind, "ok", "completed");
    else if (cond.Failed === "True")
      add("migrations", kind, "FAIL", /search-indexer-bootstrap/.test(kind)
        ? `${jobCause(j.metadata.name).startsWith("search bootstrap failed") ? jobCause(j.metadata.name)
              : `search bootstrap failed${jobCause(j.metadata.name) ? `: ${jobCause(j.metadata.name)}` : ""} (often: it ran before rds-setup.sh post granted the search logins, or OpenSearch is unreachable)`}`
          // The recovery steps always follow, whatever the cause says.
          + ` | then: kubectl -n ${cfg.namespace} delete job ${j.metadata.name} && helm upgrade (same -f files); log: kubectl -n ${cfg.namespace} logs job/${j.metadata.name}`
        : `failed${jobCause(j.metadata.name) ? `: ${jobCause(j.metadata.name)}` : ""}: kubectl -n ${cfg.namespace} logs job/${j.metadata.name}`);
    else add("migrations", kind, "FAIL", "not complete yet (running or pending); rerun helm test when it finishes");
  }
} catch (err) {
  add("migrations", "jobs", "skip", `Kubernetes API unavailable (${err.message})`);
}

if (!rbac) add("workloads", "deployments", "skip", `${howTo}: kubectl -n ${cfg.namespace} get deployments -l app.kubernetes.io/instance=${cfg.release}`);
else try {
  const deps = (await kube(`/apis/apps/v1/namespaces/${ns}/deployments?labelSelector=${sel}`)).items;
  for (const d of deps.sort((a, b) => a.metadata.name.localeCompare(b.metadata.name))) {
    const want = d.spec.replicas ?? 1;
    const st = d.status ?? {};
    const ready = st.readyReplicas ?? 0;
    const updated = st.updatedReplicas ?? 0;
    // Old pods stay ready during a stuck rollout: count only the current revision.
    const current = (st.observedGeneration ?? 0) >= (d.metadata.generation ?? 1);
    // Old-revision pods still count as ready/available: require that none remain.
    const ok = current && updated >= want && (st.replicas ?? updated) === updated && ready >= want && (st.availableReplicas ?? 0) >= want;
    add("workloads", d.metadata.name, ok ? "ok" : "FAIL",
      ok ? `${ready}/${want} ready` : `${ready}/${want} ready, ${updated}/${want} on the current revision${current ? "" : " (rollout not observed yet)"}`);
  }
} catch (err) {
  add("workloads", "deployments", "skip", `Kubernetes API unavailable (${err.message})`);
}

// --- Database logins and the CA ------------------------------------------------
const results = await checkTargets({ sessionsUsage: true });
for (const r of results) add("database", r.label, r.status, r.login ? `login=${r.login}: ${r.summary ?? r.detail}` : r.detail);
if (targets.length === 0) add("database", "logins", "skip", "no operator-supplied database URLs in this release");

// One row per distinct CA source; cfg.caSha256 maps "<kind>/<name>" to the
// sha256 values the components pin for it.
const caSources = new Map();
for (const t of targets) if (t.ca?.name) caSources.set(`${t.ca.kind}/${t.ca.name}/${t.ca.key}`, t);
if (caSources.size === 0 && targets.length) add("ca", "postgres CA", "FAIL", "no CA configured for the database connections");
for (const [id, t] of [...caSources].sort()) {
  const pem = caFor(t);
  if (!pem) {
    add("ca", id, "FAIL", `not mounted: ${t.ca.kind} ${t.ca.name} (key ${t.ca.key}) is missing in namespace ${cfg.namespace}`);
    continue;
  }
  let certs = 0;
  try {
    for (const c of pem.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) ?? []) {
      new X509Certificate(c);
      certs++;
    }
  } catch {
    certs = -1;
  }
  const sha = createHash("sha256").update(pem).digest("hex");
  const want = [...new Set(cfg.caSha256?.[id] ?? [])];
  const bad = want.filter((w) => w !== sha);
  if (certs <= 0) add("ca", id, "FAIL", "the bundle holds no parseable certificate");
  else add("ca", id, bad.length ? "FAIL" : "ok",
    bad.length ? `sha256 ${sha} differs from the configured ${bad.join(", ")}: update every caSha256/sha256 for ${t.ca.name} in values`
      : `${certs} certificate(s), sha256 ${sha}${want.length ? " matches values" : ""}`);
}

// --- Pod Identity: S3 users got credentials injected ----------------------------
if (cfg.s3?.bucket && cfg.s3.provider === "s3") {
  const users = pods.filter((p) => p.status?.phase === "Running" && (p.spec.containers ?? []).some((c) => (c.env ?? []).some((e) => e.name === "LOCKER_BUCKET")));
  // Per ServiceAccount, every running S3 pod must have credentials: worker
  // Deployments share one, so one restarted pod must not hide the others.
  const bySa = new Map();
  for (const p of users) {
    const sa = p.spec.serviceAccountName || "default";
    const envs = p.spec.containers.flatMap((c) => (c.env ?? []).map((e) => e.name));
    const injected = ["AWS_CONTAINER_CREDENTIALS_FULL_URI", "AWS_ROLE_ARN", "AWS_ACCESS_KEY_ID", "LOCKER_ACCESS_KEY_ID"].some((n) => envs.includes(n));
    const e = bySa.get(sa) ?? { total: 0, ok: 0 };
    e.total++; if (injected) e.ok++;
    bySa.set(sa, e);
  }
  if (!rbac) add("pod identity", "s3 workloads", "skip", `${howTo}: kubectl -n ${cfg.namespace} get pods -o yaml | grep AWS_CONTAINER_CREDENTIALS_FULL_URI`);
  else if (bySa.size === 0) add("pod identity", "s3 workloads", "skip", "no running pod uses the S3 bucket yet");
  for (const [sa, e] of [...bySa].sort())
    add("pod identity", `serviceaccount/${sa}`, e.ok === e.total ? "ok" : "FAIL",
      e.ok === e.total ? `AWS credentials in ${e.total}/${e.total} running pod(s)`
        : `${e.total - e.ok}/${e.total} running pod(s) have no AWS credentials: create the EKS Pod Identity association (or IRSA role) for this ServiceAccount (aws eks create-pod-identity-association --namespace ${cfg.namespace} --service-account ${sa} ...), then restart those pods`);
} else if (cfg.s3?.bucket) add("pod identity", "s3 workloads", "skip", `locker.provider=${cfg.s3.provider}: no AWS credentials to check`);

// --- Reachability (network only; any HTTP answer counts) -------------------------
function reach(url) {
  return new Promise((resolve) => {
    let req;
    try {
      req = https.request(url, { method: "HEAD", timeout: 8000 }, (res) => { res.resume(); resolve({ status: res.statusCode }); });
    } catch (e) {
      // e.g. an http:// URL: a FAIL row, not an aborted table.
      return resolve({ error: e.code || e.message });
    }
    req.on("timeout", () => req.destroy(new Error("timed out")));
    req.on("error", (e) => resolve({ error: e.code || e.message }));
    req.end();
  });
}
if (cfg.s3?.bucket && (cfg.s3.provider !== "s3" || cfg.s3.endpoint)) {
  add("s3", cfg.s3.bucket, "skip", `locker.provider=${cfg.s3.provider}${cfg.s3.endpoint ? ` with endpoint ${cfg.s3.endpoint}` : ""}: only AWS S3 is checked here`);
} else if (cfg.s3?.bucket) {
  const url = `https://s3.${cfg.s3.region}.amazonaws.com/${encodeURIComponent(cfg.s3.bucket)}`;
  const r = await reach(url);
  if (r.error) add("s3", cfg.s3.bucket, "FAIL", `cannot reach s3.${cfg.s3.region}.amazonaws.com (${r.error}): check egress, NAT or the S3 VPC endpoint`);
  else if (r.status === 404) add("s3", cfg.s3.bucket, "FAIL", `bucket not found in ${cfg.s3.region}`);
  else if (r.status === 301) add("s3", cfg.s3.bucket, "FAIL", `bucket exists in another region than ${cfg.s3.region}`);
  else add("s3", cfg.s3.bucket, "ok", `endpoint reachable, bucket exists (HTTP ${r.status} unauthenticated)`);
} else add("s3", "bucket", "skip", "no S3 bucket configured");
for (const u of [...new Set(cfg.search ?? [])]) {
  const r = await reach(u);
  const host = new URL(u).host;
  add("search", host, r.error ? "FAIL" : "ok", r.error ? `cannot reach ${host} (${r.error}): check the OpenSearch security group and VPC access` : `reachable (HTTP ${r.status})`);
}
if (!(cfg.search ?? []).length) add("search", "opensearch", "skip", "no OpenSearch URL configured");

// --- Table ------------------------------------------------------------------------
const w = (k) => Math.max(...rows.map((r) => String(r[k]).length));
const [wa, wc] = [w("area"), w("check")];
console.log(`Agent Relay install status (release ${cfg.release}, namespace ${cfg.namespace})`);
console.log(`  ${"AREA".padEnd(wa)}  ${"CHECK".padEnd(wc)}  STATUS  DETAIL`);
for (const r of rows) console.log(`  ${r.area.padEnd(wa)}  ${r.check.padEnd(wc)}  ${r.status.padEnd(6)}  ${r.detail}`);
const failed = rows.filter((r) => r.status === "FAIL");
console.log(failed.length ? `UNHEALTHY: ${failed.length} check(s) failed` : `HEALTHY: ${rows.filter((r) => r.status === "ok").length} check(s) ok`);
if (failed.some((r) => r.area === "database"))
  console.log("Database logins: run scripts/selfhost/configure-rds.sh, or see https://agentrelay.com/docs/self-hosting/troubleshooting#database-logins");
process.exit(failed.length ? 1 : 0);
