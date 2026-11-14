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
  #protocolVersion: string | null = null;
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
        this.#protocolVersion = null;
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
    await this.#rpc("initialize", { protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: { name: "slack-relay", version: "0.1" } });
    await this.#notify("notifications/initialized");
  }

  async #notify(method: string): Promise<void> {
    await this.#post({ jsonrpc: "2.0", method });
  }

  async #rpc(method: string, params: Record<string, unknown>): Promise<unknown> {
    const id = ++this.#id;
    const res = await this.#post({ jsonrpc: "2.0", id, method, params });
    const msg = await readRpcResponse(res, id);
    if (!msg) throw new Error(`${this.#s.name} ${method}: no response`);
    if (msg.error) throw Object.assign(new Error(`${this.#s.name} ${method}: ${msg.error.message}`), { code: msg.error.code });
    if (method === "initialize") this.#protocolVersion = (msg.result as { protocolVersion?: string } | undefined)?.protocolVersion ?? PROTOCOL_VERSION;
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
        ...(this.#protocolVersion ? { "mcp-protocol-version": this.#protocolVersion } : {}),
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

const PROTOCOL_VERSION = "2025-06-18";

type RpcMessage = { id?: number; result?: unknown; error?: { code: number; message: string } };

/** JSON-RPC messages in a body: plain JSON, or the events of a server-sent-events stream (data lines joined). */
export function rpcMessagesIn(body: string): RpcMessage[] {
  const text = body.trim();
  if (!text) return [];
  if (text.startsWith("{") || text.startsWith("[")) {
    try {
      const v = JSON.parse(text) as RpcMessage | RpcMessage[];
      return Array.isArray(v) ? v : [v];
    } catch {
      return [];
    }
  }
  const out: RpcMessage[] = [];
  for (const event of text.split(/\r?\n\r?\n/)) {
    const data = event
      .split(/\r?\n/)
      .filter((l) => l.startsWith("data:"))
      .map((l) => l.slice(5).replace(/^ /, ""))
      .join("\n");
    if (!data) continue;
    try {
      out.push(JSON.parse(data) as RpcMessage);
    } catch {
      // not JSON; skip
    }
  }
  return out;
}

/** The response with this id, or null; notifications and other ids are ignored. */
export function parseRpcBody(body: string, id: number): RpcMessage | null {
  return rpcMessagesIn(body).find((m) => m.id === id) ?? null;
}

/**
 * Reads a response until the message with this id arrives. An SSE stream is
 * read event by event and released as soon as it has that message, so a
 * server that keeps the stream open can't hold the call.
 */
async function readRpcResponse(res: Response, id: number): Promise<RpcMessage | null> {
  if (!(res.headers.get("content-type") ?? "").includes("text/event-stream") || !res.body) return parseRpcBody(await res.text(), id);
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (value) buf += decoder.decode(value, { stream: true });
      const events = buf.split(/\r?\n\r?\n/);
      buf = done ? "" : events.pop() ?? "";
      const found = parseRpcBody(events.join("\n\n"), id);
      if (found) return found;
      if (done) return parseRpcBody(buf, id);
    }
  } finally {
    await reader.cancel().catch(() => undefined);
  }
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
