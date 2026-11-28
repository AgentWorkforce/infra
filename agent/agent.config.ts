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
  instanceType: "t3.medium",
  // Pinned (Canonical 24.04, serial 20261023, as relay-app), so Canonical's
  // moving "current" pointer does not make every deploy full. A new image is
  // a deliberate change of this id: a full deploy, dispatched with allow_restart.
  ami: "ami-08cf17e3856f70154",
  rootVolumeGiB: 150,
  laneFiles: ["lead-prompt.md", "setup-lane.sh", "load-secrets-lane.sh", "broker.ref"],
  aptPackages: ["shellcheck", "yamllint"],
  // The host assumes layered-agent-admin-infra-ops-<stage> (AdministratorAccess,
  // made by the layered-agents platform deploy); setup-lane.sh makes it the
  // agent user's default AWS profile.
  awsAdmin: true,
  // The host may also assume agent-cred-broker, the AWS credential broker's
  // one long-lived role (broker/terraform); setup-lane.sh makes it the agent
  // user's aws-cred-broker profile. Khaliq approved (2026-11-15). Must match
  // layered-agents infra/agents.ts, which builds the boundary.
  credentialBroker: true,
  secrets: [
    { envVar: "CLOUDFLARE_API_TOKEN_PARAM", param: "cloudflare-api-token", exportAs: "CLOUDFLARE_API_TOKEN" },
    { envVar: "CLOUDFLARE_ACCOUNT_ID_PARAM", param: "cloudflare-account-id", exportAs: "CLOUDFLARE_ACCOUNT_ID" },
    // GCP credential JSON (a keyless workload identity config, or a key): load-secrets-lane.sh writes it to a file.
    { envVar: "GCP_SA_KEY_PARAM", param: "gcp-service-account-key" },
    { envVar: "POSTHOG_API_KEY_PARAM", param: "posthog-personal-api-key", exportAs: "POSTHOG_PERSONAL_API_KEY" },
    { envVar: "POSTHOG_HOST_PARAM", param: "posthog-host", exportAs: "POSTHOG_HOST" },
    { envVar: "AZURE_TENANT_ID_PARAM", param: "azure-tenant-id", exportAs: "AZURE_TENANT_ID" },
    { envVar: "AZURE_CLIENT_ID_PARAM", param: "azure-client-id", exportAs: "AZURE_CLIENT_ID" },
    { envVar: "AZURE_CLIENT_SECRET_PARAM", param: "azure-client-secret", exportAs: "AZURE_CLIENT_SECRET" },
    { envVar: "AZURE_SUBSCRIPTION_ID_PARAM", param: "azure-subscription-id", exportAs: "AZURE_SUBSCRIPTION_ID" },
    // The credential broker's read-only Relaycast observer token: setup-lane.sh writes it to a
    // file only credbroker reads (never secrets.env). Must match layered-agents infra/agents.ts.
    { envVar: "RELAY_OBSERVER_TOKEN_PARAM", param: "relay-observer-token" },
  ],
  relaySessions: { tokenParam: `/relaycast-agent-host/${stage}/relay-sessions-token-infra-ops` },
  repos: ["AgentWorkforce/infra"],
  // New issues in the infra repo wake the lead, which DMs khaliq-gant (Khaliq, 2026-11-14).
  issueWatch: { repos: ["AgentWorkforce/infra"], notify: "khaliq-gant" },
  relayDescription: "infra-ops layered lead: AWS, Cloudflare, GCP, PostHog and Azure operator for AgentWorkforce/infra",
  // Codex until the Anthropic credit is topped up (Khaliq, 2026-11-24). Must match
  // layered-agents infra/agents.ts (#69), which lets the host read this key.
  // Low effort on the fast tier (kit 0.1.44): its turns are mostly approvals,
  // routing and webhook triage (Khaliq, 2026-11-27).
  lead: { harness: "codex", model: "gpt-6.2-astra", openaiKeyParam: `/relaycast-agent-host/${stage}/openai-api-key-infra-ops`, reasoningEffort: "low", serviceTier: "fast" },
  names: { platformPrefix: `/relaycast-agent-host/${stage}` },
  // The A2A card the lead publishes on the relay (set_relay_agent_card), so a
  // peer can see what to hand it before delegating. Delivered by hot update.
  card: {
    description:
      "layered-infra-ops is AgentWorkforce's infrastructure operator. It runs on its own host with administrator access in AWS, Owner in GCP and Azure, and signed-in Cloudflare and PostHog CLIs, next to the AgentWorkforce/infra Terraform modules and Helm charts. Hand it provisioning, DNS, credential rotation, analytics setup or an infrastructure investigation: it shows you the plan before it applies, asks you to confirm destructive or account-wide changes, and lands code changes as pull requests.",
    skills: [
      {
        id: "provision-cloud-resources",
        name: "Provision or change cloud resources",
        description:
          "Creates, changes or removes resources in AWS, GCP and Azure (buckets, databases, clusters, queues, networks, workload service accounts) with Terraform or the cloud CLIs. Replies with the plan before applying; deleting data, databases, clusters, IAM users or roles, or billing changes need you to confirm the exact plan in a second message. It does not change another layered agent's deploy role or host boundary.",
        tags: ["aws", "gcp", "azure", "terraform"],
        examples: [
          "Create a versioned, private S3 bucket for session archives in us-west-2 and send me its ARN",
          "Add a Cloud SQL Postgres 16 instance in agent-relay-internal for relayhistory and tell me the connection name",
          "Scale the agent-relay GKE node pool to 4 nodes and show me the plan first",
        ],
      },
      {
        id: "cloudflare-dns-and-workers",
        name: "Cloudflare DNS, Workers and R2",
        description:
          "Manages Cloudflare with wrangler and the API: DNS records and zones, Worker deploys (dry run first), routes, R2 buckets and KV.",
        tags: ["cloudflare", "dns", "workers"],
        examples: [
          "Point preview.agentrelay.com at the new load balancer with a proxied CNAME",
          "Deploy the Worker on my branch with wrangler and show me the dry run first",
          "List the R2 buckets with their sizes and which Workers bind them",
        ],
      },
      {
        id: "terraform-helm-changes",
        name: "Change the infra repo's Terraform and Helm",
        description:
          "Edits AgentWorkforce/infra's Terraform modules and Helm charts on a branch, runs the checks its CI runs (helm lint, Terraform checks, shellcheck, yamllint) and opens a pull request. Never pushes to main. Hand-made infra changes are written down in the PR so they can be captured in code.",
        tags: ["terraform", "helm", "pull-request"],
        examples: [
          "Add a podDisruptionBudget option to the relaycast chart and open a PR",
          "Expose the bucket ARN as an output of the object storage module",
          "Bump the relayfile chart's image digest to the one in this release and open a PR",
        ],
      },
      {
        id: "aws-credentials",
        name: "Short-lived AWS credentials for agents",
        description:
          "The AWS credential broker: DM me a request whose whole text is the JSON in agent/broker/AGENTS.md (AgentWorkforce/infra) and I return 15-60 minute credentials sealed to your own key. Workspace agents get the sandbox and neon-exit project access with no approval; anything else waits for Khaliq. Never send or ask for plaintext keys over Relay.",
        tags: ["aws", "credentials", "broker"],
        examples: [
          "30 minutes of read access to the neon-exit/runner secret in 500268966557 (us-east-1), encrypted to my key",
          "How do I get AWS credentials for the sandbox without SSO?",
        ],
      },
      {
        id: "rotate-credentials",
        name: "Rotate credentials",
        description:
          "Rotates API tokens, service principal secrets and service account keys in AWS, GCP, Azure, Cloudflare and PostHog, and updates the SSM parameters or secrets that hold them. Never prints, logs, commits or sends a secret value.",
        tags: ["secrets", "security"],
        examples: [
          "Rotate the Cloudflare API token CI uses and update its SSM parameter",
          "The Azure client secret for our deploy principal expires next week: rotate it and tell me where it is stored",
        ],
      },
      {
        id: "posthog-setup",
        name: "PostHog analytics setup",
        description:
          "Sets up and checks PostHog: projects, dashboards, insights, feature flags and event ingestion, through posthog-cli and the API.",
        tags: ["posthog", "analytics"],
        examples: [
          "Build a PostHog dashboard for the Desktop sign-in funnel",
          "Is the session_uploaded event still arriving in PostHog? Show the last 24 hours",
          "Create a feature flag for the new history search, off by default",
        ],
      },
      {
        id: "investigate-infrastructure",
        name: "Investigate infrastructure",
        description:
          "Looks into incidents, health and cost across the clouds: describes current state, reads logs and metrics, checks certificates, ingress and DNS, and reports findings with the commands and resource ids behind them.",
        tags: ["investigation", "incident", "cost"],
        examples: [
          "Why is the agent-relay ingress on GKE returning 502s? Check backends and certificates",
          "What drove last week's AWS bill increase?",
          "An agent host is at 95% disk: find what is using it",
        ],
      },
    ],
    tags: ["infra", "aws", "gcp", "azure", "cloudflare", "posthog", "terraform", "helm"],
    documentationUrl: "https://github.com/AgentWorkforce/infra",
  },
});
