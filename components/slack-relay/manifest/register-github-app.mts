#!/usr/bin/env node
// Registers the read-only GitHub App for slack-relay's repos sidecar
// (repos.app) and stores its credentials, without printing them.
//
//   node register-github-app.mts --org example-org --k8s-namespace agent-relay
//   node register-github-app.mts --org example-org --gcp-project example-project
//   node register-github-app.mts --user --out-dir ./github-app   # files, mode 0600
//
// Run it as a GitHub organization owner (or, with --user, as the account that
// owns the repositories), on a machine with a browser. It
//   1. serves the app manifest on http://127.0.0.1:<port>/ and opens it: the
//      browser posts it to GitHub's "Create GitHub App" page;
//   2. receives the one-time code on /created and converts it
//      (POST /app-manifests/{code}/conversions) into the app ID and private key;
//   3. writes them to every store asked for: --k8s-namespace (Secret
//      slack-relay-github-app, keys app-id, private-key, installation-id, via
//      kubectl), --gcp-project (Secret Manager secrets github-app-id,
//      github-app-private-key, github-app-installation-id, via gcloud),
//      --out-dir (files);
//   4. opens the app's install page, receives the installation ID on
//      /installed and stores it too;
//   5. verifies: mints an installation token and lists the repositories the
//      installation can read (names only).
//
// Other subcommands, for a manual flow:
//   manifest            print the manifest JSON
//   form                print a self-contained HTML form that registers the app
//                       (no callback: generate a private key on the app's page)
//   exchange --code C   convert a code from the redirect and store the result
//
// GitHub Enterprise Server: --github-url https://ghe.example.com (the API is
// <url>/api/v3 unless --api-url says otherwise).
// Needs Node 22.18+ (type stripping); no dependencies.

import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";
import { appJwt, findInstallation, installationToken, loadKey } from "../../../charts/slack-relay/files/github-app.mts";
import { listRepos } from "../../../charts/slack-relay/files/repo-list.mts";

type Init = { method?: string; headers: Record<string, string>; body?: string };
export type Fetch = (url: string, init: Init) => Promise<Response>;

const here = dirname(fileURLToPath(import.meta.url));
const OWNER = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/;

/** What the stores hold. */
export type Credentials = { appId: string; privateKey: string; installationId?: string };

export interface Store {
  label: string;
  put(c: Credentials): Promise<void>;
}

/** Runs a command with `stdin` as its input; secrets go only through stdin. */
export type Runner = (cmd: string, args: string[], stdin?: string) => Promise<{ code: number; stdout: string; stderr: string }>;

export const run: Runner = (cmd, args, stdin) =>
  new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", reject);
    child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
    child.stdin.end(stdin ?? "");
  });

// ---- URLs and the manifest ----

export function githubBase(url: string): string {
  const u = new URL(url);
  if (u.protocol !== "https:" && u.protocol !== "http:") throw new Error("--github-url must be an http(s) URL");
  if (u.username || u.password || u.search || u.hash) throw new Error("--github-url must be a plain base URL");
  return u.href.replace(/\/+$/, "");
}

/** api.github.com for github.com, <base>/api/v3 for GitHub Enterprise Server. */
export function apiBase(github: string, override = ""): string {
  if (override) return githubBase(override);
  return new URL(github).host === "github.com" ? "https://api.github.com" : `${github}/api/v3`;
}

/** GitHub's "register an app from a manifest" page for an organization, or the signed-in user. */
export function newAppUrl(github: string, org: string, state: string): string {
  if (org && !OWNER.test(org)) throw new Error(`--org ${JSON.stringify(org)} is not a GitHub organization name`);
  const path = org ? `/organizations/${org}/settings/apps/new` : "/settings/apps/new";
  return `${github}${path}?state=${encodeURIComponent(state)}`;
}

export function buildManifest(opts: { name: string; callback?: string }): Record<string, unknown> {
  const m = JSON.parse(readFileSync(join(here, "github-app-manifest.json"), "utf8")) as Record<string, unknown>;
  if (!opts.name || opts.name.length > 34) throw new Error("--name must be 1 to 34 characters (GitHub's limit)");
  m.name = opts.name;
  if (opts.callback) {
    m.redirect_url = `${opts.callback}/created`;
    m.setup_url = `${opts.callback}/installed`;
    m.setup_on_update = true;
  }
  return m;
}

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** A self-contained page that posts the manifest to GitHub (submitted on load when `auto`). */
export function formHtml(action: string, manifest: Record<string, unknown>, auto: boolean): string {
  return `<!doctype html>
<meta charset="utf-8">
<title>Register the GitHub App</title>
<body style="font: 16px system-ui, sans-serif; max-width: 40rem; margin: 3rem auto; padding: 0 1rem">
<h1 style="font-size: 1.4rem">Register the read-only GitHub App</h1>
<p>GitHub asks you to confirm the name; the app gets read-only Contents and Metadata access and no webhook.</p>
<form id="f" method="post" action="${esc(action)}">
<input type="hidden" name="manifest" value="${esc(JSON.stringify(manifest))}">
<button type="submit" style="font-size: 1rem; padding: .6rem 1.2rem">Create the GitHub App on GitHub</button>
</form>
${auto ? '<script>document.getElementById("f").submit()</script>' : ""}
</body>
`;
}

// ---- The manifest conversion ----

export type Conversion = { appId: string; slug: string; name: string; htmlUrl: string; privateKey: string };

/** POST /app-manifests/{code}/conversions: the new app's ID and private key (and secrets this sidecar has no use for). */
export async function exchangeCode(api: string, code: string, fetchImpl: Fetch = fetch): Promise<Conversion> {
  if (!/^[A-Za-z0-9_-]{1,200}$/.test(code)) throw new Error("the code from GitHub is malformed");
  const res = await fetchImpl(`${api}/app-manifests/${code}/conversions`, {
    method: "POST",
    headers: { accept: "application/vnd.github+json", "x-github-api-version": "2022-11-28", "user-agent": "slack-relay-register-github-app" },
  });
  if (!res.ok) {
    const hint = res.status === 404 ? " (the code is used or older than an hour: register again)" : "";
    throw new Error(`POST /app-manifests/{code}/conversions: HTTP ${res.status}${hint}`);
  }
  const b = (await res.json()) as { id?: unknown; slug?: unknown; name?: unknown; html_url?: unknown; pem?: unknown };
  if (typeof b.id !== "number" || typeof b.pem !== "string" || typeof b.slug !== "string") {
    throw new Error("POST /app-manifests/{code}/conversions: the response has no app ID, slug or private key");
  }
  loadKey(b.pem); // an RSA private key, or throw before storing anything
  return {
    appId: String(b.id),
    slug: b.slug,
    name: typeof b.name === "string" ? b.name : b.slug,
    htmlUrl: typeof b.html_url === "string" ? b.html_url : "",
    privateKey: b.pem,
  };
}

/** Where to install the app: <html_url>/installations/new, kept on the GitHub host. */
export function installUrl(github: string, c: Pick<Conversion, "slug" | "htmlUrl">): string {
  let page = `${github}/apps/${encodeURIComponent(c.slug)}`;
  if (c.htmlUrl) {
    const u = new URL(c.htmlUrl);
    if (u.origin === new URL(github).origin) page = u.href.replace(/\/+$/, "");
  }
  return `${page}/installations/new`;
}

// ---- Stores ----

const SECRET = /^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$/;

/** A Kubernetes Secret (keys app-id, private-key, installation-id), by server-side apply from stdin. */
export function k8sStore(namespace: string, name = "slack-relay-github-app", runner: Runner = run, context = ""): Store {
  if (!SECRET.test(namespace) || !SECRET.test(name)) throw new Error("--k8s-namespace and --k8s-secret must be Kubernetes names");
  return {
    label: `Kubernetes Secret ${namespace}/${name}`,
    async put(c) {
      const data: Record<string, string> = {
        "app-id": Buffer.from(c.appId).toString("base64"),
        "private-key": Buffer.from(c.privateKey).toString("base64"),
      };
      if (c.installationId) data["installation-id"] = Buffer.from(c.installationId).toString("base64");
      const secret = {
        apiVersion: "v1",
        kind: "Secret",
        type: "Opaque",
        metadata: { name, namespace, labels: { "app.kubernetes.io/part-of": "slack-relay" } },
        data,
      };
      // Server-side apply keeps no last-applied copy of the key in an annotation.
      const args = [...(context ? ["--context", context] : []), "apply", "--server-side", "--force-conflicts", "--field-manager=register-github-app", "-f", "-"];
      const r = await runner("kubectl", args, JSON.stringify(secret));
      if (r.code !== 0) throw new Error(`kubectl apply of Secret ${namespace}/${name} failed: ${r.stderr.trim().split("\n").pop()}`);
    },
  };
}

/** Google Secret Manager: github-app-id, github-app-private-key, github-app-installation-id, a new version each time. */
export function gcpStore(project: string, runner: Runner = run, prefix = "github-app"): Store {
  if (!/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(project)) throw new Error("--gcp-project must be a Google Cloud project ID");
  const put1 = async (secret: string, value: string) => {
    const p = ["--project", project];
    const exists = (await runner("gcloud", ["secrets", "describe", secret, ...p, "--format=value(name)"])).code === 0;
    const args = exists
      ? ["secrets", "versions", "add", secret, ...p, "--data-file=-"]
      : ["secrets", "create", secret, ...p, "--replication-policy=automatic", "--labels=app=slack-relay", "--data-file=-"];
    const r = await runner("gcloud", args, value);
    if (r.code !== 0) throw new Error(`gcloud ${args.slice(0, 3).join(" ")} failed: ${r.stderr.trim().split("\n").pop()}`);
  };
  return {
    label: `Secret Manager in ${project} (${prefix}-id, ${prefix}-private-key, ${prefix}-installation-id)`,
    async put(c) {
      await put1(`${prefix}-id`, c.appId);
      await put1(`${prefix}-private-key`, c.privateKey);
      if (c.installationId) await put1(`${prefix}-installation-id`, c.installationId);
    },
  };
}

/** Files app-id, private-key, installation-id in a directory, mode 0600. */
export function dirStore(dir: string): Store {
  return {
    label: `files in ${dir}`,
    async put(c) {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      const write = (f: string, v: string) => {
        writeFileSync(join(dir, f), v, { mode: 0o600 });
        chmodSync(join(dir, f), 0o600);
      };
      write("app-id", c.appId);
      write("private-key", c.privateKey);
      if (c.installationId) write("installation-id", c.installationId);
    },
  };
}

// ---- Verification ----

/** Mints an installation token and lists what the installation can read: proof the stored credentials work. */
export async function verify(api: string, c: Credentials, fetchImpl: Fetch = fetch): Promise<{ installationId: string; repos: string[] }> {
  const jwt = appJwt(c.appId, loadKey(c.privateKey));
  const installationId = await findInstallation(api, jwt, c.installationId ?? "", fetchImpl);
  const { token } = await installationToken(api, jwt, installationId, fetchImpl);
  const repos = await listRepos(api, token, fetchImpl as (u: string, i: { headers: Record<string, string> }) => Promise<Response>, "app");
  return { installationId, repos };
}

// ---- The guided flow ----

export type RegisterOptions = {
  github: string;
  api: string;
  org: string;
  name: string;
  stores: Store[];
  port?: number;
  timeoutMs?: number;
  open?: (url: string) => void;
  log?: (line: string) => void;
  fetchImpl?: Fetch;
  /** Called once the server listens, with its base URL (tests drive the browser side with it). */
  onListening?: (base: string) => void;
};

const page = (title: string, body: string) =>
  `<!doctype html><meta charset="utf-8"><title>${esc(title)}</title><body style="font: 16px system-ui, sans-serif; max-width: 40rem; margin: 3rem auto; padding: 0 1rem"><h1 style="font-size: 1.4rem">${esc(title)}</h1>${body}</body>`;

export function register(o: RegisterOptions): Promise<{ appId: string; slug: string; installationId: string; repos: string[] }> {
  const log = o.log ?? ((l: string) => process.stderr.write(`${l}\n`));
  const fetchImpl = o.fetchImpl ?? fetch;
  const state = randomBytes(16).toString("hex");
  let creds: Credentials | null = null;
  let app: Conversion | null = null;
  let busy = false;

  return new Promise((resolve, reject) => {
    let timer: NodeJS.Timeout | undefined;
    const finish = (err: Error | null, value?: { appId: string; slug: string; installationId: string; repos: string[] }) => {
      clearTimeout(timer);
      server.close();
      server.closeAllConnections?.();
      if (err) reject(err);
      else resolve(value!);
    };
    const send = (res: ServerResponse, status: number, html: string) => {
      res.writeHead(status, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "referrer-policy": "no-referrer" });
      res.end(html);
    };

    const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
      const base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
      const url = new URL(req.url ?? "/", base);
      try {
        if (req.method !== "GET") return send(res, 405, page("Not allowed", ""));
        if (url.pathname === "/") {
          const manifest = buildManifest({ name: o.name, callback: base });
          return send(res, 200, formHtml(newAppUrl(o.github, o.org, state), manifest, true));
        }
        if (url.pathname === "/created") {
          if (url.searchParams.get("state") !== state) return send(res, 400, page("Wrong state", "<p>This page was not opened by this registration. Start again.</p>"));
          if (app || busy) return send(res, 409, page("Already registered", "<p>The app was already created; install it from the terminal's link.</p>"));
          busy = true;
          app = await exchangeCode(o.api, url.searchParams.get("code") ?? "", fetchImpl);
          creds = { appId: app.appId, privateKey: app.privateKey };
          for (const s of o.stores) {
            await s.put(creds);
            log(`stored the app ID and private key: ${s.label}`);
          }
          busy = false;
          const install = installUrl(o.github, app);
          log(`created GitHub App ${app.name} (ID ${app.appId}). Install it on the repositories' owner: ${install}`);
          o.open?.(install);
          res.writeHead(303, { location: install, "cache-control": "no-store" });
          return res.end();
        }
        if (url.pathname === "/installed") {
          if (!app || !creds) return send(res, 409, page("Not yet", "<p>Create the app first.</p>"));
          const id = url.searchParams.get("installation_id") ?? "";
          if (!/^[0-9]{1,20}$/.test(id)) return send(res, 400, page("No installation", "<p>GitHub sent no installation ID.</p>"));
          // An installation ID from the browser is unauthenticated: it is
          // stored only after a token for it is minted with the app's key.
          const checked = await verify(o.api, { ...creds, installationId: id }, fetchImpl);
          creds = { ...creds, installationId: id };
          for (const s of o.stores) {
            await s.put(creds);
            log(`stored the installation ID: ${s.label}`);
          }
          log(`verified: installation ${id} can read ${checked.repos.length} repositor${checked.repos.length === 1 ? "y" : "ies"}`);
          for (const r of checked.repos) log(`  ${r}`);
          send(res, 200, page("Done", `<p>The app is installed and its credentials are stored. ${checked.repos.length} repositories are readable. You can close this tab.</p>`));
          return finish(null, { appId: app.appId, slug: app.slug, installationId: id, repos: checked.repos });
        }
        send(res, 404, page("Not found", ""));
      } catch (err) {
        busy = false;
        // Messages never carry the key, the JWT or a token (see github-app.mts).
        const msg = (err as Error).message;
        log(`error: ${msg}`);
        send(res, 500, page("Something went wrong", `<p>${esc(msg)}</p><p>See the terminal.</p>`));
        if (url.pathname === "/created") finish(err as Error);
      }
    });
    server.on("error", reject);
    server.listen(o.port ?? 0, "127.0.0.1", () => {
      const base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
      timer = setTimeout(() => finish(new Error("timed out waiting for GitHub (the manifest code is valid for an hour)")), o.timeoutMs ?? 60 * 60_000);
      log(`open ${base}/ to register the GitHub App${o.org ? ` for the ${o.org} organization` : ""} (you must be an owner)`);
      o.onListening?.(base);
      o.open?.(`${base}/`);
    });
  });
}

function openBrowser(url: string): void {
  const [cmd, args] =
    process.platform === "darwin" ? ["open", [url]] : process.platform === "win32" ? ["cmd", ["/c", "start", "", url]] : ["xdg-open", [url]];
  try {
    spawn(cmd as string, args as string[], { stdio: "ignore", detached: true }).on("error", () => {}).unref();
  } catch {
    // the URL is in the terminal
  }
}

function valuesHint(stores: Store[]): string {
  return [
    "",
    "Helm values (the chart reads app-id, private-key and installation-id from this Secret):",
    "  repos:",
    "    enabled: true",
    "    app:",
    "      privateKey: { name: slack-relay-github-app, key: private-key }",
    ...(stores.some((s) => s.label.startsWith("Secret Manager"))
      ? ["", "From Secret Manager, sync the three secrets into a Kubernetes Secret slack-relay-github-app", "with keys app-id, private-key and installation-id (e.g. with External Secrets)."]
      : []),
  ].join("\n");
}

async function main(argv: string[]): Promise<void> {
  const { values: a, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      name: { type: "string", default: "Agent Relay repos" },
      org: { type: "string", default: "" },
      user: { type: "boolean", default: false },
      "github-url": { type: "string", default: "https://github.com" },
      "api-url": { type: "string", default: "" },
      "k8s-namespace": { type: "string" },
      "k8s-secret": { type: "string", default: "slack-relay-github-app" },
      "k8s-context": { type: "string", default: "" },
      "gcp-project": { type: "string" },
      "out-dir": { type: "string" },
      code: { type: "string" },
      port: { type: "string", default: "0" },
      "no-open": { type: "boolean", default: false },
      help: { type: "boolean", short: "h", default: false },
    },
  });
  const cmd = positionals[0] ?? "register";
  if (a.help) {
    process.stdout.write(readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").filter((l) => l.startsWith("//")).map((l) => l.slice(3)).join("\n") + "\n");
    return;
  }
  const github = githubBase(a["github-url"]!);
  const api = apiBase(github, a["api-url"]);
  if (cmd === "manifest") {
    process.stdout.write(`${JSON.stringify(buildManifest({ name: a.name! }), null, 2)}\n`);
    return;
  }
  if (!a.org === !a.user) throw new Error("say whose app it is: --org <organization> or --user");
  if (cmd === "form") {
    const action = newAppUrl(github, a.org!, randomBytes(16).toString("hex"));
    process.stdout.write(formHtml(action, buildManifest({ name: a.name! }), false));
    return;
  }
  const stores: Store[] = [];
  if (a["k8s-namespace"]) stores.push(k8sStore(a["k8s-namespace"], a["k8s-secret"], run, a["k8s-context"]));
  if (a["gcp-project"]) stores.push(gcpStore(a["gcp-project"]));
  if (a["out-dir"]) stores.push(dirStore(a["out-dir"]));
  if (stores.length === 0) throw new Error("say where to store the credentials: --k8s-namespace, --gcp-project and/or --out-dir");
  if (cmd === "exchange") {
    const app = await exchangeCode(api, a.code ?? "");
    for (const s of stores) await s.put({ appId: app.appId, privateKey: app.privateKey });
    process.stderr.write(`created GitHub App ${app.name} (ID ${app.appId}); stored in ${stores.map((s) => s.label).join("; ")}\nInstall it: ${installUrl(github, app)}\n`);
    return;
  }
  if (cmd !== "register") throw new Error(`unknown command ${cmd}: register, exchange, manifest or form`);
  const port = Number(a.port);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error("--port must be a port number");
  const done = await register({ github, api, org: a.org!, name: a.name!, stores, port, open: a["no-open"] ? undefined : openBrowser });
  process.stderr.write(`\nDone: app ${done.slug} (ID ${done.appId}), installation ${done.installationId}, ${done.repos.length} repositories.\n${valuesHint(stores)}\n`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main(process.argv.slice(2)).catch((err: Error) => {
    process.stderr.write(`register-github-app: ${err.message}\n`);
    process.exit(1);
  });
}
