# Images (agent-relay-2026.11.3)

Step 5 of 0-START-HERE.md mirrors every image in the release's
`release-manifest.json` into your Artifact Registry, by digest. These are the
eight images. A GKE install runs five of them; the other three (RelayAuth, the
non-collector Relaycast build and the Relaycast PostgreSQL-backend build) are in
the release for other profiles. Mirroring them is harmless and keeps the step identical
to the release manifest.

| Release name | `image@digest` | Runs on GKE |
|---|---|---|
| relay-control | `ghcr.io/agentworkforce/relay-control@sha256:e0611386a080b4e8e0c0629fdb23f5cf48027e7ceed77322b8086337e54f5112` | yes |
| relay-webapp | `ghcr.io/agentworkforce/relay-webapp@sha256:8cadf08921b16ac4a19d0c4daecad1813e521bdfc9b141fb284415fd6349d499` | yes |
| relaycast-eks-collector | `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68f09d5e2e686a17088f9ad533978ef13d974a47d6c212d8eedbde` | yes (Relaycast with the optional, off-by-default collector adapter; not EKS-specific) |
| sessions-pipeline | `ghcr.io/agentworkforce/sessions-pipeline@sha256:42ccfba3c085d525846045a646b4c82cf8a849367ec94751934b3749fa90a36f` | yes (worker, read API, ingest edge, search indexer, and `cloud-sql-setup.sh`) |
| sessions-migration-postgresql | `ghcr.io/cloudnative-pg/postgresql@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3` | yes (`cloud-sql-setup.sh` PostgreSQL client) |
| relaycast | `ghcr.io/agentworkforce/relaycast-self-host@sha256:84f59482cb82f3c50d38f45cfca7d004cffaa95652782dbfc93c179cc343ac59` | no |
| relaycast-postgres | `ghcr.io/agentworkforce/relaycast-self-host@sha256:cc2a79f02d39978fa04322b5a45497737ff137bc2a5db5615c7eee690030de83` | no (Relaycast 12.8.0-pg.3, for the PostgreSQL-backend profiles) |
| relayauth | `ghcr.io/agentworkforce/relayauth@sha256:c23c92d25fdffef3b5838a1eef4c226925f859706365d9ccece229795b877288` | no |

Copy each image by digest and keep the whole multi-architecture index, so the
digests stay the same in your registry (`crane copy` does this). The release
assets are signed: `gh attestation verify` against
`AgentWorkforce/infra/.github/workflows/release-agent-relay.yml` verifies
`agent-relay-0.7.8.tgz` and `release-manifest.json` if your process requires
it.

`release-images.values.yaml` (the release asset, with `__IMAGE_MIRROR_ROOT__`
replaced) points every workload at these digests under your mirror. Apply it
last. `values-gcp.yaml` on its own still names the previous release's images
(NOT-QUALIFIED.md, item 4).
