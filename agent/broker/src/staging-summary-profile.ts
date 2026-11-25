/** Application authority for the paired Cloud #6658 / Control #342 staging check.
 * The broker has no application issuer or private operator handoff bound yet.
 */
export const stagingSummaryProfile = {
  name: "staging-short-summary-status",
  environment: "staging",
  purpose: "paired short_summary_status check for cloud#6658 and relay-control#342",
  durationSeconds: 4 * 60 * 60,
  workspace: "dedicated synthetic test workspace",
  identities: [
    { name: "fixture-writer", access: "write synthetic fixture session only" },
    { name: "cloud-reader", audience: "Cloud MCP", access: "read only" },
    { name: "control-reader", audience: "Control MCP", access: "read only" },
  ],
  issuance: "unavailable",
  reason: "Staging application issuer, fixture binding, reader audiences and private handoff are unverified.",
} as const;
