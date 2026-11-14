# Agent Relay 2026.11.3

A release for GKE installs, on top of 2026.11.2 (read its notes first,
including "Upgrading: the Sessions index step"). Chart agent-relay 0.7.8.
Upgrade with the usual release upgrader (`scripts/selfhost/agent-relay-upgrade.sh`,
plan first, then `--apply`).

## What changes

- **Sessions image from relayhistory-pipeline `601d6a65`**: desktop direct
  uploads are no longer refused with `upload_digest_mismatch` on S3-compatible
  stores that serve objects back with `content-encoding: zstd` (the stored
  bytes are hashed). It also carries the GCS `storage_provider` fix (GKE
  `/turns` reads, NOT-QUALIFIED item 1), and relayscrubber 0.5.0-alpha.9. The
  ruleset is still 10 and the engine contract is unchanged. A repository's
  `host/owner/repo` project key is kept instead of being redacted. The other
  new commits (private-ingest deploy controls, operator backlog tools) are
  off unless configured.
- **Co-brand "for" line**: with a customer logo set, the sign-in pages show
  "for <logo> <name>" under the Agent Relay lockup instead of a rule and a
  stacked lockup (relay-control `0.5.23` from #133; relay-webapp from relay-web
  #139). Without a logo, nothing changes.
- **GKE installs** (from an end-to-end install into a new Google Cloud
  project):
  - the GCP Terraform example can create the image mirror and grant the GKE
    node service account read access on it (`image_mirror_repository`,
    `gke_node_service_account`). In a new project the nodes had no access, and
    step 8's Job timed out on `403` image pulls. Off unless set, so an existing
    install's plan doesn't change;
  - co-branding (relay-webapp chart 0.2.5): `global.branding.logo.dashboardKey`
    serves a second PNG beside the sign-in mark, so the sign-in page shows the
    customer's mark under the Agent Relay lockup and the dashboard shows a
    combined logo. `values-branding-example.yaml` shows the whole set, and the
    install's `values.yaml` carries it commented out;
  - `first-admin.sh` does the first admin's sign-in through the API when the
    admin can't reach the cluster: the password goes to Secret Manager first,
    and neither it nor the setup key is printed.
