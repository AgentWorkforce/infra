# Operator session erase upgrade

Operator session erase is a 2026.11.2 opt-in hard-delete path. The chart support
is inert by default and does not select a Sessions image. Use only an approved
2026.11.2 image that implements the runtime contract documented at
relayhistory-pipeline commit `3b3fddd4`.

The feature has three independent controls:

- `global.operatorSessionErase.fenceEnforced` puts the permanent erase fence on
  every ingest, active consumer, and read-API replica.
- `sessions-pipeline.operatorSessionErase.bytes.enabled` lets the ingest edge
  remove the canonical Locker bytes and search projection.
- `sessions-pipeline.operatorSessionErase.api.enabled` and
  `relay-control.sessionErasureApi.enabled` expose the operator endpoint and
  Control handoff. The umbrella requires these two switches, URL, and Secret
  references to agree.

All three controls default to `false`. A default render is unchanged.

## Prepare

1. Back up PostgreSQL and confirm the Locker bucket is versioned. Record the
   current image digests and Helm revision.
2. Create a dedicated API secret of at least 32 random characters. Store it in
   a Kubernetes Secret under the key selected by
   `operatorSessionErase.api.secretKey`; never put the value in values or a
   command argument. During rotation, add the old value under
   `previousSecretKey`, deploy the new current value, then remove the previous
   key after all callers have moved.
3. Create dedicated S3 eraser credentials in another Secret. Scope them to the
   same versioned bucket and key root used by ingest. Do not reuse the ingest
   writer credentials. The chart derives bucket, region, endpoint, and key root
   from `ingestEdge`; they cannot be configured a second time.
4. For PostgreSQL search, provision the dedicated
   `bulls96_session_erase_search` login with the supported RDS setup flow:

   ```sh
   PROVISION_ERASE_SEARCH_LOGIN=1 scripts/selfhost/rds-setup.sh post
   ```

   Supply credentials through the script's documented environment/stdin path,
   never argv. Put the resulting URL in a dedicated Secret and reference it via
   `operatorSessionErase.bytes.postgresSearch`. For OpenSearch, instead create
   a dedicated basic-auth user and Secret for
   `operatorSessionErase.bytes.opensearch`; the existing index URL and prefix
   remain the target.
5. Complete the image's migrations before rolling runtime replicas. Ensure
   `ingestEdge.postgres.poolMax` is at least 2.

## Roll out

1. Drain any asynchronous ingest admission work. Set
   `ingestEdge.admission.mode=sync` and `ingestEdge.uploadDirect.mode=off`.
   The chart refuses erase fencing with `async`, `drain`, or
   `HISTORY_UPLOAD_DIRECT` because those paths have no erase writer-drain
   protocol.
2. Enable only `global.operatorSessionErase.fenceEnforced`. Keep both API and
   byte deletion off. Roll and verify the read API first, then the active
   consumer, then ingest. Every runtime Deployment must contain
   `SESSION_ERASE_FENCE_ENFORCED=1`; bootstrap and migration Jobs must not.
3. Enable `operatorSessionErase.bytes.enabled` with the dedicated S3 and search
   Secret references. Verify a controlled erase removes the expected Locker
   object versions and search rows while retaining an auditable receipt.
4. Enable the ingest API and Control handoff together. In the umbrella chart,
   set Control's URL to the exact in-cluster ingest Service origin (for example
   `http://<release>-ingest-edge.<namespace>.svc.cluster.local`) and make its
   Secret name/key identical to the ingest API reference.
5. Confirm the API refuses unauthenticated calls, a completed erase cannot be
   read through any replica, and no erase credentials appear in rendered
   values, pod arguments, logs, or non-runtime Jobs.

## Roll back

Disable the Control handoff and ingest erase API first, then byte deletion.
Keep the fence enforced. Once erase jobs exist, removing fences can resurrect
stale bytes or projections and is not a supported rollback. On a failed
upgrade, stop and use the recorded Helm revision and database snapshot; do not
reuse partially completed erase jobs with an older image.
