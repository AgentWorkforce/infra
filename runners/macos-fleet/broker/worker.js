// fleet-runner-jit: one endpoint, POST /mint. A Mac authenticates with its
// own key (Authorization: Bearer <key>); the sha256 of that key selects the
// repo, installation and runner name it may mint for. The Worker then signs
// a GitHub App JWT, takes a short installation token scoped to that one repo
// with administration:write, and asks GitHub for a JIT runner config. The
// config is returned once, as text/plain, with the runner name in the
// x-fleet-runner-name header. Nothing secret is logged: the audit line has
// the key id (first 12 hex of the sha256), repo, runner name and outcome.

const LABELS = ["fleet-macos-arm64"];
const RUNNER_GROUP_ID = 1; // "Default" (Free plan: the only group)
const API = "https://api.github.com";
const UA = "fleet-runner-jit (AgentWorkforce/infra)";

const text = (status, body, headers = {}) =>
  new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store", ...headers } });

const b64url = (buf) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function sha256Hex(s) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function pemToPkcs8(pem) {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  if (/BEGIN RSA PRIVATE KEY/.test(pem)) {
    throw new Error("GITHUB_APP_PRIVATE_KEY is PKCS#1; convert with: openssl pkcs8 -topk8 -nocrypt -in app.pem");
  }
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0)).buffer;
}

async function appJwt(env) {
  const key = await crypto.subtle.importKey("pkcs8", pemToPkcs8(env.GITHUB_APP_PRIVATE_KEY),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const enc = (o) => b64url(new TextEncoder().encode(JSON.stringify(o)));
  const unsigned = `${enc({ alg: "RS256", typ: "JWT" })}.${enc({ iat: now - 60, exp: now + 540, iss: String(env.GITHUB_APP_ID) })}`;
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  return `${unsigned}.${b64url(sig)}`;
}

async function gh(path, token, body) {
  const r = await fetch(`${API}${path}`, {
    method: body ? "POST" : "GET",
    headers: { authorization: `Bearer ${token}`, accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28", "user-agent": UA, ...(body ? { "content-type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`github ${path} -> ${r.status} ${j.message || ""}`.trim());
  return j;
}

async function mint(env, machine, slot) {
  const [owner, repo] = machine.repo.split("/");
  const inst = await gh(`/app/installations/${machine.installation_id}/access_tokens`, await appJwt(env),
    { repositories: [repo], permissions: { administration: "write" } });
  const name = `${machine.name}-${slot}-${Date.now().toString(36)}`;
  const jit = await gh(`/repos/${owner}/${repo}/actions/runners/generate-jitconfig`, inst.token,
    { name, runner_group_id: RUNNER_GROUP_ID, labels: LABELS, work_folder: "_work" });
  return { name, config: jit.encoded_jit_config };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/healthz") return text(200, "ok\n");
    if (url.pathname !== "/mint" || request.method !== "POST") return text(404, "not found\n");

    const auth = request.headers.get("authorization") || "";
    const m = /^Bearer\s+(\S+)$/i.exec(auth);
    if (!m) return text(401, "unauthorized\n");
    const keyId = await sha256Hex(m[1]);
    let machines = {};
    try { machines = JSON.parse(env.MACHINE_KEYS || "{}"); } catch { return text(500, "MACHINE_KEYS is not JSON\n"); }
    const machine = machines[keyId];
    const audit = { t: new Date().toISOString(), key: keyId.slice(0, 12), ip: request.headers.get("cf-connecting-ip") };
    if (!machine) { console.log(JSON.stringify({ ...audit, ok: false, why: "unknown key" })); return text(403, "forbidden\n"); }

    let slot = "a";
    try { const b = await request.json(); if (typeof b.slot === "string" && /^[a-z0-9]{1,8}$/.test(b.slot)) slot = b.slot; } catch { /* body optional */ }
    try {
      const { name, config } = await mint(env, machine, slot);
      console.log(JSON.stringify({ ...audit, ok: true, repo: machine.repo, runner: name }));
      return text(200, config, { "x-fleet-runner-name": name });
    } catch (e) {
      console.log(JSON.stringify({ ...audit, ok: false, repo: machine.repo, why: String(e.message || e) }));
      return text(502, "mint failed\n");
    }
  },
};
