// Relay identity for a long-running agent. The first start registers the agent
// with a recovery-proof verifier; every later start (pod restart, reschedule)
// finds the name taken and recovers the same identity with that proof, which
// rotates its token. The proof is derived from a stable secret, so no agent
// token has to be stored.
import { createHash, createHmac } from "node:crypto";
import { RelayCast, type AgentClient } from "@relaycast/sdk";
import type { RelaygateClient } from "./gate.ts";

export function recoveryProof(secret: string, name: string): string {
  return createHmac("sha256", secret).update(`agent-relay-slack:${name}`).digest("hex");
}

export function sha256Hex(v: string): string {
  return createHash("sha256").update(v).digest("hex");
}

function errCode(err: unknown): { status?: number; code?: string } {
  const e = err as { status?: number; statusCode?: number; code?: string };
  return { status: e?.status ?? e?.statusCode, code: e?.code };
}

export async function connectAgent(opts: {
  baseUrl: string;
  workspaceKey: string;
  name: string;
  persona: string;
  proofSecret: string;
  log: (m: string) => void;
  /** With relaygate: register through the gate (its enrollment key picks the group) and talk to Relaycast through it. */
  gate?: RelaygateClient;
}): Promise<{ relay: RelayCast; agent: AgentClient; token: string }> {
  const proof = recoveryProof(opts.proofSecret, opts.name);
  if (opts.gate) {
    const reg = await opts.gate.register(opts.name, proof);
    opts.log(`registered ${opts.name} through relaygate (gid ${reg.gid})`);
    const relay = new RelayCast({ apiKey: reg.token, baseUrl: opts.gate.url });
    return { relay, agent: relay.as(reg.token), token: reg.token };
  }
  const relay = new RelayCast({ apiKey: opts.workspaceKey, baseUrl: opts.baseUrl });
  let token: string;
  try {
    const created = await relay.agents.register({
      name: opts.name,
      type: "agent",
      persona: opts.persona,
      recoveryProofHash: sha256Hex(proof),
    } as Parameters<RelayCast["agents"]["register"]>[0]);
    token = (created as { token: string }).token;
    opts.log(`registered relay agent ${opts.name}`);
  } catch (err) {
    const { status, code } = errCode(err);
    if (status !== 409 && !/conflict|exists|taken/i.test(String(code ?? ""))) throw err;
    const existing = await relay.agents.get(opts.name);
    const recovered = await relay.agents.recover({
      name: opts.name,
      expectedAgentId: existing.id,
      recoveryProof: proof,
      reason: "slack-relay restart",
    } as Parameters<RelayCast["agents"]["recover"]>[0]);
    token = (recovered as { token?: string; apiToken?: string }).token ?? (recovered as { apiToken?: string }).apiToken ?? "";
    if (!token) throw new Error(`relay recover for ${opts.name} returned no token`);
    opts.log(`recovered relay agent ${opts.name}`);
  }
  return { relay, agent: relay.as(token), token };
}

/** Creates the relay channel if needed and joins it. */
export async function ensureChannel(agent: AgentClient, name: string, topic: string): Promise<void> {
  try {
    await agent.channels.create({ name, topic });
  } catch (err) {
    const { status } = errCode(err);
    if (status !== 409) throw err;
  }
  try {
    await agent.channels.join(name);
  } catch (err) {
    const { status } = errCode(err);
    if (status !== 409) throw err;
  }
}
