// The repos sidecar's GitHub App mode (charts/slack-relay/files): github-app.mts
// mints installation tokens; repo-sync.sh renews them and lists the
// installation's repositories.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createPublicKey, generateKeyPairSync, verify } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { appJwt, findInstallation, installationToken, loadKey, mask } from "../../../charts/slack-relay/files/github-app.mts";
import { listRepos } from "../../../charts/slack-relay/files/repo-list.mts";

const files = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "charts", "slack-relay", "files");
const { privateKey: PEM } = generateKeyPairSync("rsa", {
  modulusLength: 2048,
  privateKeyEncoding: { type: "pkcs1", format: "pem" }, // GitHub's format
  publicKeyEncoding: { type: "spki", format: "pem" },
});
const KEY = loadKey(PEM);
const KEY_BODY = PEM.split("\n")[1]!; // a line of the key, as a leak marker

function decode(jwt: string) {
  const [h, c, s] = jwt.split(".");
  return {
    header: JSON.parse(Buffer.from(h!, "base64url").toString()),
    claims: JSON.parse(Buffer.from(c!, "base64url").toString()),
    valid: verify("sha256", Buffer.from(`${h}.${c}`), createPublicKey(KEY), Buffer.from(s!, "base64url")),
  };
}

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });

test("appJwt is RS256, signed by the key, issued 60 s back and valid for at most 10 minutes", () => {
  const now = 1_800_000_000;
  const { header, claims, valid } = decode(appJwt("123456", KEY, now));
  assert.deepEqual(header, { alg: "RS256", typ: "JWT" });
  assert.equal(valid, true);
  assert.deepEqual(claims, { iat: now - 60, exp: now + 540, iss: 123456 });
  assert.ok(claims.exp - now <= 600);
  assert.equal(decode(appJwt("Iv23liABCDEF", KEY, now)).claims.iss, "Iv23liABCDEF"); // a client ID stays a string
});

test("loadKey refuses non-keys and non-RSA keys without echoing them", () => {
  assert.throws(() => loadKey("not a key SECRETISH"), (e: Error) => /not a PEM private key/.test(e.message) && !e.message.includes("SECRETISH"));
  const ec = generateKeyPairSync("ec", { namedCurve: "P-256", privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } });
  assert.throws(() => loadKey(ec.privateKey), /must be an RSA key/);
});

test("findInstallation uses the configured ID, else the only installation, and refuses none or several", async () => {
  const jwt = appJwt("1", KEY);
  const never = async () => assert.fail("no API call with an explicit installation");
  assert.equal(await findInstallation("https://api.github.com", jwt, "42", never), "42");
  await assert.rejects(findInstallation("https://api.github.com", jwt, "4x", never), /must be a number/);

  const pages = (...p: unknown[][]) => {
    const seen: string[] = [];
    const f = async (url: string, init: { headers: Record<string, string> }) => {
      seen.push(url);
      assert.equal(init.headers.authorization, `Bearer ${jwt}`);
      const n = Number(new URL(url).searchParams.get("page") ?? "1");
      const link: Record<string, string> = n < p.length ? { link: `<https://ghe.example.com/api/v3/app/installations?page=${n + 1}>; rel="next"` } : {};
      return json(p[n - 1], 200, link);
    };
    return { f, seen };
  };
  const one = pages([], [{ id: 77, account: { login: "acme" } }]);
  assert.equal(await findInstallation("https://ghe.example.com/api/v3/", jwt, "", one.f), "77");
  assert.equal(one.seen.length, 2); // walked both pages
  assert.equal(one.seen[0], "https://ghe.example.com/api/v3/app/installations?per_page=100");
  await assert.rejects(findInstallation("https://ghe.example.com/api/v3", jwt, "", pages([]).f), /not installed anywhere/);
  await assert.rejects(
    findInstallation("https://ghe.example.com/api/v3", jwt, "", pages([{ id: 1, account: { login: "a" } }, { id: 2, account: { login: "b" } }]).f),
    /2 installations \(1 \(a\), 2 \(b\)\): set repos\.app\.installationId/,
  );
});

test("installationToken posts for a contents:read token and returns it with its expiry", async () => {
  const jwt = appJwt("1", KEY);
  let call: { url: string; init: { method?: string; headers: Record<string, string>; body?: string } } | undefined;
  const got = await installationToken("https://api.github.com/", jwt, "42", async (url, init) => {
    call = { url, init };
    return json({ token: "ghs_INSTALLTOKEN", expires_at: "2026-11-16T23:00:00Z", permissions: { contents: "read" } }, 201);
  });
  assert.deepEqual(got, { token: "ghs_INSTALLTOKEN", expiresAt: Date.parse("2026-11-16T23:00:00Z") / 1000 });
  assert.equal(call!.url, "https://api.github.com/app/installations/42/access_tokens");
  assert.equal(call!.init.method, "POST");
  assert.equal(call!.init.headers.authorization, `Bearer ${jwt}`);
  assert.deepEqual(JSON.parse(call!.init.body!), { permissions: { contents: "read", metadata: "read" } });

  await assert.rejects(
    installationToken("https://api.github.com", jwt, "42", async () => json({ message: "Integration not found" }, 404)),
    (e: Error) => e.message === "POST /app/installations/42/access_tokens: HTTP 404: Integration not found",
  );
  await assert.rejects(installationToken("https://api.github.com", jwt, "42", async () => json({ token: "has space", expires_at: "x" }, 201)), /no token/);
});

test("listRepos in app mode walks /installation/repositories pages", async () => {
  const seen: string[] = [];
  const names = await listRepos(
    "https://api.github.com",
    "ghs_T",
    async (url, init) => {
      seen.push(url);
      assert.equal(init.headers.authorization, "Bearer ghs_T");
      const p = new URL(url).searchParams.get("page") ?? "1";
      return p === "1"
        ? json({ total_count: 3, repositories: [{ full_name: "acme/b" }, { full_name: "../x" }] }, 200, { link: '<https://api.github.com/installation/repositories?page=2>; rel="next"' })
        : json({ total_count: 3, repositories: [{ full_name: "acme/a" }] });
    },
    "app",
  );
  assert.deepEqual(names, ["acme/a", "acme/b"]);
  assert.equal(seen[0], "https://api.github.com/installation/repositories?per_page=100");
  await assert.rejects(listRepos("https://api.github.com", "ghs_T", async () => json([]), "app"), /not a list/);
});

test("mask hides every secret", () => {
  assert.equal(mask("a SECRET b TOKEN", ["SECRET", "TOKEN", ""]), "a *** b ***");
});

// --- the sidecar end to end: a fake GitHub API, file:// remotes, the real scripts ---

function git(cwd: string, ...args: string[]) {
  return execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "init.defaultBranch=main", ...args], { cwd, encoding: "utf8" }).trim();
}

function makeRemote(root: string, repo: string, body: string) {
  const work = join(root, "work", repo);
  execFileSync("mkdir", ["-p", work, join(root, "remote", dirname(repo))]);
  git(work, "init", "-q");
  writeFileSync(join(work, "f.txt"), body);
  git(work, "add", ".");
  git(work, "commit", "-qm", "init");
  git(root, "clone", "-q", "--bare", work, join(root, "remote", `${repo}.git`));
}

function runSync(root: string, env: Record<string, string>) {
  return new Promise<{ code: number | null; log: string }>((resolve) => {
    const child = spawn("sh", [join(files, "repo-sync.sh")], {
      env: {
        PATH: process.env.PATH,
        REPOS_AUTH: "app",
        REPOS_DIR: join(root, "repos"),
        REPOS_CACHE_DIR: join(root, "cache"),
        REPOS_BASE_URL: `file://${join(root, "remote")}`,
        REPOS_SYNC_ONCE: "1",
        REPOS_LIST: "",
        ...env,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let log = "";
    child.stdout.on("data", (d) => (log += d));
    child.stderr.on("data", (d) => (log += d));
    child.on("close", (code) => resolve({ code, log }));
  });
}

function grepTree(dir: string, needles: string[]): string[] {
  const hits: string[] = [];
  for (const e of readdirSync(dir, { withFileTypes: true, recursive: true })) {
    if (!e.isFile()) continue;
    const p = join(e.parentPath, e.name);
    const body = readFileSync(p);
    for (const n of needles) if (body.includes(n)) hits.push(`${p}: ${n.slice(0, 12)}`);
  }
  return hits;
}

test("repo-sync.sh with REPOS_AUTH=app mints a token, lists the installation's repos and leaks nothing", async () => {
  const root = mkdtempSync(join(tmpdir(), "repo-sync-app-"));
  const keyDir = mkdtempSync(join(tmpdir(), "repo-sync-key-"));
  const minted: string[] = [];
  let repos = ["acme/one", "acme/two"];
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    const auth = req.headers.authorization ?? "";
    const send = (status: number, body: unknown) => res.writeHead(status, { "content-type": "application/json" }).end(JSON.stringify(body));
    if (req.method === "POST" && req.url === "/app/installations/42/access_tokens") {
      const jwt = auth.replace(/^Bearer /, "");
      const { claims, valid } = decode(jwt);
      if (!valid || claims.iss !== 123) return send(401, { message: "A JSON web token could not be decoded" });
      const token = `ghs_TOKEN${minted.length}x${"0".repeat(20)}`;
      minted.push(token);
      return send(201, { token, expires_at: new Date(Date.now() + 3600_000).toISOString() });
    }
    if (req.url?.startsWith("/installation/repositories")) {
      if (auth !== `Bearer ${minted.at(-1)}`) return send(401, { message: "Bad credentials" });
      return send(200, { total_count: repos.length, repositories: repos.map((full_name) => ({ full_name })) });
    }
    send(404, { message: "Not Found" });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  try {
    const { port } = server.address() as { port: number };
    makeRemote(root, "acme/one", "1\n");
    makeRemote(root, "acme/two", "2\n");
    const keyFile = join(keyDir, "private-key");
    writeFileSync(keyFile, PEM, { mode: 0o400 });
    const env = { GITHUB_APP_ID: "123", GITHUB_APP_INSTALLATION_ID: "42", GITHUB_APP_PRIVATE_KEY_FILE: keyFile, REPOS_API_URL: `http://127.0.0.1:${port}` };

    const first = await runSync(root, env);
    assert.equal(first.code, 0, first.log);
    assert.match(first.log, /GitHub App installation can read 2 repo\(s\)/);
    assert.equal(minted.length, 1, "one token covers the whole pass");
    assert.equal(readFileSync(join(root, "repos", "acme", "one", "f.txt"), "utf8"), "1\n");
    assert.ok(existsSync(join(root, "repos", "acme", "two", "f.txt")));

    // The installation loses acme/two: its checkout goes.
    repos = ["acme/one"];
    const second = await runSync(root, env);
    assert.equal(second.code, 0, second.log);
    assert.match(second.log, /acme\/two removed/);

    // A wrong app ID: GitHub refuses the JWT; checkouts stay, nothing leaks.
    const bad = await runSync(root, { ...env, GITHUB_APP_ID: "999" });
    assert.equal(bad.code, 1, bad.log);
    assert.match(bad.log, /GitHub App token failed: POST \/app\/installations\/42\/access_tokens: HTTP 401: A JSON web token could not be decoded/);
    assert.ok(existsSync(join(root, "repos", "acme", "one", "f.txt")));

    const secrets = [KEY_BODY, ...minted];
    for (const s of secrets) for (const r of [first, second, bad]) assert.ok(!r.log.includes(s), `a secret is in the log: ${r.log}`);
    assert.deepEqual(grepTree(root, secrets), []);
  } finally {
    server.close();
    rmSync(root, { recursive: true, force: true });
    rmSync(keyDir, { recursive: true, force: true });
  }
});

test("repo-sync.sh renews the app token before it can expire mid-fetch, and passes it to the listing", async () => {
  const root = mkdtempSync(join(tmpdir(), "repo-sync-app-"));
  try {
    makeRemote(root, "acme/one", "1\n");
    makeRemote(root, "acme/two", "2\n");
    const count = join(root, "count");
    writeFileSync(count, "");
    // A stand-in minter: tok-N, expiring in $LIFE seconds.
    const minter = join(root, "mint.sh");
    writeFileSync(minter, `#!/bin/sh\necho x >>"${count}"\nn=$(wc -l <"${count}" | tr -d ' ')\necho "tok-$n $(( $(date +%s) + LIFE ))"\n`, { mode: 0o755 });
    const list = join(root, "list.sh");
    writeFileSync(list, `#!/bin/sh\ncase $GITHUB_TOKEN in tok-*) printf 'acme/one\\nacme/two\\n' ;; *) echo "no token" >&2; exit 1 ;; esac\n`, { mode: 0o755 });
    const mints = () => readFileSync(count, "utf8").split("\n").filter(Boolean).length;

    // A long-lived token: one mint for the listing and both fetches.
    const long = await runSync(root, { REPOS_TOKEN_CMD: minter, REPOS_LIST_CMD: list, LIFE: "3600", REPOS_TIMEOUT_SECONDS: "600" });
    assert.equal(long.code, 0, long.log);
    assert.equal(mints(), 1);

    // A token about to expire (less than REPOS_TIMEOUT_SECONDS + 60 left): renewed before every use.
    writeFileSync(count, "");
    const short = await runSync(root, { REPOS_TOKEN_CMD: minter, REPOS_LIST_CMD: list, LIFE: "100", REPOS_TIMEOUT_SECONDS: "600" });
    assert.equal(short.code, 0, short.log);
    assert.equal(mints(), 3, short.log); // listing + two repos
    assert.match(short.log, /expires in \d+ s, less than REPOS_TIMEOUT_SECONDS/);

    // The minter fails: the pass fails and keeps the checkouts.
    const failed = await runSync(root, { REPOS_TOKEN_CMD: "false", REPOS_LIST_CMD: list });
    assert.equal(failed.code, 1, failed.log);
    assert.match(failed.log, /no GitHub token, keeping current checkouts/);
    assert.ok(existsSync(join(root, "repos", "acme", "one", "f.txt")));

    // Garbage from the minter is refused, not used as a token.
    const garbage = await runSync(root, { REPOS_TOKEN_CMD: "echo 'not a token at all'", REPOS_LIST_CMD: list });
    assert.equal(garbage.code, 1, garbage.log);
    assert.match(garbage.log, /unexpected output/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
