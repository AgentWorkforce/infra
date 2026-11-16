/**
 * Requester identity from the Relay server, not from the lead. The broker is
 * handed only a Relay message id. It reads the message from Relaycast
 * (cast.agentrelay.com) with a read-only observer token
 * (messages:read, dms:read, agents:read), and takes from the server:
 *  - who sent it: the message's agent_id, resolved to that agent's record
 *    (name, and type human or agent). The message's display name is only a
 *    lookup key and must resolve back to the same agent_id, so a sender
 *    can't pass as another agent by setting a display name;
 *  - what it says: the request JSON, or "approve <id> <digest>" /
 *    "refuse <id>", from the server's copy of the text;
 *  - that it was sent to the broker: Relaycast derives a DM's channel id from
 *    the workspace and the two agents, "dmch_" + sha256(
 *    "<workspace>:<lower agent id>:<higher agent id>")[0:24]. The broker
 *    computes the channel between the sender and its own Relay identity
 *    (BROKER_RELAY_NAME, layered-infra-ops) and accepts only that one, so a
 *    message the observer token can read in any other conversation is refused;
 *  - that it is recent (15 minutes).
 * The broker records every message id it has acted on, so one message can't
 * be replayed. Nothing the lead types reaches identity or the request.
 */
import { createHash } from "node:crypto";
import type { Principal } from "./policy.ts";

export interface RelayMessage {
  id: string;
  agentId: string;
  agentName: string;
  agentAddress?: string;
  text: string;
  channelId: string;
  createdAt: string;
}

export interface RelayAgent {
  id: string;
  name: string;
  type: string;
  workspaceId: string;
}

/** The one DM channel between two agents, as Relaycast derives it (engine/dm.ts deriveDmPairKey). */
export function dmChannelId(workspaceId: string, agentA: string, agentB: string): string {
  const [first, second] = [agentA, agentB].sort();
  return `dmch_${createHash("sha256").update(`${workspaceId}:${first}:${second}`).digest("hex").slice(0, 24)}`;
}

export interface RelayApi {
  message(id: string): Promise<RelayMessage | undefined>;
  agentByName(name: string): Promise<RelayAgent | undefined>;
}

export const MESSAGE_MAX_AGE_MS = 15 * 60_000;
const MESSAGE_ID_RE = /^[0-9]{6,32}$/;

export class RelayVerificationError extends Error {}

export interface Verified {
  principal: Principal;
  text: string;
  messageId: string;
}

/** The sender and text of one direct message, as the Relay server has them. Throws RelayVerificationError otherwise. */
export async function verifiedMessage(api: RelayApi, messageId: string, now: Date, brokerName: string): Promise<Verified> {
  if (!MESSAGE_ID_RE.test(messageId)) throw new RelayVerificationError(`bad Relay message id ${JSON.stringify(messageId)}`);
  const m = await api.message(messageId);
  if (!m) throw new RelayVerificationError(`Relay has no message ${messageId}`);
  if (m.id !== messageId) throw new RelayVerificationError("Relay returned a different message");
  if (!m.channelId.startsWith("dmch_")) throw new RelayVerificationError("only a direct message to the broker counts, not a channel post");
  const age = now.getTime() - Date.parse(m.createdAt);
  if (!(age >= -60_000 && age <= MESSAGE_MAX_AGE_MS)) throw new RelayVerificationError(`message ${messageId} is not from the last ${MESSAGE_MAX_AGE_MS / 60_000} minutes: send it again`);
  const agent = await api.agentByName(m.agentName);
  if (!agent || agent.id !== m.agentId) throw new RelayVerificationError("the message's sender doesn't resolve to its own agent record");
  const broker = await api.agentByName(brokerName);
  if (!broker || !broker.workspaceId) throw new RelayVerificationError(`the broker's Relay identity ${brokerName} isn't known to Relay`);
  if (agent.id === broker.id) throw new RelayVerificationError("a message the broker sent itself doesn't count");
  if (m.channelId !== dmChannelId(broker.workspaceId, agent.id, broker.id)) throw new RelayVerificationError(`the message wasn't sent to ${brokerName}: only a direct message to the broker counts`);
  const kind = agent.type === "human" ? "human" : agent.type === "agent" ? "agent" : undefined;
  if (!kind) throw new RelayVerificationError(`unknown Relay agent type ${JSON.stringify(agent.type)}`);
  return { principal: { name: agent.name, address: m.agentAddress ?? agent.name, kind, agentId: agent.id }, text: m.text, messageId };
}

/** A request body: the whole message is the JSON object (a ```json fence around it is allowed). */
export function requestFromText(text: string): unknown {
  const t = text.trim().replace(/^```(?:json)?\s*\n([\s\S]*)\n```$/, "$1").trim();
  try {
    const v = JSON.parse(t) as unknown;
    if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error("not an object");
    return v;
  } catch {
    throw new RelayVerificationError("the message isn't a credential request: its whole text must be the request JSON");
  }
}

export type Decision = { verb: "approve"; requestId: string; digest: string } | { verb: "refuse"; requestId: string };

/** An approval or refusal: the whole message is "approve <request id> <digest>" or "refuse <request id>". */
export function decisionFromText(text: string): Decision {
  const t = text.trim();
  let m = /^approve\s+(cb-[0-9a-f]{12})\s+([0-9a-f]{12,64})$/i.exec(t);
  if (m) return { verb: "approve", requestId: m[1]!.toLowerCase(), digest: m[2]!.toLowerCase() };
  m = /^refuse\s+(cb-[0-9a-f]{12})$/i.exec(t);
  if (m) return { verb: "refuse", requestId: m[1]!.toLowerCase() };
  throw new RelayVerificationError('the message must be exactly "approve <request id> <digest>" or "refuse <request id>"');
}

/** Relay agent names: what whois accepts (no path or query characters reach the API). */
const AGENT_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._@-]{0,127}$/;

/**
 * Read-only lookup of one agent's Relay identity, for pinning a delegated
 * approver's agentId: only the name, agent id and type. Never the workspace,
 * the token, or anything else the record holds.
 */
export async function whois(api: RelayApi, name: string): Promise<{ name: string; agentId: string; type: string }> {
  if (!AGENT_NAME_RE.test(name)) throw new RelayVerificationError(`bad Relay agent name ${JSON.stringify(name)}`);
  const a = await api.agentByName(name);
  if (!a || !a.id) throw new RelayVerificationError(`Relay has no agent ${name}`);
  if (a.name !== name) throw new RelayVerificationError(`Relay returned a different agent for ${name}`);
  return { name: a.name, agentId: a.id, type: a.type };
}

/** A named client: the API edge rejects some default library User-Agents (Cloudflare 1010). */
export const USER_AGENT = "aws-cred-broker/1 (AgentWorkforce layered-infra-ops)";

/** Relaycast over HTTPS with a read-only observer token. 10 s per call. */
export function relaycastApi(baseUrl: string, token: string, fetchImpl: typeof fetch = fetch): RelayApi {
  const get = async (path: string): Promise<Record<string, unknown> | undefined> => {
    const res = await fetchImpl(`${baseUrl.replace(/\/$/, "")}${path}`, { headers: { Authorization: `Bearer ${token}`, "User-Agent": USER_AGENT, Accept: "application/json" }, signal: AbortSignal.timeout(10_000) });
    if (res.status === 404) return undefined;
    if (!res.ok) throw new RelayVerificationError(`Relay API ${path.split("/").slice(0, 3).join("/")} returned ${res.status}`);
    const body = (await res.json()) as { data?: Record<string, unknown> };
    return body.data;
  };
  const str = (v: unknown): string => (typeof v === "string" ? v : "");
  return {
    async message(id) {
      const d = await get(`/v1/messages/${encodeURIComponent(id)}`);
      if (!d) return undefined;
      return {
        id: str(d.id),
        agentId: str(d.agent_id),
        agentName: str(d.agent_name),
        ...(typeof d.agent_address === "string" ? { agentAddress: d.agent_address } : {}),
        text: str(d.text),
        channelId: str(d.channel_id),
        createdAt: str(d.created_at),
      };
    },
    async agentByName(name) {
      if (!name) return undefined;
      const d = await get(`/v1/agents/${encodeURIComponent(name)}`);
      if (!d) return undefined;
      return { id: str(d.id), name: str(d.name), type: str(d.type), workspaceId: str(d.workspace_id) };
    },
  };
}
