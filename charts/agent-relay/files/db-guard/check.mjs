// Agent Relay database privilege check (databaseGuard.privilegeCheck): the
// pre-install/pre-upgrade hook. The rules live in lib.mjs (relaycast's
// verifyIdentity). Prints one line per URL, then the problems; exits 1 when
// any URL fails. Never prints a URL or password.
import { writeFileSync } from "node:fs";
import { checkTargets, POINTER } from "./lib.mjs";

const results = await checkTargets();

const width = Math.max(...results.map((r) => r.label.length), 10);
console.log("Agent Relay database privilege check (databaseGuard.privilegeCheck)");
for (const r of results) console.log(`  ${r.status.padEnd(4)} ${r.label.padEnd(width)}  ${r.login ? `login=${r.login}  ` : ""}${r.detail}`);
const failures = results.filter((r) => r.status === "FAIL");
if (failures.length === 0) {
  console.log(`ok: ${results.filter((r) => r.status === "ok").length} database login(s) verified`);
  process.exit(0);
}
const message = [
  "AR_DB_LOGIN: the database credentials in this release's Secrets are wrong; the install/upgrade was stopped before any workload changed:",
  ...failures.map((r) => `  - ${r.label} ${r.summary ?? r.detail}.`),
  `${POINTER} Then run helm again.`,
].join("\n");
console.error(message);
try {
  writeFileSync("/dev/termination-log", message.slice(0, 4000));
} catch {}
process.exit(1);
