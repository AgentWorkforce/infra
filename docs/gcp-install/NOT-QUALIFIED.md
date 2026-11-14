# What agent-relay-2026.11.6 does not yet qualify on GKE

The steps in 0-START-HERE.md were run end to end on a private regional GKE
cluster (Kubernetes 1.35, Workload Identity, IAP-only control plane) with the
release assets of agent-relay-2026.11.1, then again in a new Google Cloud
project (regional GKE 1.36) on 2026.11.1. The first install was then upgraded
through 2026.11.4 to 2026.11.6 and rechecked. These are the places where the GKE
path differs from what the release itself qualifies. Read them before a
production rollout.

1. **GCS session reads: fixed in 2026.11.6; installs upgraded from
   2026.11.1–2026.11.5 must re-stamp once.** Before 2026.11.6 the services
   recorded every session uploaded to GCS with `storage_provider = s3`, so the
   read API refused them (dashboard replay, `/v1/sessions/<id>/events` and
   `/turns` answered `501`). The 2026.11.6 Sessions image
   (relayhistory-pipeline `02c8951d`) records the Locker's real provider and
   ships an operator re-stamp tool for rows recorded before. Verified on a GKE
   install upgraded 2026.11.4 → 2026.11.6: the re-stamp fixed every older row
   (plan, then `--apply`, exit 0), a newly uploaded session was recorded as
   `gcs`, and the end-to-end cases for delivery, reads, durability and the
   sessions API (including `/turns`) passed. Upgrading from an earlier release:
   run "Re-stamp sessions uploaded before 2026.11.6" in 0-START-HERE.md. A
   fresh 2026.11.6 install doesn't need it.

   The end-to-end driver (`scripts/selfhost/e2e-gcp-proof.sh`) also runs an
   isolation case and a cleanup case that create a flow and list flow workers.
   This guide installs with flows off, so those two cases fail with
   `feature_not_enabled` / `403` even with `--skip-flows`; enable flows to run
   them.

2. **The release image overlay is the EKS one.** `release-images.values.yaml`
   and the install pack are generated for the `eks` profile, and the release
   ships no GCP overlay or GCP pack. The images are cloud-neutral (the same
   digests run on both clouds) and this guide applies that overlay on GKE,
   which the dry run proved. But the release pipeline doesn't yet produce or
   check a GKE overlay.

3. **No automated first install on GKE.** `scripts/selfhost/agent-relay-upgrade.sh
   --first-install` supports only the EKS profiles (an ECR registry, RDS
   snapshots). On GKE the install is the manual Helm sequence in steps 8–13,
   and upgrades are manual Helm upgrades too, with a Cloud SQL backup or
   export taken first.

4. **`values-gcp.yaml` at the tag pins the previous release's images**
   (sessions-pipeline `77022c5b`, relay-control 0.5.16). Only the release
   overlay brings the 2026.11.6 images. Always apply
   `release-images.values.yaml` last; without it you would install older
   images.

5. **Search runs in Cloud SQL, not OpenSearch.** The chart's OpenSearch
   backend signs requests with AWS SigV4 only, so the `gcp/search` Terraform
   module (OpenSearch on GKE with basic auth) can't serve this install. The
   guide uses `search.backend: postgres`. Fine for a proof of concept; search
   at large scale on GKE isn't load tested.

6. **`cloud-sql-setup.sh` at the tag has two defects** that this guide's copy
   fixes (the repository fix is AgentWorkforce/infra#276):
   - it rejects the Terraform output `admin_password_secret_id` (a full
     `projects/…/secrets/…` name) with a 404;
   - the CA bundle it writes has one more trailing newline than Terraform's,
     so the `caSha256` pins in `managed-values.json` don't match and the read
     API, ingest edge and search indexer fail with `PostgresTlsConfigError`.

   It also refuses to rerun `pre` after `post` (by design: nothing changes).

7. **Memorystore without AUTH.** The pinned services can't send Redis AUTH
   credentials, so the instance uses TLS (server authentication) with AUTH off.
   Network reachability is the only access control.

8. **Not HA.** Relay control, the dashboard, Relaycast (PostgreSQL backend)
   and the search indexer each run one replica, as on EKS.

9. **Release notes.** The GitHub release notes for agent-relay-2026.11.6, with
   `docs/releases/agent-relay-2026.11.5.md` and the 2026.11.2 notes before it,
   describe the changes; the published GitHub release and its signed assets
   are final.

10. **Not covered by the dry run:** CMEK keys, the optional event-driven
   pipeline (`enable_functions`), GKE Autopilot, Shared VPC, SSO (OIDC/Okta),
   titles and summaries with an LLM, and the desktop app's live upload against
   this install (the upload path was proven with the e2e driver).

11. **Desktop builds for a GKE install don't update themselves.** The signed
   desktop release feed the control API can serve signs with AWS KMS and
   stores in S3 only (`SELFHOST_DESKTOP_FEED_SIGNER=awskms`,
   `SELFHOST_DESKTOP_FEED_STORAGE=s3`). A desktop build for a GKE install works,
   but a newer version means installing the new build over the old one.
