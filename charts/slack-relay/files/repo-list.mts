// Lists every repository a GitHub token can read, for repo-sync.sh when
// repos.list is empty: `node repo-list.mts --print` writes one owner/name per
// line. With a fine-grained token, that is the token's repository selection.
//
// Reads GITHUB_TOKEN and REPOS_API_URL (https://api.github.com, or
// https://<ghe-host>/api/v3) from the environment. The token goes only in the
// Authorization header to REPOS_API_URL's origin, never to stdout or stderr.
// Runs on Node's type stripping: erasable TypeScript only, no dependencies.

const NAME = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const MAX_PAGES = 100;

type Fetch = (url: string, init: { headers: Record<string, string> }) => Promise<Response>;

/** The URL of the rel="next" page in a Link header, if it is on the API's origin. */
export function nextLink(link: string | null, api: string): string | null {
  for (const part of (link ?? "").split(",")) {
    const m = /^\s*<([^>]+)>\s*;(.*)$/.exec(part);
    if (!m || !/\brel="?next"?/.test(m[2]!)) continue;
    const next = new URL(m[1]!, api);
    // Never follow a link that would carry the token to another host.
    if (next.origin !== new URL(api).origin) throw new Error(`refusing next page on another origin (${next.origin})`);
    return next.href;
  }
  return null;
}

/** Every owner/name the token can read (GET /user/repos, all pages), sorted. */
export async function listRepos(api: string, token: string, fetchImpl: Fetch = fetch): Promise<string[]> {
  const base = api.replace(/\/+$/, "");
  let url: string | null = `${base}/user/repos?per_page=100&affiliation=owner,collaborator,organization_member`;
  const names = new Set<string>();
  for (let page = 1; url; page++) {
    if (page > MAX_PAGES) throw new Error(`more than ${MAX_PAGES} pages of repositories`);
    const res = await fetchImpl(url, {
      headers: {
        authorization: `Bearer ${token}`,
        accept: "application/vnd.github+json",
        "x-github-api-version": "2022-11-28",
        "user-agent": "slack-relay-repo-sync",
      },
    });
    if (!res.ok) throw new Error(`GET /user/repos page ${page}: HTTP ${res.status}`);
    const body: unknown = await res.json();
    if (!Array.isArray(body)) throw new Error(`GET /user/repos page ${page}: not a list`);
    for (const r of body as Array<{ full_name?: unknown }>) {
      if (typeof r?.full_name === "string" && NAME.test(r.full_name) && !/(^|\/)\.\.?(\/|$)/.test(r.full_name)) names.add(r.full_name);
    }
    url = nextLink(res.headers.get("link"), base);
  }
  return [...names].sort();
}

if (process.argv.includes("--print")) {
  const token = process.env.GITHUB_TOKEN ?? "";
  const api = process.env.REPOS_API_URL || "https://api.github.com";
  try {
    if (!token) throw new Error("GITHUB_TOKEN is not set");
    const names = await listRepos(api, token);
    process.stdout.write(names.map((n) => `${n}\n`).join(""));
  } catch (err) {
    process.stderr.write(`${(err as Error).message.split(token || "\0").join("***")}\n`);
    process.exit(1);
  }
}
