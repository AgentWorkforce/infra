// A remote MCP server behind OAuth client credentials (e.g. a gbrain
// "company brain"). Used two ways: the router calls its tools directly
// (Slack ingest), and the host hands agents a fresh bearer token for it in
// their Claude Code MCP config.

export interface OAuthMcpServer {
  /** MCP server name; agents see its tools as mcp__<name>__*. */
  name: string;
  /** Streamable HTTP MCP endpoint, e.g. https://brain.example.com/mcp */
  url: string;
  /** OAuth token endpoint (client_credentials), e.g. https://brain.example.com/token */
  tokenUrl: string;
  clientId: string;
  clientSecret: string;
  scope?: string;
}

/** Fetches and caches a client-credentials access token, refreshed a minute before expiry. */
export class TokenSource {
  readonly #s: OAuthMcpServer;
  #token: string | null = null;
  #expiresAt = 0;

  constructor(s: OAuthMcpServer) {
    this.#s = s;
  }

  async get(now = Date.now()): Promise<string> {
    if (this.#token && now < this.#expiresAt - 60_000) return this.#token;
    const res = await fetch(this.#s.tokenUrl, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "client_credentials",
        client_id: this.#s.clientId,
        client_secret: this.#s.clientSecret,
        ...(this.#s.scope ? { scope: this.#s.scope } : {}),
      }),
    });
    if (!res.ok) throw new Error(`${this.#s.name} token request failed: ${res.status}`);
    const j = (await res.json()) as { access_token?: string; expires_in?: number };
    if (!j.access_token) throw new Error(`${this.#s.name} token response had no access_token`);
    this.#token = j.access_token;
    this.#expiresAt = now + (j.expires_in ?? 3600) * 1000;
    return this.#token;
  }
}

export class McpToolError extends Error {
  readonly tool: string;
  constructor(message: string, tool: string) {
    super(message);
    this.tool = tool;
  }
}

/** Minimal streamable-HTTP MCP client: initialize once, then tools/call. */
export class McpClient {
  readonly #s: OAuthMcpServer;
  readonly #tokens: TokenSource;
  #session: string | null = null;
  #id = 0;

  constructor(s: OAuthMcpServer, tokens = new TokenSource(s)) {
    this.#s = s;
    this.#tokens = tokens;
  }

  async callTool(name: string, args: Record<string, unknown>): Promise<unknown> {
    if (!this.#session) await this.#initialize();
    try {
      return await this.#toolCall(name, args);
    } catch (err) {
      // Session expired on the server: start a new one once.
      if ((err as { status?: number }).status === 404 || (err as { status?: number }).status === 400) {
        this.#session = null;
        await this.#initialize();
        return this.#toolCall(name, args);
      }
      throw err;
    }
  }

  async #toolCall(name: string, args: Record<string, unknown>): Promise<unknown> {
    const r = (await this.#rpc("tools/call", { name, arguments: args })) as { isError?: boolean; content?: Array<{ type: string; text?: string }>; structuredContent?: unknown };
    if (r?.isError) throw new McpToolError(r.content?.map((c) => c.text ?? "").join(" ").slice(0, 500) || "tool error", name);
    return r?.structuredContent ?? r;
  }

  async #initialize(): Promise<void> {
    await this.#rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "slack-relay", version: "0.1" } });
    await this.#notify("notifications/initialized");
  }

  async #notify(method: string): Promise<void> {
    await this.#post({ jsonrpc: "2.0", method });
  }

  async #rpc(method: string, params: Record<string, unknown>): Promise<unknown> {
    const id = ++this.#id;
    const res = await this.#post({ jsonrpc: "2.0", id, method, params });
    const body = await res.text();
    const msg = parseRpcBody(body, id);
    if (!msg) throw new Error(`${this.#s.name} ${method}: empty response`);
    if (msg.error) throw Object.assign(new Error(`${this.#s.name} ${method}: ${msg.error.message}`), { code: msg.error.code });
    return msg.result;
  }

  async #post(payload: Record<string, unknown>): Promise<Response> {
    const token = await this.#tokens.get();
    const res = await fetch(this.#s.url, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
        ...(this.#session ? { "mcp-session-id": this.#session } : {}),
      },
      body: JSON.stringify(payload),
    });
    if (!res.ok && res.status !== 202) {
      const text = await res.text().catch(() => "");
      throw Object.assign(new Error(`${this.#s.name} MCP ${res.status}: ${text.slice(0, 200)}`), { status: res.status });
    }
    this.#session ??= res.headers.get("mcp-session-id");
    return res;
  }
}

type RpcMessage = { id?: number; result?: unknown; error?: { code: number; message: string } };

/** A JSON-RPC response body, either plain JSON or a server-sent-events stream. */
export function parseRpcBody(body: string, id: number): RpcMessage | null {
  const candidates: string[] = [];
  if (body.trimStart().startsWith("{")) candidates.push(body);
  else for (const line of body.split(/\r?\n/)) if (line.startsWith("data:")) candidates.push(line.slice(5).trim());
  for (const c of candidates) {
    try {
      const m = JSON.parse(c) as RpcMessage;
      if (m.id === id || candidates.length === 1) return m;
    } catch {
      // not JSON; skip
    }
  }
  return null;
}

/** Parses MCP_OAUTH_SERVERS_JSON; each entry names the env var holding its client secret. */
export function oauthServersFromEnv(env: NodeJS.ProcessEnv): OAuthMcpServer[] {
  if (!env.MCP_OAUTH_SERVERS_JSON) return [];
  const list = JSON.parse(env.MCP_OAUTH_SERVERS_JSON) as Array<Omit<OAuthMcpServer, "clientSecret"> & { clientSecretEnv: string }>;
  return list.map(({ clientSecretEnv, ...s }) => {
    const clientSecret = (env[clientSecretEnv] ?? "").trim();
    if (!clientSecret) throw new Error(`MCP server ${s.name}: ${clientSecretEnv} is empty`);
    return { ...s, clientSecret };
  });
}
