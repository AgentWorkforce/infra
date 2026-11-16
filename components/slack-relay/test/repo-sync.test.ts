// The chart's repos sidecar (charts/slack-relay/files): repo-list.mts lists the
// repos a GitHub token can read; repo-sync.sh checks them out read-only.
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { listRepos, nextLink } from "../../../charts/slack-relay/files/repo-list.mts";

const files = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "charts", "slack-relay", "files");
const TOKEN = "github_pat_TESTTOKEN0123456789";

function page(body: unknown, link?: string, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: link ? { link } : {} });
}

test("nextLink follows rel=next on the API origin and refuses any other origin", () => {
  const api = "https://api.github.com";
  assert.equal(
    nextLink('<https://api.github.com/user/repos?page=2>; rel="next", <https://api.github.com/user/repos?page=5>; rel="last"', api),
    "https://api.github.com/user/repos?page=2",
  );
  assert.equal(nextLink('<https://api.github.com/user/repos?page=1>; rel="prev"', api), null);
  assert.equal(nextLink(null, api), null);
  assert.throws(() => nextLink('<https://evil.example.com/x>; rel="next"', api), /another origin/);
});

test("listRepos walks every page, keeps valid names, and sends the token only as a header", async () => {
  const seen: string[] = [];
  const pages: Record<string, Response> = {};
  const fetchImpl = async (url: string, init: { headers: Record<string, string> }) => {
    seen.push(url);
    assert.equal(init.headers.authorization, `Bearer ${TOKEN}`);
    assert.ok(!url.includes(TOKEN));
    const p = new URL(url).searchParams.get("page") ?? "1";
    return pages[p]!;
  };
  pages["1"] = page([{ full_name: "org/zeta" }, { full_name: "org/alpha" }, { full_name: "../escape" }], '<https://ghe.example.com/api/v3/user/repos?page=2>; rel="next"');
  pages["2"] = page([{ full_name: "me/notes" }, { full_name: "org/alpha" }, { nope: 1 }]);
  const names = await listRepos("https://ghe.example.com/api/v3/", TOKEN, fetchImpl);
  assert.deepEqual(names, ["me/notes", "org/alpha", "org/zeta"]);
  assert.equal(seen.length, 2);
  assert.match(seen[0]!, /^https:\/\/ghe\.example\.com\/api\/v3\/user\/repos\?per_page=100&affiliation=owner,collaborator,organization_member$/);
});

test("listRepos fails on an API error without echoing the token", async () => {
  await assert.rejects(
    listRepos("https://api.github.com", TOKEN, async () => page({ message: "Bad credentials" }, undefined, 401)),
    (err: Error) => /HTTP 401/.test(err.message) && !err.message.includes(TOKEN),
  );
});

test("repo-list.mts --print lists repos from a live API over HTTP", async () => {
  const server = createServer((req, res) => {
    if (req.headers.authorization !== `Bearer ${TOKEN}`) return void res.writeHead(401).end("{}");
    const url = new URL(req.url!, "http://x");
    const p = url.searchParams.get("page") ?? "1";
    const addr = server.address() as { port: number };
    if (p === "1") res.setHeader("link", `<http://127.0.0.1:${addr.port}/user/repos?page=2>; rel="next"`);
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify(p === "1" ? [{ full_name: "org/b" }] : [{ full_name: "org/a" }]));
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  try {
    const { port } = server.address() as { port: number };
    const run = (token: string) =>
      new Promise<{ code: number | null; out: string; err: string }>((resolve) => {
        const child = spawn(process.execPath, ["--disable-warning=ExperimentalWarning", join(files, "repo-list.mts"), "--print"], {
          env: { PATH: process.env.PATH, GITHUB_TOKEN: token, REPOS_API_URL: `http://127.0.0.1:${port}` },
          stdio: ["ignore", "pipe", "pipe"],
        });
        let out = "";
        let err = "";
        child.stdout.on("data", (d) => (out += d));
        child.stderr.on("data", (d) => (err += d));
        child.on("close", (code) => resolve({ code, out, err }));
      });
    const ok = await run(TOKEN);
    assert.equal(ok.code, 0, ok.err);
    assert.equal(ok.out, "org/a\norg/b\n");
    const bad = await run("github_pat_WRONG");
    assert.equal(bad.code, 1);
    assert.match(bad.err, /HTTP 401/);
    assert.ok(!bad.err.includes("github_pat_WRONG"));
  } finally {
    server.close();
  }
});

// --- repo-sync.sh against local repos (file:// stands in for the GitHub host) ---

function git(cwd: string, ...args: string[]) {
  return execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "init.defaultBranch=main", ...args], { cwd, encoding: "utf8" }).trim();
}

function makeRemote(root: string, repo: string, files: Record<string, string>): string {
  const work = join(root, "work", repo);
  execFileSync("mkdir", ["-p", work]);
  git(work, "init", "-q");
  for (const [f, body] of Object.entries(files)) writeFileSync(join(work, f), body);
  git(work, "add", ".");
  git(work, "commit", "-qm", "init");
  execFileSync("mkdir", ["-p", join(root, "remote", dirname(repo))]);
  git(root, "clone", "-q", "--bare", work, join(root, "remote", `${repo}.git`));
  return git(work, "rev-parse", "HEAD");
}

function sync(root: string, env: Record<string, string>) {
  const r = spawnSync("sh", [join(files, "repo-sync.sh")], {
    encoding: "utf8",
    env: {
      PATH: process.env.PATH,
      GITHUB_TOKEN: TOKEN,
      REPOS_DIR: join(root, "repos"),
      REPOS_CACHE_DIR: join(root, "cache"),
      REPOS_BASE_URL: `file://${join(root, "remote")}`,
      REPOS_SYNC_ONCE: "1",
      ...env,
    },
  });
  return { code: r.status, log: r.stdout + r.stderr };
}

function grepTree(dir: string, needle: string): string[] {
  const hits: string[] = [];
  for (const e of readdirSync(dir, { withFileTypes: true, recursive: true })) {
    if (!e.isFile()) continue;
    const p = join(e.parentPath, e.name);
    if (readFileSync(p).includes(needle)) hits.push(p);
  }
  return hits;
}

test("repo-sync.sh checks out listed repos without .git, symlinks or the token", () => {
  const root = mkdtempSync(join(tmpdir(), "repo-sync-"));
  try {
    const sha = makeRemote(root, "acme/widgets", { "a.txt": "hello\n" });
    // A symlink in a repo must not become a way out of /repos.
    const work = join(root, "work", "acme/widgets");
    execFileSync("ln", ["-s", "/etc/passwd", join(work, "leak")]);
    git(work, "add", ".");
    git(work, "commit", "-qm", "link");
    git(work, "push", "-q", join(root, "remote", "acme/widgets.git"), "main");
    const head = git(work, "rev-parse", "HEAD");
    assert.notEqual(head, sha);

    const first = sync(root, { REPOS_LIST: "acme/widgets\n../etc" });
    assert.equal(first.code, 1, first.log); // ../etc is refused
    assert.match(first.log, new RegExp(`acme/widgets ${head} updated`));
    assert.match(first.log, /\.\.\/etc: not an owner\/name; skipped/);
    const tree = join(root, "repos", "acme", "widgets");
    assert.equal(readFileSync(join(tree, "a.txt"), "utf8"), "hello\n");
    assert.equal(existsSync(join(tree, ".git")), false);
    assert.equal(readFileSync(join(tree, "leak"), "utf8"), "/etc/passwd"); // a plain file, not a link

    const again = sync(root, { REPOS_LIST: "acme/widgets" });
    assert.equal(again.code, 0, again.log);
    assert.match(again.log, /acme\/widgets \w+ unchanged/);

    assert.ok(!first.log.includes(TOKEN) && !again.log.includes(TOKEN));
    assert.deepEqual(grepTree(root, TOKEN), []);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("repo-sync.sh with no list syncs what the token can read and removes what it no longer can", () => {
  const root = mkdtempSync(join(tmpdir(), "repo-sync-"));
  try {
    makeRemote(root, "acme/one", { "one.txt": "1\n" });
    makeRemote(root, "other/two", { "two.txt": "2\n" });
    const listFile = join(root, "list");
    const discover = { REPOS_LIST: "", REPOS_LIST_CMD: `cat ${listFile}` };

    writeFileSync(listFile, "acme/one\nother/two\n");
    const both = sync(root, discover);
    assert.equal(both.code, 0, both.log);
    assert.match(both.log, /token can read 2 repo\(s\)/);
    assert.ok(existsSync(join(root, "repos", "acme", "one", "one.txt")));
    assert.ok(existsSync(join(root, "repos", "other", "two", "two.txt")));

    // Access to other/two revoked: its checkout, cache and owner dir go.
    writeFileSync(listFile, "acme/one\n");
    const revoked = sync(root, discover);
    assert.equal(revoked.code, 0, revoked.log);
    assert.match(revoked.log, /other\/two removed \(no longer listed\)/);
    assert.equal(existsSync(join(root, "repos", "other")), false);
    assert.equal(existsSync(join(root, "cache", "other", "two.git")), false);
    assert.ok(existsSync(join(root, "repos", "acme", "one", "one.txt")));

    // Dot-prefixed repo names are ordinary repos: never taken for staging,
    // and pruned like any other when access goes.
    makeRemote(root, "acme/.github", { "dot.txt": "d\n" });
    makeRemote(root, "acme/.one.sync", { "sync.txt": "s\n" });
    makeRemote(root, "acme/.one.old", { "old.txt": "o\n" });
    writeFileSync(listFile, "acme/.github\nacme/.one.old\nacme/.one.sync\nacme/one\n");
    const dots = sync(root, discover);
    assert.equal(dots.code, 0, dots.log);
    // Update acme/one so it is swapped in again next to its dot-named peers.
    const work = join(root, "work", "acme/one");
    writeFileSync(join(work, "more.txt"), "m\n");
    git(work, "add", ".");
    git(work, "commit", "-qm", "more");
    git(work, "push", "-q", join(root, "remote", "acme/one.git"), "main");
    const swapped = sync(root, discover);
    assert.equal(swapped.code, 0, swapped.log);
    assert.match(swapped.log, /acme\/one \w+ updated/);
    assert.ok(existsSync(join(root, "repos", "acme", "one", "more.txt")));
    assert.ok(existsSync(join(root, "repos", "acme", ".github", "dot.txt")));
    assert.ok(existsSync(join(root, "repos", "acme", ".one.sync", "sync.txt")));
    assert.ok(existsSync(join(root, "repos", "acme", ".one.old", "old.txt")));
    writeFileSync(listFile, "acme/one\n");
    const undotted = sync(root, discover);
    assert.equal(undotted.code, 0, undotted.log);
    assert.match(undotted.log, /acme\/\.github removed/);
    assert.deepEqual(readdirSync(join(root, "repos", "acme")), ["one"]);

    // A failed listing (GitHub down, token expired) removes nothing.
    const failed = sync(root, { REPOS_LIST: "", REPOS_LIST_CMD: "false" });
    assert.equal(failed.code, 1, failed.log);
    assert.match(failed.log, /listing repos failed, keeping current checkouts/);
    assert.ok(existsSync(join(root, "repos", "acme", "one", "one.txt")));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
