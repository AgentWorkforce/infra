/**
 * layered-infra-ops: the infra operator agent for this repo. One EC2 host on
 * the relay as layered-infra-ops, with this repo checked out and the AWS,
 * Cloudflare, GCP, PostHog and Azure CLIs signed in. Any relay peer may hand
 * it infra work (kit delegation.md), with full permissions in each cloud.
 * Built by @agentworkforce/layered-agent; lane files are the rest of this folder.
 *
 * A fresh stack on default names (layered-agent-infra-ops-<stage>), secrets
 * under /infra-ops/<stage>/. Only platformPrefix is shared, read only: the
 * network ids and the kit's Anthropic and Nango parameters.
 *
 * Must match layered-agents infra/agents.ts: awsAdmin, secrets and the
 * sessions token. The host boundary is built from that copy, so a grant here
 * that isn't there is capped to nothing.
 */
import { defineLayeredAgent } from "@agentworkforce/layered-agent";

const stage = process.env.LAYERED_AGENT_STAGE ?? "dev";

export default defineLayeredAgent({
  name: "infra-ops",
  repo: "AgentWorkforce/infra",
  stage,
  accountId: process.env.LAYERED_AGENT_ACCOUNT_ID,
  arch: "x64",
  instanceType: "m7i.xlarge",
  // Pinned (Canonical 24.04, serial 20261023, as relay-app), so Canonical's
  // moving "current" pointer does not make every deploy full. A new image is
  // a deliberate change of this id: a full deploy, dispatched with allow_restart.
  ami: "ami-08cf17e3856f70154",
  rootVolumeGiB: 150,
  laneFiles: ["lead-prompt.md", "setup-lane.sh", "load-secrets-lane.sh"],
  aptPackages: ["shellcheck", "yamllint"],
  // The host assumes layered-agent-admin-infra-ops-<stage> (AdministratorAccess,
  // made by the layered-agents platform deploy); setup-lane.sh makes it the
  // agent user's default AWS profile.
  awsAdmin: true,
  secrets: [
    { envVar: "CLOUDFLARE_API_TOKEN_PARAM", param: "cloudflare-api-token", exportAs: "CLOUDFLARE_API_TOKEN" },
    { envVar: "CLOUDFLARE_ACCOUNT_ID_PARAM", param: "cloudflare-account-id", exportAs: "CLOUDFLARE_ACCOUNT_ID" },
    // A service-account key is JSON: load-secrets-lane.sh writes it to a file.
    { envVar: "GCP_SA_KEY_PARAM", param: "gcp-service-account-key" },
    { envVar: "POSTHOG_API_KEY_PARAM", param: "posthog-personal-api-key", exportAs: "POSTHOG_PERSONAL_API_KEY" },
    { envVar: "POSTHOG_HOST_PARAM", param: "posthog-host", exportAs: "POSTHOG_HOST" },
    { envVar: "AZURE_TENANT_ID_PARAM", param: "azure-tenant-id", exportAs: "AZURE_TENANT_ID" },
    { envVar: "AZURE_CLIENT_ID_PARAM", param: "azure-client-id", exportAs: "AZURE_CLIENT_ID" },
    { envVar: "AZURE_CLIENT_SECRET_PARAM", param: "azure-client-secret", exportAs: "AZURE_CLIENT_SECRET" },
    { envVar: "AZURE_SUBSCRIPTION_ID_PARAM", param: "azure-subscription-id", exportAs: "AZURE_SUBSCRIPTION_ID" },
  ],
  relaySessions: { tokenParam: `/relaycast-agent-host/${stage}/relay-sessions-token-infra-ops` },
  repos: ["AgentWorkforce/infra"],
  relayDescription: "infra-ops layered lead: AWS, Cloudflare, GCP, PostHog and Azure operator for AgentWorkforce/infra",
  names: { platformPrefix: `/relaycast-agent-host/${stage}` },
});
