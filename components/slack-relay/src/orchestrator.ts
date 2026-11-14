// The orchestrator: asked only about a Slack thread no agent owns yet. It sees
// the whole roster (every agent, its status, what it is doing and whose
// threads it holds) and either hands the thread to an existing agent or
// starts a new one with a brief. Its answer is written to the ledger, so the
// same thread is never asked about twice.
import Anthropic from "@anthropic-ai/sdk";
import { threadAgentName, type AgentRow, type ThreadKey } from "./ledger.ts";

export interface DecideInput {
  thread: ThreadKey;
  text: string;
  user: string;
  participants: string[];
  roster: Array<AgentRow & { threads: Array<ThreadKey & { participants: string[] }> }>;
}

export interface Decision {
  agent: string;
  brief?: string;
  reason: string;
  by: string;
}

export interface Orchestrator {
  decide(input: DecideInput): Promise<Decision>;
}

/** Pinned agents (e.g. a company-brain agent) the orchestrator may route to. */
export interface KnownAgent {
  name: string;
  description: string;
}

/** No model: every new thread gets its own agent. */
export class DeterministicOrchestrator implements Orchestrator {
  readonly #prefix: string;
  constructor(prefix = "slack") {
    this.#prefix = prefix;
  }
  async decide(input: DecideInput): Promise<Decision> {
    return { agent: threadAgentName(input.thread, this.#prefix), reason: "one agent per thread", by: "deterministic" };
  }
}

const NAME_RE = /^[a-z0-9][a-z0-9-]{1,62}$/;

const SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["action", "agent", "brief", "reason"],
  properties: {
    action: { type: "string", enum: ["assign", "new"] },
    agent: { type: "string", description: "Existing agent name for assign; for new, leave empty to use the default name." },
    brief: { type: "string", description: "What the agent should know or do for this thread, in one to three sentences." },
    reason: { type: "string", description: "One short sentence on why." },
  },
} as const;

const SYSTEM = `You are the orchestrator for a team of agents that answer people in Slack.
A Slack thread with no owner just arrived. Decide who handles it:
- "assign" it to an existing agent when the thread clearly continues that agent's work (same topic, same people) or a pinned agent is the right specialist;
- otherwise "new": start a fresh agent for this thread.
Prefer "new" when unsure: one agent per conversation keeps context clean.
Never route a thread to an agent that is failed. Reply with the JSON object only.`;

export class ClaudeOrchestrator implements Orchestrator {
  readonly #client: Anthropic;
  readonly #model: string;
  readonly #known: KnownAgent[];
  readonly #fallback: DeterministicOrchestrator;
  readonly #log: (m: string) => void;

  constructor(opts: { apiKey: string; model: string; known?: KnownAgent[]; prefix?: string; log?: (m: string) => void }) {
    this.#client = new Anthropic({ apiKey: opts.apiKey });
    this.#model = opts.model;
    this.#known = opts.known ?? [];
    this.#fallback = new DeterministicOrchestrator(opts.prefix);
    this.#log = opts.log ?? (() => {});
  }

  async decide(input: DecideInput): Promise<Decision> {
    const fallback = await this.#fallback.decide(input);
    const known = new Set([...input.roster.filter((a) => a.status !== "failed").map((a) => a.agentName), ...this.#known.map((k) => k.name)]);
    try {
      const response = await this.#client.beta.messages.create({
        model: this.#model,
        max_tokens: 16000,
        system: SYSTEM,
        output_config: { effort: "medium", format: { type: "json_schema", schema: SCHEMA } },
        betas: ["server-side-fallback-2026-07-01"],
        fallbacks: "default",
        messages: [{ role: "user", content: describe(input, this.#known, fallback.agent) }],
      } as unknown as Anthropic.Beta.MessageCreateParamsNonStreaming);
      if (response.stop_reason === "refusal") return { ...fallback, reason: "orchestrator declined; one agent per thread" };
      const text = response.content
        .filter((b): b is Anthropic.Beta.BetaTextBlock => b.type === "text")
        .map((b) => b.text)
        .join("");
      const out = JSON.parse(text) as { action: string; agent: string; brief: string; reason: string };
      const agent = out.action === "assign" ? out.agent.trim() : fallback.agent;
      // The ledger trusts this name, so it must be one we know (assign) or our own default (new).
      if (out.action === "assign" && (!known.has(agent) || !NAME_RE.test(agent))) {
        this.#log(`orchestrator chose unknown agent "${agent}"; starting a new one`);
        return { ...fallback, brief: out.brief, reason: `unknown agent "${agent}"`, by: `orchestrator:${this.#model}` };
      }
      return { agent, brief: out.brief || undefined, reason: out.reason, by: `orchestrator:${this.#model}` };
    } catch (err) {
      this.#log(`orchestrator failed (${(err as Error).message}); one agent per thread`);
      return { ...fallback, reason: "orchestrator unavailable; one agent per thread" };
    }
  }
}

function describe(input: DecideInput, known: KnownAgent[], defaultName: string): string {
  const roster = input.roster.map((a) => ({
    name: a.agentName,
    status: a.status,
    doing: a.summary,
    threads: a.threads.map((t) => ({ channel: t.channel, thread: t.threadTs, people: t.participants })),
  }));
  return JSON.stringify(
    {
      new_thread: { channel: input.thread.channel, thread: input.thread.threadTs, from: input.user, people: input.participants, text: input.text.slice(0, 4000) },
      default_new_agent_name: defaultName,
      pinned_agents: known,
      agents: roster,
    },
    null,
    2,
  );
}
