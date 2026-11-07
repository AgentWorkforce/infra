// Runs inside relaycontrol. Only non-secret first-boot identifiers leave it.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export async function waitForDefaultWorkspace(token, {
  request = fetch, now = Date.now,
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
  timeoutMs = 120_000,
} = {}) {
  const deadline = now() + timeoutMs;
  while (now() < deadline) {
    try {
      const headers = { authorization: `Bearer ${token}` };
      const orgs = await request("http://127.0.0.1:3000/api/v1/organizations", { headers, signal: AbortSignal.timeout(5000) });
      if (orgs.ok) {
        const { organizations } = await orgs.json();
        if (organizations?.length === 1) {
          const orgId = organizations[0].id;
          const response = await request(`http://127.0.0.1:3000/api/v1/organizations/${orgId}/workspaces`, { headers, signal: AbortSignal.timeout(5000) });
          if (response.ok) {
            const body = await response.json();
            const workspace = body.workspaces?.find(w => w.name === "Default");
            if (workspace?.id) return { orgId, workspaceId: workspace.id };
          }
        }
      }
    } catch {
      // Startup resets, timeouts and non-JSON proxy responses are retryable.
      // Never echo response bodies, headers or the bootstrap token.
    }
    await sleep(2000);
  }
  throw new Error("first-boot organization/Default workspace not ready after 120s");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const token = readFileSync("/var/run/agent-relay/secrets/selfhost-bootstrap-token", "utf8").trim();
  console.log(JSON.stringify(await waitForDefaultWorkspace(token)));
}
