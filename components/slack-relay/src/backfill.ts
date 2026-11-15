// One-off backfill: ingests a channel's Slack history into the knowledge base
// through the same ingest the router runs live, so pages, sources and the
// credential filter are identical. Each write is keyed by the Slack message
// (request_id), so a backfill can be re-run, can overlap live ingest, and can
// run while the router is up without duplicating a line.
//
// Run it with the router's environment (the same env file / Secrets):
//   node src/backfill.ts --channel C0123456789 [--channel ...] [--since 2026-01-01] [--dry-run]
import { readFileSync } from "node:fs";
import { env } from "node:process";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { checkWithRetry, kbStreamId, RelaygateClient } from "./gate.ts";
import type { IngestMessage } from "./ingest.ts";
import { ingestFromEnv } from "./ingest-config.ts";
import { recoveryProof } from "./relay.ts";
import { channelInfoOf, channelMessageOf, SlackWeb } from "./slack.ts";

const log = (m: string) => console.log(`${new Date().toISOString()} [backfill] ${m}`);

function secret(name: string, required = true): string {
  const file = env[`${name}_FILE`];
  const v = file ? readFileSync(file, "utf8").trim() : (env[name] ?? "").trim();
  if (!v && required) throw new Error(`${name} (or ${name}_FILE) is required`);
  return v;
}

/** Slack's paginated list calls: every page of `field`. */
export async function* paged(slack: Pick<SlackWeb, "call">, method: string, body: Record<string, unknown>, field: string): AsyncGenerator<Record<string, unknown>> {
  let cursor = "";
  do {
    const r = await slack.call(method, { ...body, limit: 200, ...(cursor ? { cursor } : {}) });
    for (const item of (r[field] as Record<string, unknown>[] | undefined) ?? []) yield item;
    const next = String((r.response_metadata as { next_cursor?: string } | undefined)?.next_cursor ?? "");
    if (next && next === cursor) throw new Error(`slack ${method}: the cursor did not advance`);
    cursor = next;
  } while (cursor);
}

/**
 * A channel's human messages since `oldest` (Slack ts seconds), thread replies
 * included, oldest first. History is read in full: a thread started before
 * `oldest` can have replies after it, and only its root leads to them.
 */
export async function channelHistory(slack: Pick<SlackWeb, "call">, channel: string, botUserId: string, oldest?: string): Promise<Array<Omit<IngestMessage, "channelName" | "isPrivate">>> {
  const out = new Map<string, Omit<IngestMessage, "channelName" | "isPrivate">>();
  const after = (ts: unknown) => !oldest || Number(ts) >= Number(oldest);
  const take = (raw: Record<string, unknown>) => {
    if (!after(raw.ts)) return;
    // Channel conversations only (the caller has refused DMs); channelMessageOf drops bots and subtypes.
    const m = channelMessageOf({ type: "message", ...raw, channel, channel_type: "channel" }, botUserId);
    if (m) out.set(m.ts, m);
  };
  for await (const msg of paged(slack, "conversations.history", { channel }, "messages")) {
    take(msg);
    if (Number(msg.reply_count ?? 0) > 0 && typeof msg.ts === "string" && after(msg.latest_reply ?? msg.ts)) {
      for await (const reply of paged(slack, "conversations.replies", { channel, ts: msg.ts, ...(oldest ? { oldest } : {}) }, "messages")) {
        if (reply.ts !== msg.ts) take(reply);
      }
    }
  }
  return [...out.values()].sort((a, b) => Number(a.ts) - Number(b.ts));
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      channel: { type: "string", multiple: true },
      since: { type: "string" },
      "dry-run": { type: "boolean", default: false },
    },
  });
  const channels = values.channel ?? [];
  if (!channels.length) throw new Error("usage: backfill.ts --channel C0123456789 [--channel ...] [--since YYYY-MM-DD] [--dry-run]");
  const since = values.since;
  if (since !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(since)) throw new Error(`--since "${since}" is not a date (YYYY-MM-DD)`);
  const oldest = since !== undefined ? String(Date.parse(`${since}T00:00:00Z`) / 1000) : undefined;
  if (oldest === "NaN") throw new Error(`--since "${since}" is not a date (YYYY-MM-DD)`);
  const dryRun = values["dry-run"] === true;

  // relaygate (opt-in): the backfill registers as its own agent, so the
  // router's token is never revoked, and every write is checked like live ingest.
  const gateUrl = (env.RELAYGATE_URL ?? "").trim();
  let beforeWrite: ((server: string, slug: string, text: string) => Promise<void>) | undefined;
  if (gateUrl && !dryRun) {
    const gate = new RelaygateClient({ url: gateUrl, enrollmentKey: secret("RELAYGATE_ENROLLMENT_KEY") });
    const name = `${env.ROUTER_AGENT_NAME ?? "slack-router"}-backfill`;
    const { token } = await gate.register(name, recoveryProof(secret("AGENT_IDENTITY_SECRET"), name));
    log(`relaygate: registered ${name}`);
    beforeWrite = (server, slug, text) => checkWithRetry(gate, token, { op: "w", resource: { kind: "stream", id: kbStreamId(server, slug) }, content: text });
  }
  const cfg = ingestFromEnv(env, { log, beforeWrite });
  if (!cfg) throw new Error("ingest is off (INGEST_MCP_SERVER is not set); nothing to backfill into");
  log(`ingest: ${cfg.describe}${dryRun ? " (dry run: nothing is written)" : ""}`);

  const slack = new SlackWeb(secret("SLACK_BOT_TOKEN"), env.SLACK_API_URL);
  const me = await slack.authTest();
  const refuseShared = env.SLACK_REFUSE_SHARED_CHANNELS !== "false";
  const allowed = new Set((env.SLACK_ALLOWED_CHANNELS ?? "").split(",").map((s) => s.trim()).filter(Boolean));
  let failed = 0;
  for (const id of channels) {
    // The same rules as live ingest: the allowlist, no DMs, shared channels
    // refused, private ones only when enabled.
    if (allowed.size > 0 && !allowed.has(id)) { log(`${id}: not in SLACK_ALLOWED_CHANNELS; skipped`); continue; }
    const raw = (await slack.call("conversations.info", { channel: id })).channel as Record<string, unknown>;
    if (raw.is_im === true || raw.is_mpim === true || (raw.is_channel !== true && raw.is_group !== true)) { log(`${id}: not a channel (DMs are never ingested); skipped`); continue; }
    const info = channelInfoOf(raw);
    if (refuseShared && info.isShared) { log(`#${info.name} (${id}): shared outside the workspace; skipped`); continue; }
    if (info.isPrivate && !cfg.privateChannels) { log(`#${info.name} (${id}): private and INGEST_PRIVATE_CHANNELS is off; skipped`); continue; }
    const source = cfg.ingest.sourceFor(info.name, info.isPrivate);
    const history = await channelHistory(slack, id, me.userId, oldest);
    log(`#${info.name} (${id}): ${history.length} messages${oldest ? ` since ${values.since}` : ""} -> source ${source ?? "(default)"} via ${cfg.serverFor(source)}`);
    if (dryRun) continue;
    let written = 0;
    let withheld = 0;
    for (const m of history) {
      try {
        const slug = await cfg.ingest.add({ ...m, channelName: info.name, isPrivate: info.isPrivate });
        if (slug) written++;
        else withheld++;
      } catch (err) {
        failed++;
        log(`#${info.name} ${m.ts}: ${(err as Error).message}`);
      }
    }
    log(`#${info.name} (${id}): ${written} written, ${withheld} withheld, ${failed} failed so far`);
  }
  if (failed) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error(`backfill failed: ${(err as Error).message}`);
    process.exit(1);
  });
}
