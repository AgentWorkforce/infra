# Images (agent-relay-2026.11.19)

Step 5 of 0-START-HERE.md mirrors every image in the release's
`release-manifest.json` into your Artifact Registry, by digest. These are the
eight images; releases after agent-relay-2026.11.19 may add relaygate (last row) once it is approved for release. A GKE install runs five of them; the other three (RelayAuth and
the two other Relaycast names) are in the release for other profiles. Mirroring them is harmless and keeps the step identical
to the release manifest. In this release the three Relaycast names
(`relaycast`, `relaycast-eks-collector`, `relaycast-postgres`) share one image
digest.

| Release name | `image@digest` | Runs on GKE |
|---|---|---|
| relay-control | `ghcr.io/agentworkforce/relay-control@sha256:0e50e62e64880c0798411f792003568be17407959403d9a07f055bf96790b260` | yes |
| relay-webapp | `ghcr.io/agentworkforce/relay-webapp@sha256:da0cc80476eac734299c0c6ceb94e2bca7dae7913cce56a8ca8592cf086dd02e` | yes |
| relaycast-eks-collector | `ghcr.io/agentworkforce/relaycast-self-host@sha256:ec062ef901af15cf575b53a71d7eb09f2e6ab6e7c0d5be2da35339a275a5c6cc` | no (Relaycast with the collector adapter, for other profiles) |
| sessions-pipeline | `ghcr.io/agentworkforce/sessions-pipeline@sha256:459104bc432c96e475352e5147e0aaeabd53f51681d4ed8e05119e8406feda7f` | yes (worker, read API, ingest edge, search indexer, and `cloud-sql-setup.sh`) |
| sessions-migration-postgresql | `ghcr.io/cloudnative-pg/postgresql@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3` | yes (`cloud-sql-setup.sh` PostgreSQL client) |
| relaycast | `ghcr.io/agentworkforce/relaycast-self-host@sha256:ec062ef901af15cf575b53a71d7eb09f2e6ab6e7c0d5be2da35339a275a5c6cc` | no |
| relaycast-postgres | `ghcr.io/agentworkforce/relaycast-self-host@sha256:ec062ef901af15cf575b53a71d7eb09f2e6ab6e7c0d5be2da35339a275a5c6cc` | yes (Relaycast 12.10.0 on the PostgreSQL backend, Cloud SQL here) |
| relayauth | `ghcr.io/agentworkforce/relayauth@sha256:c23c92d25fdffef3b5838a1eef4c226925f859706365d9ccece229795b877288` | no |
| relaygate | `ghcr.io/agentworkforce/relaygate@sha256:29ca6cd1cc3c45b0dc4386fb471741987647116ae9e9f9268f85b05cc62ce6b6` | no (the optional built-in gate, `charts/relaygate`; not in the 2026.11.16 or 2026.11.19 manifests; listed from the first release that approves it) |

Copy each image by digest and keep the whole multi-architecture index, so the
digests stay the same in your registry (`crane copy` does this). The release
assets are signed: `gh attestation verify` against
`AgentWorkforce/infra/.github/workflows/release-agent-relay.yml` verifies
`agent-relay-0.7.81.tgz` and `release-manifest.json` if your process requires
it.

`release-images.values.yaml` (the release asset, with `__IMAGE_MIRROR_ROOT__`
replaced) points every workload at these digests under your mirror. Apply it
last. `values-gcp.yaml` on its own still names a different relay-control image
(NOT-QUALIFIED.md, item 4).
