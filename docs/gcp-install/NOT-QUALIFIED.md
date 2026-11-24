# What agent-relay-2026.11.16 does not yet qualify on GKE

The steps in 0-START-HERE.md were run end to end on a private regional GKE
cluster (Kubernetes 1.35, Workload Identity, IAP-only control plane) with the
release assets of agent-relay-2026.11.1, then again in a new Google Cloud
project (regional GKE 1.36) on 2026.11.1. The first install was then upgraded
through 2026.11.4 to 2026.11.6 and rechecked. These are the places where the GKE
path differs from what the release itself qualifies. Read them before a
production rollout. The guide's values render against agent-relay-2026.11.16;
that release was not installed on GKE.

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
   fresh install of 2026.11.6 or later doesn't need it.

   The end-to-end driver (`scripts/selfhost/e2e-gcp-proof.sh`) also runs an
   isolation case and a cleanup case that create a flow and list flow workers.
   This guide installs with flows off, so those two cases fail with
   `feature_not_enabled` / `403` even with `--skip-flows`; enable flows to run
   them.

   **Long sessions need a longer read deadline.** The read API reads a
   session's chunks from GCS one after another (about 30 ms each), so with the
   default 3 s deadline a session of more than about 100 chunks answers
   `501 turns_canonical_deadline`. The guide's `values.yaml` sets
   `READ_API_CANONICAL_DEADLINE_MS=15000` in `sessionReadApi.extraEnv`; keep
   it. Parallel chunk reads are coming in a later Sessions image.

   **`/turns` and `/metadata` are empty on self-host.** They serve Agent Relay
   conversation-turn records, which only the hosted service forwards into
   ingest; nothing in a self-hosted install produces them, so `/turns` answers
   200 with no turns and `/metadata` 404. The session itself is complete:
   `/events` carries the whole transcript, and the dashboard's session view
   renders the full conversation from it. Session summaries need titles and
   summaries turned on
   (`__LLM_MODEL__`, after install).

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

4. **`values-gcp.yaml` at the tag pins a different relay-control image from
   the release's.** It names relay-control 0.5.35 (`1cb5bd71`); the release
   pins `0e50e62e`. Its sessions-pipeline digest (`459104bc`) matches the
   release. Only the release overlay brings the 2026.11.19 relay-control
   image. Always apply `release-images.values.yaml` last; without it you would
   install a different relay-control image from the release's.

5. **Search runs in Cloud SQL, not OpenSearch.** The chart's OpenSearch
   backend signs requests with AWS SigV4 only, so the `gcp/search` Terraform
   module (OpenSearch on GKE with basic auth) can't serve this install. The
   guide uses `search.backend: postgres`. Fine for a proof of concept; search
   at large scale on GKE isn't load tested.

6. **Use this guide's `cloud-sql-setup.sh`, not the tag's
   `scripts/selfhost/cloud-sql-setup.sh`.** The tag's copy writes `HOOPDB_URL`
   without the CA file the session-brief worker needs
   (`sslrootcert=/etc/postgres-ca/ca.crt`, AgentWorkforce/infra#359); this
   guide's copy adds it. (The two defects fixed by AgentWorkforce/infra#276,
   the `admin_password_secret_id` 404 and the CA bundle's extra trailing
   newline, are fixed in both copies.)

   It also refuses to rerun `pre` after `post` (by design: nothing changes).

7. **Memorystore without AUTH.** The pinned services can't send Redis AUTH
   credentials, so the instance uses TLS (server authentication) with AUTH off.
   Network reachability is the only access control.

8. **Not HA.** Relay control, the dashboard, Relaycast (PostgreSQL backend)
   and the search indexer each run one replica, as on EKS.

9. **Release notes.** The GitHub release notes for agent-relay-2026.11.19, with
   `docs/releases/agent-relay-2026.11.5.md` and the 2026.11.2 notes before it,
   describe the changes; the published GitHub release and its signed assets
   are final.

10. **Not covered by the dry run:** CMEK keys, the optional event-driven
   pipeline (`enable_functions`), GKE Autopilot, Shared VPC, SSO (OIDC/Okta),
   titles and summaries with an LLM, and the desktop app's live upload against
   this install (the upload path was proven with the e2e driver).

11. **Desktop builds for a GKE install update themselves only from relay-control
   0.5.25.** agent-relay-2026.11.19 pins a relay-control built after the
   2026.11.16 pin (0.5.34), so past 0.5.25. From 0.5.25 relay-control stores the signed desktop feed in a GCS bucket
   (`desktop_feed_bucket_name`, step 4) and signs it with a key file
   (`relay-control.desktopFeed.signingKeys`). On a release that pins an older
   relay-control, a newer desktop version means installing the new build over
   the old one.
