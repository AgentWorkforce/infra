// GitHub App auth for repo-sync.sh (repos.app): `node github-app.mts token`
// writes "<installation token> <expiry, Unix seconds>" to stdout, one line.
//
// Mints a short-lived JWT (RS256) from the app's private key, finds the
// installation (GITHUB_APP_INSTALLATION_ID, or the app's only installation),
// and exchanges the JWT for an installation access token narrowed to
// contents:read and metadata:read. GitHub expires the token after an hour;
// repo-sync.sh asks for a new one before that.
//
// Environment: GITHUB_APP_ID (app ID or client ID), GITHUB_APP_PRIVATE_KEY_FILE
// (PEM), GITHUB_APP_INSTALLATION_ID (optional), REPOS_API_URL
// (https://api.github.com, or https://<ghe-host>/api/v3).
//
// The private key is read from a file only this sidecar mounts. The key, the
// JWT and the token go only in the Authorization header to REPOS_API_URL's
// origin; the token goes to stdout for repo-sync.sh and nowhere else. Errors
// carry the HTTP status and GitHub's message, with any secret masked.
// Runs on Node's type stripping: erasable TypeScript only, no dependencies.

import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import { nextLink } from "./repo-list.mts";

type Init = { method?: string; headers: Record<string, string>; body?: string };
type Fetch = (url: string, init: Init) => Promise<Response>;

const MAX_PAGES = 100;
/** The permissions asked for on every token, whatever else the app may hold. */
export const TOKEN_PERMISSIONS = { contents: "read", metadata: "read" } as const;

const b64url = (b: Buffer | string) => Buffer.from(b).toString("base64url");

/** The app's private key; refuses anything but an RSA private key. */
export function loadKey(pem: string): KeyObject {
  let key: KeyObject;
  try {
    key = createPrivateKey(pem);
  } catch {
    // Never echo the input: it is the key.
    throw new Error("the GitHub App private key is not a PEM private key");
  }
  if (key.asymmetricKeyType !== "rsa") throw new Error("the GitHub App private key must be an RSA key");
  return key;
}

/** The JWT that authenticates as the app: RS256, issued 60 s ago (clock skew), valid for 9 more minutes. */
export function appJwt(appId: string, key: KeyObject, nowSeconds = Math.floor(Date.now() / 1000)): string {
  // GitHub takes the app ID (a number) or the client ID (a string) as iss.
  const iss = /^[0-9]+$/.test(appId) ? Number(appId) : appId;
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(JSON.stringify({ iat: nowSeconds - 60, exp: nowSeconds + 540, iss }));
  const sig = sign("sha256", Buffer.from(`${header}.${claims}`), key);
  return `${header}.${claims}.${b64url(sig)}`;
}

function headers(jwt: string): Record<string, string> {
  return {
    authorization: `Bearer ${jwt}`,
    accept: "application/vnd.github+json",
    "x-github-api-version": "2022-11-28",
    "user-agent": "slack-relay-repo-sync",
  };
}

/** "HTTP <status>" plus GitHub's message, if the body has one. */
async function failure(what: string, res: Response): Promise<Error> {
  let msg = "";
  try {
    const body = (await res.json()) as { message?: unknown };
    if (typeof body?.message === "string") msg = `: ${body.message.slice(0, 200)}`;
  } catch {
    // not JSON
  }
  return new Error(`${what}: HTTP ${res.status}${msg}`);
}

/** The installation to use: `wanted` if set, else the app's only installation (GET /app/installations, all pages). */
export async function findInstallation(api: string, jwt: string, wanted: string, fetchImpl: Fetch = fetch): Promise<string> {
  if (wanted) {
    if (!/^[0-9]+$/.test(wanted)) throw new Error("GITHUB_APP_INSTALLATION_ID must be a number");
    return wanted;
  }
  const base = api.replace(/\/+$/, "");
  let url: string | null = `${base}/app/installations?per_page=100`;
  const found: Array<{ id: string; account: string }> = [];
  for (let page = 1; url; page++) {
    if (page > MAX_PAGES) throw new Error(`more than ${MAX_PAGES} pages of installations`);
    const res = await fetchImpl(url, { headers: headers(jwt) });
    if (!res.ok) throw await failure(`GET /app/installations page ${page}`, res);
    const body: unknown = await res.json();
    if (!Array.isArray(body)) throw new Error(`GET /app/installations page ${page}: not a list`);
    for (const i of body as Array<{ id?: unknown; account?: { login?: unknown } }>) {
      if (typeof i?.id === "number" || (typeof i?.id === "string" && /^[0-9]+$/.test(i.id))) {
        found.push({ id: String(i.id), account: typeof i.account?.login === "string" ? i.account.login : "?" });
      }
    }
    url = nextLink(res.headers.get("link"), base);
  }
  if (found.length === 0) {
    throw new Error("the GitHub App is not installed anywhere: install it on the organization (or account) that owns the repositories");
  }
  if (found.length > 1) {
    const list = found.map((i) => `${i.id} (${i.account})`).join(", ");
    throw new Error(`the GitHub App has ${found.length} installations (${list}): set repos.app.installationId to one of them`);
  }
  return found[0]!.id;
}

/** An installation access token (POST /app/installations/{id}/access_tokens) and its expiry in Unix seconds. */
export async function installationToken(
  api: string,
  jwt: string,
  installationId: string,
  fetchImpl: Fetch = fetch,
): Promise<{ token: string; expiresAt: number }> {
  if (!/^[0-9]+$/.test(installationId)) throw new Error("installation id must be a number");
  const base = api.replace(/\/+$/, "");
  const res = await fetchImpl(`${base}/app/installations/${installationId}/access_tokens`, {
    method: "POST",
    headers: { ...headers(jwt), "content-type": "application/json" },
    body: JSON.stringify({ permissions: TOKEN_PERMISSIONS }),
  });
  if (!res.ok) throw await failure(`POST /app/installations/${installationId}/access_tokens`, res);
  const body = (await res.json()) as { token?: unknown; expires_at?: unknown };
  const expiresAt = typeof body?.expires_at === "string" ? Math.floor(Date.parse(body.expires_at) / 1000) : NaN;
  if (typeof body?.token !== "string" || !/^[A-Za-z0-9_.-]+$/.test(body.token) || !Number.isFinite(expiresAt)) {
    throw new Error(`POST /app/installations/${installationId}/access_tokens: no token in the response`);
  }
  return { token: body.token, expiresAt };
}

/** Masks every secret in a message. */
export function mask(message: string, secrets: string[]): string {
  let out = message;
  for (const s of secrets) if (s) out = out.split(s).join("***");
  return out;
}

if (process.argv[2] === "token") {
  const secrets: string[] = [];
  try {
    const appId = process.env.GITHUB_APP_ID ?? "";
    const keyFile = process.env.GITHUB_APP_PRIVATE_KEY_FILE ?? "";
    const api = process.env.REPOS_API_URL || "https://api.github.com";
    if (!/^([0-9]+|Iv[0-9A-Za-z.]+)$/.test(appId)) throw new Error("GITHUB_APP_ID must be the app's numeric ID (or its client ID)");
    if (!keyFile) throw new Error("GITHUB_APP_PRIVATE_KEY_FILE is not set");
    let pem: string;
    try {
      pem = readFileSync(keyFile, "utf8");
    } catch (err) {
      throw new Error(`cannot read the GitHub App private key file (${(err as NodeJS.ErrnoException).code ?? "error"})`);
    }
    secrets.push(pem.trim());
    const jwt = appJwt(appId, loadKey(pem));
    secrets.push(jwt);
    const id = await findInstallation(api, jwt, process.env.GITHUB_APP_INSTALLATION_ID ?? "");
    const { token, expiresAt } = await installationToken(api, jwt, id);
    secrets.push(token);
    process.stdout.write(`${token} ${expiresAt}\n`);
  } catch (err) {
    process.stderr.write(`${mask((err as Error).message, secrets)}\n`);
    process.exit(1);
  }
}
