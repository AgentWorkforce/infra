/**
 * layered-infra-ops's host. Deployed by .github/workflows/agent-deploy.yml
 * (layered-agents' composite deploy action) on push to main under agent/ or by
 * manual dispatch; never by hand without the owner.
 *
 * A new stack: it creates its own host role, instance profile and log groups
 * under the default layered-agent names. The admin role the host assumes
 * (awsAdmin) is created by layered-agents' platform deploy, not here. Its
 * network ids come from SSM under
 * /relaycast-agent-host/<stage>/network/ (published by relaycast-cloud's
 * agent-host stack), shared with the other agent hosts and only read here.
 *
 * State: the shared "layered-agents" store (alchemy-state-layered-agents-<account>-<region>-an),
 * prefix agents/infra-ops.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import * as Alchemy from "alchemy";
import * as AWS from "@alchemy.run/aws";
import * as Effect from "effect/Effect";
import { agentStatePrefix, guardProblems, layeredAgentHost, layeredAgentsState, readNetwork } from "@agentworkforce/layered-agent";
import agent from "./agent.config.ts";

const pin = process.env.LAYERED_AGENT_PIN_TEMPLATE;
const templateOverride = pin ? JSON.stringify(JSON.parse(readFileSync(pin, "utf8"))) : undefined;

export default Alchemy.Stack(
  "layered-agent-infra-ops",
  { providers: AWS.providers(), state: layeredAgentsState(agentStatePrefix(agent.input.name)) },
  Effect.gen(function* () {
    const stage = yield* Alchemy.Stage;
    const env = yield* AWS.AWSEnvironment.current;
    const problems = guardProblems({ stage, accountId: env.accountId, region: env.region }, agent);
    if (problems.length > 0) throw new Error(`infra-ops agent: not deployable; nothing was changed:\n  - ${problems.join("\n  - ")}`);
    const network = yield* Effect.promise(() => readNetwork(agent.names.platformPrefix, agent.region));
    return yield* layeredAgentHost(agent, {
      accountId: env.accountId,
      laneDir: fileURLToPath(new URL(".", import.meta.url)),
      network,
      templateOverride,
    });
  }),
);
