// The router: the flow-shaped, deterministic core. Each Slack message runs the
// same steps in order:
//
//   1. record    write the message to the ledger (dedupes Slack retries)
//   2. route     the ledger's owner for this thread, if any
//   3. decide    only an unowned thread asks the orchestrator, whose choice
//                is written to the ledger and never asked again
//   4. deliver   post to the relay thread for that Slack thread, addressed to
//                the owning agent, with its session and the roster
//   5. return    an agent's reply in that relay thread goes back to the Slack
//                thread the ledger maps it to
//
// The orchestrator is the only model call here; everything else is a lookup.
import { sessionIdFor } from "./session-id.ts";
import type { Ledger, ThreadKey } from "./ledger.ts";
import type { Orchestrator } from "./orchestrator.ts";
import { dataOf, replyOf, type InboundData, type RelayEventLike, type RelayMessageLike, type RosterEntry } from "./protocol.ts";
import type { SlackInbound, SlackWebLike } from "./slack.ts";

export interface RouterRelay {
  message?(id: string): Promise<RelayMessageLike>;
  send(channel: string, text: string, opts?: { data?: Record<string, unknown> }): Promise<{ id: string }>;
  reply(id: string, text: string, opts?: { data?: Record<string, unknown> }): Promise<{ id: string }>;
}


export class Router {
  readonly #ledger: Ledger;
  readonly #relay: RouterRelay;
  readonly #slack: SlackWebLike;
  readonly #orchestrator: Orchestrator;
  readonly #channel: string;
  readonly #self: string;
  readonly #log: (m: string) => void;
  readonly #chains = new Map<string, Promise<unknown>>();

  constructor(opts: {
    ledger: Ledger;
    relay: RouterRelay;
    slack: SlackWebLike;
    orchestrator: Orchestrator;
    channel: string;
    selfName: string;
    log?: (m: string) => void;
  }) {
    this.#ledger = opts.ledger;
    this.#relay = opts.relay;
    this.#slack = opts.slack;
    this.#orchestrator = opts.orchestrator;
    this.#channel = opts.channel.replace(/^#/, "");
    this.#self = opts.selfName;
    this.#log = opts.log ?? (() => {});
  }

  /** Slack threads the ledger already knows: plain replies in them are relayed without a mention. */
  isTrackedThread = (team: string, channel: string, threadTs: string): boolean => {
    const t = this.#ledger.thread({ team, channel, threadTs });
    return Boolean(t?.agentName);
  };

  /** Steps 1-4 for one Slack message. Serialized per Slack thread. */
  fromSlack(m: SlackInbound & { team: string }): Promise<string | null> {
    const key: ThreadKey = { team: m.team, channel: m.channel, threadTs: m.threadTs };
    const chainKey = `${key.team}/${key.channel}/${key.threadTs}`;
    const prior = this.#chains.get(chainKey) ?? Promise.resolve();
    const run = prior.catch(() => undefined).then(() => this.#route(m, key));
    this.#chains.set(chainKey, run);
    void run.finally(() => {
      if (this.#chains.get(chainKey) === run) this.#chains.delete(chainKey);
    });
    return run;
  }

  async #route(m: SlackInbound & { team: string }, key: ThreadKey): Promise<string | null> {
    // 1. record
    const decision = this.#ledger.recordInbound({ ...key, ts: m.ts, user: m.user, text: m.text });
    if (!decision) return null;

    // 2-3. route, or decide once
    let agentName: string;
    let brief: string | undefined;
    if (decision.kind === "owned") {
      agentName = decision.agent.agentName;
      if (decision.wake) this.#log(`waking ${agentName} for ${m.channel}:${m.threadTs}`);
    } else {
      const choice = await this.#orchestrator.decide({
        thread: key,
        text: m.text,
        user: m.user,
        participants: this.#ledger.participants(key),
        roster: this.#ledger.roster(),
      });
      agentName = choice.agent;
      brief = choice.brief;
      this.#ledger.assign(key, agentName, choice.by, choice.reason);
      this.#log(`assigned ${m.channel}:${m.threadTs} -> ${agentName} (${choice.by}: ${choice.reason})`);
    }

    // 4. deliver
    const agent = this.#ledger.agent(agentName);
    const sessionId = agent?.sessionId ?? sessionIdFor(agentName);
    const resume = Boolean(agent?.lastWakeAt);
    const data: InboundData = {
      kind: "slack.inbound",
      slack: { ...{ team: key.team, channel: key.channel, thread_ts: key.threadTs }, ts: m.ts, user: m.user, participants: this.#ledger.participants(key) },
      target: agentName,
      session: { id: sessionId, resume },
      ...(brief ? { brief } : {}),
      roster: this.#roster(agentName),
    };
    if (!agent?.sessionId) this.#ledger.setAgentStatus(agentName, agent?.status ?? "spawning", { sessionId });
    const body = `[slack <@${m.user}>${m.kind === "dm" ? " dm" : ""}] ${m.text}`;
    const thread = this.#ledger.thread(key);
    let relayId: string;
    if (thread?.relayParentId) {
      relayId = (await this.#relay.reply(thread.relayParentId, body, { data: data as unknown as Record<string, unknown> })).id;
    } else {
      relayId = (await this.#relay.send(this.#channel, `@${agentName} ${body}`, { data: data as unknown as Record<string, unknown> })).id;
      this.#ledger.setRelayParent(key, relayId);
    }
    this.#log(`slack ${m.kind} ${m.channel}:${m.ts} -> relay ${relayId} @${agentName}${resume ? " (resume)" : ""}`);
    return relayId;
  }

  /** Step 5: an agent's reply in a relay thread goes back to its Slack thread. */
  async fromRelay(ev: RelayEventLike): Promise<boolean> {
    if (ev.type !== "thread.reply" || !ev.parentId) return false;
    if (ev.channel && ev.channel.replace(/^#/, "") !== this.#channel) return false;
    const msg = ev.message;
    if (!msg?.id || !msg.text || msg.agentName === this.#self) return false;
    const thread = this.#ledger.threadByRelayParent(ev.parentId);
    if (!thread) return false;
    // Only the owner answers into Slack; other agents may talk in the relay thread.
    if (thread.agentName && msg.agentName !== thread.agentName) return false;
    let reply = replyOf(dataOf(msg));
    if (!reply && this.#relay.message) reply = replyOf(dataOf(await this.#relay.message(msg.id).catch(() => undefined)));
    const posted = await this.#slack.postMessage({ channel: thread.channel, threadTs: thread.threadTs, text: msg.text });
    this.#ledger.setAgentStatus(msg.agentName!, reply?.error ? "failed" : "active", {
      ...(reply?.session_id ? { sessionId: reply.session_id } : {}),
      ...(reply?.summary ? { summary: reply.summary } : {}),
    });
    this.#ledger.recordOutbound(thread, msg.agentName!, posted.ts);
    this.#log(`relay ${msg.id} @${msg.agentName} -> slack ${thread.channel}:${thread.threadTs}`);
    return true;
  }

  /** Marks agents silent for `idleMs` as released; the next message wakes them. */
  sweepIdle(idleMs: number): string[] {
    const released = this.#ledger.idleAgents(idleMs).map((a) => a.agentName);
    for (const name of released) this.#ledger.setAgentStatus(name, "released");
    return released;
  }

  #roster(except: string): RosterEntry[] {
    return this.#ledger
      .roster()
      .filter((a) => a.agentName !== except)
      .slice(0, 25)
      .map((a) => ({ name: a.agentName, status: a.status, summary: a.summary, threads: a.threads.length }));
  }
}

export { sessionIdFor };
