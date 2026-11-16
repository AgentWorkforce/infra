// components/slack-relay/manifest/register-github-app.mts: the guided GitHub
// App registration, against a fake GitHub and fake stores.
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  apiBase,
  buildManifest,
  dirStore,
  exchangeCode,
  formHtml,
  gcpStore,
  githubBase,
  installUrl,
  k8sStore,
  newAppUrl,
  register,
  verify,
  type Credentials,
  type Runner,
  type Store,
} from "../manifest/register-github-app.mts";

const { privateKey: PEM } = generateKeyPairSync("rsa", {
  modulusLength: 2048,
  privateKeyEncoding: { type: "pkcs1", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});
const KEY_LINE = PEM.split("\n")[1]!;

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

test("the manifest asks for read-only contents and metadata, no webhook, private", () => {
  const m = buildManifest({ name: "Example agents" });
  assert.equal(m.name, "Example agents");
  assert.equal(m.public, false);
  assert.deepEqual(m.default_permissions, { contents: "read", metadata: "read" });
  assert.deepEqual(m.default_events, []);
  assert.equal((m.hook_attributes as { active: boolean }).active, false);
  assert.equal(m.redirect_url, undefined);
  const cb = buildManifest({ name: "x", callback: "http://127.0.0.1:5000" });
  assert.equal(cb.redirect_url, "http://127.0.0.1:5000/created");
  assert.equal(cb.setup_url, "http://127.0.0.1:5000/installed");
  assert.throws(() => buildManifest({ name: "x".repeat(35) }), /34 characters/);
});

test("URLs: github.com and GitHub Enterprise Server, organization or user", () => {
  assert.equal(githubBase("https://github.com/"), "https://github.com");
  assert.throws(() => githubBase("https://user:pw@ghe.example.com"), /plain base URL/);
  assert.equal(apiBase("https://github.com"), "https://api.github.com");
  assert.equal(apiBase("https://ghe.example.com"), "https://ghe.example.com/api/v3");
  assert.equal(apiBase("https://ghe.example.com", "https://api.ghe.example.com/"), "https://api.ghe.example.com");
  assert.equal(newAppUrl("https://github.com", "example-org", "s1"), "https://github.com/organizations/example-org/settings/apps/new?state=s1");
  assert.equal(newAppUrl("https://ghe.example.com", "", "s1"), "https://ghe.example.com/settings/apps/new?state=s1");
  assert.throws(() => newAppUrl("https://github.com", "../evil", "s"), /not a GitHub organization name/);
  assert.equal(installUrl("https://github.com", { slug: "a-b", htmlUrl: "https://github.com/apps/a-b" }), "https://github.com/apps/a-b/installations/new");
  assert.equal(installUrl("https://ghe.example.com", { slug: "a-b", htmlUrl: "https://ghe.example.com/github-apps/a-b" }), "https://ghe.example.com/github-apps/a-b/installations/new");
  // An html_url on another host is not followed.
  assert.equal(installUrl("https://github.com", { slug: "a-b", htmlUrl: "https://evil.example.com/x" }), "https://github.com/apps/a-b/installations/new");
});

test("the form escapes the manifest into a hidden field", () => {
  const html = formHtml("https://github.com/settings/apps/new?state=s", { name: 'a"<b>' }, false);
  assert.match(html, /name="manifest" value="\{&quot;name&quot;:&quot;a\\&quot;&lt;b&gt;&quot;\}"/);
  assert.ok(!html.includes("<script>"));
  assert.ok(formHtml("https://x", {}, true).includes(".submit()"));
});

test("exchangeCode converts the code and refuses bad codes or responses", async () => {
  let called = "";
  const app = await exchangeCode("https://api.github.com", "abc123", async (url, init) => {
    called = `${init.method} ${url}`;
    assert.equal(init.headers.authorization, undefined); // the code is the credential
    return json({ id: 4242, slug: "example-agents", name: "Example agents", html_url: "https://github.com/apps/example-agents", pem: PEM, client_secret: "cs", webhook_secret: null }, 201);
  });
  assert.equal(called, "POST https://api.github.com/app-manifests/abc123/conversions");
  assert.deepEqual({ ...app, privateKey: app.privateKey === PEM }, { appId: "4242", slug: "example-agents", name: "Example agents", htmlUrl: "https://github.com/apps/example-agents", privateKey: true });
  await assert.rejects(exchangeCode("https://api.github.com", "a/../b", async () => assert.fail()), /malformed/);
  await assert.rejects(exchangeCode("https://api.github.com", "abc", async () => json({}, 404)), /HTTP 404 \(the code is used or older than an hour/);
  await assert.rejects(exchangeCode("https://api.github.com", "abc", async () => json({ id: 1, slug: "s", pem: "nope" }, 201)), /not a PEM private key/);
});

function fakeRunner(results: Record<string, number> = {}) {
  const calls: Array<{ cmd: string; args: string[]; stdin?: string }> = [];
  const runner: Runner = async (cmd, args, stdin) => {
    calls.push({ cmd, args, stdin });
    return { code: results[args.slice(0, 2).join(" ")] ?? 0, stdout: "", stderr: "boom\n" };
  };
  return { runner, calls };
}

const CREDS: Credentials = { appId: "4242", privateKey: PEM, installationId: "77" };

test("k8sStore server-side applies one Secret with the key only on stdin", async () => {
  const { runner, calls } = fakeRunner();
  await k8sStore("agent-relay", "slack-relay-github-app", runner, "my-ctx").put(CREDS);
  assert.equal(calls.length, 1);
  const c = calls[0]!;
  assert.equal(c.cmd, "kubectl");
  assert.deepEqual(c.args, ["--context", "my-ctx", "apply", "--server-side", "--force-conflicts", "--field-manager=register-github-app", "-f", "-"]);
  assert.ok(!c.args.join(" ").includes(KEY_LINE));
  const s = JSON.parse(c.stdin!);
  assert.equal(s.metadata.name, "slack-relay-github-app");
  assert.equal(s.metadata.namespace, "agent-relay");
  assert.deepEqual(
    Object.fromEntries(Object.entries(s.data as Record<string, string>).map(([k, v]) => [k, Buffer.from(v, "base64").toString()])),
    { "app-id": "4242", "private-key": PEM, "installation-id": "77" },
  );
  // Before installation: no installation-id key yet.
  const first = fakeRunner();
  await k8sStore("agent-relay", undefined, first.runner).put({ appId: "1", privateKey: PEM });
  assert.deepEqual(Object.keys(JSON.parse(first.calls[0]!.stdin!).data), ["app-id", "private-key"]);
  assert.throws(() => k8sStore("Bad_NS"), /Kubernetes names/);
  const failing = fakeRunner({ "apply --server-side": 1 });
  await assert.rejects(k8sStore("ns", "s", failing.runner).put(CREDS), /kubectl apply of Secret ns\/s failed: boom/);
});

test("gcpStore creates missing secrets and adds versions to existing ones, values only on stdin", async () => {
  // github-app-id exists (describe succeeds); the others do not.
  const calls: Array<{ args: string[]; stdin?: string }> = [];
  const runner: Runner = async (_cmd, args, stdin) => {
    calls.push({ args, stdin });
    const missing = args[1] === "describe" && args[2] !== "github-app-id";
    return { code: missing ? 1 : 0, stdout: "", stderr: "" };
  };
  await gcpStore("example-project", runner).put(CREDS);
  const writes = calls.filter((c) => c.args[1] !== "describe");
  assert.deepEqual(
    writes.map((c) => c.args.slice(0, 4).join(" ")),
    ["secrets versions add github-app-id", "secrets create github-app-private-key --project", "secrets create github-app-installation-id --project"],
  );
  assert.deepEqual(writes.map((c) => c.stdin), ["4242", PEM, "77"]);
  for (const c of calls) {
    assert.ok(c.args.includes("--project") && c.args.includes("example-project"));
    assert.ok(!c.args.join(" ").includes(KEY_LINE));
  }
  assert.ok(writes.every((c) => c.args.includes("--data-file=-")));
  assert.throws(() => gcpStore("Bad Project"), /Google Cloud project ID/);
});

test("dirStore writes 0600 files", async () => {
  const dir = mkdtempSync(join(tmpdir(), "gh-app-store-"));
  try {
    await dirStore(join(dir, "out")).put(CREDS);
    assert.equal(readFileSync(join(dir, "out", "private-key"), "utf8"), PEM);
    assert.equal(readFileSync(join(dir, "out", "installation-id"), "utf8"), "77");
    for (const f of ["app-id", "private-key", "installation-id"]) assert.equal(statSync(join(dir, "out", f)).mode & 0o777, 0o600);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

/** A fake GitHub API: the manifest conversion, app installations, tokens and installation repos. */
function fakeGitHub() {
  const seen: string[] = [];
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    seen.push(`${req.method} ${req.url}`);
    const send = (status: number, body: unknown) => res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
    if (req.method === "POST" && req.url === "/app-manifests/good-code/conversions") {
      return send(201, { id: 4242, slug: "example-agents", name: "Example agents", html_url: "https://github.com/apps/example-agents", pem: PEM });
    }
    if (req.method === "POST" && req.url === "/app/installations/77/access_tokens") return send(201, { token: "ghs_FAKE", expires_at: new Date(Date.now() + 3600_000).toISOString() });
    if (req.method === "POST" && req.url?.startsWith("/app/installations/")) return send(404, { message: "Not Found" });
    if (req.url?.startsWith("/installation/repositories")) {
      if (req.headers.authorization !== "Bearer ghs_FAKE") return send(401, { message: "Bad credentials" });
      return send(200, { total_count: 2, repositories: [{ full_name: "example-org/web" }, { full_name: "example-org/api" }] });
    }
    send(404, { message: "Not Found" });
  });
  return { server, seen };
}

test("verify mints an installation token and lists the repos", async () => {
  const gh = fakeGitHub();
  await new Promise<void>((r) => gh.server.listen(0, "127.0.0.1", r));
  try {
    const api = `http://127.0.0.1:${(gh.server.address() as { port: number }).port}`;
    assert.deepEqual(await verify(api, CREDS), { installationId: "77", repos: ["example-org/api", "example-org/web"] });
    await assert.rejects(verify(api, { ...CREDS, installationId: "78" }), /HTTP 404/);
  } finally {
    gh.server.close();
  }
});

test("register: browser → GitHub → /created → stores → install → /installed → verified", async () => {
  const gh = fakeGitHub();
  await new Promise<void>((r) => gh.server.listen(0, "127.0.0.1", r));
  const puts: Credentials[] = [];
  const store: Store = { label: "memory", put: async (c) => void puts.push({ ...c }) };
  const opened: string[] = [];
  const logs: string[] = [];
  try {
    const api = `http://127.0.0.1:${(gh.server.address() as { port: number }).port}`;
    let base = "";
    let listening!: () => void;
    const ready = new Promise<void>((r) => (listening = r));
    const done = register({
      github: "https://github.com",
      api,
      org: "example-org",
      name: "Example agents",
      stores: [store],
      open: (u) => void opened.push(u),
      log: (l) => void logs.push(l),
      onListening: (b) => {
        base = b;
        listening();
      },
    });
    await ready;
    assert.equal(opened[0], `${base}/`);

    // The landing page posts the manifest, with the callbacks, to the org's new-app page.
    const landing = await (await fetch(`${base}/`)).text();
    const action = /action="([^"]+)"/.exec(landing)![1]!.replace(/&amp;/g, "&");
    const state = new URL(action).searchParams.get("state")!;
    assert.match(action, /^https:\/\/github\.com\/organizations\/example-org\/settings\/apps\/new\?state=[0-9a-f]{32}$/);
    assert.match(landing, /&quot;redirect_url&quot;:&quot;http:\/\/127\.0\.0\.1:\d+\/created&quot;/);

    // Out of order or forged callbacks are refused.
    assert.equal((await fetch(`${base}/installed?installation_id=77`)).status, 409);
    assert.equal((await fetch(`${base}/created?code=good-code&state=wrong`)).status, 400);
    assert.equal(puts.length, 0);

    // GitHub redirects back with the code: exchanged, stored, sent on to the install page.
    const created = await fetch(`${base}/created?code=good-code&state=${state}`, { redirect: "manual" });
    assert.equal(created.status, 303);
    assert.equal(created.headers.get("location"), "https://github.com/apps/example-agents/installations/new");
    assert.equal(opened[1], "https://github.com/apps/example-agents/installations/new");
    assert.deepEqual(puts, [{ appId: "4242", privateKey: PEM }]);
    assert.equal((await fetch(`${base}/created?code=good-code&state=${state}`)).status, 409); // one-shot

    // An installation ID the app's key can't get a token for is not stored.
    assert.equal((await fetch(`${base}/installed?installation_id=78`)).status, 500);
    assert.equal(puts.length, 1);

    const installed = await fetch(`${base}/installed?installation_id=77&setup_action=install`);
    assert.equal(installed.status, 200);
    const result = await done;
    assert.deepEqual(result, { appId: "4242", slug: "example-agents", installationId: "77", repos: ["example-org/api", "example-org/web"] });
    assert.deepEqual(puts[1], { appId: "4242", privateKey: PEM, installationId: "77" });
    assert.ok(logs.some((l) => /verified: installation 77 can read 2 repositories/.test(l)));
    for (const l of logs) assert.ok(!l.includes(KEY_LINE) && !l.includes("ghs_FAKE"), l);
  } finally {
    gh.server.close();
  }
});
