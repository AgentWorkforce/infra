# Agent Relay 2026.11.6

Chart agent-relay 0.7.11 (same content as 0.7.10). Builds on 2026.11.5; read
its notes first.

## What changes

- **Sessions image from relayhistory-pipeline `02c8951d`**
  (`sha256:3d9c0a4d…`): on Google Cloud Storage, session transcripts and
  metadata open. Earlier images indexed every upload as stored in S3 (the queue
  event parser stamped `s3`), so `GET /v1/sessions/<id>/turns` and `/metadata`
  answered `501 turns_canonical_pointer_invalid` on GKE. Uploads now record the
  configured Locker provider.
- **Repair for sessions already indexed as S3 on a GCS install:**
  `src/session-pipeline/index-provider-restamp.ts` in the same image. Run it
  once, from the services image, with the read API's `LOCKER_PROVIDER=gcs` and
  `LOCKER_BUCKET`, and the database URL in `INDEX_PROVIDER_RESTAMP_DATABASE_URL`
  or `INDEX_PROVIDER_RESTAMP_DATABASE_URL_FILE`. Without `--apply` it only
  plans; `--apply` restamps one row at a time and prints counts. Exit codes: 0
  done, 3 incomplete (rerun), 5 some rows kept by ingest guards, 2 gate
  failure, 4 database error. Don't update `session_index` by hand: its ingest
  triggers would silently skip rows.
- Also in that image, inert on a self-hosted install: operator backlog tools
  (backfill, export, presence; run only by hand), `BACKLOG_OPS_EXECUTE_ENABLED`
  (a constant read by the GitHub dispatcher only) and `CANONICAL_READ_ENABLED`
  (hosted Cloudflare reader only).
- relay-control and relay-webapp are unchanged from 2026.11.5 (co-brand "for"
  line).

On GKE, `SERVICES_IMAGE` (guide step 7) is the Sessions digest above.
