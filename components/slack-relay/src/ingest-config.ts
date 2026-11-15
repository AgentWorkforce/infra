// Builds the Slack ingest from the environment. Shared by the router (live
// ingest) and backfill.ts (history), so both write the same pages the same way.
import { McpClient, oauthServersFromEnv, type OAuthMcpServer } from "./mcp.ts";
import { SlackIngest, type SourceRule, type ToolCaller } from "./ingest.ts";

export interface IngestConfig {
  ingest: SlackIngest;
  /** The MCP server each source is written through (the default server for any source not listed). */
  serverFor: (sourceId: string | undefined) => string;
  privateChannels: boolean;
  describe: string;
}

/**
 * INGEST_MCP_SERVER writes the default source (INGEST_SOURCE_ID).
 * INGEST_SOURCE_SERVERS ({"<source>": "<MCP server name>"}) names the writer
 * for each other source: gbrain lets a remote client write only to its own
 * write source. Returns null when ingest is off.
 */
export function ingestFromEnv(
  env: NodeJS.ProcessEnv,
  opts: {
    log: (m: string) => void;
    /** Asked before each write with the server it goes through (relaygate /v1/check). */
    beforeWrite?: (server: string, slug: string, text: string) => Promise<void>;
    client?: (server: OAuthMcpServer) => ToolCaller;
  },
): IngestConfig | null {
  if (!env.INGEST_MCP_SERVER) return null;
  const servers = oauthServersFromEnv(env);
  const byName = (name: string, what: string): OAuthMcpServer => {
    const s = servers.find((x) => x.name === name);
    if (!s) throw new Error(`${what} ${name} is not in MCP_OAUTH_SERVERS_JSON`);
    return s;
  };
  const client = opts.client ?? ((s: OAuthMcpServer) => new McpClient(s));
  const main = byName(env.INGEST_MCP_SERVER, "INGEST_MCP_SERVER");
  const perSource = env.INGEST_SOURCE_SERVERS ? (JSON.parse(env.INGEST_SOURCE_SERVERS) as Record<string, string>) : {};
  const brains: Record<string, ToolCaller> = {};
  for (const [source, name] of Object.entries(perSource)) brains[source] = client(byName(name, `INGEST_SOURCE_SERVERS.${source}`));
  const serverFor = (sourceId: string | undefined) => (sourceId && perSource[sourceId]) || main.name;

  const ingest = new SlackIngest({
    brain: client(main),
    brains,
    sourceId: env.INGEST_SOURCE_ID,
    privateSourceId: env.INGEST_PRIVATE_SOURCE_ID,
    rules: env.INGEST_SOURCE_RULES ? (JSON.parse(env.INGEST_SOURCE_RULES) as SourceRule[]) : [],
    prefix: env.INGEST_PAGE_PREFIX ?? "slack",
    log: opts.log,
    beforeWrite: opts.beforeWrite
      ? (slug, text, sourceId) => opts.beforeWrite!(serverFor(sourceId), slug, text)
      : undefined,
  });
  const privateChannels = env.INGEST_PRIVATE_CHANNELS === "true";
  const others = Object.entries(perSource).map(([src, name]) => `${src} -> ${name}`);
  const describe =
    `on -> ${main.name}${env.INGEST_SOURCE_ID ? ` (source ${env.INGEST_SOURCE_ID})` : ""}` +
    (others.length ? `, ${others.join(", ")}` : "") +
    (privateChannels ? ", private channels too" : ", public channels");
  return { ingest, serverFor, privateChannels, describe };
}
