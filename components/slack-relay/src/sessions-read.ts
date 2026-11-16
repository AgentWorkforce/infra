// Read access to Agent Relay Sessions for the hosted agents, as the agents.
//
// relaygate gates every read on the principal named by X-Relaygate-Token (the agent's rg_ token, so its group, the
// pit) and forwards the Sessions read credential in Authorization unchanged (contract "Session uploads"). The read
// credential is a short-lived rth_at_read_ token relay-control mints for the uploader user (the same user the
// enrollment key belongs to). Two things keep it from widening what an agent can read:
//
//  - it never leaves this process. The agents' MCP server (sessions-mcp.ts) calls the loopback proxy below with the
//    agent's own rg_ token; the proxy adds the read credential and forwards to relaygate. Nothing the agent can
//    read (its .mcp.json, the MCP server's argv or environment) contains it;
//  - the proxy always sends the agent's rg_ token in X-Relaygate-Token, so relaygate decides as the agent. The
//    upstream read API also scopes by the token's user, so what an agent sees is at most what both may read.
//
// Without X-Relaygate-Token relaygate would take the read token itself as the principal (the uploader user), which
// is why the token must never reach an agent: it would read as the user, not as the pit.
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { CredentialError, type SessionsCredential } from "./sessions-upload.ts";

/** A cached read token from relay-control, refreshed (or minted again) before it expires. In memory only. */
export class SessionReadCredential {
  readonly #controlUrl: string;
  readonly #workspaceId: string;
  /** The uploader user's relay-control session (sh_at_), shared with the uploader so refreshes never race. */
  readonly #control: SessionsCredential;
  readonly #fetch: typeof fetch;
  readonly #label: string;
  #pair: { access: string; accessExp: number; refresh?: string; refreshExp: number } | null = null;
  #pending: Promise<string> | null = null;

  constructor(o: { controlUrl: string; workspaceId: string; control: SessionsCredential; fetch?: typeof fetch; label?: string }) {
    this.#controlUrl = o.controlUrl.replace(/\/$/, "");
    this.#workspaceId = o.workspaceId;
    this.#control = o.control;
    this.#fetch = o.fetch ?? globalThis.fetch;
    this.#label = o.label ?? "slack-relay agent session reads";
  }

  /** The read token was refused upstream (401): get a new one next time. */
  invalidate(): void {
    if (this.#pair) this.#pair.accessExp = 0;
  }

  get(): Promise<string> {
    this.#pending ??= this.#get().finally(() => (this.#pending = null));
    return this.#pending;
  }

  async #get(): Promise<string> {
    const now = Date.now();
    if (this.#pair && this.#pair.accessExp - now > 60_000) return this.#pair.access;
    let j: any = null;
    if (this.#pair?.refresh && this.#pair.refreshExp - now > 60_000) {
      j = await this.#post("refresh", { refreshToken: this.#pair.refresh });
    }
    j ??= await this.#post("session", { label: this.#label });
    if (!j) throw new CredentialError("relay-control refused a session read credential (the uploader user needs rth:read in the workspace)");
    if (typeof j.accessToken !== "string" || !j.accessToken) throw new CredentialError("relay-control answered without a read token");
    const exp = Date.parse(j.accessTokenExpiresAt ?? "");
    const rexp = Date.parse(j.refreshTokenExpiresAt ?? "");
    this.#pair = {
      access: j.accessToken,
      // Without a stated expiry, use it for at most five minutes.
      accessExp: Number.isFinite(exp) ? exp : now + 5 * 60_000,
      refresh: typeof j.refreshToken === "string" ? j.refreshToken : undefined,
      refreshExp: Number.isFinite(rexp) ? rexp : 0,
    };
    return this.#pair.access;
  }

  /** The JSON answer on 200, null on a refused request (400/401/403/404); anything else throws. */
  async #post(kind: "session" | "refresh", body: unknown, retried = false): Promise<any> {
    const bearer = await this.#control.get();
    if (!bearer) throw new CredentialError("no uploader session to mint read credentials with");
    let res: Response;
    try {
      res = await this.#fetch(`${this.#controlUrl}/api/v1/workspaces/${encodeURIComponent(this.#workspaceId)}/session-read/${kind}`, {
        method: "POST",
        headers: { authorization: `Bearer ${bearer}`, "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(15_000),
      });
    } catch (err) {
      throw new CredentialError(`relay-control unreachable (${(err as Error).name})`);
    }
    if (res.ok) return res.json();
    await res.body?.cancel().catch(() => undefined);
    // The uploader session itself expired or was rotated elsewhere: refresh it once.
    if (res.status === 401 && !retried) {
      this.#control.invalidate();
      return this.#post(kind, body, true);
    }
    if ([400, 401, 403, 404].includes(res.status)) return null;
    throw new CredentialError(`relay-control ${res.status}`);
  }
}

/**
 * The organization's members (id, name, email) from relay-control, so sessions show people, not user ids:
 * GET /api/v1/organizations/<org>/memberships, which any member may call (the uploader user's sh_at_). Cached for
 * `ttlMs`; a failed refresh keeps the last list.
 */
export class MemberDirectory {
  readonly #controlUrl: string;
  readonly #orgId: string;
  readonly #control: SessionsCredential;
  readonly #fetch: typeof fetch;
  readonly #ttlMs: number;
  #cache: { at: number; members: Array<{ id: string; name: string | null; email: string | null }> } | null = null;
  #pending: Promise<Array<{ id: string; name: string | null; email: string | null }>> | null = null;

  constructor(o: { controlUrl: string; orgId: string; control: SessionsCredential; fetch?: typeof fetch; ttlMs?: number }) {
    this.#controlUrl = o.controlUrl.replace(/\/$/, "");
    this.#orgId = o.orgId;
    this.#control = o.control;
    this.#fetch = o.fetch ?? globalThis.fetch;
    this.#ttlMs = o.ttlMs ?? 10 * 60_000;
  }

  list(): Promise<Array<{ id: string; name: string | null; email: string | null }>> {
    if (this.#cache && Date.now() - this.#cache.at < this.#ttlMs) return Promise.resolve(this.#cache.members);
    this.#pending ??= this.#load()
      .catch((err) => {
        if (this.#cache) return this.#cache.members;
        throw err;
      })
      .finally(() => (this.#pending = null));
    return this.#pending;
  }

  async #load(retried = false): Promise<Array<{ id: string; name: string | null; email: string | null }>> {
    const bearer = await this.#control.get();
    if (!bearer) throw new CredentialError("no uploader session to list members with");
    const res = await this.#fetch(`${this.#controlUrl}/api/v1/organizations/${encodeURIComponent(this.#orgId)}/memberships`, {
      headers: { authorization: `Bearer ${bearer}` },
      signal: AbortSignal.timeout(15_000),
    });
    if (res.status === 401 && !retried) {
      await res.body?.cancel().catch(() => undefined);
      this.#control.invalidate();
      return this.#load(true);
    }
    if (!res.ok) {
      await res.body?.cancel().catch(() => undefined);
      throw new CredentialError(`relay-control memberships ${res.status}`);
    }
    const j = (await res.json()) as { memberships?: Array<Record<string, unknown>> };
    const members = (j.memberships ?? []).flatMap((m) =>
      typeof m.userId === "string" ? [{ id: m.userId, name: typeof m.name === "string" ? m.name : null, email: typeof m.email === "string" ? m.email : null }] : [],
    );
    this.#cache = { at: Date.now(), members };
    return members;
  }
}

/** The relaygate read routes the proxy forwards (contract "Session uploads"); anything else is refused. */
const SESSION_ID = "[A-Za-z0-9._:-]{1,200}";
const ROUTES = [
  new RegExp(`^/v1/sessions$`),
  new RegExp(`^/v1/sessions/${SESSION_ID}/(events|turns|metadata|brief|catalog|timing|thread|analysis)$`),
  new RegExp(`^/v1/events$`),
];
const MAX_UPSTREAM_BYTES = 4 * 1024 * 1024;

export interface ReadProxyOptions {
  /** relaygate's Sessions proxy, e.g. http://relaygate:8080/sessions. */
  baseUrl: string;
  workspaceId: string;
  credential: Pick<SessionReadCredential, "get" | "invalidate">;
  /** True when `token` is the rg_ token of an agent this host runs. */
  isAgentToken: (token: string) => boolean;
  /** Who the workspace's user ids are (GET /members); without it, /members answers an empty list. */
  members?: Pick<MemberDirectory, "list">;
  fetch?: typeof fetch;
  log?: (m: string) => void;
}

/**
 * The loopback proxy the agents' MCP servers read through: GET only, the read routes only, authenticated with the
 * agent's own rg_ token, which is forwarded as X-Relaygate-Token next to the host's read credential.
 */
export class SessionsReadProxy {
  readonly #o: Required<Omit<ReadProxyOptions, "members">> & Pick<ReadProxyOptions, "members">;
  #server: Server | null = null;
  url = "";

  constructor(o: ReadProxyOptions) {
    this.#o = { fetch: globalThis.fetch, log: () => {}, ...o, baseUrl: o.baseUrl.replace(/\/$/, "") };
  }

  async listen(port = 0, host = "127.0.0.1"): Promise<string> {
    this.#server = createServer((req, res) => {
      void this.#handle(req, res).catch(() => {
        if (!res.headersSent) res.writeHead(502, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: "sessions_unavailable" }));
      });
    });
    await new Promise<void>((r) => this.#server!.listen(port, host, r));
    const a = this.#server.address() as { port: number };
    this.url = `http://${host}:${a.port}`;
    return this.url;
  }

  close(): Promise<void> {
    return new Promise((r) => (this.#server ? this.#server.close(() => r()) : r()));
  }

  async #handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const send = (status: number, body: unknown) => {
      res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify(body));
    };
    const token = /^Bearer\s+(rg_\S+)$/.exec(req.headers.authorization ?? "")?.[1];
    if (!token || !this.#o.isAgentToken(token)) return send(401, { error: "unknown_agent" });
    if (req.method !== "GET") return send(405, { error: "read_only" });
    const u = new URL(req.url ?? "/", "http://proxy");
    if (u.pathname === "/members") {
      try {
        return send(200, { members: (await this.#o.members?.list()) ?? [] });
      } catch (err) {
        this.#o.log(`sessions read: member names unavailable (${(err as Error).message})`);
        return send(503, { error: "members_unavailable" });
      }
    }
    if (!ROUTES.some((r) => r.test(u.pathname))) return send(404, { error: "route_not_proxied" });
    // The workspace is the host's, never the caller's.
    u.searchParams.set("workspace", this.#o.workspaceId);
    const target = `${this.#o.baseUrl}${u.pathname}?${u.searchParams}`;
    const route = u.pathname.replace(new RegExp(`/${SESSION_ID}/`), "/:id/");
    for (let attempt = 0; ; attempt++) {
      let cred: string;
      try {
        cred = await this.#o.credential.get();
      } catch (err) {
        this.#o.log(`sessions read: no read credential (${(err as Error).message})`);
        return send(503, { error: "sessions_credential_unavailable" });
      }
      let up: Response;
      try {
        up = await this.#o.fetch(target, {
          headers: { "x-relaygate-token": token, authorization: `Bearer ${cred}`, accept: "application/json" },
          redirect: "error",
          signal: AbortSignal.timeout(20_000),
        });
      } catch (err) {
        this.#o.log(`sessions read: ${route} unreachable (${(err as Error).name})`);
        return send(502, { error: "sessions_unavailable" });
      }
      if (up.status === 401 && attempt === 0) {
        await up.body?.cancel().catch(() => undefined);
        this.#o.credential.invalidate();
        continue;
      }
      const body = await readBounded(up, MAX_UPSTREAM_BYTES);
      if (body === null) return send(502, { error: "response_too_large" });
      this.#o.log(`sessions read: ${route} ${up.status}`);
      res.writeHead(up.status, { "content-type": up.headers.get("content-type") ?? "application/json", "cache-control": "no-store" }).end(body);
      return;
    }
  }
}

/** The body as bytes, or null past `max` (the stream is cancelled). */
async function readBounded(res: Response, max: number): Promise<Buffer | null> {
  if (!res.body) return Buffer.alloc(0);
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      await reader.cancel().catch(() => undefined);
      return null;
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks);
}
