# Images (agent-relay-2026.11.1)

Step 5 of 0-START-HERE.md mirrors every image in the release's
`release-manifest.json` into your Artifact Registry, by digest. These are the
eight images. A GKE install runs five of them; the other three (RelayAuth,
legacy RelayHistory and the non-collector Relaycast build) are in the release
for other profiles. Mirroring them is harmless and keeps the step identical
to the release manifest.

| Release name | `image@digest` | Runs on GKE |
|---|---|---|
| relay-control | `ghcr.io/agentworkforce/relay-control@sha256:7eaee303a9da600a55014d221f55e52b1d51d12df9af5ea1e2fc3d880576f6f8` | yes |
| relay-webapp | `ghcr.io/agentworkforce/relay-webapp@sha256:3171edd07263a63d3f99143e91706d70b857d494f819cba6b283193871888a98` | yes |
| relaycast-eks-collector | `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68f09d5e2e686a17088f9ad533978ef13d974a47d6c212d8eedbde` | yes (Relaycast with the optional, off-by-default collector adapter; not EKS-specific) |
| sessions-pipeline | `ghcr.io/agentworkforce/sessions-pipeline@sha256:aa8d86854db28debe326bcffd705e44ae93e20f40f587d80d635bc3b404ed117` | yes (worker, read API, ingest edge, search indexer, and `cloud-sql-setup.sh`) |
| sessions-migration-postgresql | `ghcr.io/cloudnative-pg/postgresql@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3` | yes (`cloud-sql-setup.sh` PostgreSQL client) |
| relaycast | `ghcr.io/agentworkforce/relaycast-self-host@sha256:84f59482cb82f3c50d38f45cfca7d004cffaa95652782dbfc93c179cc343ac59` | no |
| relayauth | `ghcr.io/agentworkforce/relayauth@sha256:c23c92d25fdffef3b5838a1eef4c226925f859706365d9ccece229795b877288` | no |
| relayhistory | `ghcr.io/agentworkforce/relayhistory@sha256:d3166bb14e1d6043426a4dd8cc05408b94574c8d79ad5fd6e789e0de00ab371b` | no |

Copy each image by digest and keep the whole multi-architecture index, so the
digests stay the same in your registry (`crane copy` does this). The release
assets are signed: `gh attestation verify` against
`AgentWorkforce/infra/.github/workflows/release-agent-relay.yml` verifies
`agent-relay-0.6.53.tgz` and `release-manifest.json` if your process requires
it.

`release-images.values.yaml` (the release asset, with `__IMAGE_MIRROR_ROOT__`
replaced) points every workload at these digests under your mirror. Apply it
last. `values-gcp.yaml` on its own still names the previous release's images
(NOT-QUALIFIED.md, item 4).
