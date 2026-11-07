// Runs inside relaycontrol. Only non-secret first-boot identifiers leave it.
import { readFileSync } from "node:fs";
const token = readFileSync("/var/run/agent-relay/secrets/selfhost-bootstrap-token", "utf8").trim();
const deadline = Date.now() + 120_000;
while (Date.now() < deadline) {
  const headers = { authorization: `Bearer ${token}` };
  const orgs = await fetch("http://127.0.0.1:3000/api/v1/organizations", { headers, signal: AbortSignal.timeout(5000) });
  if (orgs.ok) {
    const { organizations } = await orgs.json();
    if (organizations?.length === 1) {
      const orgId = organizations[0].id;
      const response = await fetch(`http://127.0.0.1:3000/api/v1/organizations/${orgId}/workspaces`, { headers, signal: AbortSignal.timeout(5000) });
      const body = await response.json();
      const workspace = body.workspaces?.find(w => w.name === "Default");
      if (response.ok && workspace?.id) {
        console.log(JSON.stringify({ orgId, workspaceId: workspace.id }));
        process.exit(0);
      }
    }
  }
  await new Promise(r => setTimeout(r, 2000));
}
throw new Error("first-boot organization/Default workspace not ready after 120s");
