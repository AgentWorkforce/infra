// Device login for an existing fixture workspace; stdout is private token state.
import { readFileSync } from "node:fs";
const input = JSON.parse(readFileSync(0, "utf8"));
const bootstrap = readFileSync("/var/run/agent-relay/secrets/selfhost-bootstrap-token", "utf8").trim();
async function post(path, body, token) {
  const response = await fetch(`http://127.0.0.1:3000${path}`, {
    method: "POST", signal: AbortSignal.timeout(10000),
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`workspace device login failed: HTTP ${response.status}`);
  return response.json();
}
const start = await post("/api/v1/auth/device/start", { client_name: "kind-pipeline-read" });
await post("/api/v1/auth/device/approve", {
  action: "approve", user_code: start.user_code, user_id: input.userId, workspace_id: input.workspaceId,
}, bootstrap);
const tokens = await post("/api/v1/auth/device/token", { device_code: start.device_code });
if (typeof tokens.access_token !== "string") throw new Error("missing workspace device session");
process.stdout.write(JSON.stringify({ accessToken: tokens.access_token }));
