# Images (agent-relay-2026.11.6)

Step 5 of 0-START-HERE.md mirrors every image in the release's
`release-manifest.json` into your Artifact Registry, by digest. These are the
eight images. A GKE install runs five of them; the other three (RelayAuth and
the two other Relaycast builds) are in the release for other profiles. Mirroring them is harmless and keeps the step identical
to the release manifest.

| Release name | `image@digest` | Runs on GKE |
|---|---|---|
| relay-control | `ghcr.io/agentworkforce/relay-control@sha256:46e2cb514ba2ab3ec753fb3f3c0e17caff562350cbb671dbfc9f49b9463e0d49` | yes |
| relay-webapp | `ghcr.io/agentworkforce/relay-webapp@sha256:9414d55446bbd4db9c82e344c109a4e829d76f536a49bd5917e7ebcc86ed3f23` | yes |
| relaycast-eks-collector | `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68f09d5e2e686a17088f9ad533978ef13d974a47d6c212d8eedbde` | no (Relaycast with the collector adapter, for other profiles) |
| sessions-pipeline | `ghcr.io/agentworkforce/sessions-pipeline@sha256:3d9c0a4dff67c92da30964857713e625f3f967bc2ff98851614a70adbb4fe3fe` | yes (worker, read API, ingest edge, search indexer, and `cloud-sql-setup.sh`) |
| sessions-migration-postgresql | `ghcr.io/cloudnative-pg/postgresql@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3` | yes (`cloud-sql-setup.sh` PostgreSQL client) |
| relaycast | `ghcr.io/agentworkforce/relaycast-self-host@sha256:84f59482cb82f3c50d38f45cfca7d004cffaa95652782dbfc93c179cc343ac59` | no |
| relaycast-postgres | `ghcr.io/agentworkforce/relaycast-self-host@sha256:cc2a79f02d39978fa04322b5a45497737ff137bc2a5db5615c7eee690030de83` | yes (Relaycast 12.8.0-pg.3 on the PostgreSQL backend, Cloud SQL here) |
| relayauth | `ghcr.io/agentworkforce/relayauth@sha256:c23c92d25fdffef3b5838a1eef4c226925f859706365d9ccece229795b877288` | no |

Copy each image by digest and keep the whole multi-architecture index, so the
digests stay the same in your registry (`crane copy` does this). The release
assets are signed: `gh attestation verify` against
`AgentWorkforce/infra/.github/workflows/release-agent-relay.yml` verifies
`agent-relay-0.7.11.tgz` and `release-manifest.json` if your process requires
it.

`release-images.values.yaml` (the release asset, with `__IMAGE_MIRROR_ROOT__`
replaced) points every workload at these digests under your mirror. Apply it
last. `values-gcp.yaml` on its own still names the previous release's images
(NOT-QUALIFIED.md, item 4).
