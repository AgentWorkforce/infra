// relaygate client (opt-in). With a gate configured, every agent registers
// through it with the gate's enrollment key and uses its rg_ token for all
// Relaycast traffic (relaygate proxies Relaycast; the agents never hold a
// Relaycast credential). Egress relaygate can't see (Slack posts, knowledge
// base writes) is asked about first with /v1/check and sent only on "allow".
// Contract: AgentWorkforce/relaygate docs/contract.md.

export interface GateRegistration {
  agentId: string;
  gid: number;
  token: string;
}

/** The gate refused (mode bits or classifier). Final: never retried. */
export class GateDenied extends Error {
  readonly code: string;
  constructor(code: string, message = code) {
    super(message);
    this.code = code;
  }
}

/** The gate couldn't decide (classifier down, upstream down). Retryable; never "allow". */
export class GateUnavailable extends Error {}

/**
 * relaygate knows every stream (a Slack thread, a knowledge-base page) only by
 * an opaque id its owner picks; it never parses it. The ids here are this
 * component's: slack:<team>/<channel>/<thread_ts>, kb:<server>/<page slug>.
 */
export interface CheckResource {
  kind: "stream";
  id: string;
}

export const slackStreamId = (ref: { team: string; channel: string; thread_ts: string }) => `slack:${ref.team}/${ref.channel}/${ref.thread_ts}`;
export const kbStreamId = (server: string, slug: string) => `kb:${server}/${slug}`;

export interface CheckRequest {
  op: "r" | "w";
  resource: CheckResource;
  content: string;
}

export class RelaygateClient {
  readonly url: string;
  readonly #enrollmentKey: string;

  constructor(opts: { url: string; enrollmentKey: string }) {
    this.url = opts.url.replace(/\/$/, "");
    this.#enrollmentKey = opts.enrollmentKey;
  }

  /**
   * Registers `name` in the enrollment key's group, or gets the same identity
   * back (a new token, the old one revoked) with the recovery proof set at
   * first registration.
   */
  async register(name: string, recovery: string): Promise<GateRegistration> {
    const res = await fetch(`${this.url}/v1/register`, {
      method: "POST",
      headers: { authorization: `Bearer ${this.#enrollmentKey}`, "content-type": "application/json" },
      body: JSON.stringify({ name, recovery }),
    });
    const body = (await res.json().catch(() => ({}))) as { agent_id?: string; gid?: number; token?: string; error?: string };
    if (res.ok && body.token && body.agent_id) return { agentId: body.agent_id, gid: body.gid ?? -1, token: body.token };
    if (res.status >= 500) throw new GateUnavailable(`relaygate register ${name}: ${res.status} ${body.error ?? ""}`.trim());
    throw new GateDenied(body.error ?? `http_${res.status}`, `relaygate register ${name}: ${res.status} ${body.error ?? ""}`.trim());
  }

  /** Asks whether `token`'s principal may send this out. Resolves only on allow. */
  async check(token: string, req: CheckRequest): Promise<void> {
    let res: Response;
    try {
      res = await fetch(`${this.url}/v1/check`, {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: JSON.stringify(req),
      });
    } catch (err) {
      throw new GateUnavailable(`relaygate check: ${(err as Error).message}`);
    }
    const body = (await res.json().catch(() => ({}))) as { decision?: string; error?: string; reason?: string };
    if (res.ok && body.decision === "allow") return;
    if (res.status === 403 || (res.ok && body.decision === "deny")) {
      throw new GateDenied(body.error ?? "relaygate_denied", `relaygate denied: ${body.error ?? body.reason ?? "deny"}`);
    }
    // 503 relaygate_unavailable, any other status, or an unexpected body: not an allow.
    throw new GateUnavailable(`relaygate check: ${res.status} ${body.error ?? ""}`.trim());
  }
}

/** A relaygate denial surfaced by the Relaycast SDK on a proxied call (403 relaygate_*). */
export function isGateDenial(err: unknown): boolean {
  const e = err as { status?: number; statusCode?: number; code?: string; message?: string };
  const status = e?.status ?? e?.statusCode;
  return status === 403 && /relaygate_/.test(`${e?.code ?? ""} ${e?.message ?? ""}`);
}

/** Calls `check` and retries only while the gate is unavailable; a denial is final. */
export async function checkWithRetry(gate: RelaygateClient, token: string, req: CheckRequest, delaysMs = [500, 2000, 5000]): Promise<void> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await gate.check(token, req);
    } catch (err) {
      if (err instanceof GateDenied || attempt >= delaysMs.length) throw err;
      await new Promise((r) => setTimeout(r, delaysMs[attempt]));
    }
  }
}
