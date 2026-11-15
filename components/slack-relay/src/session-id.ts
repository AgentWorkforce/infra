import { createHash } from "node:crypto";

/** A stable Claude session id (UUID-shaped) for an agent: the same agent always resumes the same session. */
export function sessionIdFor(agentName: string): string {
  const h = createHash("sha256").update(`agent-relay-slack-session:${agentName}`).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
}
