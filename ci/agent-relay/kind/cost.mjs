// Exercise reported cost/usage attribution through real authenticated ingest.
// This is fixture data, not a vendor bill or a live model invocation.
import { readFileSync } from "node:fs";
const input = JSON.parse(readFileSync(0, "utf8"));
async function request(url, token, body) {
  const response = await fetch(url, {
    method: "POST", signal: AbortSignal.timeout(15000),
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`cost fixture request failed: HTTP ${response.status}`);
  return response.json();
}
const session = await request(
  `http://127.0.0.1:3000/api/v1/workspaces/${input.workspaceId}/relayhistory/session`,
  input.accessToken, { mode: "sync", label: "kind-cost-fixture" });
if (typeof session.accessToken !== "string") throw new Error("missing real History sync session");
const fixture = { eventId: `assistant:kind-cost-${input.marker}`, inputTokens: 320, outputTokens: 52, costUsdMicros: 125000 };
const payload = {
  batchId: `kind-cost-${input.marker}`, machine: { id: `kind-cost-${input.marker}` }, records: [{
    kind: "assistant", source: "claude", sessionId: input.sessionId,
    eventId: fixture.eventId, ts: new Date().toISOString(),
    content: `Reported cost fixture ${input.marker}`, actorRole: "assistant",
    provider: "kind-fixture", model: "kind-cost-fixture",
    usage: { input: fixture.inputTokens, output: fixture.outputTokens }, costUsdMicros: fixture.costUsdMicros,
  }],
};
// The caller sends this through the verified public History TLS origin.
// This stdout is private protocol state, never a public proof detail.
process.stdout.write(JSON.stringify({ ...fixture, accessToken: session.accessToken, payload }));
