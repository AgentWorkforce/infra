<!-- Generated from self-hosted/requirements.yaml by ci/self-hosted-requirements/registry.mjs render. Do not edit. -->
# Self-hosted requirements and options

Everything a self-hosted Agent Relay operator has to provide or decide, per
install profile, generated from one registry. A **requirement** must exist
before install (a Kubernetes Secret with exact keys, a database role or
extension, a DNS name and certificate, workload identity, a cluster
capability). An **option** is a choice with a default (database backend and
mode, function boundary, ingress scheme, add-ons). Each entry says which chart
values, env vars and Secret keys it maps to, who provides it in each profile,
and how to verify it. CI keeps the registry, the charts and this page in step:
every env var, Secret key and Secret-bearing value the templates use must be
registered, every shipped entry must exist in the charts, planned entries must
not be referenced by any template, and the compatibility matrix must equal
the pinned digests.

Source of truth: [`self-hosted/requirements.yaml`](../self-hosted/requirements.yaml). 154 entries: 49 requirements (49 shipped, 0 planned), 105 options (104 shipped, 1 planned).

## Contents

- [Compatibility matrix](#compatibility-matrix)
- [Profiles](#profiles)
  - [selfhost-postgres](#profile-selfhost-postgres)
  - [migration](#profile-migration)
  - [external-selfhosted](#profile-external-selfhosted)
  - [external-rds](#profile-external-rds)
  - [aws-rds-native](#profile-aws-rds-native)
  - [external-supabase](#profile-external-supabase)
  - [aws-cnpg](#profile-aws-cnpg)
  - [aws-supabase](#profile-aws-supabase)
  - [gcp-cloudsql](#profile-gcp-cloudsql)
  - [relaycast](#profile-relaycast)
  - [relayauth](#profile-relayauth)
  - [relay-control](#profile-relay-control)
  - [relay-webapp](#profile-relay-webapp)
  - [agent-relay](#profile-agent-relay)
  - [relayfile](#profile-relayfile)
  - [relayflows](#profile-relayflows)
  - [relay-chief](#profile-relay-chief)
  - [relaychief-control](#profile-relaychief-control)
  - [relayfile-control](#profile-relayfile-control)
  - [durable-actors](#profile-durable-actors)
  - [relaycast-durable-actors](#profile-relaycast-durable-actors)
  - [relaycast-postgres](#profile-relaycast-postgres)
  - [relayfile-durable-actors](#profile-relayfile-durable-actors)
  - [agent-relay-durable-actors](#profile-agent-relay-durable-actors)
  - [agent-relay-eks-durable-actors](#profile-agent-relay-eks-durable-actors)
  - [telemetry-collector](#profile-telemetry-collector)
- [All entries](#all-entries)

## Compatibility matrix

Services image (sessions-pipeline-worker, alleyoop and the privileged SQL Jobs):

| registry | image | source | migration generation |
| --- | --- | --- | --- |
| GHCR | `ghcr.io/agentworkforce/96bulls-services@sha256:6f22ea17dff336e1431664542759fd27958649388b90a0b2f0881883caa7c6b2` | sessions-pipeline `7d7229bb31c121ecb98cd4e35c248fc2cf5669ad` | `eff8b3be46565b57ad8fa5e4a066dbb6d1fe608313d9c1680bfbcd484add259b` |
| ECR (AWS path) | `500268966557.dkr.ecr.us-west-2.amazonaws.com/96bulls-services@sha256:5bb6075240afa02a1b1797a81c07bffa029954eac7803d702ecba20db35d4db9` | same | same |

| row | status | charts | image | services source / generation | supported dbMode + boundary | notes |
| --- | --- | --- | --- | --- | --- | --- |
| telemetry-collector-0.1.7 | unreleased | telemetry-collector 0.1.7 |  |  |  | Carries 0.1.6 with neutral README wording. No template or default render changes. |
| telemetry-collector-0.1.6 | **planned** | telemetry-collector 0.1.6 |  |  |  | Superseded before a chart tag by 0.1.7. Admits the published customer Control 0.5.16 source, whose collector, CLI and event catalog match the reviewed d1089f8d generation. Kind selects its signed 0b9c5a07 image so registering the brief producer no longer prevents collector startup. Older sources remain available for compatible producer catalogs. |
| telemetry-collector-0.1.5 | shipped | telemetry-collector 0.1.5 |  |  |  | Accepts the reviewed Relaycast native-workspace observation and installation exception vocabulary. Existing source revisions remain available for rollback. The operator supplies the image and registration. |
| telemetry-collector-0.1.4 | shipped | telemetry-collector 0.1.4 |  |  |  | Admits the reviewed brief-worker and coordination-overlaps collector vocabulary. Keeps the prior private-file recovery source available for existing installs and rollback. Images and producer registrations remain operator inputs. |
| telemetry-collector-0.1.3 | shipped | telemetry-collector 0.1.3 |  |  |  | Requires the qualified private-file recovery source; retired source declarations are refused. Restores owned committed segments to 0600 before listening after a remount, preserving bytes. Typed Control and sessions producer registries are available, but the chart selects no images or credentials and enables no producers. Verify signed source/digest and operator storage separately. |
| telemetry-collector-0.1.2 | shipped | telemetry-collector 0.1.2 |  |  |  | Runs the current public Control collector package under an exclusive kernel file lock and renders numeric limits as decimal strings. Requires independently verified immutable images, TLS, producer credentials and exclusive Pod storage fencing; advisory lock contention does not replace storage fencing. No profile enablement or all-component telemetry coverage is implied. |
| telemetry-collector-0.1.1 | shipped | telemetry-collector 0.1.1 |  |  |  | Refuses relay-control images at render time: they do not contain the collector CLI this chart runs. |
| telemetry-collector-0.1.0 | shipped | telemetry-collector 0.1.0 |  |  |  | Default-off umbrella analytics file collector. Requires accepted immutable collector and TLS-proxy images, producer and TLS Secrets and an exclusive persistent volume. Source rendering does not prove image entrypoint, TLS, durable acknowledgement, power-loss recovery or whole-application analytics coverage. The currently reviewed collector CLI registers relaycontrol events only. |
| session-read-api-0.2.12 | unreleased | session-read-api 0.2.12 | session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>` |  |  | Adds the default-off permanent operator session erase fence to every read-API replica. The managed env appears only when selected; extraEnv cannot override it. Requires a separately qualified 2026.11.2 Sessions image and coordinated ingest/consumer fencing. |
| session-read-api-0.2.11 | shipped | session-read-api 0.2.11 | session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>` |  |  | Upgrade compatibility for the 2026.11.0 customer pack: literal true READ_API_TIMING_ASSUME_NO_TURNS and READ_API_CANONICAL_PIN_LAGGING_POINTER extraEnv entries are normalized onto their structured values and omitted from extraEnv. Unset or true structured values are accepted; explicit false or any non-literal legacy value fails closed. New values must use timing.assumeNoTurns and canonical.pinLaggingPointer. |
| session-read-api-0.2.10 | shipped | session-read-api 0.2.10 | session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>` |  |  | Adds managed default-off timing.assumeNoTurns and canonical.pinLaggingPointer values, rendering READ_API_TIMING_ASSUME_NO_TURNS and READ_API_CANONICAL_PIN_LAGGING_POINTER only when selected and reserving both from extraEnv. The AWS RDS native profile selects them because its fresh native store has no legacy timing-turn population and async admission can temporarily leave the canonical pointer behind session_index. Otherwise combines 0.2.9 output/digest and the shared scrub-engine contract; defaults remain unchanged. |
| session-read-api-0.2.9 | **planned** | session-read-api 0.2.9 | session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>` |  |  | Superseded before release by 0.2.10. Combines 0.2.8 default-off output.enabled and digest.enabled with the shared scrub-engine contract used by the umbrella reader-first and phase-2 rollout. Defaults emit no SCRUB_ENGINE, SCRUB_ENGINE_REQUIRED or READER_MAX_RULESET bindings and keep output/digest off; explicit rollout values require the qualified alpha.5 services image. |
| session-read-api-0.2.8 | **planned** | session-read-api 0.2.8 | session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>` |  |  | Superseded before release by 0.2.9. Adds default-off output.enabled and digest.enabled, rendering READ_API_OUTPUT_ENABLED=1 / READ_API_DIGEST_ENABLED=1 with the managed Postgres facts backends, and digest.narrative.* for in-process narrative generation. The narrative model defaults to unset, so no model call is made and no session content leaves the cluster. Reserves those env names from extraEnv. Requires a services image with migration 20261105045040_selfhost_output_facts and a facts writer (the pipeline consumer with output facts on). |
| session-read-api-0.2.7 | shipped | session-read-api 0.2.7 | session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>` |  |  | When coordinationOverlaps.enabled is selected, renders both READ_API_COORDINATION_OVERLAPS_ENABLED=true and the managed Postgres backend. The standalone leaf default remains off; sessions-pipeline 0.8.21 supplies its own default-on adapter. Requires an independently qualified services image from relayhistory-pipeline fe62ed80 or a reviewed successor, including migration 20261105047000_coordination_fact_readers. |
| session-read-api-0.2.6 | **planned** | session-read-api 0.2.6 |  |  |  | Superseded before release by 0.2.7. Makes readerMaxRuleset default null, omitting READER_MAX_RULESET so legacy reads remain unchanged. |
| session-read-api-0.2.5 | shipped | session-read-api 0.2.5 | session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>` |  |  | Adds managed readerMaxRuleset (READER_MAX_RULESET), default 8 and restricted to 8, 9 or 10. Raising it requires an independently qualified image containing relayhistory-pipeline #489 at 0ad0813c or a reviewed successor. This reader ceiling neither selects a writer ruleset nor enables a workload. |
| session-read-api-0.2.4 | shipped | session-read-api 0.2.4 | session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>` |  |  | Adds the default-off coordinationOverlaps.enabled switch. It emits READ_API_COORDINATION_OVERLAPS_ENABLED=true only when selected and reserves that env name from extraEnv. No image, workload, Secret, database or migration default changes. |
| session-read-api-0.2.3 | shipped | session-read-api 0.2.3 | session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>` |  |  | Adds managed default-off native collector adapters. Each service uses a component-bound Secret reference, an opaque installation ID, HTTPS and optional public additional CA trust. Preflight/bootstrap has no analytics credentials. No application image default, SQL, admission mode, profile or runtime is changed; a qualified source71801741-or-later image and operator registrations remain required. |
| session-read-api-0.2.2 | shipped | session-read-api 0.2.2 | session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>` |  |  | Admits exactly "*" for directoryWorkspaces with auth.mode=self_issued. |
| session-read-api-0.2.1 | **planned** | session-read-api 0.2.1 | session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>` |  |  | Defaults READ_API_COMPLETE_SINCE to epoch for a new self-host store populated only by its own ingest. Partial legacy imports must retain an explicit real coverage floor matching the indexer. Image, auth, routing and enabled defaults are unchanged; this does not assert coverage for an imported store or qualify a runtime. |
| sessions-pipeline-0.8.30 | unreleased | sessions-pipeline 0.8.30<br>sessions-pipeline-worker 0.7.9<br>session-ingest-api 0.4.5<br>session-read-api 0.2.12<br>(deps: worker 0.7.9, alleyoop 0.4.5, sessionReadApi 0.2.12, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>Operator session erase values remain default-off and do not pin the 2026.11.2 candidate image. Runtime qualification is separate. Existing chart/profile image pins remain unchanged. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Carries 0.8.29 and adds default-off worker.migrations.allowBlockingIndexBuild (HOOPDB_ALLOW_BLOCKING_INDEX_BUILD, migrate container only): the adopt-or-create index steps may then build a missing index on a populated table with a blocking CREATE INDEX instead of refusing. scripts/selfhost/agent-relay-upgrade.sh sets it for one upgrade of a small database. Default renders are byte-identical. |
| sessions-pipeline-0.8.29 | shipped | sessions-pipeline 0.8.29<br>sessions-pipeline-worker 0.7.8<br>session-ingest-api 0.4.5<br>session-read-api 0.2.12<br>(deps: worker 0.7.8, alleyoop 0.4.5, sessionReadApi 0.2.12, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>Operator session erase values remain default-off and do not pin the 2026.11.2 candidate image. Runtime qualification is separate. Existing chart/profile image pins remain unchanged. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Carries 0.8.28 and adds default-off ingestEdge.ledger (sql\|s3, pipeline decision 0005: INGEST_LEDGER=s3 on the ingest edge only, with render-time refusals of sessionSelection and the operator session erase) and a default-off rearmSweeper CronJob (one rearm-sweeper-main pass per tick, Forbid, dedicated file-mounted S3 credential or EKS Pod Identity from pipeline 9be2ad8e). Default renders are byte-identical. No image pin or live install changes. |
| sessions-pipeline-0.8.28 | shipped | sessions-pipeline 0.8.28<br>sessions-pipeline-worker 0.7.8<br>session-ingest-api 0.4.5<br>session-read-api 0.2.12<br>(deps: worker 0.7.8, alleyoop 0.4.5, sessionReadApi 0.2.12, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>Operator session erase values remain default-off and do not pin the 2026.11.2 candidate image. Runtime qualification is separate. Existing chart/profile image pins remain unchanged. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Carries the default-off operator session erase wiring from 0.8.27. The search-indexer bootstrap now shares the Sessions migrator advisory lock, retries only the two exact PostgreSQL XX000 catalog-race signatures inside one Pod, and disables Kubernetes Job retries so a recovered upgrade leaves no Error Pod. The RDS-native profile waits boundedly for rds-setup post to activate the runtime LOGIN before bootstrap. No image pin or live install changes. |
| sessions-pipeline-0.8.27 | **planned** | sessions-pipeline 0.8.27<br>sessions-pipeline-worker 0.7.8<br>session-ingest-api 0.4.5<br>session-read-api 0.2.12 |  |  |  | Superseded before a chart tag by 0.8.28. Adds default-off, fail-closed operator session erase fencing, API, S3 byte deletion and PostgreSQL/OpenSearch search cleanup adapters. No image is selected; default renders remain unchanged. |
| sessions-pipeline-0.8.26 | shipped | sessions-pipeline 0.8.26 |  |  |  | Carries 0.8.25 and adds session-read-api 0.2.11 upgrade compatibility for the two legacy 2026.11.0 pack read-assumption extraEnv entries. No profile, image, workload or database default changes. |
| sessions-pipeline-0.8.25 | shipped | sessions-pipeline 0.8.25<br>sessions-pipeline-worker 0.7.8<br>session-ingest-api 0.4.5<br>session-read-api 0.2.10<br>(deps: worker 0.7.8, alleyoop 0.4.5, sessionReadApi 0.2.10, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>The customer release profiles pin the approved alpha.5 services image from source 7e9b2f0f on every services-image workload, including the output-facts bootstrap Job. The artifact contains the reviewed ruleset-10 wasm-bindgen package and migrations through 20261105047000_coordination_fact_readers, including 20261105045040_selfhost_output_facts. Chart defaults remain unselected. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Adds session-read-api 0.2.10 and selects its managed timing.assumeNoTurns and canonical.pinLaggingPointer values only in the aws-rds-native profile, preventing fresh native reads from failing timing_turns_unknown and transient *_canonical_manifest_mismatch while preserving every other profile default. Otherwise combines 0.8.24 output facts/bootstrap/read API values and the strict global.scrubEngine rollout; the AWS profile still has no narrative model. |
| sessions-pipeline-0.8.24 | **planned** | sessions-pipeline 0.8.24<br>sessions-pipeline-worker 0.7.8<br>session-ingest-api 0.4.5<br>session-read-api 0.2.9<br>(deps: worker 0.7.8, alleyoop 0.4.5, sessionReadApi 0.2.9, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>` |  |  | Superseded before release by 0.8.25. Combines 0.8.23 first-class output facts, its deterministic hook-free bootstrap Job and read API output/digest values with one strict global.scrubEngine selection on every services-image workload and Job. |
| sessions-pipeline-0.8.23 | **planned** | sessions-pipeline 0.8.23<br>sessions-pipeline-worker 0.7.7<br>session-ingest-api 0.4.4<br>session-read-api 0.2.8<br>(deps: worker 0.7.7, alleyoop 0.4.4, sessionReadApi 0.2.8, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>` |  |  | Superseded before release by 0.8.24. Adds first-class output facts: searchIndexer.outputFacts.enabled and nativeConsumer.outputFacts.enabled render RELAYHISTORY_SELFHOST_OUTPUT_FACTS=true (default off), and searchIndexer.outputFacts.bootstrap renders the optional, deterministic, hook-free output facts bootstrap Job as the schema owner. The aws-rds-native profile turns on facts plus the read API output and digest routes, with no narrative model. |
| sessions-pipeline-0.8.22 | shipped | sessions-pipeline 0.8.22<br>sessions-pipeline-worker 0.7.7<br>session-ingest-api 0.4.4<br>session-read-api 0.2.7<br>(deps: worker 0.7.7, alleyoop 0.4.4, sessionReadApi 0.2.7, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>The aws-rds-native profile requires one approved release-overlay services digest for worker, alleyoop, sessionReadApi, ingestEdge and searchIndexer; every profile digest stays empty in source. Coordination overlaps require an independently qualified artifact from relayhistory-pipeline fe62ed80 or a reviewed successor, including migration 20261105047000_coordination_fact_readers. Setting an explicit readerMaxRuleset also requires #489 including its default-path compatibility and binding fixes. The artifact must include #484 for default-on claim-lock 429/Retry-After behavior, fresh-install search_index grants, schema through 046010 and session query. Existing profile image pins are unchanged. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Adds default-off self-host upload-inbox scanning with an existing witness Secret and required async admission. Requires a qualified published image containing pipeline #515. No image pin or runtime enablement changes. |
| sessions-pipeline-0.8.21 | shipped | sessions-pipeline 0.8.21<br>sessions-pipeline-worker 0.7.7<br>session-ingest-api 0.4.4<br>session-read-api 0.2.7<br>(deps: worker 0.7.7, alleyoop 0.4.4, sessionReadApi 0.2.7, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>The aws-rds-native profile requires one approved release-overlay services digest for worker, alleyoop, sessionReadApi, ingestEdge and searchIndexer; every profile digest stays empty in source. Coordination overlaps require an independently qualified artifact from relayhistory-pipeline fe62ed80 or a reviewed successor, including migration 20261105047000_coordination_fact_readers. Setting an explicit readerMaxRuleset also requires #489 including its default-path compatibility and binding fixes. The artifact must include #484 for default-on claim-lock 429/Retry-After behavior, fresh-install search_index grants, schema through 046010 and session query. Existing profile image pins are unchanged. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Defaults the coordination-overlaps endpoint on when sessionReadApi is enabled, with the managed Postgres backend. The standalone leaf reader remains default off and the Dashboard view remains separately default off. Populated databases must prebuild the two exact partial indexes concurrently before migration 20261105047000_coordination_fact_readers; fresh installs build them directly. No services image or runtime is selected. |
| sessions-pipeline-0.8.20 | **planned** | sessions-pipeline 0.8.20<br>sessions-pipeline-worker 0.7.7<br>session-ingest-api 0.4.4<br>session-read-api 0.2.6 |  |  |  | Superseded before release by 0.8.21. Carries the default-off native brief collector adapter and nullable reader ceilings. |
| sessions-pipeline-0.8.19 | shipped | sessions-pipeline 0.8.19<br>sessions-pipeline-worker 0.7.6<br>session-ingest-api 0.4.4<br>session-read-api 0.2.6<br>(deps: worker 0.7.6, alleyoop 0.4.4, sessionReadApi 0.2.6, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>The aws-rds-native profile requires one approved release-overlay services digest for worker, alleyoop, sessionReadApi, ingestEdge and searchIndexer; every profile digest stays empty in source. Setting an explicit readerMaxRuleset requires an artifact containing relayhistory-pipeline #489 including its default-path compatibility and binding fixes, after exact-head review. The artifact must also include pipeline #484 for default-on claim-lock 429/Retry-After behavior, fresh-install search_index grants, schema through 046010, session query and coordination overlaps. Existing profile image pins are unchanged. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Extends the independent readerMaxRuleset ceiling to the native ingestEdge engine initializer, alongside nativeConsumer, nativeBrief, sessionReadApi and alleyoop. Every ceiling defaults to null and omits the binding to preserve legacy reads; explicit 8, 9 or 10 enables strict marker checks. Raising a ceiling requires a qualified #489-compatible image; the values do not select writer output, enable Rust/WASM, enable a workload, or change image pins. Keep upgraded readers at the required ceiling while newer objects remain. |
| sessions-pipeline-0.8.18 | shipped | sessions-pipeline 0.8.18<br>sessions-pipeline-worker 0.7.5<br>session-ingest-api 0.4.3<br>session-read-api 0.2.5<br>(deps: worker 0.7.5, alleyoop 0.4.3, sessionReadApi 0.2.5, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>The aws-rds-native profile requires one approved release-overlay services digest for worker, alleyoop, sessionReadApi, ingestEdge and searchIndexer; every profile digest stays empty in source. Raising any readerMaxRuleset above 8 requires an artifact containing relayhistory-pipeline #489 at 0ad0813c or a reviewed successor. The artifact must also include pipeline #484 for default-on claim-lock 429/Retry-After behavior, fresh-install search_index grants, schema through 046010, session query and coordination overlaps. Existing profile image pins are unchanged. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Adds independently staged readerMaxRuleset ceilings for nativeConsumer, nativeBrief, sessionReadApi and alleyoop. Every ceiling defaults to 8 and admits only 8, 9 or 10. Raising a ceiling requires a qualified #489-compatible image; the values do not select writer output, enable Rust/WASM, enable a workload, or change image pins. Keep upgraded readers at the required ceiling while newer objects remain. |
| sessions-pipeline-0.8.17 | **planned** | sessions-pipeline 0.8.17<br>sessions-pipeline-worker 0.7.4<br>session-ingest-api 0.4.2<br>session-read-api 0.2.4 |  |  |  | Superseded before release by 0.8.18. Routes the exact upload token refresh path to native ingest in both reader modes; retains all image, migration, authority and admission choices. |
| sessions-pipeline-0.8.16 | shipped | sessions-pipeline 0.8.16<br>sessions-pipeline-worker 0.7.4<br>session-ingest-api 0.4.2<br>session-read-api 0.2.4<br>(deps: worker 0.7.4, alleyoop 0.4.2, sessionReadApi 0.2.4, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>The aws-rds-native profile requires one approved release-overlay services digest for worker, alleyoop, sessionReadApi, ingestEdge and searchIndexer; every profile digest stays empty in source. The artifact must also include pipeline #484 for default-on claim-lock 429/Retry-After behavior; older images may ignore the new variable. The artifact must include the fresh-install search_index grants, schema through 046010, session query and coordination overlaps. Existing profile image pins are unchanged. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Adds managed ingestEdge.claimLockBusy, default true, emitting INGEST_CLAIM_LOCK_BUSY=on. Requires an independently qualified image containing pipeline #484; no image pin or admission mode changes. Claim lock waits become 429 with Retry-After; statement timeouts remain 503. Includes the existing AWS RDS native profile. |
| sessions-pipeline-0.8.15 | shipped | sessions-pipeline 0.8.15<br>sessions-pipeline-worker 0.7.4<br>session-ingest-api 0.4.2<br>session-read-api 0.2.4<br>(deps: worker 0.7.4, alleyoop 0.4.2, sessionReadApi 0.2.4, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>The aws-rds-native profile requires one approved release-overlay services digest for worker, alleyoop, sessionReadApi, ingestEdge and searchIndexer; every profile digest stays empty in source. The artifact must include the fresh-install search_index grants, schema through 046010, session query and coordination overlaps. Existing profile image pins are unchanged. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Adds the customer-neutral, fail-closed AWS RDS native profile: external RDS, S3 Pod Identity, OpenSearch, read API, ingest edge and search indexer. It carries no customer resource identifier or services digest; an approved private release overlay is mandatory. The profile enables the structured coordination-overlaps switch and the session-query path, and CI proves the shared immutable image, dedicated ServiceAccounts, verified RDS CA, Secret references and absence of static AWS keys. |
| sessions-pipeline-0.8.14 | shipped | sessions-pipeline 0.8.14<br>sessions-pipeline-worker 0.7.4<br>session-ingest-api 0.4.2<br>session-read-api 0.2.4<br>(deps: worker 0.7.4, alleyoop 0.4.2, sessionReadApi 0.2.4, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>session-read-api self_issued, events.messageIds and coordinationOverlaps need an explicitly qualified compatible image. Native ingest edge (SERVICE=session-ingest) remains unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Carries session-read-api 0.2.4 and its default-off coordination overlaps switch. No image pin, workload, Secret, database or migration default changes. |
| sessions-pipeline-0.8.13 | shipped | sessions-pipeline 0.8.13<br>sessions-pipeline-worker 0.7.4<br>session-ingest-api 0.4.2<br>session-read-api 0.2.3<br>(deps: worker 0.7.4, alleyoop 0.4.2, sessionReadApi 0.2.3, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>session-read-api self_issued and events.messageIds need at least ghcr.io/agentworkforce/96bulls-services@sha256:d55840ab4bf4e2fea3769db690f3c8d32979ab455ef251172f914ac011cb8c33 (pipeline eebaced9). Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Adds GCS Workload Identity support to the native ingest edge and PostgreSQL search indexer, plus a restricted GCS data-path environment for the indexer. Existing defaults remain S3 and every native service stays default-off. |
| sessions-pipeline-0.8.11 | shipped | sessions-pipeline 0.8.11<br>sessions-pipeline-worker 0.7.4<br>session-ingest-api 0.4.2<br>session-read-api 0.2.2<br>(deps: worker 0.7.4, alleyoop 0.4.2, sessionReadApi 0.2.2, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>session-read-api self_issued and events.messageIds need at least ghcr.io/agentworkforce/96bulls-services@sha256:d55840ab4bf4e2fea3769db690f3c8d32979ab455ef251172f914ac011cb8c33 (pipeline eebaced9). Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Adds optional nativeBrief.baseUrl (OPENAI_BASE_URL) and nativeBrief.allowInClusterHttp for the session-brief worker. Default renders are unchanged apart from chart versions; runtime images and SQL are unchanged. |
| sessions-pipeline-0.8.10 | **planned** | sessions-pipeline 0.8.10<br>sessions-pipeline-worker 0.7.3<br>session-ingest-api 0.4.2<br>session-read-api 0.2.2<br>(deps: worker 0.7.3, alleyoop 0.4.2, sessionReadApi 0.2.2, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>session-read-api self_issued and events.messageIds need at least ghcr.io/agentworkforce/96bulls-services@sha256:d55840ab4bf4e2fea3769db690f3c8d32979ab455ef251172f914ac011cb8c33 (pipeline eebaced9). Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Deployment-only retirement remains default-enabled. Explicitly setting deployment.enabled=false omits only the selected legacy Deployment; all other resources remain managed. Runtime images and SQL are unchanged. Retained upgrades require an actual-current render review; this source release does not claim runtime retirement or data migration. |
| sessions-pipeline-0.8.9 | **planned** | sessions-pipeline 0.8.9<br>sessions-pipeline-worker 0.7.3<br>session-ingest-api 0.4.1<br>session-read-api 0.2.2<br>(deps: worker 0.7.3, alleyoop 0.4.1, sessionReadApi 0.2.2, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>session-read-api self_issued and events.messageIds need at least ghcr.io/agentworkforce/96bulls-services@sha256:d55840ab4bf4e2fea3769db690f3c8d32979ab455ef251172f914ac011cb8c33 (pipeline eebaced9). Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Native canonical consumer and single-origin routing remain default-off and require independently qualified source, image, schema and separate runtime credentials. The explicit native kind core lifecycle is source-tested only; no fresh or repeat runtime acceptance is inferred. |
| sessions-pipeline-0.8.8 | **planned** | sessions-pipeline 0.8.8<br>sessions-pipeline-worker 0.7.3<br>session-ingest-api 0.4.1<br>session-read-api 0.2.2<br>(deps: worker 0.7.3, alleyoop 0.4.1, sessionReadApi 0.2.2, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>session-read-api self_issued and events.messageIds need at least ghcr.io/agentworkforce/96bulls-services@sha256:d55840ab4bf4e2fea3769db690f3c8d32979ab455ef251172f914ac011cb8c33 (pipeline eebaced9). Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Adds default-off ingestEdge.heartbeatAccept. |
| sessions-pipeline-0.8.7 | **planned** | sessions-pipeline 0.8.7<br>sessions-pipeline-worker 0.7.3<br>session-ingest-api 0.4.1<br>session-read-api 0.2.2<br>(deps: worker 0.7.3, alleyoop 0.4.1, sessionReadApi 0.2.2, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>session-read-api self_issued and events.messageIds need at least ghcr.io/agentworkforce/96bulls-services@sha256:d55840ab4bf4e2fea3769db690f3c8d32979ab455ef251172f914ac011cb8c33 (pipeline eebaced9). Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Adds default-off managed native briefs in worker 0.7.3, retaining reader 0.2.2 and all existing ingest admission. Requires an explicit compatible image, scoped model credential and reader migration; no runtime or image acceptance is implied. |
| sessions-pipeline-0.8.6 | **planned** | sessions-pipeline 0.8.6<br>sessions-pipeline-worker 0.7.2<br>session-ingest-api 0.4.1<br>session-read-api 0.2.2<br>(deps: worker 0.7.2, alleyoop 0.4.1, sessionReadApi 0.2.2, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>session-read-api self_issued and events.messageIds need at least ghcr.io/agentworkforce/96bulls-services@sha256:d55840ab4bf4e2fea3769db690f3c8d32979ab455ef251172f914ac011cb8c33 (pipeline eebaced9). Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Takes reader 0.2.2. Version 0.8.5 is reserved by a concurrent change. |
| sessions-pipeline-0.8.4 | **planned** | sessions-pipeline 0.8.4<br>sessions-pipeline-worker 0.7.2<br>session-ingest-api 0.4.1<br>session-read-api 0.2.1<br>(deps: worker 0.7.2, alleyoop 0.4.1, sessionReadApi 0.2.1, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>session-read-api self_issued and events.messageIds need at least ghcr.io/agentworkforce/96bulls-services@sha256:d55840ab4bf4e2fea3769db690f3c8d32979ab455ef251172f914ac011cb8c33 (pipeline eebaced9). Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Adds explicit sync/async/drain ingest admission from merged pipeline #398/f0860b2e. Sync remains the default and no profile enables the native edge. Reader 0.2.1 defaults new-store coverage to epoch with a partial-import override. Retains the default-off Pod Identity and session-selection settings from 0.8.2. Preserves 0.8.3 search-indexer custom-CA trust. A qualified combined-image digest and separate runtime acceptance are required. |
| sessions-pipeline-0.8.3 | **planned** | sessions-pipeline 0.8.3<br>sessions-pipeline-worker 0.7.2<br>session-ingest-api 0.4.1<br>session-read-api 0.2.0<br>(deps: worker 0.7.2, alleyoop 0.4.1, sessionReadApi 0.2.0, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>session-read-api self_issued and events.messageIds need at least ghcr.io/agentworkforce/96bulls-services@sha256:d55840ab4bf4e2fea3769db690f3c8d32979ab455ef251172f914ac011cb8c33 (pipeline eebaced9). Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Search indexer sets NODE_EXTRA_CA_CERTS for its custom-ca profile so the worker pool verifies Postgres. |
| sessions-pipeline-0.8.2 | **planned** | sessions-pipeline 0.8.2<br>sessions-pipeline-worker 0.7.2<br>session-ingest-api 0.4.1<br>session-read-api 0.2.0<br>(deps: worker 0.7.2, alleyoop 0.4.1, sessionReadApi 0.2.0, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>session-read-api self_issued and events.messageIds need at least ghcr.io/agentworkforce/96bulls-services@sha256:d55840ab4bf4e2fea3769db690f3c8d32979ab455ef251172f914ac011cb8c33 (pipeline eebaced9). Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Adds default-off ingestEdge Pod Identity credentials and the session-selection erase flag. |
| sessions-pipeline-0.8.1 | **planned** | sessions-pipeline 0.8.1<br>sessions-pipeline-worker 0.7.2<br>session-ingest-api 0.4.1<br>session-read-api 0.2.0<br>(deps: worker 0.7.2, alleyoop 0.4.1, sessionReadApi 0.2.0, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-read-api: `ghcr.io/agentworkforce/96bulls-services@sha256:<required>`<br>session-read-api self_issued and events.messageIds need at least ghcr.io/agentworkforce/96bulls-services@sha256:d55840ab4bf4e2fea3769db690f3c8d32979ab455ef251172f914ac011cb8c33 (pipeline eebaced9). Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Allows sessionReadApi.auth.mode=self_issued with a /v1-only ingress and a NetworkPolicy that names Control, and adds the default-off events.messageIds value. Default auth stays relaycontrol_only. |
| sessions-pipeline-0.8.0 | shipped | sessions-pipeline 0.8.0<br>sessions-pipeline-worker 0.7.2<br>session-ingest-api 0.4.1<br>session-read-api 0.1.0<br>(deps: worker 0.7.2, alleyoop 0.4.1, sessionReadApi 0.1.0, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Moves the session read API to the standalone session-read-api chart, carried as a default-off dependency under sessionReadApi. The old readApi key refuses to render with a migration message. Default auth is relaycontrol_only. |
| sessions-pipeline-0.7.6 | **planned** | sessions-pipeline 0.7.6<br>sessions-pipeline-worker 0.7.2<br>session-ingest-api 0.4.1<br>(deps: worker 0.7.2, alleyoop 0.4.1, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Adds the default-off searchIndexer block (pipeline session-pipeline-consumer, OpenSearch by default). With it off, every render differs only in the helm.sh/chart labels. |
| sessions-pipeline-0.7.5 | shipped | sessions-pipeline 0.7.5<br>sessions-pipeline-worker 0.7.2<br>session-ingest-api 0.4.1<br>(deps: worker 0.7.2, alleyoop 0.4.1, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Adds default-off postgresCa so Node workloads and migrate Jobs can verify the Postgres server certificate (NODE_EXTRA_CA_CERTS); with it unset every sessions-pipeline render differs only in the helm.sh/chart labels. The relayhistory checksum/config annotation also changes under agent-relay, which rolls those pods on upgrade (see the agent-relay 0.5.3 row). Adds the default-off native edge from merged pipeline #363; no compatible image or runtime acceptance is supplied. Adds Secret-only read API credentials and a true default-off regression. Normal composition with main bfcf6050 retains the descriptive session names and upgrade/IAM guards. Adds a default-off read API Deployment and ClusterIP Service with explicit compatible image/config requirements and enabled-state readiness. Worker and ingest images, migration generation and roles are unchanged. Pipeline PRs 317/318 are merged; their container/routes source does not establish the approved Postgres/canonical/auth assembly; no read API deployment or runtime proof is claimed. |
| sessions-pipeline-0.7.4 | **planned** | sessions-pipeline 0.7.4<br>sessions-pipeline-worker 0.7.1<br>session-ingest-api 0.4.0<br>(deps: worker 0.7.1, alleyoop 0.4.0, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>Native ingest edge (SERVICE=session-ingest): unqualified; an explicit qualified combined-image digest is required. Pins above belong to the existing internal worker/ingest services, not ingestEdge. | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>rds + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Never released; superseded by 0.7.5. Adds the default-off native edge from merged pipeline #363; no compatible image or runtime acceptance is supplied. Adds Secret-only read API credentials and a true default-off regression. Normal composition with main bfcf6050 retains the descriptive session names and upgrade/IAM guards. Adds a default-off read API Deployment and ClusterIP Service with explicit compatible image/config requirements and enabled-state readiness. Worker and ingest images, migration generation and roles are unchanged. Pipeline PRs 317/318 are merged; their container/routes source does not establish the approved Postgres/canonical/auth assembly; no read API deployment or runtime proof is claimed. |
| sessions-pipeline-0.7.2 | **planned** | sessions-pipeline 0.7.2<br>sessions-pipeline-worker 0.7.0<br>session-ingest-api 0.4.0<br>(deps: worker 0.7.0, alleyoop 0.4.0, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…` | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Adds Secret-only read API credentials and a true default-off regression. Normal composition with main bfcf6050 retains the descriptive session names and upgrade/IAM guards. Adds a default-off read API Deployment and ClusterIP Service with explicit compatible image/config requirements and enabled-state readiness. Worker and ingest images, migration generation and roles are unchanged. Pipeline PRs 317/318 are merged; their container/routes source does not establish the approved Postgres/canonical/auth assembly; no read API deployment or runtime proof is claimed. |
| sessions-pipeline-0.7.1 | shipped | sessions-pipeline 0.7.1<br>sessions-pipeline-worker 0.7.0<br>session-ingest-api 0.4.0<br>(deps: worker 0.7.0, alleyoop 0.4.0, hoopdb 0.9.0, session-object-storage 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>session-ingest-api: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…` | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Normal composition with main bfcf6050 retains the descriptive session names and upgrade/IAM guards. Adds a default-off read API Deployment and ClusterIP Service with explicit compatible image/config requirements and enabled-state readiness. Worker and ingest images, migration generation and roles are unchanged. Pipeline PRs 317/318 are merged; their container/routes source does not establish the approved Postgres/canonical/auth assembly; no read API deployment or runtime proof is claimed. |
| sessions-pipeline-0.6.0 | shipped | sessions-pipeline 0.6.0<br>sessions-pipeline-worker 0.6.0<br>alleyoop 0.3.8<br>(deps: worker 0.6.0, alleyoop 0.3.8, hoopdb 0.9.0, locker 5.4.0, otel 0.178.0) | sessions-pipeline-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>alleyoop: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…` | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | Rename: the umbrella and worker charts were published as 96bulls (last 0.5.4) and 96bulls-worker (last 0.5.3); they continue here as sessions-pipeline 0.6.0 and sessions-pipeline-worker 0.6.0 (96bulls 0.5.5 was never released). alleyoop 0.3.8 only relabels part-of. Includes alleyoop 0.3.7 auth.allowInterimRelayAuthBearer (ALLOW_INTERIM_RELAYAUTH_BEARER, default false, environment=local only). Same services image and db combos as 0.5.4. Upgrade path: helm upgrade <existing 96bulls release> agentworkforce/sessions-pipeline keeps the release, resource names and selectors (the worker alias is unchanged; only chart and part-of labels change). A standalone 96bulls-worker release keeps its selectors only with nameOverride: 96bulls-worker. |
| 96bulls-0.5.4 | shipped | 96bulls 0.5.4<br>96bulls-worker 0.5.3<br>alleyoop 0.3.6<br>(deps: worker 0.5.3, alleyoop 0.3.6, hoopdb 0.9.0, locker 5.4.0, otel 0.178.0) | 96bulls-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>alleyoop: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…` | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | allowInClusterHttp (ALLOW_IN_CLUSTER_HTTP, default false) for alleyoop and the worker, and the optional alleyoop auth.historyOrigin (RELAYHISTORY_ORIGIN). Same services image and db combos. 96bulls 0.5.3 / alleyoop 0.3.5 were reserved for the interim-bearer PR and never released; it shipped as 0.5.5 / 0.3.7. Superseded by sessions-pipeline 0.6.0. |
| 96bulls-0.5.2 | shipped | 96bulls 0.5.2<br>96bulls-worker 0.5.2<br>alleyoop 0.3.4<br>(deps: worker 0.5.2, alleyoop 0.3.4, hoopdb 0.9.0, locker 5.4.0, otel 0.178.0) | 96bulls-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>alleyoop: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…` | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | License-annotation patch bump of 0.5.1; same services image and db combos. Superseded by 0.5.4. |
| 96bulls-0.5.1 | shipped | 96bulls 0.5.1<br>96bulls-worker 0.5.1<br>alleyoop 0.3.3<br>(deps: worker 0.5.1, alleyoop 0.3.3, hoopdb 0.9.0, locker 5.4.0, otel 0.178.0) | 96bulls-worker: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…`<br>alleyoop: `agentworkforce/96bulls-services@sha256:6f22ea17dff3…` | `7d7229bb31c1` / `eff8b3be4656` | selfhosted + global-default-revoke (cnpg)<br>selfhosted + global-default-revoke (external)<br>cloudsql + global-default-revoke (external)<br>supabase + event-trigger (external) (held)<br>supabase + (unset) (external) (fails closed)<br>local + (unset) (any) (dev only) | sessions-pipeline main 7d7229b (#124 session list RPC, #125 Supabase event-trigger boundary, #139 its manifest sync, #137 exact sessions function ACL). The AWS path pins the ECR digest of the same build. Superseded by 0.5.2. |
| sessions-pipeline-next | **planned** | sessions-pipeline next | not built for the charts yet | `475d503216a2` / `5ed119133e36` |  | Follow-up re-pin to sessions-pipeline main after #127 (session briefs, generation 5ed11913...). Needs new GHCR/ECR digests, ci/sessions-pipeline-search-worker-role/services-commit and services-generation, and the session-brief entries below shipped. |
| relaycast-0.3.12 | unreleased | relaycast 0.3.12 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca7ab5…` |  |  | PostgreSQL failover hardening: healthProbes legacy\|split (split uses /health/live and /health/ready from relaycast#667), TCP keepalive sysctls on the PostgreSQL backend (Kubernetes 1.29+), NODE_OPTIONS heap at 75 % of the memory limit for the wait init and migration Jobs (#668), and persistence.zone with node-drain docs. SQLite renders are unchanged. |
| relaycast-0.3.11 | **planned** | relaycast 0.3.11 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca7ab5…` |  |  | Durable-actors gateway robustness: object-store gateways with more than one replica render a maxUnavailable=1 PDB, and runtime.durableActors.gateway.topologySpread generates a release-scoped topology selector. SQLite and PostgreSQL default renders are unchanged. |
| relaycast-0.3.10 | **planned** | relaycast 0.3.10 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca7ab5…` |  |  | Moving a PostgreSQL release to durable-actors: opt-in migration Jobs (migration.*: preflight, export, files, import, verify, open; rendered one at a time by the upgrader, never part of a release), persistence.retainForMigration (keeps the previous backend's data claim through the move and a rollback) and runtime.durableActors.socketOrigin (DURABLE_ACTORS_SOCKET_ORIGIN: dial actor sockets in-cluster; needs an actors gateway with relaycast #655). Default renders unchanged. docs/relaycast-postgres-to-actors-migration.md. |
| relaycast-0.3.9 | **planned** | relaycast 0.3.9 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca7ab5…` |  |  | Adds an optional existing PVC for local durable-actors dev-runtime state across pod replacements; disposable emptyDir remains the default. No image, runtime or customer profile changes. |
| relaycast-0.3.8 | **planned** | relaycast 0.3.8 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca7ab5…` |  |  | Adds default-off Node runtime collector analytics using a dedicated credential and HTTPS CA. Default runtime images stay unchanged and the operator selects an image with collector support. |
| relaycast-0.3.7 | shipped | relaycast 0.3.7 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca7ab5…` |  |  | Actor-mode keyed workspace bootstrap Secret and proof policy; matching gateway and actor environments and a qualified actor rollout are required. No live rollout is claimed. |
| relaycast-0.3.6 | **planned** | relaycast 0.3.6 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca7ab5…` |  |  | Superseded before tagging by relaycast-0.3.7. Adds default-off runtime.backend=postgres (image relaycast-self-host 12.8.0-pg.1, sha256:84f59482cb82f3c50d38f45cfca7d004cffaa95652782dbfc93c179cc343ac59, pinned in runtime.postgres.image), a hash-named migration Job and postgresCa. sqlite and durable-actors renders differ only in the helm.sh/chart label. |
| relaycast-0.3.5 | shipped | relaycast 0.3.5 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca7ab5…` |  |  | Repository rename to AgentWorkforce/infra: canonical source and Helm repository URLs, with matching local dependency patch versions. Runtime images, application source, migration generation and deployment values are unchanged. This release has no new live application proof. |
| relaycast-0.3.4 | shipped | relaycast 0.3.4 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca7ab5…` |  |  | runtime.durableActors.deployer.artifactStore (driver gcs \| s3, s3.region/endpoint/forcePathStyle): the deploy Job uploads bundles to S3 for a durable-actors control plane on S3 (needs a relaycast-actors-deployer image from relaycast #626 or later). Default render unchanged apart from the helm.sh/chart label. Same default image as 0.3.3. |
| relaycast-0.3.3 | shipped | relaycast 0.3.3 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca7ab5…` |  |  | Comment and README fix of 0.3.2: the pinned default (engine 12.7.0) already satisfies the >=12.3.x requirement for ar_ custody, so the credentials guidance no longer asks for an image.digest override. Same default image as 0.3.2. |
| relaycast-0.3.2 | shipped | relaycast 0.3.2 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:81274dca7ab5…` |  |  | Default image moves to relaycast-self-host 12.7.0 (relaycast main bf713d86, engine 12.7.0), built by the reviewed publish-container workflow with an SPDX SBOM, max-mode provenance and a GitHub build-provenance attestation (run 41717074565); public, amd64+arm64. Superseded by 0.3.3. |
| relaycast-0.3.1 | shipped | relaycast 0.3.1 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:a05732ad4f36…` |  |  | README-only bump of 0.3.0 for the sessions-pipeline rename. Superseded by 0.3.2. |
| relaycast-0.3.0 | shipped | relaycast 0.3.0 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:a05732ad4f36…` |  |  | License-annotation bump of 0.2.0 (unreleased 0.2.1) plus runtime.backend=durable-actors (env contract v1): relaycast-actors-gateway and relaycast-actors-deployer images, digests supplied by the operator; the SQLite image above is unchanged and remains the default. Superseded by 0.3.1. |
| relaycast-0.2.0 | shipped | relaycast 0.2.0 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:a05732ad4f36…` |  |  | engine 12.2.1 + the internal admin API (relaycast main bdf1b69c). Upgrade path from 0.1.0 is in charts/relaycast/README.md. Superseded by 0.3.0. |
| relaycast-0.1.0 | shipped | relaycast 0.1.0 | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:5c86c095a335…` |  |  | image 8.0.0; superseded by 0.2.0. ci/relaycast/smoke.sh upgrades from it. |
| relayauth-0.1.5 | unreleased | relayauth 0.1.5 | relayauth: `ghcr.io/agentworkforce/relayauth@sha256:c23c92d25fdf…` |  |  | Deployment-only retirement remains default-enabled. Explicitly setting deployment.enabled=false omits only the selected legacy Deployment; all other resources remain managed. Runtime images and SQL are unchanged. Retained upgrades require an actual-current render review; this source release does not claim runtime retirement or data migration. |
| relayauth-0.1.4 | **planned** | relayauth 0.1.4 | relayauth: `ghcr.io/agentworkforce/relayauth@sha256:c23c92d25fdf…` |  |  | Repository rename to AgentWorkforce/infra: canonical source and Helm repository URLs, with matching local dependency patch versions. Runtime images, application source, migration generation and deployment values are unchanged. This release has no new live application proof. |
| relayauth-0.1.3 | shipped | relayauth 0.1.3 | relayauth: `ghcr.io/agentworkforce/relayauth@sha256:c23c92d25fdf…` |  |  | README-only bump of 0.1.2: the relaycast default (engine 12.7.0) satisfies ar_ custody, so no relaycast image.digest override is listed. |
| relayauth-0.1.2 | shipped | relayauth 0.1.2 | relayauth: `ghcr.io/agentworkforce/relayauth@sha256:c23c92d25fdf…` |  |  | License-annotation patch bump of 0.1.1. Superseded by 0.1.3. |
| relayauth-0.1.1 | shipped | relayauth 0.1.1 | relayauth: `ghcr.io/agentworkforce/relayauth@sha256:c23c92d25fdf…` |  |  | relayauth 784582ef (machine-bound History assertion contract, relayauth #113). Superseded by 0.1.2. |
| relayauth-0.1.0 | shipped | relayauth 0.1.0 | relayauth: `ghcr.io/agentworkforce/relayauth@sha256:eb71daa28e30…` |  |  | superseded by 0.1.1. |
| agent-relay-0.7.4 | unreleased | agent-relay 0.7.4<br>relay-control 0.4.15<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.12, relayauth 0.1.5, sessions-pipeline 0.8.30, relay-control 0.4.15, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.3, relayfile 0.2.2, telemetry-collector 0.1.7, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>relaycast-postgres: `ghcr.io/agentworkforce/relaycast-self-host@sha256:1307bd845031…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Carries 0.7.3 and sessions-pipeline 0.8.30 (default-off worker.migrations.allowBlockingIndexBuild, set by the self-host upgrader for one upgrade of a small database from its Sessions index census). Default renders are unchanged. |
| agent-relay-0.7.3 | **planned** | agent-relay 0.7.3<br>relay-control 0.4.15<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.12, relayauth 0.1.5, sessions-pipeline 0.8.29, relay-control 0.4.15, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.3, relayfile 0.2.2, telemetry-collector 0.1.7, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>relaycast-postgres: `ghcr.io/agentworkforce/relaycast-self-host@sha256:1307bd845031…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before a chart tag by 0.7.4. Carries 0.7.2 and relaycast 0.3.12 (PostgreSQL failover hardening: split health probes, keepalive sysctls, migration heap, persistence.zone). The eks-rds-native render gains the keepalive sysctls and NODE_OPTIONS on the Relaycast init and migrate Job. |
| agent-relay-0.7.2 | **planned** | agent-relay 0.7.2<br>relay-control 0.4.15<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.11, relayauth 0.1.5, sessions-pipeline 0.8.29, relay-control 0.4.15, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.3, relayfile 0.2.2, telemetry-collector 0.1.7, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>relaycast-postgres: `ghcr.io/agentworkforce/relaycast-self-host@sha256:1307bd845031…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before a chart tag by 0.7.3. Carries 0.7.0, neutral values comments, telemetry-collector 0.1.7, and prepares the AWS EKS Relaycast durable-actors target: profile pins the post-migration actor images, uses S3 with no Relaycast PVC, three zone-spread gateways with a PDB, tuned 1 GiB actor hosts (warm 3, maxStarting 8), and a protected 1 CPU/1-2 GiB singleton controller. Existing PostgreSQL installs still move only through the full-copy credentials/cutover upgrader; no automatic backend flip. |
| agent-relay-0.7.1 | **planned** | agent-relay 0.7.1<br>relay-control 0.4.15<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.10, relayauth 0.1.5, sessions-pipeline 0.8.29, relay-control 0.4.15, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.2, relayfile 0.2.2, telemetry-collector 0.1.7, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before a chart tag by 0.7.2. Carries 0.7.0 with neutral values comments and telemetry-collector 0.1.7. No template or default render changes. |
| agent-relay-0.7.0 | **planned** | agent-relay 0.7.0<br>relay-control 0.4.15<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.10, relayauth 0.1.5, sessions-pipeline 0.8.29, relay-control 0.4.15, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.2, relayfile 0.2.2, telemetry-collector 0.1.6, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before a chart tag by 0.7.1. Removes the standalone RelayHistory component (charts/relayhistory and its image): History is the native Sessions read API and ingest edge with relay-control's native backend, values-eks.yaml and values-gcp.yaml are native on their own (values-eks-native.yaml and values-gcp-native.yaml become empty compatibility overlays), components.relayauth defaults to false, and components.relayhistory=true or a relayhistory values block fails the render. values-eks.yaml + values-eks-native.yaml, values-eks.yaml + values-eks-rds-native.yaml and values-gcp.yaml + values-gcp-native.yaml render byte-identically to 0.6.60. Also carries the unreleased 0.6.60 (sessions-pipeline 0.8.29, default-off ingestEdge.ledger and rearmSweeper) and 0.6.59. |
| agent-relay-0.6.60 | **planned** | agent-relay 0.6.60<br>relayhistory 0.1.3<br>relay-control 0.4.15<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.10, relayauth 0.1.5, sessions-pipeline 0.8.29, relayhistory 0.1.3, relay-control 0.4.15, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.2, relayfile 0.2.2, telemetry-collector 0.1.6, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before a chart tag by 0.7.0. Carries 0.6.59 with sessions-pipeline 0.8.29 (default-off ingestEdge.ledger and rearmSweeper for pipeline decision 0005). No image or default render changes. |
| agent-relay-0.6.59 | **planned** | agent-relay 0.6.59<br>relayhistory 0.1.3<br>relay-control 0.4.15<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.10, relayauth 0.1.5, sessions-pipeline 0.8.28, relayhistory 0.1.3, relay-control 0.4.15, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.2, relayfile 0.2.2, telemetry-collector 0.1.6, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before a chart tag by 0.6.60. Carries 0.6.58 with relaycast 0.3.10 (opt-in Relaycast PostgreSQL to durable-actors migration Jobs, retained data claim, in-cluster actor socket origin), values-eks-actors.yaml dialling actor sockets through the in-cluster control plane, and scripts/selfhost/agent-relay-upgrade.sh --relaycast-actors credentials\|cutover with the selfhost-upgrade.yml inputs. No image or default render changes outside the actors profile. |
| agent-relay-0.6.58 | **planned** | agent-relay 0.6.58<br>relayhistory 0.1.3<br>relay-control 0.4.15<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.9, relayauth 0.1.5, sessions-pipeline 0.8.28, relayhistory 0.1.3, relay-control 0.4.15, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.2, relayfile 0.2.2, telemetry-collector 0.1.6, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Carries 0.6.57 and adds durable-actors 0.14.6-awf.2 (UPSTREAM.md patch 12): an optional postgresCa value appends a PostgreSQL server CA to the image system roots (init container postgres-ca-bundle, in-memory volume postgres-ca at /etc/postgres-ca/ca.crt, SSL_CERT_FILE) in the control plane and pool manager, so the stock upstream client verifies RDS with sslmode=require. values-eks-rds-native.yaml points it at rds-ca for the layered EKS actors profile. Default renders are unchanged. |
| agent-relay-0.6.57 | **planned** | agent-relay 0.6.57<br>relayhistory 0.1.3<br>relay-control 0.4.15<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.9, relayauth 0.1.5, sessions-pipeline 0.8.28, relayhistory 0.1.3, relay-control 0.4.15, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.6, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before a chart tag by 0.6.58. Carries 0.6.56 with relaycast 0.3.9 optional existing-claim actor dev storage; preserves the AWS bootstrap ordering and Sessions 0.8.28. No image or customer profile changes. |
| agent-relay-0.6.56 | **planned** | agent-relay 0.6.56<br>relayhistory 0.1.3<br>relay-control 0.4.15<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.28, relayhistory 0.1.3, relay-control 0.4.15, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.6, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Carries 0.6.55 and sessions-pipeline 0.8.28. The AWS search-indexer bootstrap waits for the rds-setup post runtime LOGIN, then serializes with the Sessions migrator and performs exact same-Pod catalog-race retries without Kubernetes retry Pods. The AWS RDS-native profile persists its descriptive-worker-name acknowledgement so a second and later Helm upgrade stays idempotent. No image pin or live install changes. |
| agent-relay-0.6.55 | **planned** | agent-relay 0.6.55<br>relayhistory 0.1.3<br>relay-control 0.4.15<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.27, relayhistory 0.1.3, relay-control 0.4.15, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.6, relay-chief 0.1.0) |  |  |  | Superseded before a chart tag by 0.6.56. Makes the AWS durable-actors profile composable after the EKS RDS-native profile by clearing Relaycast's inherited PostgreSQL CA source. |
| agent-relay-0.6.54 | **planned** | agent-relay 0.6.54<br>relayhistory 0.1.3<br>relay-control 0.4.15<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.27, relayhistory 0.1.3, relay-control 0.4.15, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.6, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before a chart tag by 0.6.55. Adds default-off, fail-closed operator session erase composition across Control and Sessions. It selects no 2026.11.2 image and changes no live defaults; default renders remain byte-identical apart from normalized chart version labels. |
| agent-relay-0.6.53 | **planned** | agent-relay 0.6.53 |  |  |  | Superseded before a chart tag by 0.6.54. Carried sessions-pipeline 0.8.26 and the 2026.11.0 pack read-assumption upgrade compatibility. |
| relay-control-0.4.14 | shipped | relay-control 0.4.14 |  |  |  | Control chart generation used by agent-relay 0.6.53 before the operator session erase handoff was added. |
| agent-relay-0.6.52 | **planned** | agent-relay 0.6.52<br>relayhistory 0.1.3<br>relay-control 0.4.14<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.25, relayhistory 0.1.3, relay-control 0.4.14, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.6, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Carries 0.6.51 and adds a public /healthz route to the native GCP history read edge so verify-public.sh health checks answer on the read API probe the GCE health check already uses. Other service/profile images are unchanged. Superseded before release by 0.6.53. |
| agent-relay-0.6.51 | **planned** | agent-relay 0.6.51<br>relayhistory 0.1.3<br>relay-control 0.4.14<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.25, relayhistory 0.1.3, relay-control 0.4.14, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.6, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Carries 0.6.50 with telemetry-collector 0.1.6, accepting the published customer Control 0.5.16 collector source and its brief/Relaycast event catalog. The Kind recipe selects that immutable image to fix fresh collector startup with the brief producer. Other service/profile images are unchanged. |
| agent-relay-0.6.50 | **planned** | agent-relay 0.6.50<br>relayhistory 0.1.3<br>relay-control 0.4.14<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.25, relayhistory 0.1.3, relay-control 0.4.14, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Supersedes 0.6.49 before release by pinning relay-webapp be770cac (digest da0cc804) in the GCP, EKS and reusable EKS/RDS customer profiles. That image adds the Policies and Downloads pages, the split-host download CSRF fix, source-free session links, and the script-free /brand/ CSP and 404 required by the hosted customer-logo wiring. Carries 0.6.49 and relay-control chart 0.4.14 with the owner-only usage_people selection; usage_people still needs a separately qualified relay-control 0.5.17-or-later image and a dashboard image with the People view. |
| agent-relay-0.6.49 | **planned** | agent-relay 0.6.49<br>relayhistory 0.1.3<br>relay-control 0.4.14<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.25, relayhistory 0.1.3, relay-control 0.4.14, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before release by 0.6.50. Adds the owner-only usage_people selection (relay-control chart 0.4.14 accepts selectedFeatures usage_people). Pinned digests are unchanged from 0.6.48; usage_people needs relay-control 0.5.17 or later and a dashboard image with the People view. Otherwise as 0.6.48. |
| agent-relay-0.6.48 | **planned** | agent-relay 0.6.48<br>relayhistory 0.1.3<br>relay-control 0.4.13<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.25, relayhistory 0.1.3, relay-control 0.4.13, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before release by 0.6.49. Adds the reusable customer-neutral values-eks-rds-native.yaml umbrella overlay on top of 0.6.47 and preserves its hosted customer-logo chart wiring: RDS, S3 Pod Identity, OpenSearch, native read/ingest/indexing, Output/digest/facts without a narrative model, structured password/setup-key sign-in, default-off coordination and agent-name views, and the approved 2026.11.0 image pins. Carries sessions-pipeline 0.8.25, whose AWS profile selects the fresh-native timing and lagging-canonical assumptions required by that image. It preserves the reader-first ceiling-10 phase and leaves output-facts bootstrap and wasm-bindgen writer selection explicit. Render and golden tests prove the four exact Pod Identity ServiceAccounts, no rendered Secrets, no legacy RelayAuth/History workloads, and the default EBS StorageClass contract. |
| agent-relay-0.6.47 | **planned** | agent-relay 0.6.47<br>relayhistory 0.1.3<br>relay-control 0.4.13<br>relay-webapp 0.2.4<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.24, relayhistory 0.1.3, relay-control 0.4.13, relay-webapp 0.2.4, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before release by 0.6.48. Adds the hosted customer logo: global.branding.logo (inline svg, or existingConfigMap and key) is served by relay-webapp 0.2.4 at <dashboard origin>/brand/<file>, and relay-control 0.4.13 points SELFHOST_LOGIN_LOGO_URL at it (login.logoUrl overrides; login.orgName sets SELFHOST_LOGIN_ORG_NAME). Off by default; default renders differ from 0.6.46 only in the helm.sh/chart labels. Images unchanged from 0.6.46; a relay-webapp image from #132 adds the /brand/ CSP and 404. Otherwise as 0.6.46. |
| agent-relay-0.6.46 | **planned** | agent-relay 0.6.46<br>relayhistory 0.1.3<br>relay-control 0.4.12<br>relay-webapp 0.2.3<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.24, relayhistory 0.1.3, relay-control 0.4.12, relay-webapp 0.2.3, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relaycast: `ghcr.io/agentworkforce/relaycast-self-host@sha256:ab9dd6781e68…`<br>sessions-pipeline-worker: `ghcr.io/agentworkforce/sessions-pipeline@sha256:77022c5b6a1d…`<br>relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before release by 0.6.47, which adds the hosted customer logo. Customer pack release candidate on top of 0.6.45 and its first-class output-facts/bootstrap/read API defaults plus the approved relay-control 0.5.16 pin from source 83a57d38: GCP and EKS pin the signed Sessions alpha.5 image from source 7e9b2f0f on every services-image workload and Job, including output-facts bootstrap, the collector-capable Relaycast image from cac175b5 and relay-webapp c485ba65. Both profiles are reader-first at ceiling 10; values-scrub-wasm-bindgen.yaml is the explicit phase-2 cutover. The customer EKS profile selects usage and launch after the ar-lap owner lifecycle proof passed capability, owned-target, spawn, idempotent replay, Ready, cross-session ownership refusal, release and roster-removal checks. Remove launch if its enrolled owner/admin Desktop target regresses at install time. Relaycast analytics, MinIO direct upload and password/setup-key options remain default off. |
| agent-relay-0.6.45 | **planned** | agent-relay 0.6.45<br>relayhistory 0.1.3<br>relay-control 0.4.12<br>relay-webapp 0.2.3<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.23, relayhistory 0.1.3, relay-control 0.4.12, relay-webapp 0.2.3, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before release by 0.6.46. Carries sessions-pipeline 0.8.23: first-class output facts, the optional output facts bootstrap Job and session read API output/digest values; the aws-rds-native profile turns facts, Output and digest on with no narrative model. Pinned images are unchanged from 0.6.44. |
| agent-relay-0.6.44 | **planned** | agent-relay 0.6.44<br>relayhistory 0.1.3<br>relay-control 0.4.12<br>relay-webapp 0.2.3<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.22, relayhistory 0.1.3, relay-control 0.4.12, relay-webapp 0.2.3, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before release by 0.6.45. Pins the approved relay-control 0.5.16 image from source 83a57d38 (run 42975781927) in the GCP customer handoff and the AWS EKS profile: it adds shared-session read auditing with an owner/admin export (#100, migration 0042) and the bounded native provider transport (#101) on top of 0.5.15. Otherwise as 0.6.43; no services pin or rollout is selected. |
| agent-relay-0.6.43 | **planned** | agent-relay 0.6.43<br>relayhistory 0.1.3<br>relay-control 0.4.12<br>relay-webapp 0.2.3<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.22, relayhistory 0.1.3, relay-control 0.4.12, relay-webapp 0.2.3, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before release by 0.6.44, which pins relay-control 0.5.16. Pins the approved relay-control 0.5.15 image from source 31ff0737 (run 42973044715) in the GCP customer handoff and the AWS EKS profile: it carries the setup key, temporary passwords and password sign-in without SMTP (#96) that relay-control chart 0.4.12 exposes, MCP agent launch (#95), Desktop dashboard redirects (#97) and Claude chat attestation (#98), on top of 0.5.12. Otherwise as 0.6.42; no services pin or rollout is selected. |
| agent-relay-0.6.42 | **planned** | agent-relay 0.6.42<br>relayhistory 0.1.3<br>relay-control 0.4.12<br>relay-webapp 0.2.3<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.22, relayhistory 0.1.3, relay-control 0.4.12, relay-webapp 0.2.3, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before release by 0.6.43, which pins relay-control 0.5.15. Carries relay-control 0.4.12: optional auth.password.enabled (SELFHOST_SIGNIN_METHODS with password, SMTP optional), auth.trustedProxies (SELFHOST_TRUSTED_PROXIES, 1 by default with password sign-in) and the operator-generated one-time first-admin secretKeys.setupKey (SELFHOST_SETUP_KEY_FILE, API pod only). Nothing renders while they are unset. Password sign-in without SMTP and the setup key need a relay-control image from source bd1c9a03 (#96) or later; the pinned digests are unchanged. Otherwise as 0.6.41. |
| agent-relay-0.6.41 | **planned** | agent-relay 0.6.41<br>relayhistory 0.1.3<br>relay-control 0.4.11<br>relay-webapp 0.2.3<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.22, relayhistory 0.1.3, relay-control 0.4.11, relay-webapp 0.2.3, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before release by 0.6.42. Adds default-off MinIO presigned direct-upload issuer wiring. Compatible published Control #94, Desktop and pipeline #525 artifacts require qualification before enablement. Image pins are unchanged from 0.6.40. |
| agent-relay-0.6.40 | **planned** | agent-relay 0.6.40<br>relayhistory 0.1.3<br>relay-control 0.4.10<br>relay-webapp 0.2.3<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.22, relayhistory 0.1.3, relay-control 0.4.10, relay-webapp 0.2.3, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before release by 0.6.41. Adds the default-off agent launch selection (relay-control chart 0.4.10 accepts selectedFeatures launch). Pinned Control and dashboard digests are unchanged from 0.6.39; launch needs relay-control 0.5.14 or later (index sha256:eec96e31c4625291884d075f1c145caff0507badf2154a2ecf78763af1ececf3, source 1309ee65, run 42970141599). Otherwise as 0.6.39. |
| agent-relay-0.6.39 | **planned** | agent-relay 0.6.39<br>relayhistory 0.1.3<br>relay-control 0.4.9<br>relay-webapp 0.2.3<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.22, relayhistory 0.1.3, relay-control 0.4.9, relay-webapp 0.2.3, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before release by 0.6.40. Adds the default-off owner-only Usage page selection (relay-control chart 0.4.9 accepts selectedFeatures usage). Pinned Control and dashboard digests are unchanged from 0.6.38; usage needs a Control image with the usage API and a dashboard image with the Usage page. Otherwise as 0.6.38. |
| agent-relay-0.6.38 | **planned** | agent-relay 0.6.38<br>relayhistory 0.1.3<br>relay-control 0.4.8<br>relay-webapp 0.2.3<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.22, relayhistory 0.1.3, relay-control 0.4.8, relay-webapp 0.2.3, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before release by 0.6.39. Carries default-off direct-upload Control and native consumer values (Control 0.4.8 and sessions-pipeline 0.8.22), with isolated AWS upload/issuer/consumer IAM and Pod Identity wiring. Requires compatible published Control #90 and pipeline #515 artifacts before enablement. Existing image defaults and disabled manifests are unchanged. |
| agent-relay-0.6.37 | **planned** | agent-relay 0.6.37<br>relayhistory 0.1.3<br>relay-control 0.4.7<br>relay-webapp 0.2.3<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.21, relayhistory 0.1.3, relay-control 0.4.7, relay-webapp 0.2.3, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Pins the approved relay-control 0.5.12 image from source bf8924c3 (run 42959388630) in the GCP customer handoff and the AWS EKS profile; it adds EKS Pod Identity / IRSA credentials to the default AWS chain, which the Desktop-feed signer and S3 storage need on EKS. Otherwise carries 0.6.36: sessions-pipeline 0.8.21 with its default-on Postgres coordination-overlaps endpoint when the reader is enabled, relay-webapp 0.2.3 with the strict default-off coordination-overlaps view, and the default-off Relaycast collector analytics. A qualified immutable services image remains a prerequisite; no services pin or rollout is selected. |
| agent-relay-0.6.36 | **planned** | agent-relay 0.6.36<br>relayhistory 0.1.3<br>relay-control 0.4.7<br>relay-webapp 0.2.3<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.21, relayhistory 0.1.3, relay-control 0.4.7, relay-webapp 0.2.3, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:bd295ccb7d13…` |  |  | Superseded before release by 0.6.37. Carries sessions-pipeline 0.8.21 coordination overlaps, relay-webapp 0.2.3 and the default-off Relaycast collector analytics; 0.6.37 additionally pins relay-control 0.5.12 in the GCP handoff and AWS EKS profiles. |
| agent-relay-0.6.35 | **planned** | agent-relay 0.6.35<br>relayhistory 0.1.3<br>relay-control 0.4.7<br>relay-webapp 0.2.2<br>(deps: relaycast 0.3.8, relayauth 0.1.5, sessions-pipeline 0.8.20, relayhistory 0.1.3, relay-control 0.4.7, relay-webapp 0.2.2, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.5, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Superseded before release by 0.6.36. Carries default-off Relaycast collector analytics and the matching collector vocabulary. |
| agent-relay-0.6.34 | **planned** | agent-relay 0.6.34<br>relayhistory 0.1.3<br>relay-control 0.4.7<br>relay-webapp 0.2.2<br>(deps: relaycast 0.3.7, relayauth 0.1.5, sessions-pipeline 0.8.20, relayhistory 0.1.3, relay-control 0.4.7, relay-webapp 0.2.2, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.4, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Carries relay-control 0.4.7 with the optional auth.microsoft sign-in pass-through (SELFHOST_MICROSOFT_*, secretKeys.microsoftClientSecret). Nothing renders while auth.microsoft is empty; the API reads it only from an image with relay-control #87. |
| agent-relay-0.6.33 | **planned** | agent-relay 0.6.33<br>relayhistory 0.1.3<br>relay-control 0.4.6<br>relay-webapp 0.2.2<br>(deps: relaycast 0.3.7, relayauth 0.1.5, sessions-pipeline 0.8.20, relayhistory 0.1.3, relay-control 0.4.6, relay-webapp 0.2.2, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.4, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Carries telemetry-collector 0.1.4 with the brief-worker vocabulary source allowlist. Keeps the default-off brief analytics binding and the approved Control GCP handoff. |
| agent-relay-0.6.32 | **planned** | agent-relay 0.6.32<br>relayhistory 0.1.3<br>relay-control 0.4.6<br>relay-webapp 0.2.2<br>(deps: relaycast 0.3.7, relayauth 0.1.5, sessions-pipeline 0.8.20, relayhistory 0.1.3, relay-control 0.4.6, relay-webapp 0.2.2, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.3, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Carries sessions-pipeline 0.8.20 and the default-off native brief collector binding. Retains the approved Control GCP handoff and dashboard analytics values. |
| agent-relay-0.6.31 | **planned** | agent-relay 0.6.31<br>relayhistory 0.1.3<br>relay-control 0.4.6<br>relay-webapp 0.2.2<br>(deps: relaycast 0.3.7, relayauth 0.1.5, sessions-pipeline 0.8.19, relayhistory 0.1.3, relay-control 0.4.6, relay-webapp 0.2.2, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.3, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Carries relay-webapp 0.2.2 with an explicit nullable dashboard analytics runtime flag, preserving both true and false without adding collector credentials to the browser. Retains relay-control 0.4.6 native public-reader aliases, sessions-pipeline 0.8.19 and its opt-in reader ceilings, and the approved relay-control 0.5.10 GCP handoff pin from source 1e552737. Desktop feed and signer behavior are unchanged. No customer target or rollout is selected. |
| agent-relay-0.6.30 | **planned** | agent-relay 0.6.30<br>relayhistory 0.1.3<br>relay-control 0.4.6<br>relay-webapp 0.2.1 |  |  |  | Superseded before release by 0.6.31. Carries the approved relay-control 0.5.10 GCP handoff pin; 0.6.31 additionally preserves the dashboard analytics runtime selection. |
| agent-relay-0.6.29 | **planned** | agent-relay 0.6.29<br>relayhistory 0.1.3<br>relay-control 0.4.6<br>relay-webapp 0.2.1 |  |  |  | Superseded before release by 0.6.30. Carries relay-control 0.4.6 and the native public-reader host alias; 0.6.30 additionally pins the approved relay-control 0.5.10 image in the GCP customer handoff profile. |
| agent-relay-0.6.28 | **planned** | agent-relay 0.6.28<br>relayhistory 0.1.3<br>relay-control 0.4.5<br>relay-webapp 0.2.1 |  |  |  | Superseded before release by 0.6.29. Carries sessions-pipeline 0.8.19 reader ceilings; 0.6.29 also retains the native public-reader host alias. |
| agent-relay-0.6.27 | **planned** | agent-relay 0.6.27<br>relayhistory 0.1.3<br>relay-control 0.4.5<br>relay-webapp 0.2.1 |  |  |  | Superseded before release by 0.6.28. Carries sessions-pipeline 0.8.18 reader ceilings; 0.6.28 also covers the native ingest-edge engine initializer. |
| agent-relay-0.6.26 | **planned** | agent-relay 0.6.26<br>relayhistory 0.1.3<br>relay-control 0.4.5<br>relay-webapp 0.2.1 |  |  |  | Superseded before release by 0.6.27. Carries the exact native-ingest upload token refresh route repair without changing image, migration, authority or admission choices. |
| agent-relay-0.6.25 | **planned** | agent-relay 0.6.25<br>relayhistory 0.1.3<br>relay-control 0.4.5<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.5, sessions-pipeline 0.8.16, relayhistory 0.1.3, relay-control 0.4.5, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.3, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Carries sessions-pipeline 0.8.16 and the managed default-on claim-lock busy mapping. The qualified services image must contain pipeline #484; no image, customer target, or admission mode is selected here. |
| agent-relay-0.6.24 | **planned** | agent-relay 0.6.24<br>relayhistory 0.1.3<br>relay-control 0.4.5<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.5, sessions-pipeline 0.8.15, relayhistory 0.1.3, relay-control 0.4.5, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.3, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Carries sessions-pipeline 0.8.15 and its customer-neutral, fail-closed AWS RDS native profile. The umbrella still supplies no customer resource identifiers or release-overlay services/webapp digests. |
| agent-relay-0.6.23 | **planned** | agent-relay 0.6.23<br>relayhistory 0.1.3<br>relay-control 0.4.5<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.5, sessions-pipeline 0.8.14, relayhistory 0.1.3, relay-control 0.4.5, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.3, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Carries sessions-pipeline 0.8.14 and the default-off coordination overlaps switch. Existing profiles, image pins, workloads, Secrets, databases and migrations are unchanged. |
| agent-relay-0.6.22 | **planned** | agent-relay 0.6.22<br>relayhistory 0.1.3<br>relay-control 0.4.5<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.5, sessions-pipeline 0.8.13, relayhistory 0.1.3, relay-control 0.4.5, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.3, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Adds the GCP native History overlay and GKE routing for the Sessions read API and ingest edge, refreshes the GCP profile to the customer-qualified services, webapp and relay-control 0.5.8 digests, and takes sessions-pipeline 0.8.13 for native GCS support. Retains the default-off Control collector and external introspection configuration from 0.6.21. |
| agent-relay-0.6.21 | **planned** | agent-relay 0.6.21<br>relayhistory 0.1.3<br>relay-control 0.4.5<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.5, sessions-pipeline 0.8.12, relayhistory 0.1.3, relay-control 0.4.5, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.3, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Never released; superseded by 0.6.22. Adds default-off Control collector analytics and an API-only external introspection Secret reference. No source/image default or runtime changes. Collector credentials and CA never reach migration Jobs or pepper init containers; existing introspection keys remain compatible. |
| agent-relay-0.6.20 | **planned** | agent-relay 0.6.20<br>relayhistory 0.1.3<br>relay-control 0.4.4<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.5, sessions-pipeline 0.8.12, relayhistory 0.1.3, relay-control 0.4.4, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.3, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Adds managed default-off native collector adapters. Each service uses a component-bound Secret reference, an opaque installation ID, HTTPS and optional public additional CA trust. Preflight/bootstrap has no analytics credentials. No application image default, SQL, admission mode, profile or runtime is changed; a qualified source71801741-or-later image and operator registrations remain required. |
| agent-relay-0.6.19 | **planned** | agent-relay 0.6.19<br>relayhistory 0.1.3<br>relay-control 0.4.4<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.5, sessions-pipeline 0.8.11, relayhistory 0.1.3, relay-control 0.4.4, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.3, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Picks up telemetry-collector 0.1.3 and its qualified private-file recovery source. The collector remains default-off; application pins, producer configuration and database behavior are unchanged. |
| agent-relay-0.6.18 | **planned** | agent-relay 0.6.18<br>relayhistory 0.1.3<br>relay-control 0.4.4<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.5, sessions-pipeline 0.8.11, relayhistory 0.1.3, relay-control 0.4.4, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.2, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Picks up sessions-pipeline 0.8.11 (optional nativeBrief.baseUrl and nativeBrief.allowInClusterHttp). Default renders are unchanged apart from chart versions. |
| agent-relay-0.6.17 | **planned** | agent-relay 0.6.17<br>relayhistory 0.1.3<br>relay-control 0.4.4<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.5, sessions-pipeline 0.8.10, relayhistory 0.1.3, relay-control 0.4.4, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.2, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Adds optional secretKeys.passwordPepper to relay-control; the default render is unchanged. |
| agent-relay-0.6.16 | **planned** | agent-relay 0.6.16<br>relayhistory 0.1.3<br>relay-control 0.4.3<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.5, sessions-pipeline 0.8.10, relayhistory 0.1.3, relay-control 0.4.3, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.2, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Never released; superseded by 0.6.17. Deployment-only retirement remains default-enabled. Explicitly setting deployment.enabled=false omits only the selected legacy Deployment; all other resources remain managed. Runtime images and SQL are unchanged. Retained upgrades require an actual-current render review; this source release does not claim runtime retirement or data migration. |
| agent-relay-0.6.15 | **planned** | agent-relay 0.6.15<br>relayhistory 0.1.2<br>relay-control 0.4.3<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.4, sessions-pipeline 0.8.9, relayhistory 0.1.2, relay-control 0.4.3, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.2, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Never released; superseded by 0.6.16. Takes telemetry-collector 0.1.2 with the current public Control collector package, kernel writer lock and decimal numeric limits. All producers and the component remain default-off; existing application image pins are unchanged and are not native-runtime qualification. |
| agent-relay-0.6.14 | **planned** | agent-relay 0.6.14<br>relayhistory 0.1.2<br>relay-control 0.4.3<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.4, sessions-pipeline 0.8.9, relayhistory 0.1.2, relay-control 0.4.3, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.1, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Never released; superseded by 0.6.15. Adds explicit managed optional-feature selection and native independent-reader local core phase admission. Defaults preserve extraEnv compatibility; no license is used. Native runtime and public artifacts require separate qualification; the old pinned Control image is not a compatible native-core image claim. |
| agent-relay-0.6.13 | **planned** | agent-relay 0.6.13<br>relayhistory 0.1.2<br>relay-control 0.4.2<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.4, sessions-pipeline 0.8.8, relayhistory 0.1.2, relay-control 0.4.2, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.1, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Takes sessions-pipeline 0.8.8 (ingest edge heartbeat). |
| agent-relay-0.6.12 | **planned** | agent-relay 0.6.12<br>relayhistory 0.1.2<br>relay-control 0.4.2<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.4, sessions-pipeline 0.8.7, relayhistory 0.1.2, relay-control 0.4.2, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.1, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Takes sessions-pipeline 0.8.7 and its default-off managed brief worker while preserving Control 0.4.2 license retirement and native backend. No image publication or runtime acceptance is implied. |
| agent-relay-0.6.11 | **planned** | agent-relay 0.6.11<br>relayhistory 0.1.2<br>relay-control 0.4.2<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.4, sessions-pipeline 0.8.6, relayhistory 0.1.2, relay-control 0.4.2, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.1, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Removes the self-host license Secret mount and values. Optional components are selected with SELFHOST_FEATURES through relay-control extraEnv. The pinned Control digest predates license removal and still needs the replacement image; no rollout is claimed. |
| agent-relay-0.6.10 | **planned** | agent-relay 0.6.10<br>relayhistory 0.1.2<br>relay-control 0.4.1<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.4, sessions-pipeline 0.8.6, relayhistory 0.1.2, relay-control 0.4.1, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.1, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Adds relay-control 0.4.1 with services.relayhistoryBackend=native and the no-RelayAuth overlay. Version 0.6.9 is reserved by a concurrent change. |
| agent-relay-0.6.8 | **planned** | agent-relay 0.6.8<br>relayhistory 0.1.2<br>relay-control 0.4.0<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.7, relayauth 0.1.4, sessions-pipeline 0.8.4, relayhistory 0.1.2, relay-control 0.4.0, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.1, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Uses relaycast 0.3.7 for actor-mode bootstrap wiring. Retains sessions-pipeline 0.8.4 and reader 0.2.1 async-admission/inception options from 0.6.7; defaults remain disabled and no rollout is claimed. |
| agent-relay-0.6.7 | **planned** | agent-relay 0.6.7<br>relayhistory 0.1.2<br>relay-control 0.4.0<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.6, relayauth 0.1.4, sessions-pipeline 0.8.4, relayhistory 0.1.2, relay-control 0.4.0, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.1, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Superseded before tagging by agent-relay-0.6.8. Takes sessions-pipeline 0.8.4 with opt-in async admission and reader 0.2.1 inception coverage for new own-ingest stores, retaining explicit partial-import floors. Preserves current Relaycast, RelayChief Control and Webapp dependencies. Defaults remain disabled; no image qualification or rollout is supplied. |
| agent-relay-0.6.6 | **planned** | agent-relay 0.6.6<br>relayhistory 0.1.2<br>relay-control 0.4.0<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.6, relayauth 0.1.4, sessions-pipeline 0.8.3, relayhistory 0.1.2, relay-control 0.4.0, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.1, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Superseded before tagging by agent-relay-0.6.8. Takes sessions-pipeline 0.8.3 (search indexer Node CA). |
| agent-relay-0.6.5 | **planned** | agent-relay 0.6.5<br>relayhistory 0.1.2<br>relay-control 0.4.0<br>relay-webapp 0.2.1<br>(deps: relaycast 0.3.6, relayauth 0.1.4, sessions-pipeline 0.8.2, relayhistory 0.1.2, relay-control 0.4.0, relay-webapp 0.2.1, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.1, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Takes relay-webapp 0.2.1 (default-off runtime.sessionReadApiEnabled). |
| agent-relay-0.6.4 | **planned** | agent-relay 0.6.4<br>relayhistory 0.1.2<br>relay-control 0.4.0<br>relay-webapp 0.2.0<br>(deps: relaycast 0.3.6, relayauth 0.1.4, sessions-pipeline 0.8.2, relayhistory 0.1.2, relay-control 0.4.0, relay-webapp 0.2.0, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.1, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Takes sessions-pipeline 0.8.2 (ingestEdge Pod Identity and session selection). |
| agent-relay-0.6.3 | **planned** | agent-relay 0.6.3<br>relayhistory 0.1.2<br>relay-control 0.4.0<br>relay-webapp 0.2.0<br>(deps: relaycast 0.3.6, relayauth 0.1.4, sessions-pipeline 0.8.1, relayhistory 0.1.2, relay-control 0.4.0, relay-webapp 0.2.0, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.1, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Takes relaycast 0.3.6 (default-off runtime.backend=postgres). With it off, every render differs only in the helm.sh/chart labels. |
| agent-relay-0.6.2 | **planned** | agent-relay 0.6.2<br>relayhistory 0.1.2<br>relay-control 0.4.0<br>relay-webapp 0.2.0<br>(deps: relaycast 0.3.5, relayauth 0.1.4, sessions-pipeline 0.8.1, relayhistory 0.1.2, relay-control 0.4.0, relay-webapp 0.2.0, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.1, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Takes sessions-pipeline 0.8.1, which allows the default-off self_issued read API mode. |
| agent-relay-0.6.1 | **planned** | agent-relay 0.6.1<br>relayhistory 0.1.2<br>relay-control 0.4.0<br>relay-webapp 0.2.0<br>(deps: relaycast 0.3.5, relayauth 0.1.4, sessions-pipeline 0.8.0, relayhistory 0.1.2, relay-control 0.4.0, relay-webapp 0.2.0, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.1, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `ghcr.io/agentworkforce/relay-control@sha256:d8c26d44dccb…`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Moves Control to ghcr.io/agentworkforce/relay-control 0.5.0 and the relay-control package paths; older pins need server.args and migrations.args. Adds default-off session read handoff and introspection values. The handoff needs Control 0.5.1, not yet published. |
| agent-relay-0.6.0 | **planned** | agent-relay 0.6.0<br>relayhistory 0.1.2<br>relay-control 0.3.1<br>relay-webapp 0.2.0<br>(deps: relaycast 0.3.5, relayauth 0.1.4, sessions-pipeline 0.8.0, relayhistory 0.1.2, relay-control 0.3.1, relay-webapp 0.2.0, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.0, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `<required repository>@sha256:<required>`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Takes sessions-pipeline 0.8.0, which moves the session read API to its own chart under sessionReadApi. |
| agent-relay-0.5.5 | **planned** | agent-relay 0.5.5<br>relayhistory 0.1.2<br>relay-control 0.3.1<br>relay-webapp 0.2.0<br>(deps: relaycast 0.3.5, relayauth 0.1.4, sessions-pipeline 0.7.6, relayhistory 0.1.2, relay-control 0.3.1, relay-webapp 0.2.0, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.0, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `<required repository>@sha256:<required>`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Takes sessions-pipeline 0.7.6 (default-off searchIndexer). With it off, every render differs only in the helm.sh/chart labels. |
| agent-relay-0.5.4 | **planned** | agent-relay 0.5.4<br>relayhistory 0.1.2<br>relay-control 0.3.1<br>relay-webapp 0.2.0<br>(deps: relaycast 0.3.5, relayauth 0.1.4, sessions-pipeline 0.7.5, relayhistory 0.1.2, relay-control 0.3.1, relay-webapp 0.2.0, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.0, relay-chief 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `<required repository>@sha256:<required>`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Adds relay-chief 0.1.0 as a default-off component (components.relayChief). With it off, every render differs only in the helm.sh/chart labels. |
| agent-relay-0.5.3 | **planned** | agent-relay 0.5.3<br>relayhistory 0.1.2<br>relay-control 0.3.1<br>relay-webapp 0.2.0<br>(deps: relaycast 0.3.5, relayauth 0.1.4, sessions-pipeline 0.7.5, relayhistory 0.1.2, relay-control 0.3.1, relay-webapp 0.2.0, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `<required repository>@sha256:<required>`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Never released; superseded by 0.5.4. Adds default-off postgresCa so Node workloads and migrate Jobs can verify the Postgres server certificate (NODE_EXTRA_CA_CERTS); with it unset every render differs only in the helm.sh/chart labels and the relayhistory checksum/config annotation, which hashes the ConfigMap including that label and so rolls the relayhistory pods on upgrade. Adds the default-off native ingest slot from pipeline #363 without an accepted artifact or rollout. Composes landed session naming/main bfcf6050, default-off telemetry #95/a45dbb2d and default-off reader #81/01dc7aee; preserves the standalone Chief registry outside the umbrella/kind profiles. Source-only Control/Webapp public chart rename. The Control chart requires both repository and digest explicitly; Webapp requires a verified digest; real profile image coordinates remain explicitly pinned to their existing repositories until those publishers supply new receipts. Existing releases must translate values keys and preserve names/selectors/DNS with a reviewed compatibility overlay. Kind refuses the old Control/Webapp layout before mutation. No RelayAuth or standalone History removal, publisher dispatch, rollout or new runtime proof is included; the sessions-native replacement remains dependency-gated. |
| agent-relay-0.5.2 | **planned** | agent-relay 0.5.2<br>relayhistory 0.1.1<br>relay-control 0.3.0<br>relay-webapp 0.2.0<br>(deps: relaycast 0.3.5, relayauth 0.1.4, sessions-pipeline 0.7.4, relayhistory 0.1.1, relay-control 0.3.0, relay-webapp 0.2.0, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `<required repository>@sha256:<required>`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Never released; superseded by 0.5.3. Adds the default-off native ingest slot from pipeline #363 without an accepted artifact or rollout. Composes landed session naming/main bfcf6050, default-off telemetry #95/a45dbb2d and default-off reader #81/01dc7aee; preserves the standalone Chief registry outside the umbrella/kind profiles. Source-only Control/Webapp public chart rename. The Control chart requires both repository and digest explicitly; Webapp requires a verified digest; real profile image coordinates remain explicitly pinned to their existing repositories until those publishers supply new receipts. Existing releases must translate values keys and preserve names/selectors/DNS with a reviewed compatibility overlay. Kind refuses the old Control/Webapp layout before mutation. No RelayAuth or standalone History removal, publisher dispatch, rollout or new runtime proof is included; the sessions-native replacement remains dependency-gated. |
| agent-relay-0.5.0 | **planned** | agent-relay 0.5.0<br>relayhistory 0.1.1<br>relay-control 0.3.0<br>relay-webapp 0.2.0<br>(deps: relaycast 0.3.5, relayauth 0.1.4, sessions-pipeline 0.7.2, relayhistory 0.1.1, relay-control 0.3.0, relay-webapp 0.2.0, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2, telemetry-collector 0.1.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-control: `<required repository>@sha256:<required>`<br>relay-webapp: `ghcr.io/agentworkforce/relay-webapp@sha256:<required>` |  |  | Composes landed session naming/main bfcf6050, default-off telemetry #95/a45dbb2d and default-off reader #81/01dc7aee; preserves the standalone Chief registry outside the umbrella/kind profiles. Source-only Control/Webapp public chart rename. The Control chart requires both repository and digest explicitly; Webapp requires a verified digest; real profile image coordinates remain explicitly pinned to their existing repositories until those publishers supply new receipts. Existing releases must translate values keys and preserve names/selectors/DNS with a reviewed compatibility overlay. Kind refuses the old Control/Webapp layout before mutation. No RelayAuth or standalone History removal, publisher dispatch, rollout or new runtime proof is included; the sessions-native replacement remains dependency-gated. |
| agent-relay-0.3.17 | **planned** | agent-relay 0.3.17<br>relayhistory 0.1.1<br>relay-cloud-api 0.2.7<br>relay-dashboard 0.1.3<br>(deps: relaycast 0.3.5, relayauth 0.1.4, sessions-pipeline 0.6.2, relayhistory 0.1.1, relay-cloud-api 0.2.7, relay-dashboard 0.1.3, relayflows 0.2.5, durable-actors 0.14.6-awf.1, relayfile 0.2.2) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-cloud-api: `ghcr.io/agentworkforce/selfhost-api@sha256:<required>`<br>relay-dashboard: `ghcr.io/agentworkforce/relay-dashboard@sha256:<required>` |  |  | Historical untagged source proposal at d8bbff820a6541593fa2e889cbf14e3aa1f0baa7, superseded by the public-name source row; not a published or current release. Bundles sessions-pipeline 0.6.2 default-off read API plumbing and relay-cloud-api 0.2.7 legacy-client env omission. Supersedes the untagged 0.3.16 source and retains its kind core/addons relay-webapp b944a979 image pin at sha256:e4de2c628e72e906e809fd32e6192baa7c93a404eb019964cd7706805e316e6a; no new UI/runtime proof is claimed. Includes unset OAuth/raw FILE-alias reservation and strict valueFrom source validation from the reviewed extraEnv guard proposal. No profile enables the component or reroutes relaycontrol. Compatible runtime assembly and image remain upstream dependencies. Existing kind evidence belongs to its pinned base revision, not this new chart version. |
| agent-relay-0.3.12 | shipped | agent-relay 0.3.12<br>relayhistory 0.1.1<br>relay-cloud-api 0.2.4<br>relay-dashboard 0.1.3<br>(deps: relaycast 0.3.4, relayauth 0.1.3, sessions-pipeline 0.6.0, relayhistory 0.1.1, relay-cloud-api 0.2.4, relay-dashboard 0.1.3, relayflows 0.2.4, durable-actors 0.14.6-awf.1, relayfile 0.2.1) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-cloud-api: `ghcr.io/agentworkforce/selfhost-api@sha256:<required>`<br>relay-dashboard: `ghcr.io/agentworkforce/relay-dashboard@sha256:<required>` |  |  | 0.3.12 is published from the tag agent-relay-0.3.12 (release run 41985579885). New in 0.3.12: Durable actors on AWS EKS. values-eks-actors.yaml is a standalone profile (Relaycast and Relayfile in actor mode on durable-actors with S3 storage, runc actor hosts on a tainted node group, EKS Pod Identity); scripts/selfhost/eks-actors-sandbox.sh and eks-actors-install.sh build the proof in a Pippen sandbox. Bundles durable-actors 0.14.6-awf.1 (UPSTREAM.md patches 10 and 11: storage.provider s3, storage.s3.*, AWS zones, sandbox.*; needs a control-plane image from the AgentWorkforce durable-actors fork), relaycast 0.3.4 and relayfile 0.2.1 (S3 deployer artifact store). NOTES warns when storage.s3.actorCredentials is control-plane. With none of these values set every render is byte-identical to 0.3.11 apart from the helm.sh/chart labels. values-eks-actors.yaml pins six public GHCR actor images by digest (durable-actors-control-plane and durable-actors-typescript from the fork tag awf-v0.14.6-aws.2, linux/amd64 only; relaycast-actors-gateway and relaycast-actors-deployer from relaycast 4e90b169; relayfile-actors and relayfile-actors-workspace from relayfile 30a5e007; anonymous pulls verified 2026-11-04), recorded as inactive entries in customer-images.yaml. The actor components stay off by default. Release images and values-gcp.yaml pins are unchanged from 0.3.11. |
| agent-relay-0.3.11 | shipped | agent-relay 0.3.11<br>relayhistory 0.1.1<br>relay-cloud-api 0.2.4<br>relay-dashboard 0.1.3<br>(deps: relaycast 0.3.3, relayauth 0.1.3, sessions-pipeline 0.6.0, relayhistory 0.1.1, relay-cloud-api 0.2.4, relay-dashboard 0.1.3, relayflows 0.2.4, durable-actors 0.14.6, relayfile 0.2.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-cloud-api: `ghcr.io/agentworkforce/selfhost-api@sha256:<required>`<br>relay-dashboard: `ghcr.io/agentworkforce/relay-dashboard@sha256:<required>` |  |  | 0.3.11 is published from the tag agent-relay-0.3.11 (release run 41812609280). It pins public release images in values-gcp.yaml: selfhost-api 0.3.0 sha256:95c7877741054dc2f1cafa26be3faa9bfe4660ed85d637aef4524daa10481963 (relaycontrol 9b80b04: bootstrap, OIDC, invites, coding-agent credentials, device logins, Desktop sign-in origin, operator OAuth apps), relay-dashboard sha256:c50005fcdd1fc5ab5ef3dac9b621db8e0c7e03480406bfe519743ae435d8f1ad (relay-dashboard e5003d0: hosted Cloud look, Connections with Coding agents and visual parity #91, Members with email invites), RelayHistory sha256:d3166bb14e1d6043426a4dd8cc05408b94574c8d79ad5fd6e789e0de00ab371b (relayhistory-cloud 53c3333) and 96bulls-services sha256:070fe6fd46ecd1e1f9db32ff22379f6df9b9e6c4d48ede5312c8fb986a95f3a9 (sessions-pipeline f1c2672, origin-bound courier assertions) on worker and alleyoop, replacing the REQUIRED OVERRIDE zero digests; the services image needs its HoopDb role bootstraps (/app/supabase/bootstrap/session_directory_search_worker.sql, session_token_verifier.sql, session_ingest_roles.sql) before its first migrate. values-eks.yaml moves to the same selfhost-api and relay-dashboard digests. Leaf chart defaults are unchanged. Supersedes the never-tagged 0.3.10 and includes its changes: values-eks.yaml, the AWS EKS profile proven end to end on EKS Auto Mode with real DNS and TLS and the interim bearer off (docs/self-hosted-eks.md): one ALB Ingress with host rules and an ACM certificate (scripts/selfhost/eks-alb-ingress.sh), EKS Pod Identity to S3 for the Sessions Pipeline, in-cluster CloudNativePG for HoopDb, the control API and RelayHistory, Relaycast on SQLite, RelayHistory ghcr.io/agentworkforce/relayhistory@sha256:d3166bb1 (relayhistory-cloud 53c3333) and the services image 96bulls-services@sha256:070fe6fd (sessions-pipeline f1c2672, with #204). 0.3.10 in turn supersedes the never-tagged 0.3.9 and includes its changes: Bundles relay-cloud-api 0.2.4: first-boot bootstrap (bootstrap.orgName/adminEmail create the organization, its owner and a Default workspace bound to a new Relaycast workspace through secretKeys.relaycastInternalSecret; idempotent), sign-in (auth.oidc OpenID Connect with PKCE; auth.emailLink with smtp), invites (auth.inviteTtlHours, auth.autoJoinDomains) and smtp for invite emails; values-gcp.yaml carries a commented example. Requires a selfhost-api image from relaycontrol #13 or later and a dashboard image from relay-dashboard #92 or later for the Members invite UI; 0.3.11 pins both in values-gcp.yaml. With none of these values set every render is byte-identical apart from the helm.sh/chart labels. Supersedes the never-released 0.3.8 and includes its changes: Bundles relay-cloud-api 0.2.3, which adds integrations.<provider>.existingSecret: the customer's own OAuth app per integration (client ID from the Secret, client secret mounted as a file), for just-in-time connects from the CLI, flow onboarding and flow creation. Register <publicUrl>/api/v1/integrations/oauth/callback in each provider app. Requires a selfhost-api built from relaycontrol with operator OAuth apps (selfhost/jit-integrations). Supersedes the never-released 0.3.7 and includes its changes: A GKE proof-overlay and documentation patch of 0.3.6: values-gcp-proof-live.yaml sets relay-dashboard.customerProfile.desktop (urlScheme and siteUrl of the proof's custom Desktop build) (folds helm-charts #46), and relay-dashboard chart 0.1.3 documents customerProfile.desktop in its README. The Connect your agents link needs a dashboard image from relay-dashboard #88 or later; the overlay's own dashboard digest (53d484b) predates it, and the live proof deploy overrides that digest. Templates, images and values-gcp.yaml are unchanged from 0.3.6; renders differ only in the helm.sh/chart labels, plus DASHBOARD_CUSTOMER_PROFILE in the gcp-proof-live render. |
| agent-relay-0.3.6 | shipped | agent-relay 0.3.6<br>relayhistory 0.1.1<br>relay-cloud-api 0.2.2<br>relay-dashboard 0.1.2<br>(deps: relaycast 0.3.3, relayauth 0.1.3, sessions-pipeline 0.6.0, relayhistory 0.1.1, relay-cloud-api 0.2.2, relay-dashboard 0.1.2, relayflows 0.2.4, durable-actors 0.14.6, relayfile 0.2.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-cloud-api: `ghcr.io/agentworkforce/selfhost-api@sha256:<required>`<br>relay-dashboard: `ghcr.io/agentworkforce/relay-dashboard@sha256:<required>` |  |  | 0.3.6 is published from the tag agent-relay-0.3.6 (release run 41769269329); it releases the never-tagged 0.3.5 together with dashboard branding. From 0.3.5: opt-in single-host mode (global.singleHost.host, off by default): the dashboard and the control API share one host (/, /cloud/api, /login, /api), relay-cloud-api 0.2.2 derives publicUrl and the dashboard derives runtime.publicUrl and ingress.host from it, and the GKE Ingress drops the api host; Relaycast, Relay History, Relayfile and durable-actors keep their own hosts (README Single-host mode). New in 0.3.6: relay-dashboard chart 0.1.2 adds the optional customerProfile (enterprise branding: product name and title, light/dark logo, favicon, accent and button colors, support link, Powered by Agent Relay) rendered into DASHBOARD_CUSTOMER_PROFILE and served in /runtime-config.js; values-gcp.yaml carries a commented example. Branding needs a dashboard image built from relay-dashboard 8eac2bd or later (which also fixes the sessions sidebar facets); the pinned customer dashboard digest predates it and ignores the value. With single-host mode off and no customerProfile every default render is byte-identical to 0.3.4 apart from the helm.sh/chart labels. Images unchanged from 0.3.4. |
| agent-relay-0.3.4 | shipped | agent-relay 0.3.4<br>relayhistory 0.1.1<br>relay-cloud-api 0.2.1<br>relay-dashboard 0.1.0<br>(deps: relaycast 0.3.3, relayauth 0.1.3, sessions-pipeline 0.6.0, relayhistory 0.1.1, relay-cloud-api 0.2.1, relay-dashboard 0.1.0, relayflows 0.2.4, durable-actors 0.14.6, relayfile 0.2.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-cloud-api: `ghcr.io/agentworkforce/selfhost-api@sha256:<required>`<br>relay-dashboard: `ghcr.io/agentworkforce/relay-dashboard@sha256:<required>` |  |  | 0.3.4 is published from the tag agent-relay-0.3.4 (release run 41754926487) as a documentation patch of 0.3.3: relaycast chart 0.3.3 and relayauth chart 0.1.3 drop the stale instruction to override the relaycast image.digest for ar_ credentials (the pinned engine 12.7.0 default satisfies >=12.3.x), and values-gcp.yaml's credentials comment says the same. Images, templates and rendered values-gcp.yaml are unchanged from 0.3.3. |
| agent-relay-0.3.3 | shipped | agent-relay 0.3.3<br>relayhistory 0.1.1<br>relay-cloud-api 0.2.1<br>relay-dashboard 0.1.0<br>(deps: relaycast 0.3.2, relayauth 0.1.2, sessions-pipeline 0.6.0, relayhistory 0.1.1, relay-cloud-api 0.2.1, relay-dashboard 0.1.0, relayflows 0.2.4, durable-actors 0.14.6, relayfile 0.2.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-cloud-api: `ghcr.io/agentworkforce/selfhost-api@sha256:<required>`<br>relay-dashboard: `ghcr.io/agentworkforce/relay-dashboard@sha256:<required>` |  |  | 0.3.3 (tag agent-relay-0.3.3) moves relaycast to chart 0.3.2 and pins relaycast-self-host sha256:81274dca7ab58673383dc7a9c777f422f29606c7422e81b5ea15724770f1455e (relaycast main bf713d86, engine 12.7.0; SBOM + max-mode provenance + GitHub attestation; public) in values-gcp.yaml, and includes the never-tagged 0.3.2 proof refresh: GKE proof refresh on top of 0.3.1 (tag agent-relay-0.3.1). Proof overlays only: values-gcp-proof-durable-actors.yaml pins relaycast-actors-gateway sha256:faf66ec45d2c755ab5cdc6ee32bca6dc48446dff444118cab18fa1f765124ffa and relaycast-actors-deployer sha256:a81e91ed52bfb7cbb0a8c2773752df3b5d78afdc443608998b3203a30e314cee (relaycast main 3624cc12); values-gcp-proof-relayfile.yaml pins relayfile-actors sha256:7fb2110701a004f9f7ed2b025d25156fbe993208598bfbd0498a48b30df48299 and relayfile-actors-workspace sha256:c5851a1b1f7624390a1a00ebdee69e8e521dc3f23f345c582d62e09dba9a6e83 (relayfile main 39f84fcf); values-gcp-proof-live.yaml pins the experimental unsupported RelayHistory sha256:f36ae1671bdcd88a2b8b2df62c8edecb1381237d9f968747b39298959ad33563 (relayhistory-cloud 3cb76752). Proof CPU requests sized for the e2-medium pool, and the README documents the write-hold upgrade with the Relayflows smoke Job. The customer profile (values-gcp.yaml) and templates are unchanged from 0.3.1 apart from the Relaycast pin. Superseded by 0.3.4. |
| agent-relay-0.3.1 | shipped | agent-relay 0.3.1<br>relayhistory 0.1.1<br>relay-cloud-api 0.2.1<br>relay-dashboard 0.1.0<br>(deps: relaycast 0.3.1, relayauth 0.1.2, sessions-pipeline 0.6.0, relayhistory 0.1.1, relay-cloud-api 0.2.1, relay-dashboard 0.1.0, relayflows 0.2.4, durable-actors 0.14.6, relayfile 0.2.0) | relayhistory: `ghcr.io/agentworkforce/relayhistory@sha256:<required>`<br>relay-cloud-api: `ghcr.io/agentworkforce/selfhost-api@sha256:<required>`<br>relay-dashboard: `ghcr.io/agentworkforce/relay-dashboard@sha256:<required>` |  |  | 0.3.1 is published from the tag agent-relay-0.3.1 as the first reviewable, preview-labelled customer release; it includes the never-released 0.2.0, 0.2.1 and 0.3.0 changes described below. values-gcp.yaml pins these GHCR digests (supply chain per image): selfhost-api sha256:535e6718fa239ce87dead3d22e7c53324bed44bfcef94018918e8804d24af478 (relaycontrol main 8e989a1; SBOM + max-mode provenance; package still private), relay-dashboard sha256:bbeca872c7e204a02a17050db6ac6309c6d36a07bcd00e1da3a739923f990282 (main b213406; SBOM + max-mode provenance + GitHub attestation, public; self-host build that only uses the same-origin /cloud/api prefix), relayauth sha256:c23c92d2... (784582e; SBOM + provenance), relaycast-self-host sha256:a05732ad... (bdf1b69; NO SBOM and only buildx min-mode provenance; attested rebuild pending relaycast #619). RelayHistory and the Sessions services release images are not published and stay REQUIRED OVERRIDE (zero digest). values-gcp.yaml also sets alleyoop.auth.issuer and historyOrigin (the chart default rejected RelayAuth assertions; the umbrella now refuses an alleyoop historyOrigin that differs from relayhistory.relayauth.historyOrigin). Status: docs/handoff/STATUS.md. 0.3.0 renamed the Sessions subchart values key from 96bulls: to sessions-pipeline: (move your overrides; resource names under the umbrella are unchanged). relay-cloud-api 0.2.0 renders the relaycontrol contract (encryption.keyId required; internal token, dashboardUrl, flows, telemetry off by default). The GKE ingress denies /internal on the api host and gives the api backend a BackendConfig timeout (default 3600s) for the flows queue SSE stream. Supersedes the never-released 0.1.0. GKE proof packaging. Live proof pins (values-gcp-proof-live.yaml): dashboard sha256:23361e08b899f272ed5debcbd4e7d6c6555591029357d6fba6c54236063bca62 (relay-dashboard 53d484b); experimental unsupported RelayHistory sha256:72a057c27edbec53412a2b3a665913810b5d9a95d8b6b818946f1892590147bf (relayhistory-cloud 74a6e526, erasure fix). The CI render fixture and customer-images.yaml keep dashboard sha256:9bfc0c6b873411c7a0da60d746883bdef6aafd86a9b733c719500a603890b6fe and RelayHistory sha256:8fbda9bd89dd33994b6b3331fb403c38a25f04e6742050bd717e99661f3544ba. selfhost-api remains fail-closed until published and supplied by digest. The dashboard's same-origin /cloud/api is served by selfhost-api natively (it owns /cloud/api and /login; no ingress rewrite). No HA claim. 0.2.0 adds optional components.durableActors (vendored durable-actors 0.14.6) and components.relayfile, both off by default. relayhistory 0.1.1 adds migrations.drainForWriteHold (two-step write-hold upgrade; the migrate Job waits until no History pod exists, README). relay-cloud-api 0.2.1: telemetry.level defaults to errors (scrubbed error metadata and health only; it takes effect once the install is registered with installId, install key and endpoint, so a default render stays off and a partial registration fails), telemetry.egressTo defaults to empty (restricted egress with https telemetry must list the ingest addresses), the standalone Ingress denies /internal when secretKeys.internalToken is set, and Helm 3.10+ is required. 0.2.1 moved to 96bulls 0.5.5 (interim RelayAuth bearer stays off by default) and supersedes the never-released 0.2.0. |
| relayfile-0.2.2 | unreleased | relayfile 0.2.2 | relayfile: `ghcr.io/agentworkforce/relayfile:0.1.0` |  |  | Repository rename to AgentWorkforce/infra: canonical source and Helm repository URLs, with matching local dependency patch versions. Runtime images, application source, migration generation and deployment values are unchanged. This release has no new live application proof. |
| relayfile-0.2.1 | shipped | relayfile 0.2.1 | relayfile: `ghcr.io/agentworkforce/relayfile:0.1.0` |  |  | runtime.durableActors.deployer.artifactStore (driver gcs \| s3, s3.region/endpoint/forcePathStyle): the deploy Job uploads bundles to S3 for a durable-actors control plane on S3 (needs a relayfile-actors-workspace image from relayfile #559 or later). Default render unchanged apart from the helm.sh/chart label. |
| relayfile-0.2.0 | shipped | relayfile 0.2.0 | relayfile: `ghcr.io/agentworkforce/relayfile:0.1.0` |  |  | License-annotation bump of 0.1.1 (unreleased 0.1.2) plus runtime.backend=durable-actors (gateway, session broker: ghcr.io/agentworkforce/relayfile-actors by digest; deploy Job and dev sidecar: relayfile-actors-workspace by digest). Go server image by tag (Chart.appVersion), not digest; default render unchanged. |
| durable-actors-0.14.6-awf.3 | unreleased | durable-actors 0.14.6-awf.3 |  |  |  | Carries awf.2 and adds optional controller podDisruptionBudget and generated topologySpread values. Both stay off by default; replicaCount > 1 retains its automatic maxUnavailable=1 PDB. |
| durable-actors-0.14.6-awf.2 | **planned** | durable-actors 0.14.6-awf.2 |  |  |  | Carries 0.14.6-awf.1 and adds UPSTREAM.md patch 12: postgresCa {enabled, configMap\|secret, key}: an init container writes the image system roots plus the CA into in-memory volume postgres-ca (/etc/postgres-ca/ca.crt) for the control plane and pool manager, and SSL_CERT_FILE points at it. Works with the unmodified upstream images (OpenSSL native-tls verifies chain and hostname for sslmode=require). Default renders are unchanged. |
| durable-actors-0.14.6-awf.1 | **planned** | durable-actors 0.14.6-awf.1 |  |  |  | Superseded before a chart tag by 0.14.6-awf.2. The vendored v0.14.6 chart plus UPSTREAM.md patch 10 (AWS: storage.provider s3, storage.s3.{region,actorCredentials,actorRoleArn,endpoint,forcePathStyle}, serviceAccount.annotations, sandbox.{runtimeClassName,nodeSelector,tolerations}, AWS availability zones in placement.zone) and patch 11 (the -awf.1 version suffix). The S3 values need a control-plane image from the AgentWorkforce durable-actors fork (selfhost/aws-s3, GHCR durable-actors-control-plane); upstream 0.14.6 images ignore them. GCS defaults render as the upstream chart apart from the helm.sh/chart label. Supersedes the never-released 0.14.6 row: Vendored TerseAI/durable-actors release chart v0.14.6 (tag commit 5f0a2d62, asset sha256 a489cd15...bee) with the local patches listed in charts/durable-actors/UPSTREAM.md (root global, invoke-only key, host idle timeout, pool-manager name length, zero-valued bounds, lowercase ingress host, schema patterns, README links). Never published by this repo; images pinned by upstream digest (charts/durable-actors/UPSTREAM.md). |
| relayfile-0.1.1 | shipped | relayfile 0.1.1 | relayfile: `ghcr.io/agentworkforce/relayfile:0.1.0` |  |  | image by tag (Chart.appVersion), not digest. Superseded by 0.2.0. |
| relay-chief-0.1.0 | unreleased | relay-chief 0.1.0 |  |  |  | First chart, rendered only. No Relay Chief image is published and the digest is operator-supplied until one exists. |
| relayfile-control-0.1.0 | unreleased | relayfile-control 0.1.0 | relayfile-control: `ghcr.io/agentworkforce/relayfile-control@sha256:<required>` |  |  | First chart, rendered only. The chart ships no default digest; the operator sets image.digest. |
| relaychief-control-0.1.1 | unreleased | relaychief-control 0.1.1 | relaychief-control: `ghcr.io/agentworkforce/relaychief-control@sha256:ddd4129f062c…` |  |  | Optional secretKeys.relaySecret, encryptionKeyId and encryptionKey (all three or none) for platform-issued chief Relay identities. They need an image built from relaychief-control PR 5 or later; the default digest is unchanged and predates it. Rendered only. |
| relaychief-control-0.1.0 | shipped | relaychief-control 0.1.0 | relaychief-control: `ghcr.io/agentworkforce/relaychief-control@sha256:ddd4129f062c…` |  |  | First chart, rendered only. Defaults to the published relaychief-control 0.1.0 image. |
| relayflows-0.2.5 | unreleased | relayflows 0.2.5 | relayflows: `node:22.23.3-bookworm-slim` |  |  | Repository rename to AgentWorkforce/infra: canonical source and Helm repository URLs, with matching local dependency patch versions. Runtime images, application source, migration generation and deployment values are unchanged. This release has no new live application proof. |
| relayflows-0.2.4 | shipped | relayflows 0.2.4 | relayflows: `node:22.23.3-bookworm-slim` |  |  | License-annotation patch bump of 0.2.3; the stock image installs the pinned relayflows runtime at start. |
| relayflows-0.2.3 | shipped | relayflows 0.2.3 | relayflows: `node:22.23.3-bookworm-slim` |  |  | the stock image installs the pinned relayflows runtime at start; production uses an immutable flow image. Superseded by 0.2.4. |

### Supported dbMode and function boundary combinations

| dbMode | boundary | HoopDb | status | profiles | notes |
| --- | --- | --- | --- | --- | --- |
| `selfhosted` | `global-default-revoke` | cnpg | shipped | selfhost-postgres, migration, aws-cnpg | chart Jobs install the runtime role and the function default |
| `selfhosted` | `global-default-revoke` | external | shipped | external-selfhosted | operator runs the bootstrap files as a superuser |
| `rds` | `global-default-revoke` | external | shipped | external-rds, aws-rds-native | the RDS master runs the rds_*.sql bootstrap first |
| `cloudsql` | `global-default-revoke` | external | shipped | gcp-cloudsql | operator runs the Cloud SQL bootstrap files as the migration owner; roleBootstrap false |
| `supabase` | `event-trigger` | external | held | external-supabase | supabaseActivation.hold; migrate refuses until the reviewed event trigger is installed and --activation-check passes |
| `supabase` | (unset) | external | fails closed | aws-supabase | renders; migrate refuses with function_boundary_unproven |
| `local` | (unset) | any | dev only |  | local stack only; never a self-host install |
| `selfhosted` | `event-trigger` | any | refused | | event-trigger is supabase only |
| `cloudsql` | `event-trigger` | any | refused | | event-trigger is supabase only |
| `selfhosted` | (unset) | any | refused | | functionBoundaryMode is required in selfhosted mode |
| `cloudsql` | (unset) | any | refused | | functionBoundaryMode is required in cloudsql mode |
| `supabase` | `any` | cnpg | refused | | the in-cluster HoopDb is plain Postgres and needs selfhosted mode |
| `cloudsql` | `any` | cnpg | refused | | the in-cluster HoopDb needs selfhosted mode |

## Profiles

Each profile lists what the operator must provide (requirements) and what they can choose (options). `provided by` says who satisfies it in that profile: `operator` (you, before install), `chart` (rendered by the chart), `migrator` (the HoopDb migrate Job), or `stack` (the AWS/GCP infrastructure stack). Items marked **planned** are not implemented: no chart reads them yet.

### Profile: selfhost-postgres

**New self-host install, in-cluster CloudNativePG HoopDb.** initdb creates the search Worker role; the runtime-role and function-default Jobs run as postgres before migrate on every deploy; in-cluster MinIO Locker.

chart `sessions-pipeline` · values [`profiles/selfhost-postgres.yaml`](../charts/sessions-pipeline/profiles/selfhost-postgres.yaml) · dbMode `selfhosted` · boundary `global-default-revoke` · HoopDb cnpg · services image GHCR · install: `helm install sessions-pipeline agentworkforce/sessions-pipeline -f profiles/selfhost-postgres.yaml --set global.tenant.orgId=<org> --set alleyoop.auth.jwksUrl=<jwks url>`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [CloudNativePG operator installed](#req-k8s-cnpg-operator) | operator | values `hoopdb.enabled` | kubectl get crd clusters.postgresql.cnpg.io && kubectl get deploy -A -l app.kubernetes.io/name=cloudnative-pg |
| shipped | [A default StorageClass for the in-cluster HoopDb and Locker volumes](#req-k8s-storage) | operator | values `hoopdb.cluster.storage.size`, `session-object-storage.persistence.size` | kubectl get storageclass (one marked default), then kubectl get pvc -n <ns> all Bound |
| shipped | [External Secrets Operator and a ClusterSecretStore (only with externalSecrets.enabled)](#req-k8s-external-secrets-operator) | operator | values `sessions-pipeline-worker:externalSecrets.*`, `session-ingest-api:externalSecrets.*` | kubectl get crd externalsecrets.external-secrets.io && kubectl get clustersecretstore <name>; the ExternalSecret reports Ready |
| shipped | [Pull Secret for the private GHCR services image](#req-secret-image-pull) | operator | values `worker.imagePullSecrets`, `alleyoop.imagePullSecrets`; Secret `<pull secret>` (type kubernetes.io/dockerconfigjson with read access to ghcr.io/agentworkforce/96bulls-services) | kubectl get secret <pull secret> -o jsonpath='{.type}' is kubernetes.io/dockerconfigjson; pods are not ImagePullBackOff |
| shipped | [Locker credential Secret (MinIO root / S3 static keys)](#req-secret-locker-credentials) | operator | values `worker.existingSecret`, `alleyoop.existingSecret`, `session-object-storage.existingSecret`, `worker.secretKeys.lockerAccessKeyId`, `worker.secretKeys.lockerSecretAccessKey`, `alleyoop.secretKeys.lockerAccessKeyId`, `alleyoop.secretKeys.lockerSecretAccessKey`; env `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`; Secret `sessions-pipeline-locker` keys `rootUser`, `rootPassword`; Secret `sessions-pipeline-locker` (the bundled upstream MinIO requires literal Secret data keys rootUser and rootPassword) | kubectl get secret sessions-pipeline-locker -o jsonpath='{.data}' has rootUser and rootPassword |
| shipped | [Summary encryption keyring (SUMMARY_MASTER_KEYS)](#req-secret-summary-master-keys) | operator | values `worker.summaryEncryption.existingSecret`, `worker.summaryEncryption.key`, `worker.summaryEncryption.mountPath`, `worker.summaryEncryption.fileName`; env `SUMMARY_MASTER_KEYS_FILE`, `SUMMARY_MASTER_KEYS`; Secret `sessions-pipeline-locker` keys `SUMMARY_MASTER_KEYS` | kubectl exec deploy/<release>-worker-bob-costas -- test -r /var/run/secrets/sessions-pipeline/summary-master-keys; the Secret key parses as <id>:<64 hex> |
| shipped | [HoopDb connection Secret (HOOPDB_URL)](#req-secret-hoopdb-url) | chart | values `worker.hoopdb.existingSecret`, `worker.hoopdb.key`, `worker.secretKeys.hoopdbUrl`, `alleyoop.hoopdb.existingSecret`, `alleyoop.hoopdb.key`, `alleyoop.secretKeys.hoopdbUrl`; env `HOOPDB_URL`; Secret `hoopdb-app` keys `uri` | kubectl get secret hoopdb-app -o jsonpath='{.data.uri}' is non-empty once the CNPG Cluster is ready |
| shipped | [Agent Relay org id (TENANT_ORG_ID)](#req-sessions-pipeline-tenant-org-id) | operator | values `global.tenant.orgId`, `worker.tenant.orgId`, `alleyoop.tenant.orgId`; env `TENANT_ORG_ID` | helm template renders (it fails with "tenant.orgId (or global.tenant.orgId) is required" otherwise) |
| shipped | [A RelayAuth JWKS URL reachable from alleyoop](#req-sessions-pipeline-relayauth-jwks) | operator | values `alleyoop.auth.jwksUrl`; env `RELAYAUTH_JWKS_URL` | kubectl run -it --rm curl --image=curlimages/curl -- curl -fsS <jwksUrl> returns {"keys":[...]} |
| shipped | [PostgreSQL 17 with pg_trgm and btree_gin (and vector) available](#req-db-postgres-17-extensions) | chart | values `hoopdb.cluster.imageName`, `hoopdb.cluster.initdb.postInitApplicationSQL` | psql "$HOOPDB_URL" -Atc "select name from pg_available_extensions where name in ('pg_trgm','btree_gin','vector')" lists all three; server_version_num >= 170000 |
| shipped | [A database dedicated to HoopDb](#req-db-dedicated-database) | chart | values `hoopdb.cluster.initdb.database`, `hoopdb.cluster.initdb.owner` | psql "$HOOPDB_URL" -Atc "select nspname from pg_namespace where nspname not like 'pg_%' and nspname <> 'information_schema'" shows only HoopDb schemas |
| shipped | [Supabase compatibility roles (anon, authenticated, service_role)](#req-db-compat-roles) | chart | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `worker.migrations.supabaseShim` | psql "$HOOPDB_URL" -Atc "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role')" is 3 |
| shipped | [The session directory search Worker role (session_directory_search_worker)](#req-db-search-worker-role) | chart | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `searchWorkerRole.bootstrapJob.enabled`, `searchWorkerRole.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.role` | psql "$HOOPDB_URL" -Atc "select rolcanlogin, rolconfig from pg_roles where rolname='session_directory_search_worker'" is f\|{statement_timeout=2s} |
| shipped | [The dedicated HoopDb runtime role (HOOPDB_RUNTIME_ROLE, e.g. sessions_pipeline_runtime)](#req-db-runtime-role) | chart | values `worker.migrations.runtimeRole`, `worker.migrations.runtimeRoleLogin`, `runtimeRole.bootstrapJob.enabled`, `runtimeRole.bootstrapJob.sqlPath`; env `HOOPDB_RUNTIME_ROLE`, `HOOPDB_RUNTIME_ROLE_LOGIN` | psql "$HOOPDB_URL" -Atc "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin from pg_roles where rolname='sessions_pipeline_runtime'" is f\|f\|f\|f\|f\|t; migrate refuses otherwise |
| shipped | [The durable function boundary installed before the first migrate](#req-db-function-boundary) | chart | values `functionDefaultRevoke.bootstrapJob.enabled`, `functionDefaultRevoke.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.functionDefault` | the function-default Job completes and migrate's wait-for-role logs "present: ... + owner function default" |
| shipped | [The services image digest for the privileged SQL Jobs](#req-sessions-pipeline-privileged-sql-image) | chart | values `privilegedSql.sqlImage.repository`, `privilegedSql.sqlImage.digest`, `searchWorkerRole.bootstrapJob.sqlImage.*`, `runtimeRole.bootstrapJob.sqlImage.*`, `functionDefaultRevoke.bootstrapJob.sqlImage.*` | helm template renders (it fails with "sqlImage.repository and .digest are required" otherwise); ci/sessions-pipeline-profiles/matrix.sh asserts the image |
| shipped | [migrate always runs the phase 2 role verify (HOOPDB_ROLE_VERIFY=true)](#req-sessions-pipeline-role-verify) | chart | env `HOOPDB_ROLE_VERIFY` | kubectl get job -l app.kubernetes.io/component=hoopdb-migrate -o yaml shows HOOPDB_ROLE_VERIFY "true"; workloads go ready after migrate |
| shipped | [Model API key Secret for session briefs (OPENAI_API_KEY)](#req-secret-model-api-key) | operator | values `worker.nativeBrief.openaiSecret`, `worker.nativeBrief.openaiSecret.name`, `worker.nativeBrief.openaiSecret.key`; env `OPENAI_API_KEY`; Secret `<model key Secret>` keys `OPENAI_API_KEY` | A worker Pod references the chosen Secret/key; the init container does not. Verify an actual model result separately. |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [alleyoop token verification source](#opt-alleyoop-auth-mode) | `jwksUrl`, `localJwks` | `jwksUrl` | values `alleyoop.auth.jwksUrl`, `alleyoop.auth.localJwks`, `alleyoop.auth.issuer`, `alleyoop.auth.audience`, `alleyoop.secretKeys.jwksJson`; env `RELAYAUTH_JWKS_URL`, `JWKS_JSON`, `AUTH_ISSUER`, `AUTH_AUDIENCE`; Secret `<existingSecret>` keys `JWKS_JSON` (only with auth.localJwks=true) |
| shipped | [Plain http to in-cluster Service FQDNs](#opt-sessions-pipeline-in-cluster-http) | `false`, `true` | `false` | values `alleyoop.allowInClusterHttp`, `worker.allowInClusterHttp`; env `ALLOW_IN_CLUSTER_HTTP` |
| shipped | [CA bundle for verifying the Postgres server certificate (postgresCa)](#opt-postgres-ca-bundle) | `false`, `true` | `false` | values `worker.postgresCa.*`, `alleyoop.postgresCa.*`, `relay-control:postgresCa.*`, `relaychief-control:postgresCa.*`, `relayfile-control:postgresCa.*`; env `NODE_EXTRA_CA_CERTS`, `PGSSLROOTCERT` |
| shipped | [RelayHistory origin expected by the ingest](#opt-alleyoop-history-origin) | `unset`, `origin` | `unset` | values `alleyoop.auth.historyOrigin`; env `RELAYHISTORY_ORIGIN` |
| shipped | [Interim RelayAuth bearer compatibility (local only)](#opt-alleyoop-interim-relayauth-bearer) | `false`, `true` | `false` | values `alleyoop.auth.allowInterimRelayAuthBearer`; env `ALLOW_INTERIM_RELAYAUTH_BEARER` |
| shipped | [HoopDb backend](#opt-sessions-pipeline-hoopdb-backend) | `cnpg`, `external` | `cnpg` | values `hoopdb.enabled` |
| shipped | [Migrator database mode (HOOPDB_DB_MODE)](#opt-sessions-pipeline-db-mode) | `selfhosted`, `cloudsql`, `rds`, `supabase`, `local` | `selfhosted` | values `worker.migrations.databaseMode`; env `HOOPDB_DB_MODE` |
| shipped | [Function boundary mode (HOOPDB_FUNCTION_BOUNDARY_MODE)](#opt-sessions-pipeline-function-boundary-mode) | `global-default-revoke`, `event-trigger` | `global-default-revoke` | values `worker.migrations.functionBoundaryMode`; env `HOOPDB_FUNCTION_BOUNDARY_MODE`, `HOOPDB_FUNCTION_BOUNDARY_APPROVED` |
| shipped | [Plain-Postgres role shim (HOOPDB_SUPABASE_SHIM)](#opt-sessions-pipeline-supabase-shim) | `true`, `false` | `true` | values `worker.migrations.supabaseShim`; env `HOOPDB_SUPABASE_SHIM` |
| shipped | [Migrator role bootstrap (HOOPDB_ROLE_BOOTSTRAP)](#opt-sessions-pipeline-role-bootstrap) | `true`, `false`, `unset` | (no default) | values `worker.migrations.roleBootstrap`; env `HOOPDB_ROLE_BOOTSTRAP` |
| shipped | [Runtime workload role (HOOPDB_RUNTIME_WORKLOAD_ROLE)](#opt-sessions-pipeline-runtime-workload-role) | `""`, `<role>` | `""` | values `worker.migrations.runtimeWorkloadRole`; env `HOOPDB_RUNTIME_WORKLOAD_ROLE` |
| shipped | [Blocking index build for one migrate run (HOOPDB_ALLOW_BLOCKING_INDEX_BUILD)](#opt-sessions-pipeline-allow-blocking-index-build) | `false`, `true` | `false` | values `worker.migrations.allowBlockingIndexBuild`; env `HOOPDB_ALLOW_BLOCKING_INDEX_BUILD` |
| shipped | [migrate's wait-for-role ordering](#opt-sessions-pipeline-wait-for-role) | `true`, `false` | `true` | values `worker.migrations.waitForRole.enabled`, `worker.migrations.waitForRole.functionDefault`, `worker.migrations.waitForRole.image`, `worker.migrations.waitForRole.intervalSeconds`, `worker.migrations.waitForRole.role` |
| shipped | [Separate migration-owner URL for migrate](#opt-hoopdb-migration-owner-url) | `""`, `<secret>/<key>` | `""` | values `worker.migrations.hoopdb.existingSecret`, `worker.migrations.hoopdb.key` |
| shipped | [Locker object store](#opt-sessions-pipeline-locker-backend) | `minio`, `external` | `minio` | values `session-object-storage.enabled`, `worker.locker.endpoint`, `worker.locker.bucket`, `worker.locker.region`, `alleyoop.locker.endpoint`, `alleyoop.locker.bucket`, `alleyoop.locker.region`, `worker.lockerInit.enabled`; env `LOCKER_ENDPOINT`, `LOCKER_BUCKET`, `LOCKER_REGION` |
| shipped | [Locker credentials mode](#opt-sessions-pipeline-locker-credentials-mode) | `secret`, `podIdentity` | `secret` | values `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode` |
| shipped | [Locker provider (S3-compatible or native GCS)](#opt-sessions-pipeline-locker-provider) | `s3`, `gcs` | `s3` | values `worker.locker.provider`, `alleyoop.locker.provider`, `worker.extraEnv`, `alleyoop.extraEnv`; env `LOCKER_PROVIDER`, `PIPELINE_RAW_PROVIDER`, `CLOUD_SQL_CONNECTION_NAME`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_AUTH_ENABLED`, `REDIS_TRANSIT_ENCRYPTION`, `REDIS_TLS_CA_PEM`, `PUBSUB_TOPIC`, `PUBSUB_SUBSCRIPTION` |
| shipped | [Services image registry](#opt-sessions-pipeline-services-image) | `ghcr`, `ecr`, `release-overlay` | `ghcr` | values `worker.image.repository`, `worker.image.digest`, `worker.image.tag`, `alleyoop.image.repository`, `alleyoop.image.digest`, `alleyoop.image.tag`, `global.imageRegistry` |
| shipped | [OpenTelemetry export](#opt-sessions-pipeline-otel) | `""`, `<your OTLP endpoint>`, `http://otel-collector:4318` | `""` | values `global.otel.endpoint`, `otel.enabled`, `otel.config.*`; env `OTEL_EXPORTER_OTLP_ENDPOINT` |
| shipped | [Workspace, deployment and environment labels](#opt-sessions-pipeline-deployment-identity) | `<any>` | `workspaceId=default`, `deployment=selfhost`, `environment=production` | values `worker.tenant.workspaceId`, `worker.deployment.name`, `worker.deployment.id`, `worker.environment`, `alleyoop.tenant.workspaceId`, `alleyoop.deployment.name`, `alleyoop.deployment.id`, `alleyoop.environment`; env `WORKSPACE_ID`, `DEPLOYMENT`, `DEPLOYMENT_ID`, `ENVIRONMENT` |
| shipped | [Stage worker health server](#opt-sessions-pipeline-worker-health) | `true`, `false` | `true` | values `worker.workerHealth.*`; env `WORKER_HEALTH_PORT`, `WORKER_UNHEALTHY_AFTER_FAILURES`, `WORKER_MAX_TICK_AGE_MS` |
| shipped | [Bob Costas summariser model (BOB_COSTAS_MODEL)](#opt-sessions-pipeline-bob-costas-model) | `off` | `off` | values `worker.components.bob-costas.env`; env `BOB_COSTAS_MODEL` |
| **planned** | [Transcript search backend (search.backend)](#opt-sessions-pipeline-search-backend) | `postgres`, `clickhouse` (**planned**) | `postgres` | values `search.backend`, `search.clickhouse.*` |
| shipped | [Native model session briefs](#opt-sessions-pipeline-session-briefs) | `false`, `true` | `false` | values `worker.components.session-brief.enabled`, `worker.components.session-brief.replicas`, `worker.nativeBrief.enabled`, `worker.nativeBrief.image.*`, `worker.nativeBrief.workspaceIds`, `worker.nativeBrief.model`, `worker.nativeBrief.baseUrl`, `worker.nativeBrief.allowInClusterHttp`, `worker.nativeBrief.keyPrefix`, `worker.nativeBrief.sweepSeconds`, `worker.nativeBrief.batch`, `worker.nativeBrief.globalDailyCap`, `worker.nativeBrief.sessionDailyCap`, `worker.nativeBrief.openaiEgress.*`, `worker.postgresCa.sha256`; env `SESSION_BRIEF_ENABLED`, `SESSION_BRIEF_CANONICAL_INPUT`, `SESSION_BRIEF_WORKSPACE_IDS`, `SESSION_BRIEF_MODEL`, `SESSION_BRIEF_SWEEP_SECONDS`, `SESSION_BRIEF_BATCH`, `SESSION_BRIEF_GLOBAL_DAILY_CAP`, `SESSION_BRIEF_SESSION_DAILY_CAP`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `OPENAI_BASE_URL` |
| shipped | [Sessions reader ruleset ceiling](#opt-sessions-pipeline-reader-max-ruleset) | (no default), `8`, `9`, `10` | (no default) | values `nativeConsumer.readerMaxRuleset`, `worker.nativeBrief.readerMaxRuleset`, `sessionReadApi.readerMaxRuleset`, `alleyoop.readerMaxRuleset`, `ingestEdge.readerMaxRuleset`; env `READER_MAX_RULESET` |
| shipped | [Shared Sessions scrub engine rollout contract](#opt-sessions-pipeline-scrub-engine) | (no default), `reader-first`, `wasm-bindgen` | (no default) | values `global.scrubEngine.engine`, `global.scrubEngine.required`, `global.scrubEngine.readerMaxRuleset`; env `SCRUB_ENGINE`, `SCRUB_ENGINE_REQUIRED`, `READER_MAX_RULESET` |
| shipped | [Native brief collector analytics adapter](#opt-sessions-pipeline-brief-collector-analytics) | `false`, `true` | `false` | values `worker.nativeBrief.analytics.*`; env `ANALYTICS_SINK`, `ANALYTICS_DEPLOYMENT_ID`, `ANALYTICS_COLLECTOR_URL`, `ANALYTICS_COLLECTOR_TOKEN`, `ANALYTICS_COLLECTOR_CA_FILE`; Secret `<Native brief component-bound analytics producer Secret>` keys `token` |
| shipped | [Default-off native session upload edge](#opt-sessions-native-ingest) | `disabled`, `enabled` | `disabled` | values `ingestEdge.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_INGEST`, `RELAYHISTORY_SELFHOST_SESSION_SELECTION`, `RELAYHISTORY_SELFHOST_HEARTBEAT_ACCEPT`, `RELAYHISTORY_INGEST_PORT`, `RELAYHISTORY_INGEST_ORIGIN`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`, `RELAYHISTORY_INGEST_DATABASE_URL`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYHISTORY_INGEST_PG_POOL_MAX`, `ALLOW_IN_CLUSTER_HTTP`, `LOCKER_PROVIDER`, `LOCKER_BUCKET`, `LOCKER_ENDPOINT`, `LOCKER_REGION`, `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`, `INGEST_KEY_ROOT`, `INGEST_MAX_PER_USER`, `INGEST_MAX_PER_ORG`; Secret `<native ingest runtime Secret>` keys `database-url`, `introspect-secret`; Secret `<native ingest object-store Secret>` keys `access-key-id`, `secret-access-key` |
| shipped | [Default-off self-host session read API container](#opt-sessions-read-api) | `disabled`, `enabled` | `disabled` | values `fullnameOverride`, `replicas`, `image.*`, `imagePullSecrets`, `port`, `probeRuntime`, `origin`, `completeSince`, `directoryWorkspaces`, `login.advertisesSync`, `turns.assumeNoLegacy`, `timing.assumeNoTurns`, `canonical.pinLaggingPointer`, `events.messageIds`, `coordinationOverlaps.enabled`, `serviceAccountCreate`, `allowInClusterHttp`, `config.*`, `postgres.*`, `postgresCa.*`, `search.*`, `auth.*`, `cors.*`, `ingress.*`, `networkPolicy.*`, `extraEnv`, `extraVolumes`, `extraVolumeMounts`, `serviceAccountName`, `nodeSelector`, `tolerations`, `affinity`, `podAnnotations`, `resources`; env `SERVICE`, `RELAYHISTORY_SELFHOST_READ_API`, `RELAYHISTORY_READ_API_PORT`, `RELAYHISTORY_READ_API_SECRET`, `READ_API_ORIGIN`, `READ_API_AUTH_MODE`, `READ_API_COMPLETE_SINCE`, `READ_API_DIRECTORY_WORKSPACES`, `READ_API_CORS_ALLOWED_ORIGINS`, `RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC`, `READ_API_TURNS_ASSUME_NO_LEGACY`, `READ_API_TIMING_ASSUME_NO_TURNS`, `READ_API_CANONICAL_PIN_LAGGING_POINTER`, `READ_API_EVENT_MESSAGE_IDS`, `READ_API_COORDINATION_OVERLAPS_ENABLED`, `READ_API_COORDINATION_OVERLAPS_BACKEND`, `READ_API_INTERNAL_SECRET`, `READ_API_INTERNAL_SECRET_PREVIOUS`, `READ_API_ACCESS_TOKEN_TTL_SECONDS`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `SEARCH_INDEX_BACKEND`, `ALLOW_IN_CLUSTER_HTTP`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYAUTH_JWKS_URL`, `RELAYAUTH_ISSUER`, `RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API configuration Secret>` keys `RELAYHISTORY_READ_API_SECRET`; Secret `<read API introspection Secret>` keys `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API internal Secret>` keys `READ_API_INTERNAL_SECRET`; Secret `<read API previous internal Secret>` keys `READ_API_INTERNAL_SECRET_PREVIOUS` |
| shipped | [Default-off self-host transcript search writer](#opt-sessions-search-indexer) | `disabled`, `enabled` | `disabled` | values `searchIndexer.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `LOCKER_BUCKET`, `LOCKER_REGION`, `LOCKER_ENDPOINT`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `WORKER_HEALTH_PORT`; Secret `<search indexer configuration Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<search indexer bootstrap Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` |
| shipped | [Self-host output facts writer and bootstrap Job](#opt-sessions-output-facts) | `disabled`, `enabled` | `disabled` | values `searchIndexer.outputFacts.enabled`, `searchIndexer.outputFacts.bootstrap.*`, `nativeConsumer.outputFacts.enabled`; env `RELAYHISTORY_SELFHOST_OUTPUT_FACTS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_DEADLINE_SECONDS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_ALLOW_PARTIAL` |
| shipped | [Session read API Output and daily digest routes](#opt-sessions-read-api-output-digest) | `disabled`, `enabled` | `disabled` | values `output.enabled`, `digest.enabled`, `digest.narrative.*`; env `READ_API_OUTPUT_ENABLED`, `READ_API_OUTPUT_BACKEND`, `READ_API_DIGEST_ENABLED`, `READ_API_DIGEST_BACKEND`, `READ_API_DIGEST_NARRATIVE_MODEL`, `READ_API_DIGEST_NARRATIVE_DB_URL`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`; Secret `<digest narrative model API key Secret, model only>` keys `OPENAI_API_KEY`; Secret `<digest narrative writer login Secret, model only>` keys `READ_API_DIGEST_NARRATIVE_DB_URL` |
| shipped | [Native ingest claim lock retry response](#opt-sessions-native-ingest-claim-lock-busy) | `true`, `false` | `true` | values `ingestEdge.claimLockBusy`; env `INGEST_CLAIM_LOCK_BUSY` |
| shipped | [Native ingest admission mode](#opt-sessions-native-ingest-admission) | `sync`, `async`, `drain` | `sync` | values `ingestEdge.admission.mode`, `ingestEdge.admission.concurrency`, `ingestEdge.admission.scanIntervalMs`, `ingestEdge.admission.maxAttempts`; env `SELFHOST_INGEST_ADMISSION`, `SELFHOST_ADMISSION_CONCURRENCY`, `SELFHOST_ADMISSION_SCAN_MS`, `SELFHOST_ADMISSION_MAX_ATTEMPTS` |
| shipped | [Default-off native canonical pointer and search consumer](#opt-sessions-native-consumer) | `disabled`, `enabled` | `disabled` | values `nativeConsumer.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `HOOPDB_DB_MODE`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_RUNTIME`, `PIPELINE_FANOUT`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `CONSUMER_RECONCILE_EVERY_MINUTES`, `PIPELINE_RECONCILE_LOOKBACK_MINUTES`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `ALLOW_IN_CLUSTER_HTTP`, `WORKER_HEALTH_PORT`, `CONSUMER_UNHEALTHY_FILE`, `LOCKER_PROVIDER`, `LOCKER_BUCKET`, `LOCKER_ENDPOINT`, `LOCKER_REGION`, `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`, `NATIVE_CONSUMER_CA_SOURCE_FILE`, `NATIVE_CONSUMER_PREFLIGHT_MODE`, `NATIVE_CONSUMER_EXPECTED_ROLE`, `NATIVE_CONSUMER_EXPECTED_DATABASE`, `NATIVE_CONSUMER_EXPECTED_HOST`, `NATIVE_CONSUMER_EXPECTED_PORT`, `NATIVE_CONSUMER_PREFLIGHT_TIMEOUT_SECONDS`; Secret `<native consumer runtime JSON Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<native consumer Job-only owner JSON Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<native consumer S3 static Secret, secret mode only>` keys `access-key-id`, `secret-access-key` |
| shipped | [Native History public route](#opt-sessions-pipeline-native-routing) | `disabled`, `enabled` | `disabled` | values `nativeRouting.*`; Secret `<existing public History TLS Secret>` |
| shipped | [Retire a legacy Deployment while retaining resources](#opt-legacy-deployment-retirement) | `true`, `false` | `true` | values `deployment.enabled` |
| shipped | [Native direct upload inbox scan](#opt-history-direct-upload-consumer) | `off`, `allowlist`, `on` | `off` | values `ingestEdge.uploadDirect.*`, `ingestEdge.keyRoot`, `ingestEdge.createServiceAccount`; env `HISTORY_UPLOAD_DIRECT`, `HISTORY_UPLOAD_DIRECT_ALLOWLIST`, `SELFHOST_UPLOAD_SCAN_BATCH`, `UPLOAD_WITNESS_KEY`; Secret `<operator-chosen shared upload witness Secret>` keys `upload-witness-key` |
| shipped | [S3 upload ledger for the native ingest (decision 0005)](#opt-sessions-pipeline-s3-ledger) | `sql`, `s3` | `sql` | values `ingestEdge.ledger`; env `INGEST_LEDGER` |
| shipped | [S3 ledger re-arm sweeper CronJob](#opt-sessions-pipeline-rearm-sweeper) | `false`, `true` | `false` | values `rearmSweeper.*`; env `INGEST_REARM_SWEEPER_ENABLED`, `INGEST_REARM_BUCKET`, `INGEST_REARM_REGION`, `INGEST_REARM_ENDPOINT`, `INGEST_REARM_KEY_ROOT`, `INGEST_REARM_ORGS`, `INGEST_REARM_DRY_RUN`, `INGEST_REARM_CONCURRENCY`, `INGEST_REARM_MAX_MARKERS`, `INGEST_REARM_CREDENTIALS`, `INGEST_REARM_S3_ACCESS_KEY_ID_FILE`, `INGEST_REARM_S3_SECRET_ACCESS_KEY_FILE`; Secret `<dedicated re-arm sweeper S3 Secret>` keys `access-key-id`, `secret-access-key` |

### Profile: migration

**Existing self-host release, in-cluster CloudNativePG HoopDb created before the search Worker role.** selfhost-postgres plus searchWorkerRole.bootstrapJob, because initdb never runs again on an existing cluster.

chart `sessions-pipeline` · values [`profiles/migration.yaml`](../charts/sessions-pipeline/profiles/migration.yaml) · dbMode `selfhosted` · boundary `global-default-revoke` · HoopDb cnpg · services image GHCR · install: `helm upgrade <existing release> agentworkforce/sessions-pipeline -f profiles/migration.yaml --set global.tenant.orgId=<org> --set alleyoop.auth.jwksUrl=<jwks url>`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [CloudNativePG operator installed](#req-k8s-cnpg-operator) | operator | values `hoopdb.enabled` | kubectl get crd clusters.postgresql.cnpg.io && kubectl get deploy -A -l app.kubernetes.io/name=cloudnative-pg |
| shipped | [A default StorageClass for the in-cluster HoopDb and Locker volumes](#req-k8s-storage) | operator | values `hoopdb.cluster.storage.size`, `session-object-storage.persistence.size` | kubectl get storageclass (one marked default), then kubectl get pvc -n <ns> all Bound |
| shipped | [External Secrets Operator and a ClusterSecretStore (only with externalSecrets.enabled)](#req-k8s-external-secrets-operator) | operator | values `sessions-pipeline-worker:externalSecrets.*`, `session-ingest-api:externalSecrets.*` | kubectl get crd externalsecrets.external-secrets.io && kubectl get clustersecretstore <name>; the ExternalSecret reports Ready |
| shipped | [Pull Secret for the private GHCR services image](#req-secret-image-pull) | operator | values `worker.imagePullSecrets`, `alleyoop.imagePullSecrets`; Secret `<pull secret>` (type kubernetes.io/dockerconfigjson with read access to ghcr.io/agentworkforce/96bulls-services) | kubectl get secret <pull secret> -o jsonpath='{.type}' is kubernetes.io/dockerconfigjson; pods are not ImagePullBackOff |
| shipped | [Locker credential Secret (MinIO root / S3 static keys)](#req-secret-locker-credentials) | operator | values `worker.existingSecret`, `alleyoop.existingSecret`, `session-object-storage.existingSecret`, `worker.secretKeys.lockerAccessKeyId`, `worker.secretKeys.lockerSecretAccessKey`, `alleyoop.secretKeys.lockerAccessKeyId`, `alleyoop.secretKeys.lockerSecretAccessKey`; env `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`; Secret `sessions-pipeline-locker` keys `rootUser`, `rootPassword`; Secret `sessions-pipeline-locker` (the bundled upstream MinIO requires literal Secret data keys rootUser and rootPassword) | kubectl get secret sessions-pipeline-locker -o jsonpath='{.data}' has rootUser and rootPassword |
| shipped | [Summary encryption keyring (SUMMARY_MASTER_KEYS)](#req-secret-summary-master-keys) | operator | values `worker.summaryEncryption.existingSecret`, `worker.summaryEncryption.key`, `worker.summaryEncryption.mountPath`, `worker.summaryEncryption.fileName`; env `SUMMARY_MASTER_KEYS_FILE`, `SUMMARY_MASTER_KEYS`; Secret `sessions-pipeline-locker` keys `SUMMARY_MASTER_KEYS` | kubectl exec deploy/<release>-worker-bob-costas -- test -r /var/run/secrets/sessions-pipeline/summary-master-keys; the Secret key parses as <id>:<64 hex> |
| shipped | [HoopDb connection Secret (HOOPDB_URL)](#req-secret-hoopdb-url) | chart | values `worker.hoopdb.existingSecret`, `worker.hoopdb.key`, `worker.secretKeys.hoopdbUrl`, `alleyoop.hoopdb.existingSecret`, `alleyoop.hoopdb.key`, `alleyoop.secretKeys.hoopdbUrl`; env `HOOPDB_URL`; Secret `hoopdb-app` keys `uri` | kubectl get secret hoopdb-app -o jsonpath='{.data.uri}' is non-empty once the CNPG Cluster is ready |
| shipped | [Agent Relay org id (TENANT_ORG_ID)](#req-sessions-pipeline-tenant-org-id) | operator | values `global.tenant.orgId`, `worker.tenant.orgId`, `alleyoop.tenant.orgId`; env `TENANT_ORG_ID` | helm template renders (it fails with "tenant.orgId (or global.tenant.orgId) is required" otherwise) |
| shipped | [A RelayAuth JWKS URL reachable from alleyoop](#req-sessions-pipeline-relayauth-jwks) | operator | values `alleyoop.auth.jwksUrl`; env `RELAYAUTH_JWKS_URL` | kubectl run -it --rm curl --image=curlimages/curl -- curl -fsS <jwksUrl> returns {"keys":[...]} |
| shipped | [PostgreSQL 17 with pg_trgm and btree_gin (and vector) available](#req-db-postgres-17-extensions) | chart | values `hoopdb.cluster.imageName`, `hoopdb.cluster.initdb.postInitApplicationSQL` | psql "$HOOPDB_URL" -Atc "select name from pg_available_extensions where name in ('pg_trgm','btree_gin','vector')" lists all three; server_version_num >= 170000 |
| shipped | [A database dedicated to HoopDb](#req-db-dedicated-database) | chart | values `hoopdb.cluster.initdb.database`, `hoopdb.cluster.initdb.owner` | psql "$HOOPDB_URL" -Atc "select nspname from pg_namespace where nspname not like 'pg_%' and nspname <> 'information_schema'" shows only HoopDb schemas |
| shipped | [Supabase compatibility roles (anon, authenticated, service_role)](#req-db-compat-roles) | chart | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `worker.migrations.supabaseShim` | psql "$HOOPDB_URL" -Atc "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role')" is 3 |
| shipped | [The session directory search Worker role (session_directory_search_worker)](#req-db-search-worker-role) | chart | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `searchWorkerRole.bootstrapJob.enabled`, `searchWorkerRole.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.role` | psql "$HOOPDB_URL" -Atc "select rolcanlogin, rolconfig from pg_roles where rolname='session_directory_search_worker'" is f\|{statement_timeout=2s} |
| shipped | [The dedicated HoopDb runtime role (HOOPDB_RUNTIME_ROLE, e.g. sessions_pipeline_runtime)](#req-db-runtime-role) | chart | values `worker.migrations.runtimeRole`, `worker.migrations.runtimeRoleLogin`, `runtimeRole.bootstrapJob.enabled`, `runtimeRole.bootstrapJob.sqlPath`; env `HOOPDB_RUNTIME_ROLE`, `HOOPDB_RUNTIME_ROLE_LOGIN` | psql "$HOOPDB_URL" -Atc "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin from pg_roles where rolname='sessions_pipeline_runtime'" is f\|f\|f\|f\|f\|t; migrate refuses otherwise |
| shipped | [The durable function boundary installed before the first migrate](#req-db-function-boundary) | chart | values `functionDefaultRevoke.bootstrapJob.enabled`, `functionDefaultRevoke.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.functionDefault` | the function-default Job completes and migrate's wait-for-role logs "present: ... + owner function default" |
| shipped | [The services image digest for the privileged SQL Jobs](#req-sessions-pipeline-privileged-sql-image) | chart | values `privilegedSql.sqlImage.repository`, `privilegedSql.sqlImage.digest`, `searchWorkerRole.bootstrapJob.sqlImage.*`, `runtimeRole.bootstrapJob.sqlImage.*`, `functionDefaultRevoke.bootstrapJob.sqlImage.*` | helm template renders (it fails with "sqlImage.repository and .digest are required" otherwise); ci/sessions-pipeline-profiles/matrix.sh asserts the image |
| shipped | [migrate always runs the phase 2 role verify (HOOPDB_ROLE_VERIFY=true)](#req-sessions-pipeline-role-verify) | chart | env `HOOPDB_ROLE_VERIFY` | kubectl get job -l app.kubernetes.io/component=hoopdb-migrate -o yaml shows HOOPDB_ROLE_VERIFY "true"; workloads go ready after migrate |
| shipped | [Model API key Secret for session briefs (OPENAI_API_KEY)](#req-secret-model-api-key) | operator | values `worker.nativeBrief.openaiSecret`, `worker.nativeBrief.openaiSecret.name`, `worker.nativeBrief.openaiSecret.key`; env `OPENAI_API_KEY`; Secret `<model key Secret>` keys `OPENAI_API_KEY` | A worker Pod references the chosen Secret/key; the init container does not. Verify an actual model result separately. |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [alleyoop token verification source](#opt-alleyoop-auth-mode) | `jwksUrl`, `localJwks` | `jwksUrl` | values `alleyoop.auth.jwksUrl`, `alleyoop.auth.localJwks`, `alleyoop.auth.issuer`, `alleyoop.auth.audience`, `alleyoop.secretKeys.jwksJson`; env `RELAYAUTH_JWKS_URL`, `JWKS_JSON`, `AUTH_ISSUER`, `AUTH_AUDIENCE`; Secret `<existingSecret>` keys `JWKS_JSON` (only with auth.localJwks=true) |
| shipped | [Plain http to in-cluster Service FQDNs](#opt-sessions-pipeline-in-cluster-http) | `false`, `true` | `false` | values `alleyoop.allowInClusterHttp`, `worker.allowInClusterHttp`; env `ALLOW_IN_CLUSTER_HTTP` |
| shipped | [CA bundle for verifying the Postgres server certificate (postgresCa)](#opt-postgres-ca-bundle) | `false`, `true` | `false` | values `worker.postgresCa.*`, `alleyoop.postgresCa.*`, `relay-control:postgresCa.*`, `relaychief-control:postgresCa.*`, `relayfile-control:postgresCa.*`; env `NODE_EXTRA_CA_CERTS`, `PGSSLROOTCERT` |
| shipped | [RelayHistory origin expected by the ingest](#opt-alleyoop-history-origin) | `unset`, `origin` | `unset` | values `alleyoop.auth.historyOrigin`; env `RELAYHISTORY_ORIGIN` |
| shipped | [Interim RelayAuth bearer compatibility (local only)](#opt-alleyoop-interim-relayauth-bearer) | `false`, `true` | `false` | values `alleyoop.auth.allowInterimRelayAuthBearer`; env `ALLOW_INTERIM_RELAYAUTH_BEARER` |
| shipped | [HoopDb backend](#opt-sessions-pipeline-hoopdb-backend) | `cnpg`, `external` | `cnpg` | values `hoopdb.enabled` |
| shipped | [Migrator database mode (HOOPDB_DB_MODE)](#opt-sessions-pipeline-db-mode) | `selfhosted`, `cloudsql`, `rds`, `supabase`, `local` | `selfhosted` | values `worker.migrations.databaseMode`; env `HOOPDB_DB_MODE` |
| shipped | [Function boundary mode (HOOPDB_FUNCTION_BOUNDARY_MODE)](#opt-sessions-pipeline-function-boundary-mode) | `global-default-revoke`, `event-trigger` | `global-default-revoke` | values `worker.migrations.functionBoundaryMode`; env `HOOPDB_FUNCTION_BOUNDARY_MODE`, `HOOPDB_FUNCTION_BOUNDARY_APPROVED` |
| shipped | [Plain-Postgres role shim (HOOPDB_SUPABASE_SHIM)](#opt-sessions-pipeline-supabase-shim) | `true`, `false` | `true` | values `worker.migrations.supabaseShim`; env `HOOPDB_SUPABASE_SHIM` |
| shipped | [Migrator role bootstrap (HOOPDB_ROLE_BOOTSTRAP)](#opt-sessions-pipeline-role-bootstrap) | `true`, `false`, `unset` | (no default) | values `worker.migrations.roleBootstrap`; env `HOOPDB_ROLE_BOOTSTRAP` |
| shipped | [Runtime workload role (HOOPDB_RUNTIME_WORKLOAD_ROLE)](#opt-sessions-pipeline-runtime-workload-role) | `""`, `<role>` | `""` | values `worker.migrations.runtimeWorkloadRole`; env `HOOPDB_RUNTIME_WORKLOAD_ROLE` |
| shipped | [Blocking index build for one migrate run (HOOPDB_ALLOW_BLOCKING_INDEX_BUILD)](#opt-sessions-pipeline-allow-blocking-index-build) | `false`, `true` | `false` | values `worker.migrations.allowBlockingIndexBuild`; env `HOOPDB_ALLOW_BLOCKING_INDEX_BUILD` |
| shipped | [migrate's wait-for-role ordering](#opt-sessions-pipeline-wait-for-role) | `true`, `false` | `true` | values `worker.migrations.waitForRole.enabled`, `worker.migrations.waitForRole.functionDefault`, `worker.migrations.waitForRole.image`, `worker.migrations.waitForRole.intervalSeconds`, `worker.migrations.waitForRole.role` |
| shipped | [Separate migration-owner URL for migrate](#opt-hoopdb-migration-owner-url) | `""`, `<secret>/<key>` | `""` | values `worker.migrations.hoopdb.existingSecret`, `worker.migrations.hoopdb.key` |
| shipped | [Locker object store](#opt-sessions-pipeline-locker-backend) | `minio`, `external` | `minio` | values `session-object-storage.enabled`, `worker.locker.endpoint`, `worker.locker.bucket`, `worker.locker.region`, `alleyoop.locker.endpoint`, `alleyoop.locker.bucket`, `alleyoop.locker.region`, `worker.lockerInit.enabled`; env `LOCKER_ENDPOINT`, `LOCKER_BUCKET`, `LOCKER_REGION` |
| shipped | [Locker credentials mode](#opt-sessions-pipeline-locker-credentials-mode) | `secret`, `podIdentity` | `secret` | values `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode` |
| shipped | [Locker provider (S3-compatible or native GCS)](#opt-sessions-pipeline-locker-provider) | `s3`, `gcs` | `s3` | values `worker.locker.provider`, `alleyoop.locker.provider`, `worker.extraEnv`, `alleyoop.extraEnv`; env `LOCKER_PROVIDER`, `PIPELINE_RAW_PROVIDER`, `CLOUD_SQL_CONNECTION_NAME`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_AUTH_ENABLED`, `REDIS_TRANSIT_ENCRYPTION`, `REDIS_TLS_CA_PEM`, `PUBSUB_TOPIC`, `PUBSUB_SUBSCRIPTION` |
| shipped | [Services image registry](#opt-sessions-pipeline-services-image) | `ghcr`, `ecr`, `release-overlay` | `ghcr` | values `worker.image.repository`, `worker.image.digest`, `worker.image.tag`, `alleyoop.image.repository`, `alleyoop.image.digest`, `alleyoop.image.tag`, `global.imageRegistry` |
| shipped | [OpenTelemetry export](#opt-sessions-pipeline-otel) | `""`, `<your OTLP endpoint>`, `http://otel-collector:4318` | `""` | values `global.otel.endpoint`, `otel.enabled`, `otel.config.*`; env `OTEL_EXPORTER_OTLP_ENDPOINT` |
| shipped | [Workspace, deployment and environment labels](#opt-sessions-pipeline-deployment-identity) | `<any>` | `workspaceId=default`, `deployment=selfhost`, `environment=production` | values `worker.tenant.workspaceId`, `worker.deployment.name`, `worker.deployment.id`, `worker.environment`, `alleyoop.tenant.workspaceId`, `alleyoop.deployment.name`, `alleyoop.deployment.id`, `alleyoop.environment`; env `WORKSPACE_ID`, `DEPLOYMENT`, `DEPLOYMENT_ID`, `ENVIRONMENT` |
| shipped | [Stage worker health server](#opt-sessions-pipeline-worker-health) | `true`, `false` | `true` | values `worker.workerHealth.*`; env `WORKER_HEALTH_PORT`, `WORKER_UNHEALTHY_AFTER_FAILURES`, `WORKER_MAX_TICK_AGE_MS` |
| shipped | [Bob Costas summariser model (BOB_COSTAS_MODEL)](#opt-sessions-pipeline-bob-costas-model) | `off` | `off` | values `worker.components.bob-costas.env`; env `BOB_COSTAS_MODEL` |
| **planned** | [Transcript search backend (search.backend)](#opt-sessions-pipeline-search-backend) | `postgres`, `clickhouse` (**planned**) | `postgres` | values `search.backend`, `search.clickhouse.*` |
| shipped | [Native model session briefs](#opt-sessions-pipeline-session-briefs) | `false`, `true` | `false` | values `worker.components.session-brief.enabled`, `worker.components.session-brief.replicas`, `worker.nativeBrief.enabled`, `worker.nativeBrief.image.*`, `worker.nativeBrief.workspaceIds`, `worker.nativeBrief.model`, `worker.nativeBrief.baseUrl`, `worker.nativeBrief.allowInClusterHttp`, `worker.nativeBrief.keyPrefix`, `worker.nativeBrief.sweepSeconds`, `worker.nativeBrief.batch`, `worker.nativeBrief.globalDailyCap`, `worker.nativeBrief.sessionDailyCap`, `worker.nativeBrief.openaiEgress.*`, `worker.postgresCa.sha256`; env `SESSION_BRIEF_ENABLED`, `SESSION_BRIEF_CANONICAL_INPUT`, `SESSION_BRIEF_WORKSPACE_IDS`, `SESSION_BRIEF_MODEL`, `SESSION_BRIEF_SWEEP_SECONDS`, `SESSION_BRIEF_BATCH`, `SESSION_BRIEF_GLOBAL_DAILY_CAP`, `SESSION_BRIEF_SESSION_DAILY_CAP`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `OPENAI_BASE_URL` |
| shipped | [Sessions reader ruleset ceiling](#opt-sessions-pipeline-reader-max-ruleset) | (no default), `8`, `9`, `10` | (no default) | values `nativeConsumer.readerMaxRuleset`, `worker.nativeBrief.readerMaxRuleset`, `sessionReadApi.readerMaxRuleset`, `alleyoop.readerMaxRuleset`, `ingestEdge.readerMaxRuleset`; env `READER_MAX_RULESET` |
| shipped | [Shared Sessions scrub engine rollout contract](#opt-sessions-pipeline-scrub-engine) | (no default), `reader-first`, `wasm-bindgen` | (no default) | values `global.scrubEngine.engine`, `global.scrubEngine.required`, `global.scrubEngine.readerMaxRuleset`; env `SCRUB_ENGINE`, `SCRUB_ENGINE_REQUIRED`, `READER_MAX_RULESET` |
| shipped | [Native brief collector analytics adapter](#opt-sessions-pipeline-brief-collector-analytics) | `false`, `true` | `false` | values `worker.nativeBrief.analytics.*`; env `ANALYTICS_SINK`, `ANALYTICS_DEPLOYMENT_ID`, `ANALYTICS_COLLECTOR_URL`, `ANALYTICS_COLLECTOR_TOKEN`, `ANALYTICS_COLLECTOR_CA_FILE`; Secret `<Native brief component-bound analytics producer Secret>` keys `token` |
| shipped | [Default-off native session upload edge](#opt-sessions-native-ingest) | `disabled`, `enabled` | `disabled` | values `ingestEdge.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_INGEST`, `RELAYHISTORY_SELFHOST_SESSION_SELECTION`, `RELAYHISTORY_SELFHOST_HEARTBEAT_ACCEPT`, `RELAYHISTORY_INGEST_PORT`, `RELAYHISTORY_INGEST_ORIGIN`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`, `RELAYHISTORY_INGEST_DATABASE_URL`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYHISTORY_INGEST_PG_POOL_MAX`, `ALLOW_IN_CLUSTER_HTTP`, `LOCKER_PROVIDER`, `LOCKER_BUCKET`, `LOCKER_ENDPOINT`, `LOCKER_REGION`, `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`, `INGEST_KEY_ROOT`, `INGEST_MAX_PER_USER`, `INGEST_MAX_PER_ORG`; Secret `<native ingest runtime Secret>` keys `database-url`, `introspect-secret`; Secret `<native ingest object-store Secret>` keys `access-key-id`, `secret-access-key` |
| shipped | [Default-off self-host session read API container](#opt-sessions-read-api) | `disabled`, `enabled` | `disabled` | values `fullnameOverride`, `replicas`, `image.*`, `imagePullSecrets`, `port`, `probeRuntime`, `origin`, `completeSince`, `directoryWorkspaces`, `login.advertisesSync`, `turns.assumeNoLegacy`, `timing.assumeNoTurns`, `canonical.pinLaggingPointer`, `events.messageIds`, `coordinationOverlaps.enabled`, `serviceAccountCreate`, `allowInClusterHttp`, `config.*`, `postgres.*`, `postgresCa.*`, `search.*`, `auth.*`, `cors.*`, `ingress.*`, `networkPolicy.*`, `extraEnv`, `extraVolumes`, `extraVolumeMounts`, `serviceAccountName`, `nodeSelector`, `tolerations`, `affinity`, `podAnnotations`, `resources`; env `SERVICE`, `RELAYHISTORY_SELFHOST_READ_API`, `RELAYHISTORY_READ_API_PORT`, `RELAYHISTORY_READ_API_SECRET`, `READ_API_ORIGIN`, `READ_API_AUTH_MODE`, `READ_API_COMPLETE_SINCE`, `READ_API_DIRECTORY_WORKSPACES`, `READ_API_CORS_ALLOWED_ORIGINS`, `RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC`, `READ_API_TURNS_ASSUME_NO_LEGACY`, `READ_API_TIMING_ASSUME_NO_TURNS`, `READ_API_CANONICAL_PIN_LAGGING_POINTER`, `READ_API_EVENT_MESSAGE_IDS`, `READ_API_COORDINATION_OVERLAPS_ENABLED`, `READ_API_COORDINATION_OVERLAPS_BACKEND`, `READ_API_INTERNAL_SECRET`, `READ_API_INTERNAL_SECRET_PREVIOUS`, `READ_API_ACCESS_TOKEN_TTL_SECONDS`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `SEARCH_INDEX_BACKEND`, `ALLOW_IN_CLUSTER_HTTP`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYAUTH_JWKS_URL`, `RELAYAUTH_ISSUER`, `RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API configuration Secret>` keys `RELAYHISTORY_READ_API_SECRET`; Secret `<read API introspection Secret>` keys `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API internal Secret>` keys `READ_API_INTERNAL_SECRET`; Secret `<read API previous internal Secret>` keys `READ_API_INTERNAL_SECRET_PREVIOUS` |
| shipped | [Default-off self-host transcript search writer](#opt-sessions-search-indexer) | `disabled`, `enabled` | `disabled` | values `searchIndexer.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `LOCKER_BUCKET`, `LOCKER_REGION`, `LOCKER_ENDPOINT`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `WORKER_HEALTH_PORT`; Secret `<search indexer configuration Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<search indexer bootstrap Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` |
| shipped | [Self-host output facts writer and bootstrap Job](#opt-sessions-output-facts) | `disabled`, `enabled` | `disabled` | values `searchIndexer.outputFacts.enabled`, `searchIndexer.outputFacts.bootstrap.*`, `nativeConsumer.outputFacts.enabled`; env `RELAYHISTORY_SELFHOST_OUTPUT_FACTS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_DEADLINE_SECONDS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_ALLOW_PARTIAL` |
| shipped | [Session read API Output and daily digest routes](#opt-sessions-read-api-output-digest) | `disabled`, `enabled` | `disabled` | values `output.enabled`, `digest.enabled`, `digest.narrative.*`; env `READ_API_OUTPUT_ENABLED`, `READ_API_OUTPUT_BACKEND`, `READ_API_DIGEST_ENABLED`, `READ_API_DIGEST_BACKEND`, `READ_API_DIGEST_NARRATIVE_MODEL`, `READ_API_DIGEST_NARRATIVE_DB_URL`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`; Secret `<digest narrative model API key Secret, model only>` keys `OPENAI_API_KEY`; Secret `<digest narrative writer login Secret, model only>` keys `READ_API_DIGEST_NARRATIVE_DB_URL` |
| shipped | [Native ingest claim lock retry response](#opt-sessions-native-ingest-claim-lock-busy) | `true`, `false` | `true` | values `ingestEdge.claimLockBusy`; env `INGEST_CLAIM_LOCK_BUSY` |
| shipped | [Native ingest admission mode](#opt-sessions-native-ingest-admission) | `sync`, `async`, `drain` | `sync` | values `ingestEdge.admission.mode`, `ingestEdge.admission.concurrency`, `ingestEdge.admission.scanIntervalMs`, `ingestEdge.admission.maxAttempts`; env `SELFHOST_INGEST_ADMISSION`, `SELFHOST_ADMISSION_CONCURRENCY`, `SELFHOST_ADMISSION_SCAN_MS`, `SELFHOST_ADMISSION_MAX_ATTEMPTS` |
| shipped | [Default-off native canonical pointer and search consumer](#opt-sessions-native-consumer) | `disabled`, `enabled` | `disabled` | values `nativeConsumer.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `HOOPDB_DB_MODE`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_RUNTIME`, `PIPELINE_FANOUT`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `CONSUMER_RECONCILE_EVERY_MINUTES`, `PIPELINE_RECONCILE_LOOKBACK_MINUTES`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `ALLOW_IN_CLUSTER_HTTP`, `WORKER_HEALTH_PORT`, `CONSUMER_UNHEALTHY_FILE`, `LOCKER_PROVIDER`, `LOCKER_BUCKET`, `LOCKER_ENDPOINT`, `LOCKER_REGION`, `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`, `NATIVE_CONSUMER_CA_SOURCE_FILE`, `NATIVE_CONSUMER_PREFLIGHT_MODE`, `NATIVE_CONSUMER_EXPECTED_ROLE`, `NATIVE_CONSUMER_EXPECTED_DATABASE`, `NATIVE_CONSUMER_EXPECTED_HOST`, `NATIVE_CONSUMER_EXPECTED_PORT`, `NATIVE_CONSUMER_PREFLIGHT_TIMEOUT_SECONDS`; Secret `<native consumer runtime JSON Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<native consumer Job-only owner JSON Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<native consumer S3 static Secret, secret mode only>` keys `access-key-id`, `secret-access-key` |
| shipped | [Native direct upload inbox scan](#opt-history-direct-upload-consumer) | `off`, `allowlist`, `on` | `off` | values `ingestEdge.uploadDirect.*`, `ingestEdge.keyRoot`, `ingestEdge.createServiceAccount`; env `HISTORY_UPLOAD_DIRECT`, `HISTORY_UPLOAD_DIRECT_ALLOWLIST`, `SELFHOST_UPLOAD_SCAN_BATCH`, `UPLOAD_WITNESS_KEY`; Secret `<operator-chosen shared upload witness Secret>` keys `upload-witness-key` |
| shipped | [S3 upload ledger for the native ingest (decision 0005)](#opt-sessions-pipeline-s3-ledger) | `sql`, `s3` | `sql` | values `ingestEdge.ledger`; env `INGEST_LEDGER` |
| shipped | [S3 ledger re-arm sweeper CronJob](#opt-sessions-pipeline-rearm-sweeper) | `false`, `true` | `false` | values `rearmSweeper.*`; env `INGEST_REARM_SWEEPER_ENABLED`, `INGEST_REARM_BUCKET`, `INGEST_REARM_REGION`, `INGEST_REARM_ENDPOINT`, `INGEST_REARM_KEY_ROOT`, `INGEST_REARM_ORGS`, `INGEST_REARM_DRY_RUN`, `INGEST_REARM_CONCURRENCY`, `INGEST_REARM_MAX_MARKERS`, `INGEST_REARM_CREDENTIALS`, `INGEST_REARM_S3_ACCESS_KEY_ID_FILE`, `INGEST_REARM_S3_SECRET_ACCESS_KEY_FILE`; Secret `<dedicated re-arm sweeper S3 Secret>` keys `access-key-id`, `secret-access-key` |

### Profile: external-selfhosted

**External operator-controlled plain Postgres with a superuser (your own Postgres 17) dedicated to HoopDb.** No in-cluster SQL Jobs (the chart cannot exec into an external database); a superuser runs three bootstrap files first; migrate waits for the roles.

chart `sessions-pipeline` · values [`profiles/external-selfhosted.yaml`](../charts/sessions-pipeline/profiles/external-selfhosted.yaml) · dbMode `selfhosted` · boundary `global-default-revoke` · HoopDb external · services image GHCR · install: `helm install sessions-pipeline agentworkforce/sessions-pipeline -f profiles/external-selfhosted.yaml --set global.tenant.orgId=<org> --set alleyoop.auth.jwksUrl=<jwks url> --set worker.migrations.runtimeRole=<role> --set worker.migrations.runtimeRoleLogin=<true|false>`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [External Secrets Operator and a ClusterSecretStore (only with externalSecrets.enabled)](#req-k8s-external-secrets-operator) | operator | values `sessions-pipeline-worker:externalSecrets.*`, `session-ingest-api:externalSecrets.*` | kubectl get crd externalsecrets.external-secrets.io && kubectl get clustersecretstore <name>; the ExternalSecret reports Ready |
| shipped | [Pull Secret for the private GHCR services image](#req-secret-image-pull) | operator | values `worker.imagePullSecrets`, `alleyoop.imagePullSecrets`; Secret `<pull secret>` (type kubernetes.io/dockerconfigjson with read access to ghcr.io/agentworkforce/96bulls-services) | kubectl get secret <pull secret> -o jsonpath='{.type}' is kubernetes.io/dockerconfigjson; pods are not ImagePullBackOff |
| shipped | [Locker credential Secret (MinIO root / S3 static keys)](#req-secret-locker-credentials) | operator | values `worker.existingSecret`, `alleyoop.existingSecret`, `session-object-storage.existingSecret`, `worker.secretKeys.lockerAccessKeyId`, `worker.secretKeys.lockerSecretAccessKey`, `alleyoop.secretKeys.lockerAccessKeyId`, `alleyoop.secretKeys.lockerSecretAccessKey`; env `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`; Secret `sessions-pipeline-locker` keys `rootUser`, `rootPassword`; Secret `sessions-pipeline-locker` (the bundled upstream MinIO requires literal Secret data keys rootUser and rootPassword) | kubectl get secret sessions-pipeline-locker -o jsonpath='{.data}' has rootUser and rootPassword |
| shipped | [Summary encryption keyring (SUMMARY_MASTER_KEYS)](#req-secret-summary-master-keys) | operator | values `worker.summaryEncryption.existingSecret`, `worker.summaryEncryption.key`, `worker.summaryEncryption.mountPath`, `worker.summaryEncryption.fileName`; env `SUMMARY_MASTER_KEYS_FILE`, `SUMMARY_MASTER_KEYS`; Secret `sessions-pipeline-locker` keys `SUMMARY_MASTER_KEYS` | kubectl exec deploy/<release>-worker-bob-costas -- test -r /var/run/secrets/sessions-pipeline/summary-master-keys; the Secret key parses as <id>:<64 hex> |
| shipped | [HoopDb connection Secret (HOOPDB_URL)](#req-secret-hoopdb-url) | operator | values `worker.hoopdb.existingSecret`, `worker.hoopdb.key`, `worker.secretKeys.hoopdbUrl`, `alleyoop.hoopdb.existingSecret`, `alleyoop.hoopdb.key`, `alleyoop.secretKeys.hoopdbUrl`; env `HOOPDB_URL`; Secret `sessions-pipeline-hoopdb` keys `HOOPDB_URL` | kubectl get secret sessions-pipeline-hoopdb -o jsonpath='{.data.HOOPDB_URL}' \| base64 -d \| psql -X -c 'select 1' |
| shipped | [Agent Relay org id (TENANT_ORG_ID)](#req-sessions-pipeline-tenant-org-id) | operator | values `global.tenant.orgId`, `worker.tenant.orgId`, `alleyoop.tenant.orgId`; env `TENANT_ORG_ID` | helm template renders (it fails with "tenant.orgId (or global.tenant.orgId) is required" otherwise) |
| shipped | [A RelayAuth JWKS URL reachable from alleyoop](#req-sessions-pipeline-relayauth-jwks) | operator | values `alleyoop.auth.jwksUrl`; env `RELAYAUTH_JWKS_URL` | kubectl run -it --rm curl --image=curlimages/curl -- curl -fsS <jwksUrl> returns {"keys":[...]} |
| shipped | [PostgreSQL 17 with pg_trgm and btree_gin (and vector) available](#req-db-postgres-17-extensions) | operator | values `hoopdb.cluster.imageName`, `hoopdb.cluster.initdb.postInitApplicationSQL` | psql "$HOOPDB_URL" -Atc "select name from pg_available_extensions where name in ('pg_trgm','btree_gin','vector')" lists all three; server_version_num >= 170000 |
| shipped | [A database dedicated to HoopDb](#req-db-dedicated-database) | operator | values `hoopdb.cluster.initdb.database`, `hoopdb.cluster.initdb.owner` | psql "$HOOPDB_URL" -Atc "select nspname from pg_namespace where nspname not like 'pg_%' and nspname <> 'information_schema'" shows only HoopDb schemas |
| shipped | [Supabase compatibility roles (anon, authenticated, service_role)](#req-db-compat-roles) | migrator | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `worker.migrations.supabaseShim` | psql "$HOOPDB_URL" -Atc "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role')" is 3 |
| shipped | [The session directory search Worker role (session_directory_search_worker)](#req-db-search-worker-role) | operator | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `searchWorkerRole.bootstrapJob.enabled`, `searchWorkerRole.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.role` | run supabase/bootstrap/session_directory_search_worker.sql as a superuser; then the same query |
| shipped | [The dedicated HoopDb runtime role (HOOPDB_RUNTIME_ROLE, e.g. sessions_pipeline_runtime)](#req-db-runtime-role) | operator | values `worker.migrations.runtimeRole`, `worker.migrations.runtimeRoleLogin`, `runtimeRole.bootstrapJob.enabled`, `runtimeRole.bootstrapJob.sqlPath`; env `HOOPDB_RUNTIME_ROLE`, `HOOPDB_RUNTIME_ROLE_LOGIN` | psql "$HOOPDB_URL" -Atc "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin from pg_roles where rolname='sessions_pipeline_runtime'" is f\|f\|f\|f\|f\|t; migrate refuses otherwise |
| shipped | [The durable function boundary installed before the first migrate](#req-db-function-boundary) | operator | values `functionDefaultRevoke.bootstrapJob.enabled`, `functionDefaultRevoke.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.functionDefault` | the function-default Job completes and migrate's wait-for-role logs "present: ... + owner function default" |
| shipped | [migrate always runs the phase 2 role verify (HOOPDB_ROLE_VERIFY=true)](#req-sessions-pipeline-role-verify) | chart | env `HOOPDB_ROLE_VERIFY` | kubectl get job -l app.kubernetes.io/component=hoopdb-migrate -o yaml shows HOOPDB_ROLE_VERIFY "true"; workloads go ready after migrate |
| shipped | [Model API key Secret for session briefs (OPENAI_API_KEY)](#req-secret-model-api-key) | operator | values `worker.nativeBrief.openaiSecret`, `worker.nativeBrief.openaiSecret.name`, `worker.nativeBrief.openaiSecret.key`; env `OPENAI_API_KEY`; Secret `<model key Secret>` keys `OPENAI_API_KEY` | A worker Pod references the chosen Secret/key; the init container does not. Verify an actual model result separately. |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [alleyoop token verification source](#opt-alleyoop-auth-mode) | `jwksUrl`, `localJwks` | `jwksUrl` | values `alleyoop.auth.jwksUrl`, `alleyoop.auth.localJwks`, `alleyoop.auth.issuer`, `alleyoop.auth.audience`, `alleyoop.secretKeys.jwksJson`; env `RELAYAUTH_JWKS_URL`, `JWKS_JSON`, `AUTH_ISSUER`, `AUTH_AUDIENCE`; Secret `<existingSecret>` keys `JWKS_JSON` (only with auth.localJwks=true) |
| shipped | [Plain http to in-cluster Service FQDNs](#opt-sessions-pipeline-in-cluster-http) | `false`, `true` | `false` | values `alleyoop.allowInClusterHttp`, `worker.allowInClusterHttp`; env `ALLOW_IN_CLUSTER_HTTP` |
| shipped | [CA bundle for verifying the Postgres server certificate (postgresCa)](#opt-postgres-ca-bundle) | `false`, `true` | `false` | values `worker.postgresCa.*`, `alleyoop.postgresCa.*`, `relay-control:postgresCa.*`, `relaychief-control:postgresCa.*`, `relayfile-control:postgresCa.*`; env `NODE_EXTRA_CA_CERTS`, `PGSSLROOTCERT` |
| shipped | [RelayHistory origin expected by the ingest](#opt-alleyoop-history-origin) | `unset`, `origin` | `unset` | values `alleyoop.auth.historyOrigin`; env `RELAYHISTORY_ORIGIN` |
| shipped | [Interim RelayAuth bearer compatibility (local only)](#opt-alleyoop-interim-relayauth-bearer) | `false`, `true` | `false` | values `alleyoop.auth.allowInterimRelayAuthBearer`; env `ALLOW_INTERIM_RELAYAUTH_BEARER` |
| shipped | [HoopDb backend](#opt-sessions-pipeline-hoopdb-backend) | `cnpg`, `external` | `external` | values `hoopdb.enabled` |
| shipped | [Migrator database mode (HOOPDB_DB_MODE)](#opt-sessions-pipeline-db-mode) | `selfhosted`, `cloudsql`, `rds`, `supabase`, `local` | `selfhosted` | values `worker.migrations.databaseMode`; env `HOOPDB_DB_MODE` |
| shipped | [Function boundary mode (HOOPDB_FUNCTION_BOUNDARY_MODE)](#opt-sessions-pipeline-function-boundary-mode) | `global-default-revoke`, `event-trigger` | `global-default-revoke` | values `worker.migrations.functionBoundaryMode`; env `HOOPDB_FUNCTION_BOUNDARY_MODE`, `HOOPDB_FUNCTION_BOUNDARY_APPROVED` |
| shipped | [Plain-Postgres role shim (HOOPDB_SUPABASE_SHIM)](#opt-sessions-pipeline-supabase-shim) | `true`, `false` | `true` | values `worker.migrations.supabaseShim`; env `HOOPDB_SUPABASE_SHIM` |
| shipped | [Migrator role bootstrap (HOOPDB_ROLE_BOOTSTRAP)](#opt-sessions-pipeline-role-bootstrap) | `true`, `false`, `unset` | (no default) | values `worker.migrations.roleBootstrap`; env `HOOPDB_ROLE_BOOTSTRAP` |
| shipped | [Runtime workload role (HOOPDB_RUNTIME_WORKLOAD_ROLE)](#opt-sessions-pipeline-runtime-workload-role) | `""`, `<role>` | `""` | values `worker.migrations.runtimeWorkloadRole`; env `HOOPDB_RUNTIME_WORKLOAD_ROLE` |
| shipped | [Blocking index build for one migrate run (HOOPDB_ALLOW_BLOCKING_INDEX_BUILD)](#opt-sessions-pipeline-allow-blocking-index-build) | `false`, `true` | `false` | values `worker.migrations.allowBlockingIndexBuild`; env `HOOPDB_ALLOW_BLOCKING_INDEX_BUILD` |
| shipped | [migrate's wait-for-role ordering](#opt-sessions-pipeline-wait-for-role) | `true`, `false` | `true` | values `worker.migrations.waitForRole.enabled`, `worker.migrations.waitForRole.functionDefault`, `worker.migrations.waitForRole.image`, `worker.migrations.waitForRole.intervalSeconds`, `worker.migrations.waitForRole.role` |
| shipped | [Separate migration-owner URL for migrate](#opt-hoopdb-migration-owner-url) | `""`, `<secret>/<key>` | `""` | values `worker.migrations.hoopdb.existingSecret`, `worker.migrations.hoopdb.key` |
| shipped | [Locker object store](#opt-sessions-pipeline-locker-backend) | `minio`, `external` | `minio` | values `session-object-storage.enabled`, `worker.locker.endpoint`, `worker.locker.bucket`, `worker.locker.region`, `alleyoop.locker.endpoint`, `alleyoop.locker.bucket`, `alleyoop.locker.region`, `worker.lockerInit.enabled`; env `LOCKER_ENDPOINT`, `LOCKER_BUCKET`, `LOCKER_REGION` |
| shipped | [Locker credentials mode](#opt-sessions-pipeline-locker-credentials-mode) | `secret`, `podIdentity` | `secret` | values `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode` |
| shipped | [Locker provider (S3-compatible or native GCS)](#opt-sessions-pipeline-locker-provider) | `s3`, `gcs` | `s3` | values `worker.locker.provider`, `alleyoop.locker.provider`, `worker.extraEnv`, `alleyoop.extraEnv`; env `LOCKER_PROVIDER`, `PIPELINE_RAW_PROVIDER`, `CLOUD_SQL_CONNECTION_NAME`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_AUTH_ENABLED`, `REDIS_TRANSIT_ENCRYPTION`, `REDIS_TLS_CA_PEM`, `PUBSUB_TOPIC`, `PUBSUB_SUBSCRIPTION` |
| shipped | [Services image registry](#opt-sessions-pipeline-services-image) | `ghcr`, `ecr`, `release-overlay` | `ghcr` | values `worker.image.repository`, `worker.image.digest`, `worker.image.tag`, `alleyoop.image.repository`, `alleyoop.image.digest`, `alleyoop.image.tag`, `global.imageRegistry` |
| shipped | [OpenTelemetry export](#opt-sessions-pipeline-otel) | `""`, `<your OTLP endpoint>`, `http://otel-collector:4318` | `""` | values `global.otel.endpoint`, `otel.enabled`, `otel.config.*`; env `OTEL_EXPORTER_OTLP_ENDPOINT` |
| shipped | [Workspace, deployment and environment labels](#opt-sessions-pipeline-deployment-identity) | `<any>` | `workspaceId=default`, `deployment=selfhost`, `environment=production` | values `worker.tenant.workspaceId`, `worker.deployment.name`, `worker.deployment.id`, `worker.environment`, `alleyoop.tenant.workspaceId`, `alleyoop.deployment.name`, `alleyoop.deployment.id`, `alleyoop.environment`; env `WORKSPACE_ID`, `DEPLOYMENT`, `DEPLOYMENT_ID`, `ENVIRONMENT` |
| shipped | [Stage worker health server](#opt-sessions-pipeline-worker-health) | `true`, `false` | `true` | values `worker.workerHealth.*`; env `WORKER_HEALTH_PORT`, `WORKER_UNHEALTHY_AFTER_FAILURES`, `WORKER_MAX_TICK_AGE_MS` |
| shipped | [Bob Costas summariser model (BOB_COSTAS_MODEL)](#opt-sessions-pipeline-bob-costas-model) | `off` | `off` | values `worker.components.bob-costas.env`; env `BOB_COSTAS_MODEL` |
| **planned** | [Transcript search backend (search.backend)](#opt-sessions-pipeline-search-backend) | `postgres`, `clickhouse` (**planned**) | `postgres` | values `search.backend`, `search.clickhouse.*` |
| shipped | [Native model session briefs](#opt-sessions-pipeline-session-briefs) | `false`, `true` | `false` | values `worker.components.session-brief.enabled`, `worker.components.session-brief.replicas`, `worker.nativeBrief.enabled`, `worker.nativeBrief.image.*`, `worker.nativeBrief.workspaceIds`, `worker.nativeBrief.model`, `worker.nativeBrief.baseUrl`, `worker.nativeBrief.allowInClusterHttp`, `worker.nativeBrief.keyPrefix`, `worker.nativeBrief.sweepSeconds`, `worker.nativeBrief.batch`, `worker.nativeBrief.globalDailyCap`, `worker.nativeBrief.sessionDailyCap`, `worker.nativeBrief.openaiEgress.*`, `worker.postgresCa.sha256`; env `SESSION_BRIEF_ENABLED`, `SESSION_BRIEF_CANONICAL_INPUT`, `SESSION_BRIEF_WORKSPACE_IDS`, `SESSION_BRIEF_MODEL`, `SESSION_BRIEF_SWEEP_SECONDS`, `SESSION_BRIEF_BATCH`, `SESSION_BRIEF_GLOBAL_DAILY_CAP`, `SESSION_BRIEF_SESSION_DAILY_CAP`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `OPENAI_BASE_URL` |
| shipped | [Sessions reader ruleset ceiling](#opt-sessions-pipeline-reader-max-ruleset) | (no default), `8`, `9`, `10` | (no default) | values `nativeConsumer.readerMaxRuleset`, `worker.nativeBrief.readerMaxRuleset`, `sessionReadApi.readerMaxRuleset`, `alleyoop.readerMaxRuleset`, `ingestEdge.readerMaxRuleset`; env `READER_MAX_RULESET` |
| shipped | [Shared Sessions scrub engine rollout contract](#opt-sessions-pipeline-scrub-engine) | (no default), `reader-first`, `wasm-bindgen` | (no default) | values `global.scrubEngine.engine`, `global.scrubEngine.required`, `global.scrubEngine.readerMaxRuleset`; env `SCRUB_ENGINE`, `SCRUB_ENGINE_REQUIRED`, `READER_MAX_RULESET` |
| shipped | [Native brief collector analytics adapter](#opt-sessions-pipeline-brief-collector-analytics) | `false`, `true` | `false` | values `worker.nativeBrief.analytics.*`; env `ANALYTICS_SINK`, `ANALYTICS_DEPLOYMENT_ID`, `ANALYTICS_COLLECTOR_URL`, `ANALYTICS_COLLECTOR_TOKEN`, `ANALYTICS_COLLECTOR_CA_FILE`; Secret `<Native brief component-bound analytics producer Secret>` keys `token` |
| shipped | [Default-off native session upload edge](#opt-sessions-native-ingest) | `disabled`, `enabled` | `disabled` | values `ingestEdge.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_INGEST`, `RELAYHISTORY_SELFHOST_SESSION_SELECTION`, `RELAYHISTORY_SELFHOST_HEARTBEAT_ACCEPT`, `RELAYHISTORY_INGEST_PORT`, `RELAYHISTORY_INGEST_ORIGIN`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`, `RELAYHISTORY_INGEST_DATABASE_URL`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYHISTORY_INGEST_PG_POOL_MAX`, `ALLOW_IN_CLUSTER_HTTP`, `LOCKER_PROVIDER`, `LOCKER_BUCKET`, `LOCKER_ENDPOINT`, `LOCKER_REGION`, `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`, `INGEST_KEY_ROOT`, `INGEST_MAX_PER_USER`, `INGEST_MAX_PER_ORG`; Secret `<native ingest runtime Secret>` keys `database-url`, `introspect-secret`; Secret `<native ingest object-store Secret>` keys `access-key-id`, `secret-access-key` |
| shipped | [Default-off self-host session read API container](#opt-sessions-read-api) | `disabled`, `enabled` | `disabled` | values `fullnameOverride`, `replicas`, `image.*`, `imagePullSecrets`, `port`, `probeRuntime`, `origin`, `completeSince`, `directoryWorkspaces`, `login.advertisesSync`, `turns.assumeNoLegacy`, `timing.assumeNoTurns`, `canonical.pinLaggingPointer`, `events.messageIds`, `coordinationOverlaps.enabled`, `serviceAccountCreate`, `allowInClusterHttp`, `config.*`, `postgres.*`, `postgresCa.*`, `search.*`, `auth.*`, `cors.*`, `ingress.*`, `networkPolicy.*`, `extraEnv`, `extraVolumes`, `extraVolumeMounts`, `serviceAccountName`, `nodeSelector`, `tolerations`, `affinity`, `podAnnotations`, `resources`; env `SERVICE`, `RELAYHISTORY_SELFHOST_READ_API`, `RELAYHISTORY_READ_API_PORT`, `RELAYHISTORY_READ_API_SECRET`, `READ_API_ORIGIN`, `READ_API_AUTH_MODE`, `READ_API_COMPLETE_SINCE`, `READ_API_DIRECTORY_WORKSPACES`, `READ_API_CORS_ALLOWED_ORIGINS`, `RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC`, `READ_API_TURNS_ASSUME_NO_LEGACY`, `READ_API_TIMING_ASSUME_NO_TURNS`, `READ_API_CANONICAL_PIN_LAGGING_POINTER`, `READ_API_EVENT_MESSAGE_IDS`, `READ_API_COORDINATION_OVERLAPS_ENABLED`, `READ_API_COORDINATION_OVERLAPS_BACKEND`, `READ_API_INTERNAL_SECRET`, `READ_API_INTERNAL_SECRET_PREVIOUS`, `READ_API_ACCESS_TOKEN_TTL_SECONDS`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `SEARCH_INDEX_BACKEND`, `ALLOW_IN_CLUSTER_HTTP`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYAUTH_JWKS_URL`, `RELAYAUTH_ISSUER`, `RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API configuration Secret>` keys `RELAYHISTORY_READ_API_SECRET`; Secret `<read API introspection Secret>` keys `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API internal Secret>` keys `READ_API_INTERNAL_SECRET`; Secret `<read API previous internal Secret>` keys `READ_API_INTERNAL_SECRET_PREVIOUS` |
| shipped | [Default-off self-host transcript search writer](#opt-sessions-search-indexer) | `disabled`, `enabled` | `disabled` | values `searchIndexer.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `LOCKER_BUCKET`, `LOCKER_REGION`, `LOCKER_ENDPOINT`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `WORKER_HEALTH_PORT`; Secret `<search indexer configuration Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<search indexer bootstrap Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` |
| shipped | [Self-host output facts writer and bootstrap Job](#opt-sessions-output-facts) | `disabled`, `enabled` | `disabled` | values `searchIndexer.outputFacts.enabled`, `searchIndexer.outputFacts.bootstrap.*`, `nativeConsumer.outputFacts.enabled`; env `RELAYHISTORY_SELFHOST_OUTPUT_FACTS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_DEADLINE_SECONDS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_ALLOW_PARTIAL` |
| shipped | [Session read API Output and daily digest routes](#opt-sessions-read-api-output-digest) | `disabled`, `enabled` | `disabled` | values `output.enabled`, `digest.enabled`, `digest.narrative.*`; env `READ_API_OUTPUT_ENABLED`, `READ_API_OUTPUT_BACKEND`, `READ_API_DIGEST_ENABLED`, `READ_API_DIGEST_BACKEND`, `READ_API_DIGEST_NARRATIVE_MODEL`, `READ_API_DIGEST_NARRATIVE_DB_URL`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`; Secret `<digest narrative model API key Secret, model only>` keys `OPENAI_API_KEY`; Secret `<digest narrative writer login Secret, model only>` keys `READ_API_DIGEST_NARRATIVE_DB_URL` |
| shipped | [Native ingest claim lock retry response](#opt-sessions-native-ingest-claim-lock-busy) | `true`, `false` | `true` | values `ingestEdge.claimLockBusy`; env `INGEST_CLAIM_LOCK_BUSY` |
| shipped | [Native ingest admission mode](#opt-sessions-native-ingest-admission) | `sync`, `async`, `drain` | `sync` | values `ingestEdge.admission.mode`, `ingestEdge.admission.concurrency`, `ingestEdge.admission.scanIntervalMs`, `ingestEdge.admission.maxAttempts`; env `SELFHOST_INGEST_ADMISSION`, `SELFHOST_ADMISSION_CONCURRENCY`, `SELFHOST_ADMISSION_SCAN_MS`, `SELFHOST_ADMISSION_MAX_ATTEMPTS` |
| shipped | [Default-off native canonical pointer and search consumer](#opt-sessions-native-consumer) | `disabled`, `enabled` | `disabled` | values `nativeConsumer.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `HOOPDB_DB_MODE`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_RUNTIME`, `PIPELINE_FANOUT`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `CONSUMER_RECONCILE_EVERY_MINUTES`, `PIPELINE_RECONCILE_LOOKBACK_MINUTES`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `ALLOW_IN_CLUSTER_HTTP`, `WORKER_HEALTH_PORT`, `CONSUMER_UNHEALTHY_FILE`, `LOCKER_PROVIDER`, `LOCKER_BUCKET`, `LOCKER_ENDPOINT`, `LOCKER_REGION`, `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`, `NATIVE_CONSUMER_CA_SOURCE_FILE`, `NATIVE_CONSUMER_PREFLIGHT_MODE`, `NATIVE_CONSUMER_EXPECTED_ROLE`, `NATIVE_CONSUMER_EXPECTED_DATABASE`, `NATIVE_CONSUMER_EXPECTED_HOST`, `NATIVE_CONSUMER_EXPECTED_PORT`, `NATIVE_CONSUMER_PREFLIGHT_TIMEOUT_SECONDS`; Secret `<native consumer runtime JSON Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<native consumer Job-only owner JSON Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<native consumer S3 static Secret, secret mode only>` keys `access-key-id`, `secret-access-key` |
| shipped | [Native History public route](#opt-sessions-pipeline-native-routing) | `disabled`, `enabled` | `disabled` | values `nativeRouting.*`; Secret `<existing public History TLS Secret>` |
| shipped | [Retire a legacy Deployment while retaining resources](#opt-legacy-deployment-retirement) | `true`, `false` | `true` | values `deployment.enabled` |
| shipped | [Native direct upload inbox scan](#opt-history-direct-upload-consumer) | `off`, `allowlist`, `on` | `off` | values `ingestEdge.uploadDirect.*`, `ingestEdge.keyRoot`, `ingestEdge.createServiceAccount`; env `HISTORY_UPLOAD_DIRECT`, `HISTORY_UPLOAD_DIRECT_ALLOWLIST`, `SELFHOST_UPLOAD_SCAN_BATCH`, `UPLOAD_WITNESS_KEY`; Secret `<operator-chosen shared upload witness Secret>` keys `upload-witness-key` |
| shipped | [S3 upload ledger for the native ingest (decision 0005)](#opt-sessions-pipeline-s3-ledger) | `sql`, `s3` | `sql` | values `ingestEdge.ledger`; env `INGEST_LEDGER` |
| shipped | [S3 ledger re-arm sweeper CronJob](#opt-sessions-pipeline-rearm-sweeper) | `false`, `true` | `false` | values `rearmSweeper.*`; env `INGEST_REARM_SWEEPER_ENABLED`, `INGEST_REARM_BUCKET`, `INGEST_REARM_REGION`, `INGEST_REARM_ENDPOINT`, `INGEST_REARM_KEY_ROOT`, `INGEST_REARM_ORGS`, `INGEST_REARM_DRY_RUN`, `INGEST_REARM_CONCURRENCY`, `INGEST_REARM_MAX_MARKERS`, `INGEST_REARM_CREDENTIALS`, `INGEST_REARM_S3_ACCESS_KEY_ID_FILE`, `INGEST_REARM_S3_SECRET_ACCESS_KEY_FILE`; Secret `<dedicated re-arm sweeper S3 Secret>` keys `access-key-id`, `secret-access-key` |

### Profile: external-rds

**Amazon RDS for PostgreSQL 16+ dedicated HoopDb database.** No in-cluster SQL Jobs; the RDS master runs the rds_*.sql bootstrap before migrate.

chart `sessions-pipeline` · values [`profiles/external-rds.yaml`](../charts/sessions-pipeline/profiles/external-rds.yaml) · dbMode `rds` · boundary `global-default-revoke` · HoopDb external · services image GHCR-RDS · install: `helm install sessions-pipeline agentworkforce/sessions-pipeline -f profiles/external-rds.yaml --set global.tenant.orgId=<org> --set alleyoop.auth.jwksUrl=<jwks url> --set worker.migrations.runtimeRole=<role> --set worker.migrations.runtimeRoleLogin=true`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [External Secrets Operator and a ClusterSecretStore (only with externalSecrets.enabled)](#req-k8s-external-secrets-operator) | operator | values `sessions-pipeline-worker:externalSecrets.*`, `session-ingest-api:externalSecrets.*` | kubectl get crd externalsecrets.external-secrets.io && kubectl get clustersecretstore <name>; the ExternalSecret reports Ready |
| shipped | [Pull Secret for the private GHCR services image](#req-secret-image-pull) | operator | values `worker.imagePullSecrets`, `alleyoop.imagePullSecrets`; Secret `<pull secret>` (type kubernetes.io/dockerconfigjson with read access to ghcr.io/agentworkforce/96bulls-services) | kubectl get secret <pull secret> -o jsonpath='{.type}' is kubernetes.io/dockerconfigjson; pods are not ImagePullBackOff |
| shipped | [Locker credential Secret (MinIO root / S3 static keys)](#req-secret-locker-credentials) | operator | values `worker.existingSecret`, `alleyoop.existingSecret`, `session-object-storage.existingSecret`, `worker.secretKeys.lockerAccessKeyId`, `worker.secretKeys.lockerSecretAccessKey`, `alleyoop.secretKeys.lockerAccessKeyId`, `alleyoop.secretKeys.lockerSecretAccessKey`; env `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`; Secret `sessions-pipeline-locker` keys `rootUser`, `rootPassword`; Secret `sessions-pipeline-locker` (the bundled upstream MinIO requires literal Secret data keys rootUser and rootPassword) | kubectl get secret sessions-pipeline-locker -o jsonpath='{.data}' has rootUser and rootPassword |
| shipped | [Summary encryption keyring (SUMMARY_MASTER_KEYS)](#req-secret-summary-master-keys) | operator | values `worker.summaryEncryption.existingSecret`, `worker.summaryEncryption.key`, `worker.summaryEncryption.mountPath`, `worker.summaryEncryption.fileName`; env `SUMMARY_MASTER_KEYS_FILE`, `SUMMARY_MASTER_KEYS`; Secret `sessions-pipeline-locker` keys `SUMMARY_MASTER_KEYS` | kubectl exec deploy/<release>-worker-bob-costas -- test -r /var/run/secrets/sessions-pipeline/summary-master-keys; the Secret key parses as <id>:<64 hex> |
| shipped | [HoopDb connection Secret (HOOPDB_URL)](#req-secret-hoopdb-url) | operator | values `worker.hoopdb.existingSecret`, `worker.hoopdb.key`, `worker.secretKeys.hoopdbUrl`, `alleyoop.hoopdb.existingSecret`, `alleyoop.hoopdb.key`, `alleyoop.secretKeys.hoopdbUrl`; env `HOOPDB_URL`; Secret `sessions-pipeline-hoopdb` keys `HOOPDB_URL` | psql "$(kubectl get secret sessions-pipeline-hoopdb -o jsonpath='{.data.HOOPDB_URL}' \| base64 -d \| sed -E 's/&?uselibpqcompat=true//; s/\?&/?/')" -X -c 'select 1' |
| shipped | [Separate migration-owner connection Secret (HOOPDB_MIGRATION_URL)](#req-secret-hoopdb-migration-url) | operator | values `worker.migrations.hoopdb.existingSecret`, `worker.migrations.hoopdb.key`; Secret `sessions-pipeline-hoopdb` keys `HOOPDB_MIGRATION_URL` | psql "$(kubectl get secret sessions-pipeline-hoopdb -o jsonpath='{.data.HOOPDB_MIGRATION_URL}' \| base64 -d \| sed -E 's/&?uselibpqcompat=true//; s/\?&/?/')" -Atc 'select current_user' is the RDS master |
| shipped | [Agent Relay org id (TENANT_ORG_ID)](#req-sessions-pipeline-tenant-org-id) | operator | values `global.tenant.orgId`, `worker.tenant.orgId`, `alleyoop.tenant.orgId`; env `TENANT_ORG_ID` | helm template renders (it fails with "tenant.orgId (or global.tenant.orgId) is required" otherwise) |
| shipped | [A RelayAuth JWKS URL reachable from alleyoop](#req-sessions-pipeline-relayauth-jwks) | operator | values `alleyoop.auth.jwksUrl`; env `RELAYAUTH_JWKS_URL` | kubectl run -it --rm curl --image=curlimages/curl -- curl -fsS <jwksUrl> returns {"keys":[...]} |
| shipped | [PostgreSQL 17 with pg_trgm and btree_gin (and vector) available](#req-db-postgres-17-extensions) | operator | values `hoopdb.cluster.imageName`, `hoopdb.cluster.initdb.postInitApplicationSQL` | with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select name from pg_available_extensions where name in ('pg_trgm','btree_gin','vector')" lists all three; server_version_num >= 160000 |
| shipped | [A database dedicated to HoopDb](#req-db-dedicated-database) | operator | values `hoopdb.cluster.initdb.database`, `hoopdb.cluster.initdb.owner` | with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select nspname from pg_namespace where nspname not like 'pg_%' and nspname <> 'information_schema'" shows only HoopDb schemas |
| shipped | [Supabase compatibility roles (anon, authenticated, service_role)](#req-db-compat-roles) | operator | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `worker.migrations.supabaseShim` | with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role')" is 3 |
| shipped | [The session directory search Worker role (session_directory_search_worker)](#req-db-search-worker-role) | operator | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `searchWorkerRole.bootstrapJob.enabled`, `searchWorkerRole.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.role` | the master runs supabase/bootstrap/rds_migration_roles.sql; then, with uselibpqcompat=true removed from the URL (psql rejects it), the same query |
| shipped | [The dedicated HoopDb runtime role (HOOPDB_RUNTIME_ROLE, e.g. sessions_pipeline_runtime)](#req-db-runtime-role) | operator | values `worker.migrations.runtimeRole`, `worker.migrations.runtimeRoleLogin`, `runtimeRole.bootstrapJob.enabled`, `runtimeRole.bootstrapJob.sqlPath`; env `HOOPDB_RUNTIME_ROLE`, `HOOPDB_RUNTIME_ROLE_LOGIN` | with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin from pg_roles where rolname='sessions_pipeline_runtime'" is f\|f\|f\|f\|f\|t; migrate refuses otherwise |
| shipped | [The durable function boundary installed before the first migrate](#req-db-function-boundary) | operator | values `functionDefaultRevoke.bootstrapJob.enabled`, `functionDefaultRevoke.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.functionDefault` | migrate completes; it refuses with function_boundary_unproven unless rds_owner_function_default_revoke.sql has run |
| shipped | [migrate always runs the phase 2 role verify (HOOPDB_ROLE_VERIFY=true)](#req-sessions-pipeline-role-verify) | chart | env `HOOPDB_ROLE_VERIFY` | kubectl get job -l app.kubernetes.io/component=hoopdb-migrate -o yaml shows HOOPDB_ROLE_VERIFY "true"; workloads go ready after migrate |
| shipped | [Model API key Secret for session briefs (OPENAI_API_KEY)](#req-secret-model-api-key) | operator | values `worker.nativeBrief.openaiSecret`, `worker.nativeBrief.openaiSecret.name`, `worker.nativeBrief.openaiSecret.key`; env `OPENAI_API_KEY`; Secret `<model key Secret>` keys `OPENAI_API_KEY` | A worker Pod references the chosen Secret/key; the init container does not. Verify an actual model result separately. |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [alleyoop token verification source](#opt-alleyoop-auth-mode) | `jwksUrl`, `localJwks` | `jwksUrl` | values `alleyoop.auth.jwksUrl`, `alleyoop.auth.localJwks`, `alleyoop.auth.issuer`, `alleyoop.auth.audience`, `alleyoop.secretKeys.jwksJson`; env `RELAYAUTH_JWKS_URL`, `JWKS_JSON`, `AUTH_ISSUER`, `AUTH_AUDIENCE`; Secret `<existingSecret>` keys `JWKS_JSON` (only with auth.localJwks=true) |
| shipped | [Plain http to in-cluster Service FQDNs](#opt-sessions-pipeline-in-cluster-http) | `false`, `true` | `false` | values `alleyoop.allowInClusterHttp`, `worker.allowInClusterHttp`; env `ALLOW_IN_CLUSTER_HTTP` |
| shipped | [CA bundle for verifying the Postgres server certificate (postgresCa)](#opt-postgres-ca-bundle) | `false`, `true` | `false` | values `worker.postgresCa.*`, `alleyoop.postgresCa.*`, `relay-control:postgresCa.*`, `relaychief-control:postgresCa.*`, `relayfile-control:postgresCa.*`; env `NODE_EXTRA_CA_CERTS`, `PGSSLROOTCERT` |
| shipped | [RelayHistory origin expected by the ingest](#opt-alleyoop-history-origin) | `unset`, `origin` | `unset` | values `alleyoop.auth.historyOrigin`; env `RELAYHISTORY_ORIGIN` |
| shipped | [Interim RelayAuth bearer compatibility (local only)](#opt-alleyoop-interim-relayauth-bearer) | `false`, `true` | `false` | values `alleyoop.auth.allowInterimRelayAuthBearer`; env `ALLOW_INTERIM_RELAYAUTH_BEARER` |
| shipped | [HoopDb backend](#opt-sessions-pipeline-hoopdb-backend) | `cnpg`, `external` | `external` | values `hoopdb.enabled` |
| shipped | [Migrator database mode (HOOPDB_DB_MODE)](#opt-sessions-pipeline-db-mode) | `selfhosted`, `cloudsql`, `rds`, `supabase`, `local` | `rds` | values `worker.migrations.databaseMode`; env `HOOPDB_DB_MODE` |
| shipped | [Function boundary mode (HOOPDB_FUNCTION_BOUNDARY_MODE)](#opt-sessions-pipeline-function-boundary-mode) | `global-default-revoke`, `event-trigger` | `global-default-revoke` | values `worker.migrations.functionBoundaryMode`; env `HOOPDB_FUNCTION_BOUNDARY_MODE`, `HOOPDB_FUNCTION_BOUNDARY_APPROVED` |
| shipped | [Plain-Postgres role shim (HOOPDB_SUPABASE_SHIM)](#opt-sessions-pipeline-supabase-shim) | `true`, `false` | `false` | values `worker.migrations.supabaseShim`; env `HOOPDB_SUPABASE_SHIM` |
| shipped | [Migrator role bootstrap (HOOPDB_ROLE_BOOTSTRAP)](#opt-sessions-pipeline-role-bootstrap) | `true`, `false`, `unset` | (no default) | values `worker.migrations.roleBootstrap`; env `HOOPDB_ROLE_BOOTSTRAP` |
| shipped | [Runtime workload role (HOOPDB_RUNTIME_WORKLOAD_ROLE)](#opt-sessions-pipeline-runtime-workload-role) | `""`, `<role>` | `""` | values `worker.migrations.runtimeWorkloadRole`; env `HOOPDB_RUNTIME_WORKLOAD_ROLE` |
| shipped | [Blocking index build for one migrate run (HOOPDB_ALLOW_BLOCKING_INDEX_BUILD)](#opt-sessions-pipeline-allow-blocking-index-build) | `false`, `true` | `false` | values `worker.migrations.allowBlockingIndexBuild`; env `HOOPDB_ALLOW_BLOCKING_INDEX_BUILD` |
| shipped | [migrate's wait-for-role ordering](#opt-sessions-pipeline-wait-for-role) | `true`, `false` | `false` | values `worker.migrations.waitForRole.enabled`, `worker.migrations.waitForRole.functionDefault`, `worker.migrations.waitForRole.image`, `worker.migrations.waitForRole.intervalSeconds`, `worker.migrations.waitForRole.role` |
| shipped | [Separate migration-owner URL for migrate](#opt-hoopdb-migration-owner-url) | `""`, `<secret>/<key>` | `sessions-pipeline-hoopdb/HOOPDB_MIGRATION_URL` | values `worker.migrations.hoopdb.existingSecret`, `worker.migrations.hoopdb.key` |
| shipped | [Locker object store](#opt-sessions-pipeline-locker-backend) | `minio`, `external` | `minio` | values `session-object-storage.enabled`, `worker.locker.endpoint`, `worker.locker.bucket`, `worker.locker.region`, `alleyoop.locker.endpoint`, `alleyoop.locker.bucket`, `alleyoop.locker.region`, `worker.lockerInit.enabled`; env `LOCKER_ENDPOINT`, `LOCKER_BUCKET`, `LOCKER_REGION` |
| shipped | [Locker credentials mode](#opt-sessions-pipeline-locker-credentials-mode) | `secret`, `podIdentity` | `secret` | values `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode` |
| shipped | [Locker provider (S3-compatible or native GCS)](#opt-sessions-pipeline-locker-provider) | `s3`, `gcs` | `s3` | values `worker.locker.provider`, `alleyoop.locker.provider`, `worker.extraEnv`, `alleyoop.extraEnv`; env `LOCKER_PROVIDER`, `PIPELINE_RAW_PROVIDER`, `CLOUD_SQL_CONNECTION_NAME`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_AUTH_ENABLED`, `REDIS_TRANSIT_ENCRYPTION`, `REDIS_TLS_CA_PEM`, `PUBSUB_TOPIC`, `PUBSUB_SUBSCRIPTION` |
| shipped | [Services image registry](#opt-sessions-pipeline-services-image) | `ghcr`, `ecr`, `release-overlay` | `ghcr` | values `worker.image.repository`, `worker.image.digest`, `worker.image.tag`, `alleyoop.image.repository`, `alleyoop.image.digest`, `alleyoop.image.tag`, `global.imageRegistry` |
| shipped | [OpenTelemetry export](#opt-sessions-pipeline-otel) | `""`, `<your OTLP endpoint>`, `http://otel-collector:4318` | `""` | values `global.otel.endpoint`, `otel.enabled`, `otel.config.*`; env `OTEL_EXPORTER_OTLP_ENDPOINT` |
| shipped | [Workspace, deployment and environment labels](#opt-sessions-pipeline-deployment-identity) | `<any>` | `workspaceId=default`, `deployment=selfhost`, `environment=production` | values `worker.tenant.workspaceId`, `worker.deployment.name`, `worker.deployment.id`, `worker.environment`, `alleyoop.tenant.workspaceId`, `alleyoop.deployment.name`, `alleyoop.deployment.id`, `alleyoop.environment`; env `WORKSPACE_ID`, `DEPLOYMENT`, `DEPLOYMENT_ID`, `ENVIRONMENT` |
| shipped | [Stage worker health server](#opt-sessions-pipeline-worker-health) | `true`, `false` | `true` | values `worker.workerHealth.*`; env `WORKER_HEALTH_PORT`, `WORKER_UNHEALTHY_AFTER_FAILURES`, `WORKER_MAX_TICK_AGE_MS` |
| shipped | [Bob Costas summariser model (BOB_COSTAS_MODEL)](#opt-sessions-pipeline-bob-costas-model) | `off` | `off` | values `worker.components.bob-costas.env`; env `BOB_COSTAS_MODEL` |
| **planned** | [Transcript search backend (search.backend)](#opt-sessions-pipeline-search-backend) | `postgres`, `clickhouse` (**planned**) | `postgres` | values `search.backend`, `search.clickhouse.*` |
| shipped | [Native model session briefs](#opt-sessions-pipeline-session-briefs) | `false`, `true` | `false` | values `worker.components.session-brief.enabled`, `worker.components.session-brief.replicas`, `worker.nativeBrief.enabled`, `worker.nativeBrief.image.*`, `worker.nativeBrief.workspaceIds`, `worker.nativeBrief.model`, `worker.nativeBrief.baseUrl`, `worker.nativeBrief.allowInClusterHttp`, `worker.nativeBrief.keyPrefix`, `worker.nativeBrief.sweepSeconds`, `worker.nativeBrief.batch`, `worker.nativeBrief.globalDailyCap`, `worker.nativeBrief.sessionDailyCap`, `worker.nativeBrief.openaiEgress.*`, `worker.postgresCa.sha256`; env `SESSION_BRIEF_ENABLED`, `SESSION_BRIEF_CANONICAL_INPUT`, `SESSION_BRIEF_WORKSPACE_IDS`, `SESSION_BRIEF_MODEL`, `SESSION_BRIEF_SWEEP_SECONDS`, `SESSION_BRIEF_BATCH`, `SESSION_BRIEF_GLOBAL_DAILY_CAP`, `SESSION_BRIEF_SESSION_DAILY_CAP`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `OPENAI_BASE_URL` |
| shipped | [Sessions reader ruleset ceiling](#opt-sessions-pipeline-reader-max-ruleset) | (no default), `8`, `9`, `10` | (no default) | values `nativeConsumer.readerMaxRuleset`, `worker.nativeBrief.readerMaxRuleset`, `sessionReadApi.readerMaxRuleset`, `alleyoop.readerMaxRuleset`, `ingestEdge.readerMaxRuleset`; env `READER_MAX_RULESET` |
| shipped | [Shared Sessions scrub engine rollout contract](#opt-sessions-pipeline-scrub-engine) | (no default), `reader-first`, `wasm-bindgen` | (no default) | values `global.scrubEngine.engine`, `global.scrubEngine.required`, `global.scrubEngine.readerMaxRuleset`; env `SCRUB_ENGINE`, `SCRUB_ENGINE_REQUIRED`, `READER_MAX_RULESET` |
| shipped | [Native brief collector analytics adapter](#opt-sessions-pipeline-brief-collector-analytics) | `false`, `true` | `false` | values `worker.nativeBrief.analytics.*`; env `ANALYTICS_SINK`, `ANALYTICS_DEPLOYMENT_ID`, `ANALYTICS_COLLECTOR_URL`, `ANALYTICS_COLLECTOR_TOKEN`, `ANALYTICS_COLLECTOR_CA_FILE`; Secret `<Native brief component-bound analytics producer Secret>` keys `token` |
| shipped | [Default-off self-host session read API container](#opt-sessions-read-api) | `disabled`, `enabled` | `disabled` | values `fullnameOverride`, `replicas`, `image.*`, `imagePullSecrets`, `port`, `probeRuntime`, `origin`, `completeSince`, `directoryWorkspaces`, `login.advertisesSync`, `turns.assumeNoLegacy`, `timing.assumeNoTurns`, `canonical.pinLaggingPointer`, `events.messageIds`, `coordinationOverlaps.enabled`, `serviceAccountCreate`, `allowInClusterHttp`, `config.*`, `postgres.*`, `postgresCa.*`, `search.*`, `auth.*`, `cors.*`, `ingress.*`, `networkPolicy.*`, `extraEnv`, `extraVolumes`, `extraVolumeMounts`, `serviceAccountName`, `nodeSelector`, `tolerations`, `affinity`, `podAnnotations`, `resources`; env `SERVICE`, `RELAYHISTORY_SELFHOST_READ_API`, `RELAYHISTORY_READ_API_PORT`, `RELAYHISTORY_READ_API_SECRET`, `READ_API_ORIGIN`, `READ_API_AUTH_MODE`, `READ_API_COMPLETE_SINCE`, `READ_API_DIRECTORY_WORKSPACES`, `READ_API_CORS_ALLOWED_ORIGINS`, `RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC`, `READ_API_TURNS_ASSUME_NO_LEGACY`, `READ_API_TIMING_ASSUME_NO_TURNS`, `READ_API_CANONICAL_PIN_LAGGING_POINTER`, `READ_API_EVENT_MESSAGE_IDS`, `READ_API_COORDINATION_OVERLAPS_ENABLED`, `READ_API_COORDINATION_OVERLAPS_BACKEND`, `READ_API_INTERNAL_SECRET`, `READ_API_INTERNAL_SECRET_PREVIOUS`, `READ_API_ACCESS_TOKEN_TTL_SECONDS`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `SEARCH_INDEX_BACKEND`, `ALLOW_IN_CLUSTER_HTTP`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYAUTH_JWKS_URL`, `RELAYAUTH_ISSUER`, `RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API configuration Secret>` keys `RELAYHISTORY_READ_API_SECRET`; Secret `<read API introspection Secret>` keys `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API internal Secret>` keys `READ_API_INTERNAL_SECRET`; Secret `<read API previous internal Secret>` keys `READ_API_INTERNAL_SECRET_PREVIOUS` |
| shipped | [Default-off self-host transcript search writer](#opt-sessions-search-indexer) | `disabled`, `enabled` | `disabled` | values `searchIndexer.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `LOCKER_BUCKET`, `LOCKER_REGION`, `LOCKER_ENDPOINT`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `WORKER_HEALTH_PORT`; Secret `<search indexer configuration Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<search indexer bootstrap Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` |
| shipped | [Self-host output facts writer and bootstrap Job](#opt-sessions-output-facts) | `disabled`, `enabled` | `disabled` | values `searchIndexer.outputFacts.enabled`, `searchIndexer.outputFacts.bootstrap.*`, `nativeConsumer.outputFacts.enabled`; env `RELAYHISTORY_SELFHOST_OUTPUT_FACTS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_DEADLINE_SECONDS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_ALLOW_PARTIAL` |
| shipped | [Session read API Output and daily digest routes](#opt-sessions-read-api-output-digest) | `disabled`, `enabled` | `disabled` | values `output.enabled`, `digest.enabled`, `digest.narrative.*`; env `READ_API_OUTPUT_ENABLED`, `READ_API_OUTPUT_BACKEND`, `READ_API_DIGEST_ENABLED`, `READ_API_DIGEST_BACKEND`, `READ_API_DIGEST_NARRATIVE_MODEL`, `READ_API_DIGEST_NARRATIVE_DB_URL`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`; Secret `<digest narrative model API key Secret, model only>` keys `OPENAI_API_KEY`; Secret `<digest narrative writer login Secret, model only>` keys `READ_API_DIGEST_NARRATIVE_DB_URL` |
| shipped | [Retire a legacy Deployment while retaining resources](#opt-legacy-deployment-retirement) | `true`, `false` | `true` | values `deployment.enabled` |
| shipped | [Native direct upload inbox scan](#opt-history-direct-upload-consumer) | `off`, `allowlist`, `on` | `off` | values `ingestEdge.uploadDirect.*`, `ingestEdge.keyRoot`, `ingestEdge.createServiceAccount`; env `HISTORY_UPLOAD_DIRECT`, `HISTORY_UPLOAD_DIRECT_ALLOWLIST`, `SELFHOST_UPLOAD_SCAN_BATCH`, `UPLOAD_WITNESS_KEY`; Secret `<operator-chosen shared upload witness Secret>` keys `upload-witness-key` |
| shipped | [S3 upload ledger for the native ingest (decision 0005)](#opt-sessions-pipeline-s3-ledger) | `sql`, `s3` | `sql` | values `ingestEdge.ledger`; env `INGEST_LEDGER` |
| shipped | [S3 ledger re-arm sweeper CronJob](#opt-sessions-pipeline-rearm-sweeper) | `false`, `true` | `false` | values `rearmSweeper.*`; env `INGEST_REARM_SWEEPER_ENABLED`, `INGEST_REARM_BUCKET`, `INGEST_REARM_REGION`, `INGEST_REARM_ENDPOINT`, `INGEST_REARM_KEY_ROOT`, `INGEST_REARM_ORGS`, `INGEST_REARM_DRY_RUN`, `INGEST_REARM_CONCURRENCY`, `INGEST_REARM_MAX_MARKERS`, `INGEST_REARM_CREDENTIALS`, `INGEST_REARM_S3_ACCESS_KEY_ID_FILE`, `INGEST_REARM_S3_SECRET_ACCESS_KEY_FILE`; Secret `<dedicated re-arm sweeper S3 Secret>` keys `access-key-id`, `secret-access-key` |

### Profile: aws-rds-native

**AWS EKS native History with external RDS, S3 and OpenSearch.** Customer-neutral production shape. It fails closed until the release overlay supplies the approved services digest, customer resource IDs, origins, RDS CA hash and ALB subnet peers. No in-cluster database or privileged SQL bootstrap Job is installed.

chart `sessions-pipeline` · values [`profiles/aws-rds-native.yaml`](../charts/sessions-pipeline/profiles/aws-rds-native.yaml) · dbMode `rds` · boundary `global-default-revoke` · HoopDb external · services image RELEASE-OVERLAY · install: `helm install sessions-pipeline agentworkforce/sessions-pipeline -n agent-relay -f profiles/aws-rds-native.yaml -f /approved/private/release-values.yaml`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [Workload identity for the Locker bucket (EKS Pod Identity / GKE Workload Identity)](#req-k8s-workload-identity) | stack | values `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode`, `worker.serviceAccount.annotations`, `alleyoop.serviceAccount.annotations`, `worker.serviceAccount.name`, `alleyoop.serviceAccount.name`, `sessionReadApi.serviceAccountName`, `ingestEdge.serviceAccountName`, `searchIndexer.serviceAccount.name` | aws eks list-pod-identity-associations --cluster-name <c> includes every enabled workload ServiceAccount; the worker, ingest edge and search indexer reach only their required bucket/index resources |
| shipped | [Summary encryption keyring (SUMMARY_MASTER_KEYS)](#req-secret-summary-master-keys) | operator | values `worker.summaryEncryption.existingSecret`, `worker.summaryEncryption.key`, `worker.summaryEncryption.mountPath`, `worker.summaryEncryption.fileName`; env `SUMMARY_MASTER_KEYS_FILE`, `SUMMARY_MASTER_KEYS`; Secret `agent-relay-secrets` keys `SUMMARY_MASTER_KEYS` | kubectl exec deploy/<release>-worker-bob-costas -- test -r /var/run/secrets/sessions-pipeline/summary-master-keys; the Secret key parses as <id>:<64 hex> |
| shipped | [HoopDb connection Secret (HOOPDB_URL)](#req-secret-hoopdb-url) | operator | values `worker.hoopdb.existingSecret`, `worker.hoopdb.key`, `worker.secretKeys.hoopdbUrl`, `alleyoop.hoopdb.existingSecret`, `alleyoop.hoopdb.key`, `alleyoop.secretKeys.hoopdbUrl`; env `HOOPDB_URL`; Secret `agent-relay-secrets` keys `HOOPDB_URL` | psql "$(kubectl get secret agent-relay-secrets -o jsonpath='{.data.HOOPDB_URL}' \| base64 -d \| sed -E 's/&?uselibpqcompat=true//; s/\?&/?/')" -X -c 'select 1' |
| shipped | [Separate migration-owner connection Secret (HOOPDB_MIGRATION_URL)](#req-secret-hoopdb-migration-url) | operator | values `worker.migrations.hoopdb.existingSecret`, `worker.migrations.hoopdb.key`; Secret `agent-relay-secrets` keys `HOOPDB_MIGRATION_URL` | psql "$(kubectl get secret agent-relay-secrets -o jsonpath='{.data.HOOPDB_MIGRATION_URL}' \| base64 -d \| sed -E 's/&?uselibpqcompat=true//; s/\?&/?/')" -Atc 'select current_user' is the RDS master |
| shipped | [Agent Relay org id (TENANT_ORG_ID)](#req-sessions-pipeline-tenant-org-id) | operator | values `global.tenant.orgId`, `worker.tenant.orgId`, `alleyoop.tenant.orgId`; env `TENANT_ORG_ID` | helm template renders (it fails with "tenant.orgId (or global.tenant.orgId) is required" otherwise) |
| shipped | [A RelayAuth JWKS URL reachable from alleyoop](#req-sessions-pipeline-relayauth-jwks) | operator | values `alleyoop.auth.jwksUrl`; env `RELAYAUTH_JWKS_URL` | kubectl run -it --rm curl --image=curlimages/curl -- curl -fsS <jwksUrl> returns {"keys":[...]} |
| shipped | [PostgreSQL 17 with pg_trgm and btree_gin (and vector) available](#req-db-postgres-17-extensions) | operator | values `hoopdb.cluster.imageName`, `hoopdb.cluster.initdb.postInitApplicationSQL` | with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select name from pg_available_extensions where name in ('pg_trgm','btree_gin','vector')" lists all three; server_version_num >= 160000 |
| shipped | [A database dedicated to HoopDb](#req-db-dedicated-database) | operator | values `hoopdb.cluster.initdb.database`, `hoopdb.cluster.initdb.owner` | with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select nspname from pg_namespace where nspname not like 'pg_%' and nspname <> 'information_schema'" shows only HoopDb schemas |
| shipped | [Supabase compatibility roles (anon, authenticated, service_role)](#req-db-compat-roles) | operator | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `worker.migrations.supabaseShim` | with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role')" is 3 |
| shipped | [The session directory search Worker role (session_directory_search_worker)](#req-db-search-worker-role) | operator | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `searchWorkerRole.bootstrapJob.enabled`, `searchWorkerRole.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.role` | the master runs supabase/bootstrap/rds_migration_roles.sql; then, with uselibpqcompat=true removed from the URL (psql rejects it), the same query |
| shipped | [The dedicated HoopDb runtime role (HOOPDB_RUNTIME_ROLE, e.g. sessions_pipeline_runtime)](#req-db-runtime-role) | operator | values `worker.migrations.runtimeRole`, `worker.migrations.runtimeRoleLogin`, `runtimeRole.bootstrapJob.enabled`, `runtimeRole.bootstrapJob.sqlPath`; env `HOOPDB_RUNTIME_ROLE`, `HOOPDB_RUNTIME_ROLE_LOGIN` | with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin from pg_roles where rolname='sessions_pipeline_runtime'" is f\|f\|f\|f\|f\|t; migrate refuses otherwise |
| shipped | [The durable function boundary installed before the first migrate](#req-db-function-boundary) | operator | values `functionDefaultRevoke.bootstrapJob.enabled`, `functionDefaultRevoke.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.functionDefault` | migrate completes; it refuses with function_boundary_unproven unless rds_owner_function_default_revoke.sql has run |
| shipped | [migrate always runs the phase 2 role verify (HOOPDB_ROLE_VERIFY=true)](#req-sessions-pipeline-role-verify) | chart | env `HOOPDB_ROLE_VERIFY` | kubectl get job -l app.kubernetes.io/component=hoopdb-migrate -o yaml shows HOOPDB_ROLE_VERIFY "true"; workloads go ready after migrate |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [alleyoop token verification source](#opt-alleyoop-auth-mode) | `jwksUrl`, `localJwks` | `jwksUrl` | values `alleyoop.auth.jwksUrl`, `alleyoop.auth.localJwks`, `alleyoop.auth.issuer`, `alleyoop.auth.audience`, `alleyoop.secretKeys.jwksJson`; env `RELAYAUTH_JWKS_URL`, `JWKS_JSON`, `AUTH_ISSUER`, `AUTH_AUDIENCE`; Secret `<existingSecret>` keys `JWKS_JSON` (only with auth.localJwks=true) |
| shipped | [Plain http to in-cluster Service FQDNs](#opt-sessions-pipeline-in-cluster-http) | `false`, `true` | `false` | values `alleyoop.allowInClusterHttp`, `worker.allowInClusterHttp`; env `ALLOW_IN_CLUSTER_HTTP` |
| shipped | [CA bundle for verifying the Postgres server certificate (postgresCa)](#opt-postgres-ca-bundle) | `false`, `true` | `true` | values `worker.postgresCa.*`, `alleyoop.postgresCa.*`, `relay-control:postgresCa.*`, `relaychief-control:postgresCa.*`, `relayfile-control:postgresCa.*`; env `NODE_EXTRA_CA_CERTS`, `PGSSLROOTCERT` |
| shipped | [HoopDb backend](#opt-sessions-pipeline-hoopdb-backend) | `cnpg`, `external` | `external` | values `hoopdb.enabled` |
| shipped | [Migrator database mode (HOOPDB_DB_MODE)](#opt-sessions-pipeline-db-mode) | `selfhosted`, `cloudsql`, `rds`, `supabase`, `local` | `rds` | values `worker.migrations.databaseMode`; env `HOOPDB_DB_MODE` |
| shipped | [Function boundary mode (HOOPDB_FUNCTION_BOUNDARY_MODE)](#opt-sessions-pipeline-function-boundary-mode) | `global-default-revoke`, `event-trigger` | `global-default-revoke` | values `worker.migrations.functionBoundaryMode`; env `HOOPDB_FUNCTION_BOUNDARY_MODE`, `HOOPDB_FUNCTION_BOUNDARY_APPROVED` |
| shipped | [Plain-Postgres role shim (HOOPDB_SUPABASE_SHIM)](#opt-sessions-pipeline-supabase-shim) | `true`, `false` | `false` | values `worker.migrations.supabaseShim`; env `HOOPDB_SUPABASE_SHIM` |
| shipped | [Migrator role bootstrap (HOOPDB_ROLE_BOOTSTRAP)](#opt-sessions-pipeline-role-bootstrap) | `true`, `false`, `unset` | (no default) | values `worker.migrations.roleBootstrap`; env `HOOPDB_ROLE_BOOTSTRAP` |
| shipped | [Runtime workload role (HOOPDB_RUNTIME_WORKLOAD_ROLE)](#opt-sessions-pipeline-runtime-workload-role) | `""`, `<role>` | `""` | values `worker.migrations.runtimeWorkloadRole`; env `HOOPDB_RUNTIME_WORKLOAD_ROLE` |
| shipped | [Blocking index build for one migrate run (HOOPDB_ALLOW_BLOCKING_INDEX_BUILD)](#opt-sessions-pipeline-allow-blocking-index-build) | `false`, `true` | `false` | values `worker.migrations.allowBlockingIndexBuild`; env `HOOPDB_ALLOW_BLOCKING_INDEX_BUILD` |
| shipped | [migrate's wait-for-role ordering](#opt-sessions-pipeline-wait-for-role) | `true`, `false` | `false` | values `worker.migrations.waitForRole.enabled`, `worker.migrations.waitForRole.functionDefault`, `worker.migrations.waitForRole.image`, `worker.migrations.waitForRole.intervalSeconds`, `worker.migrations.waitForRole.role` |
| shipped | [Separate migration-owner URL for migrate](#opt-hoopdb-migration-owner-url) | `""`, `<secret>/<key>` | `agent-relay-secrets/HOOPDB_MIGRATION_URL` | values `worker.migrations.hoopdb.existingSecret`, `worker.migrations.hoopdb.key` |
| shipped | [Locker object store](#opt-sessions-pipeline-locker-backend) | `minio`, `external` | `external` | values `session-object-storage.enabled`, `worker.locker.endpoint`, `worker.locker.bucket`, `worker.locker.region`, `alleyoop.locker.endpoint`, `alleyoop.locker.bucket`, `alleyoop.locker.region`, `worker.lockerInit.enabled`; env `LOCKER_ENDPOINT`, `LOCKER_BUCKET`, `LOCKER_REGION` |
| shipped | [Locker credentials mode](#opt-sessions-pipeline-locker-credentials-mode) | `secret`, `podIdentity` | `podIdentity` | values `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode` |
| shipped | [Locker provider (S3-compatible or native GCS)](#opt-sessions-pipeline-locker-provider) | `s3`, `gcs` | `s3` | values `worker.locker.provider`, `alleyoop.locker.provider`, `worker.extraEnv`, `alleyoop.extraEnv`; env `LOCKER_PROVIDER`, `PIPELINE_RAW_PROVIDER`, `CLOUD_SQL_CONNECTION_NAME`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_AUTH_ENABLED`, `REDIS_TRANSIT_ENCRYPTION`, `REDIS_TLS_CA_PEM`, `PUBSUB_TOPIC`, `PUBSUB_SUBSCRIPTION` |
| shipped | [Services image registry](#opt-sessions-pipeline-services-image) | `ghcr`, `ecr`, `release-overlay` | `release-overlay` | values `worker.image.repository`, `worker.image.digest`, `worker.image.tag`, `alleyoop.image.repository`, `alleyoop.image.digest`, `alleyoop.image.tag`, `global.imageRegistry` |
| shipped | [OpenTelemetry export](#opt-sessions-pipeline-otel) | `""`, `<your OTLP endpoint>`, `http://otel-collector:4318` | `""` | values `global.otel.endpoint`, `otel.enabled`, `otel.config.*`; env `OTEL_EXPORTER_OTLP_ENDPOINT` |
| shipped | [Workspace, deployment and environment labels](#opt-sessions-pipeline-deployment-identity) | `<any>` | `workspaceId=default`, `deployment=selfhost`, `environment=production` | values `worker.tenant.workspaceId`, `worker.deployment.name`, `worker.deployment.id`, `worker.environment`, `alleyoop.tenant.workspaceId`, `alleyoop.deployment.name`, `alleyoop.deployment.id`, `alleyoop.environment`; env `WORKSPACE_ID`, `DEPLOYMENT`, `DEPLOYMENT_ID`, `ENVIRONMENT` |
| shipped | [Stage worker health server](#opt-sessions-pipeline-worker-health) | `true`, `false` | `true` | values `worker.workerHealth.*`; env `WORKER_HEALTH_PORT`, `WORKER_UNHEALTHY_AFTER_FAILURES`, `WORKER_MAX_TICK_AGE_MS` |
| shipped | [Bob Costas summariser model (BOB_COSTAS_MODEL)](#opt-sessions-pipeline-bob-costas-model) | `off` | `off` | values `worker.components.bob-costas.env`; env `BOB_COSTAS_MODEL` |
| shipped | [Native model session briefs](#opt-sessions-pipeline-session-briefs) | `false`, `true` | `false` | values `worker.components.session-brief.enabled`, `worker.components.session-brief.replicas`, `worker.nativeBrief.enabled`, `worker.nativeBrief.image.*`, `worker.nativeBrief.workspaceIds`, `worker.nativeBrief.model`, `worker.nativeBrief.baseUrl`, `worker.nativeBrief.allowInClusterHttp`, `worker.nativeBrief.keyPrefix`, `worker.nativeBrief.sweepSeconds`, `worker.nativeBrief.batch`, `worker.nativeBrief.globalDailyCap`, `worker.nativeBrief.sessionDailyCap`, `worker.nativeBrief.openaiEgress.*`, `worker.postgresCa.sha256`; env `SESSION_BRIEF_ENABLED`, `SESSION_BRIEF_CANONICAL_INPUT`, `SESSION_BRIEF_WORKSPACE_IDS`, `SESSION_BRIEF_MODEL`, `SESSION_BRIEF_SWEEP_SECONDS`, `SESSION_BRIEF_BATCH`, `SESSION_BRIEF_GLOBAL_DAILY_CAP`, `SESSION_BRIEF_SESSION_DAILY_CAP`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `OPENAI_BASE_URL` |
| shipped | [Sessions reader ruleset ceiling](#opt-sessions-pipeline-reader-max-ruleset) | (no default), `8`, `9`, `10` | (no default) | values `nativeConsumer.readerMaxRuleset`, `worker.nativeBrief.readerMaxRuleset`, `sessionReadApi.readerMaxRuleset`, `alleyoop.readerMaxRuleset`, `ingestEdge.readerMaxRuleset`; env `READER_MAX_RULESET` |
| shipped | [Shared Sessions scrub engine rollout contract](#opt-sessions-pipeline-scrub-engine) | (no default), `reader-first`, `wasm-bindgen` | (no default) | values `global.scrubEngine.engine`, `global.scrubEngine.required`, `global.scrubEngine.readerMaxRuleset`; env `SCRUB_ENGINE`, `SCRUB_ENGINE_REQUIRED`, `READER_MAX_RULESET` |
| shipped | [Native brief collector analytics adapter](#opt-sessions-pipeline-brief-collector-analytics) | `false`, `true` | `false` | values `worker.nativeBrief.analytics.*`; env `ANALYTICS_SINK`, `ANALYTICS_DEPLOYMENT_ID`, `ANALYTICS_COLLECTOR_URL`, `ANALYTICS_COLLECTOR_TOKEN`, `ANALYTICS_COLLECTOR_CA_FILE`; Secret `<Native brief component-bound analytics producer Secret>` keys `token` |
| shipped | [Default-off native session upload edge](#opt-sessions-native-ingest) | `disabled`, `enabled` | `enabled` | values `ingestEdge.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_INGEST`, `RELAYHISTORY_SELFHOST_SESSION_SELECTION`, `RELAYHISTORY_SELFHOST_HEARTBEAT_ACCEPT`, `RELAYHISTORY_INGEST_PORT`, `RELAYHISTORY_INGEST_ORIGIN`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`, `RELAYHISTORY_INGEST_DATABASE_URL`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYHISTORY_INGEST_PG_POOL_MAX`, `ALLOW_IN_CLUSTER_HTTP`, `LOCKER_PROVIDER`, `LOCKER_BUCKET`, `LOCKER_ENDPOINT`, `LOCKER_REGION`, `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`, `INGEST_KEY_ROOT`, `INGEST_MAX_PER_USER`, `INGEST_MAX_PER_ORG`; Secret `agent-relay-ingest-edge-runtime` keys `database-url`, `introspect-secret`; Secret `<not used: EKS Pod Identity>` keys `access-key-id`, `secret-access-key` |
| shipped | [Default-off self-host session read API container](#opt-sessions-read-api) | `disabled`, `enabled` | `enabled` | values `fullnameOverride`, `replicas`, `image.*`, `imagePullSecrets`, `port`, `probeRuntime`, `origin`, `completeSince`, `directoryWorkspaces`, `login.advertisesSync`, `turns.assumeNoLegacy`, `timing.assumeNoTurns`, `canonical.pinLaggingPointer`, `events.messageIds`, `coordinationOverlaps.enabled`, `serviceAccountCreate`, `allowInClusterHttp`, `config.*`, `postgres.*`, `postgresCa.*`, `search.*`, `auth.*`, `cors.*`, `ingress.*`, `networkPolicy.*`, `extraEnv`, `extraVolumes`, `extraVolumeMounts`, `serviceAccountName`, `nodeSelector`, `tolerations`, `affinity`, `podAnnotations`, `resources`; env `SERVICE`, `RELAYHISTORY_SELFHOST_READ_API`, `RELAYHISTORY_READ_API_PORT`, `RELAYHISTORY_READ_API_SECRET`, `READ_API_ORIGIN`, `READ_API_AUTH_MODE`, `READ_API_COMPLETE_SINCE`, `READ_API_DIRECTORY_WORKSPACES`, `READ_API_CORS_ALLOWED_ORIGINS`, `RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC`, `READ_API_TURNS_ASSUME_NO_LEGACY`, `READ_API_TIMING_ASSUME_NO_TURNS`, `READ_API_CANONICAL_PIN_LAGGING_POINTER`, `READ_API_EVENT_MESSAGE_IDS`, `READ_API_COORDINATION_OVERLAPS_ENABLED`, `READ_API_COORDINATION_OVERLAPS_BACKEND`, `READ_API_INTERNAL_SECRET`, `READ_API_INTERNAL_SECRET_PREVIOUS`, `READ_API_ACCESS_TOKEN_TTL_SECONDS`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `SEARCH_INDEX_BACKEND`, `ALLOW_IN_CLUSTER_HTTP`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYAUTH_JWKS_URL`, `RELAYAUTH_ISSUER`, `RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`; Secret `agent-relay-read-api` keys `RELAYHISTORY_READ_API_SECRET`; Secret `<not used: self-issued auth>` keys `RELAYCONTROL_INTROSPECT_SECRET`; Secret `agent-relay-secrets` keys `session-read-api-secret`; Secret `<not configured>` keys `READ_API_INTERNAL_SECRET_PREVIOUS` |
| shipped | [Default-off self-host transcript search writer](#opt-sessions-search-indexer) | `disabled`, `enabled` | `enabled` | values `searchIndexer.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `LOCKER_BUCKET`, `LOCKER_REGION`, `LOCKER_ENDPOINT`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `WORKER_HEALTH_PORT`; Secret `search-indexer-runtime` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `search-indexer-owner` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` |
| shipped | [Self-host output facts writer and bootstrap Job](#opt-sessions-output-facts) | `disabled`, `enabled` | `enabled` | values `searchIndexer.outputFacts.enabled`, `searchIndexer.outputFacts.bootstrap.*`, `nativeConsumer.outputFacts.enabled`; env `RELAYHISTORY_SELFHOST_OUTPUT_FACTS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_DEADLINE_SECONDS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_ALLOW_PARTIAL` |
| shipped | [Session read API Output and daily digest routes](#opt-sessions-read-api-output-digest) | `disabled`, `enabled` | `enabled` | values `output.enabled`, `digest.enabled`, `digest.narrative.*`; env `READ_API_OUTPUT_ENABLED`, `READ_API_OUTPUT_BACKEND`, `READ_API_DIGEST_ENABLED`, `READ_API_DIGEST_BACKEND`, `READ_API_DIGEST_NARRATIVE_MODEL`, `READ_API_DIGEST_NARRATIVE_DB_URL`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`; Secret `<digest narrative model API key Secret, model only>` keys `OPENAI_API_KEY`; Secret `<digest narrative writer login Secret, model only>` keys `READ_API_DIGEST_NARRATIVE_DB_URL` |
| shipped | [Native ingest claim lock retry response](#opt-sessions-native-ingest-claim-lock-busy) | `true`, `false` | `true` | values `ingestEdge.claimLockBusy`; env `INGEST_CLAIM_LOCK_BUSY` |
| shipped | [Native ingest admission mode](#opt-sessions-native-ingest-admission) | `sync`, `async`, `drain` | `sync` | values `ingestEdge.admission.mode`, `ingestEdge.admission.concurrency`, `ingestEdge.admission.scanIntervalMs`, `ingestEdge.admission.maxAttempts`; env `SELFHOST_INGEST_ADMISSION`, `SELFHOST_ADMISSION_CONCURRENCY`, `SELFHOST_ADMISSION_SCAN_MS`, `SELFHOST_ADMISSION_MAX_ATTEMPTS` |
| shipped | [Retire a legacy Deployment while retaining resources](#opt-legacy-deployment-retirement) | `true`, `false` | `false` | values `deployment.enabled` |
| shipped | [Native direct upload inbox scan](#opt-history-direct-upload-consumer) | `off`, `allowlist`, `on` | `off` | values `ingestEdge.uploadDirect.*`, `ingestEdge.keyRoot`, `ingestEdge.createServiceAccount`; env `HISTORY_UPLOAD_DIRECT`, `HISTORY_UPLOAD_DIRECT_ALLOWLIST`, `SELFHOST_UPLOAD_SCAN_BATCH`, `UPLOAD_WITNESS_KEY`; Secret `<operator-chosen shared upload witness Secret>` keys `upload-witness-key` |
| shipped | [S3 upload ledger for the native ingest (decision 0005)](#opt-sessions-pipeline-s3-ledger) | `sql`, `s3` | `sql` | values `ingestEdge.ledger`; env `INGEST_LEDGER` |
| shipped | [S3 ledger re-arm sweeper CronJob](#opt-sessions-pipeline-rearm-sweeper) | `false`, `true` | `false` | values `rearmSweeper.*`; env `INGEST_REARM_SWEEPER_ENABLED`, `INGEST_REARM_BUCKET`, `INGEST_REARM_REGION`, `INGEST_REARM_ENDPOINT`, `INGEST_REARM_KEY_ROOT`, `INGEST_REARM_ORGS`, `INGEST_REARM_DRY_RUN`, `INGEST_REARM_CONCURRENCY`, `INGEST_REARM_MAX_MARKERS`, `INGEST_REARM_CREDENTIALS`, `INGEST_REARM_S3_ACCESS_KEY_ID_FILE`, `INGEST_REARM_S3_SECRET_ACCESS_KEY_FILE`; Secret `<dedicated re-arm sweeper S3 Secret>` keys `access-key-id`, `secret-access-key` |

### Profile: external-supabase

**External Supabase project as HoopDb (fail-closed).** Held by supabaseActivation.hold until the pinned image is confirmed as the production-Supabase pin and the live Supabase activation steps are approved. No shim, no wait-for-role, no privileged Jobs.

chart `sessions-pipeline` · values [`profiles/external-supabase.yaml`](../charts/sessions-pipeline/profiles/external-supabase.yaml) · dbMode `supabase` · boundary `event-trigger` · HoopDb external · services image GHCR · install: `helm install sessions-pipeline agentworkforce/sessions-pipeline -f profiles/external-supabase.yaml --set global.tenant.orgId=<org> --set alleyoop.auth.jwksUrl=<jwks url> --set supabaseActivation.hold=false`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [External Secrets Operator and a ClusterSecretStore (only with externalSecrets.enabled)](#req-k8s-external-secrets-operator) | operator | values `sessions-pipeline-worker:externalSecrets.*`, `session-ingest-api:externalSecrets.*` | kubectl get crd externalsecrets.external-secrets.io && kubectl get clustersecretstore <name>; the ExternalSecret reports Ready |
| shipped | [Pull Secret for the private GHCR services image](#req-secret-image-pull) | operator | values `worker.imagePullSecrets`, `alleyoop.imagePullSecrets`; Secret `<pull secret>` (type kubernetes.io/dockerconfigjson with read access to ghcr.io/agentworkforce/96bulls-services) | kubectl get secret <pull secret> -o jsonpath='{.type}' is kubernetes.io/dockerconfigjson; pods are not ImagePullBackOff |
| shipped | [Locker credential Secret (MinIO root / S3 static keys)](#req-secret-locker-credentials) | operator | values `worker.existingSecret`, `alleyoop.existingSecret`, `session-object-storage.existingSecret`, `worker.secretKeys.lockerAccessKeyId`, `worker.secretKeys.lockerSecretAccessKey`, `alleyoop.secretKeys.lockerAccessKeyId`, `alleyoop.secretKeys.lockerSecretAccessKey`; env `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`; Secret `sessions-pipeline-locker` keys `rootUser`, `rootPassword`; Secret `sessions-pipeline-locker` (the bundled upstream MinIO requires literal Secret data keys rootUser and rootPassword) | kubectl get secret sessions-pipeline-locker -o jsonpath='{.data}' has rootUser and rootPassword |
| shipped | [Summary encryption keyring (SUMMARY_MASTER_KEYS)](#req-secret-summary-master-keys) | operator | values `worker.summaryEncryption.existingSecret`, `worker.summaryEncryption.key`, `worker.summaryEncryption.mountPath`, `worker.summaryEncryption.fileName`; env `SUMMARY_MASTER_KEYS_FILE`, `SUMMARY_MASTER_KEYS`; Secret `sessions-pipeline-locker` keys `SUMMARY_MASTER_KEYS` | kubectl exec deploy/<release>-worker-bob-costas -- test -r /var/run/secrets/sessions-pipeline/summary-master-keys; the Secret key parses as <id>:<64 hex> |
| shipped | [HoopDb connection Secret (HOOPDB_URL)](#req-secret-hoopdb-url) | operator | values `worker.hoopdb.existingSecret`, `worker.hoopdb.key`, `worker.secretKeys.hoopdbUrl`, `alleyoop.hoopdb.existingSecret`, `alleyoop.hoopdb.key`, `alleyoop.secretKeys.hoopdbUrl`; env `HOOPDB_URL`; Secret `sessions-pipeline-hoopdb` keys `HOOPDB_URL` | kubectl get secret sessions-pipeline-hoopdb -o jsonpath='{.data.HOOPDB_URL}' \| base64 -d \| psql -X -c 'select current_user' |
| shipped | [Agent Relay org id (TENANT_ORG_ID)](#req-sessions-pipeline-tenant-org-id) | operator | values `global.tenant.orgId`, `worker.tenant.orgId`, `alleyoop.tenant.orgId`; env `TENANT_ORG_ID` | helm template renders (it fails with "tenant.orgId (or global.tenant.orgId) is required" otherwise) |
| shipped | [A RelayAuth JWKS URL reachable from alleyoop](#req-sessions-pipeline-relayauth-jwks) | operator | values `alleyoop.auth.jwksUrl`; env `RELAYAUTH_JWKS_URL` | kubectl run -it --rm curl --image=curlimages/curl -- curl -fsS <jwksUrl> returns {"keys":[...]} |
| shipped | [PostgreSQL 17 with pg_trgm and btree_gin (and vector) available](#req-db-postgres-17-extensions) | operator | values `hoopdb.cluster.imageName`, `hoopdb.cluster.initdb.postInitApplicationSQL` | psql "$HOOPDB_URL" -Atc "select name from pg_available_extensions where name in ('pg_trgm','btree_gin','vector')" lists all three; server_version_num >= 170000 |
| shipped | [Supabase compatibility roles (anon, authenticated, service_role)](#req-db-compat-roles) | operator | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `worker.migrations.supabaseShim` | psql "$HOOPDB_URL" -Atc "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role')" is 3 |
| shipped | [The session directory search Worker role (session_directory_search_worker)](#req-db-search-worker-role) | operator | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `searchWorkerRole.bootstrapJob.enabled`, `searchWorkerRole.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.role` | run supabase/bootstrap/session_directory_search_worker_supabase.sql as postgres; then the same query |
| shipped | [The dedicated HoopDb runtime role (HOOPDB_RUNTIME_ROLE, e.g. sessions_pipeline_runtime)](#req-db-runtime-role) | operator | values `worker.migrations.runtimeRole`, `worker.migrations.runtimeRoleLogin`, `runtimeRole.bootstrapJob.enabled`, `runtimeRole.bootstrapJob.sqlPath`; env `HOOPDB_RUNTIME_ROLE`, `HOOPDB_RUNTIME_ROLE_LOGIN` | psql "$HOOPDB_URL" -Atc "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin from pg_roles where rolname='sessions_pipeline_runtime'" is f\|f\|f\|f\|f\|t; migrate refuses otherwise |
| shipped | [The durable function boundary installed before the first migrate](#req-db-function-boundary) | operator | values `functionDefaultRevoke.bootstrapJob.enabled`, `functionDefaultRevoke.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.functionDefault` | migrate.ts --activation-check with HOOPDB_DB_MODE=supabase HOOPDB_FUNCTION_BOUNDARY_MODE=event-trigger reports event_trigger.verified true |
| shipped | [migrate always runs the phase 2 role verify (HOOPDB_ROLE_VERIFY=true)](#req-sessions-pipeline-role-verify) | chart | env `HOOPDB_ROLE_VERIFY` | kubectl get job -l app.kubernetes.io/component=hoopdb-migrate -o yaml shows HOOPDB_ROLE_VERIFY "true"; workloads go ready after migrate |
| shipped | [Model API key Secret for session briefs (OPENAI_API_KEY)](#req-secret-model-api-key) | operator | values `worker.nativeBrief.openaiSecret`, `worker.nativeBrief.openaiSecret.name`, `worker.nativeBrief.openaiSecret.key`; env `OPENAI_API_KEY`; Secret `<model key Secret>` keys `OPENAI_API_KEY` | A worker Pod references the chosen Secret/key; the init container does not. Verify an actual model result separately. |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [alleyoop token verification source](#opt-alleyoop-auth-mode) | `jwksUrl`, `localJwks` | `jwksUrl` | values `alleyoop.auth.jwksUrl`, `alleyoop.auth.localJwks`, `alleyoop.auth.issuer`, `alleyoop.auth.audience`, `alleyoop.secretKeys.jwksJson`; env `RELAYAUTH_JWKS_URL`, `JWKS_JSON`, `AUTH_ISSUER`, `AUTH_AUDIENCE`; Secret `<existingSecret>` keys `JWKS_JSON` (only with auth.localJwks=true) |
| shipped | [Plain http to in-cluster Service FQDNs](#opt-sessions-pipeline-in-cluster-http) | `false`, `true` | `false` | values `alleyoop.allowInClusterHttp`, `worker.allowInClusterHttp`; env `ALLOW_IN_CLUSTER_HTTP` |
| shipped | [CA bundle for verifying the Postgres server certificate (postgresCa)](#opt-postgres-ca-bundle) | `false`, `true` | `false` | values `worker.postgresCa.*`, `alleyoop.postgresCa.*`, `relay-control:postgresCa.*`, `relaychief-control:postgresCa.*`, `relayfile-control:postgresCa.*`; env `NODE_EXTRA_CA_CERTS`, `PGSSLROOTCERT` |
| shipped | [RelayHistory origin expected by the ingest](#opt-alleyoop-history-origin) | `unset`, `origin` | `unset` | values `alleyoop.auth.historyOrigin`; env `RELAYHISTORY_ORIGIN` |
| shipped | [Interim RelayAuth bearer compatibility (local only)](#opt-alleyoop-interim-relayauth-bearer) | `false`, `true` | `false` | values `alleyoop.auth.allowInterimRelayAuthBearer`; env `ALLOW_INTERIM_RELAYAUTH_BEARER` |
| shipped | [HoopDb backend](#opt-sessions-pipeline-hoopdb-backend) | `cnpg`, `external` | `external` | values `hoopdb.enabled` |
| shipped | [Migrator database mode (HOOPDB_DB_MODE)](#opt-sessions-pipeline-db-mode) | `selfhosted`, `cloudsql`, `rds`, `supabase`, `local` | `supabase` | values `worker.migrations.databaseMode`; env `HOOPDB_DB_MODE` |
| shipped | [Function boundary mode (HOOPDB_FUNCTION_BOUNDARY_MODE)](#opt-sessions-pipeline-function-boundary-mode) | `global-default-revoke`, `event-trigger` | `event-trigger` | values `worker.migrations.functionBoundaryMode`; env `HOOPDB_FUNCTION_BOUNDARY_MODE`, `HOOPDB_FUNCTION_BOUNDARY_APPROVED` |
| shipped | [Plain-Postgres role shim (HOOPDB_SUPABASE_SHIM)](#opt-sessions-pipeline-supabase-shim) | `true`, `false` | `false` | values `worker.migrations.supabaseShim`; env `HOOPDB_SUPABASE_SHIM` |
| shipped | [Migrator role bootstrap (HOOPDB_ROLE_BOOTSTRAP)](#opt-sessions-pipeline-role-bootstrap) | `true`, `false`, `unset` | (no default) | values `worker.migrations.roleBootstrap`; env `HOOPDB_ROLE_BOOTSTRAP` |
| shipped | [Runtime workload role (HOOPDB_RUNTIME_WORKLOAD_ROLE)](#opt-sessions-pipeline-runtime-workload-role) | `""`, `<role>` | `""` | values `worker.migrations.runtimeWorkloadRole`; env `HOOPDB_RUNTIME_WORKLOAD_ROLE` |
| shipped | [Blocking index build for one migrate run (HOOPDB_ALLOW_BLOCKING_INDEX_BUILD)](#opt-sessions-pipeline-allow-blocking-index-build) | `false`, `true` | `false` | values `worker.migrations.allowBlockingIndexBuild`; env `HOOPDB_ALLOW_BLOCKING_INDEX_BUILD` |
| shipped | [migrate's wait-for-role ordering](#opt-sessions-pipeline-wait-for-role) | `true`, `false` | `false` | values `worker.migrations.waitForRole.enabled`, `worker.migrations.waitForRole.functionDefault`, `worker.migrations.waitForRole.image`, `worker.migrations.waitForRole.intervalSeconds`, `worker.migrations.waitForRole.role` |
| shipped | [External-Supabase activation hold](#opt-sessions-pipeline-supabase-activation-hold) | `true`, `false` | `true` | values `supabaseActivation.hold` |
| shipped | [Separate migration-owner URL for migrate](#opt-hoopdb-migration-owner-url) | `""`, `<secret>/<key>` | `""` | values `worker.migrations.hoopdb.existingSecret`, `worker.migrations.hoopdb.key` |
| shipped | [Locker object store](#opt-sessions-pipeline-locker-backend) | `minio`, `external` | `minio` | values `session-object-storage.enabled`, `worker.locker.endpoint`, `worker.locker.bucket`, `worker.locker.region`, `alleyoop.locker.endpoint`, `alleyoop.locker.bucket`, `alleyoop.locker.region`, `worker.lockerInit.enabled`; env `LOCKER_ENDPOINT`, `LOCKER_BUCKET`, `LOCKER_REGION` |
| shipped | [Locker credentials mode](#opt-sessions-pipeline-locker-credentials-mode) | `secret`, `podIdentity` | `secret` | values `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode` |
| shipped | [Locker provider (S3-compatible or native GCS)](#opt-sessions-pipeline-locker-provider) | `s3`, `gcs` | `s3` | values `worker.locker.provider`, `alleyoop.locker.provider`, `worker.extraEnv`, `alleyoop.extraEnv`; env `LOCKER_PROVIDER`, `PIPELINE_RAW_PROVIDER`, `CLOUD_SQL_CONNECTION_NAME`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_AUTH_ENABLED`, `REDIS_TRANSIT_ENCRYPTION`, `REDIS_TLS_CA_PEM`, `PUBSUB_TOPIC`, `PUBSUB_SUBSCRIPTION` |
| shipped | [Services image registry](#opt-sessions-pipeline-services-image) | `ghcr`, `ecr`, `release-overlay` | `ghcr` | values `worker.image.repository`, `worker.image.digest`, `worker.image.tag`, `alleyoop.image.repository`, `alleyoop.image.digest`, `alleyoop.image.tag`, `global.imageRegistry` |
| shipped | [OpenTelemetry export](#opt-sessions-pipeline-otel) | `""`, `<your OTLP endpoint>`, `http://otel-collector:4318` | `""` | values `global.otel.endpoint`, `otel.enabled`, `otel.config.*`; env `OTEL_EXPORTER_OTLP_ENDPOINT` |
| shipped | [Workspace, deployment and environment labels](#opt-sessions-pipeline-deployment-identity) | `<any>` | `workspaceId=default`, `deployment=selfhost`, `environment=production` | values `worker.tenant.workspaceId`, `worker.deployment.name`, `worker.deployment.id`, `worker.environment`, `alleyoop.tenant.workspaceId`, `alleyoop.deployment.name`, `alleyoop.deployment.id`, `alleyoop.environment`; env `WORKSPACE_ID`, `DEPLOYMENT`, `DEPLOYMENT_ID`, `ENVIRONMENT` |
| shipped | [Stage worker health server](#opt-sessions-pipeline-worker-health) | `true`, `false` | `true` | values `worker.workerHealth.*`; env `WORKER_HEALTH_PORT`, `WORKER_UNHEALTHY_AFTER_FAILURES`, `WORKER_MAX_TICK_AGE_MS` |
| shipped | [Bob Costas summariser model (BOB_COSTAS_MODEL)](#opt-sessions-pipeline-bob-costas-model) | `off` | `off` | values `worker.components.bob-costas.env`; env `BOB_COSTAS_MODEL` |
| **planned** | [Transcript search backend (search.backend)](#opt-sessions-pipeline-search-backend) | `postgres`, `clickhouse` (**planned**) | `postgres` | values `search.backend`, `search.clickhouse.*` |
| shipped | [Native model session briefs](#opt-sessions-pipeline-session-briefs) | `false`, `true` | `false` | values `worker.components.session-brief.enabled`, `worker.components.session-brief.replicas`, `worker.nativeBrief.enabled`, `worker.nativeBrief.image.*`, `worker.nativeBrief.workspaceIds`, `worker.nativeBrief.model`, `worker.nativeBrief.baseUrl`, `worker.nativeBrief.allowInClusterHttp`, `worker.nativeBrief.keyPrefix`, `worker.nativeBrief.sweepSeconds`, `worker.nativeBrief.batch`, `worker.nativeBrief.globalDailyCap`, `worker.nativeBrief.sessionDailyCap`, `worker.nativeBrief.openaiEgress.*`, `worker.postgresCa.sha256`; env `SESSION_BRIEF_ENABLED`, `SESSION_BRIEF_CANONICAL_INPUT`, `SESSION_BRIEF_WORKSPACE_IDS`, `SESSION_BRIEF_MODEL`, `SESSION_BRIEF_SWEEP_SECONDS`, `SESSION_BRIEF_BATCH`, `SESSION_BRIEF_GLOBAL_DAILY_CAP`, `SESSION_BRIEF_SESSION_DAILY_CAP`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `OPENAI_BASE_URL` |
| shipped | [Sessions reader ruleset ceiling](#opt-sessions-pipeline-reader-max-ruleset) | (no default), `8`, `9`, `10` | (no default) | values `nativeConsumer.readerMaxRuleset`, `worker.nativeBrief.readerMaxRuleset`, `sessionReadApi.readerMaxRuleset`, `alleyoop.readerMaxRuleset`, `ingestEdge.readerMaxRuleset`; env `READER_MAX_RULESET` |
| shipped | [Shared Sessions scrub engine rollout contract](#opt-sessions-pipeline-scrub-engine) | (no default), `reader-first`, `wasm-bindgen` | (no default) | values `global.scrubEngine.engine`, `global.scrubEngine.required`, `global.scrubEngine.readerMaxRuleset`; env `SCRUB_ENGINE`, `SCRUB_ENGINE_REQUIRED`, `READER_MAX_RULESET` |
| shipped | [Native brief collector analytics adapter](#opt-sessions-pipeline-brief-collector-analytics) | `false`, `true` | `false` | values `worker.nativeBrief.analytics.*`; env `ANALYTICS_SINK`, `ANALYTICS_DEPLOYMENT_ID`, `ANALYTICS_COLLECTOR_URL`, `ANALYTICS_COLLECTOR_TOKEN`, `ANALYTICS_COLLECTOR_CA_FILE`; Secret `<Native brief component-bound analytics producer Secret>` keys `token` |
| shipped | [Default-off native session upload edge](#opt-sessions-native-ingest) | `disabled`, `enabled` | `disabled` | values `ingestEdge.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_INGEST`, `RELAYHISTORY_SELFHOST_SESSION_SELECTION`, `RELAYHISTORY_SELFHOST_HEARTBEAT_ACCEPT`, `RELAYHISTORY_INGEST_PORT`, `RELAYHISTORY_INGEST_ORIGIN`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`, `RELAYHISTORY_INGEST_DATABASE_URL`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYHISTORY_INGEST_PG_POOL_MAX`, `ALLOW_IN_CLUSTER_HTTP`, `LOCKER_PROVIDER`, `LOCKER_BUCKET`, `LOCKER_ENDPOINT`, `LOCKER_REGION`, `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`, `INGEST_KEY_ROOT`, `INGEST_MAX_PER_USER`, `INGEST_MAX_PER_ORG`; Secret `<native ingest runtime Secret>` keys `database-url`, `introspect-secret`; Secret `<native ingest object-store Secret>` keys `access-key-id`, `secret-access-key` |
| shipped | [Default-off self-host session read API container](#opt-sessions-read-api) | `disabled`, `enabled` | `disabled` | values `fullnameOverride`, `replicas`, `image.*`, `imagePullSecrets`, `port`, `probeRuntime`, `origin`, `completeSince`, `directoryWorkspaces`, `login.advertisesSync`, `turns.assumeNoLegacy`, `timing.assumeNoTurns`, `canonical.pinLaggingPointer`, `events.messageIds`, `coordinationOverlaps.enabled`, `serviceAccountCreate`, `allowInClusterHttp`, `config.*`, `postgres.*`, `postgresCa.*`, `search.*`, `auth.*`, `cors.*`, `ingress.*`, `networkPolicy.*`, `extraEnv`, `extraVolumes`, `extraVolumeMounts`, `serviceAccountName`, `nodeSelector`, `tolerations`, `affinity`, `podAnnotations`, `resources`; env `SERVICE`, `RELAYHISTORY_SELFHOST_READ_API`, `RELAYHISTORY_READ_API_PORT`, `RELAYHISTORY_READ_API_SECRET`, `READ_API_ORIGIN`, `READ_API_AUTH_MODE`, `READ_API_COMPLETE_SINCE`, `READ_API_DIRECTORY_WORKSPACES`, `READ_API_CORS_ALLOWED_ORIGINS`, `RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC`, `READ_API_TURNS_ASSUME_NO_LEGACY`, `READ_API_TIMING_ASSUME_NO_TURNS`, `READ_API_CANONICAL_PIN_LAGGING_POINTER`, `READ_API_EVENT_MESSAGE_IDS`, `READ_API_COORDINATION_OVERLAPS_ENABLED`, `READ_API_COORDINATION_OVERLAPS_BACKEND`, `READ_API_INTERNAL_SECRET`, `READ_API_INTERNAL_SECRET_PREVIOUS`, `READ_API_ACCESS_TOKEN_TTL_SECONDS`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `SEARCH_INDEX_BACKEND`, `ALLOW_IN_CLUSTER_HTTP`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYAUTH_JWKS_URL`, `RELAYAUTH_ISSUER`, `RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API configuration Secret>` keys `RELAYHISTORY_READ_API_SECRET`; Secret `<read API introspection Secret>` keys `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API internal Secret>` keys `READ_API_INTERNAL_SECRET`; Secret `<read API previous internal Secret>` keys `READ_API_INTERNAL_SECRET_PREVIOUS` |
| shipped | [Default-off self-host transcript search writer](#opt-sessions-search-indexer) | `disabled`, `enabled` | `disabled` | values `searchIndexer.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `LOCKER_BUCKET`, `LOCKER_REGION`, `LOCKER_ENDPOINT`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `WORKER_HEALTH_PORT`; Secret `<search indexer configuration Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<search indexer bootstrap Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` |
| shipped | [Self-host output facts writer and bootstrap Job](#opt-sessions-output-facts) | `disabled`, `enabled` | `disabled` | values `searchIndexer.outputFacts.enabled`, `searchIndexer.outputFacts.bootstrap.*`, `nativeConsumer.outputFacts.enabled`; env `RELAYHISTORY_SELFHOST_OUTPUT_FACTS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_DEADLINE_SECONDS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_ALLOW_PARTIAL` |
| shipped | [Session read API Output and daily digest routes](#opt-sessions-read-api-output-digest) | `disabled`, `enabled` | `disabled` | values `output.enabled`, `digest.enabled`, `digest.narrative.*`; env `READ_API_OUTPUT_ENABLED`, `READ_API_OUTPUT_BACKEND`, `READ_API_DIGEST_ENABLED`, `READ_API_DIGEST_BACKEND`, `READ_API_DIGEST_NARRATIVE_MODEL`, `READ_API_DIGEST_NARRATIVE_DB_URL`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`; Secret `<digest narrative model API key Secret, model only>` keys `OPENAI_API_KEY`; Secret `<digest narrative writer login Secret, model only>` keys `READ_API_DIGEST_NARRATIVE_DB_URL` |
| shipped | [Native ingest claim lock retry response](#opt-sessions-native-ingest-claim-lock-busy) | `true`, `false` | `true` | values `ingestEdge.claimLockBusy`; env `INGEST_CLAIM_LOCK_BUSY` |
| shipped | [Native ingest admission mode](#opt-sessions-native-ingest-admission) | `sync`, `async`, `drain` | `sync` | values `ingestEdge.admission.mode`, `ingestEdge.admission.concurrency`, `ingestEdge.admission.scanIntervalMs`, `ingestEdge.admission.maxAttempts`; env `SELFHOST_INGEST_ADMISSION`, `SELFHOST_ADMISSION_CONCURRENCY`, `SELFHOST_ADMISSION_SCAN_MS`, `SELFHOST_ADMISSION_MAX_ATTEMPTS` |
| shipped | [Native direct upload inbox scan](#opt-history-direct-upload-consumer) | `off`, `allowlist`, `on` | `off` | values `ingestEdge.uploadDirect.*`, `ingestEdge.keyRoot`, `ingestEdge.createServiceAccount`; env `HISTORY_UPLOAD_DIRECT`, `HISTORY_UPLOAD_DIRECT_ALLOWLIST`, `SELFHOST_UPLOAD_SCAN_BATCH`, `UPLOAD_WITNESS_KEY`; Secret `<operator-chosen shared upload witness Secret>` keys `upload-witness-key` |
| shipped | [S3 upload ledger for the native ingest (decision 0005)](#opt-sessions-pipeline-s3-ledger) | `sql`, `s3` | `sql` | values `ingestEdge.ledger`; env `INGEST_LEDGER` |
| shipped | [S3 ledger re-arm sweeper CronJob](#opt-sessions-pipeline-rearm-sweeper) | `false`, `true` | `false` | values `rearmSweeper.*`; env `INGEST_REARM_SWEEPER_ENABLED`, `INGEST_REARM_BUCKET`, `INGEST_REARM_REGION`, `INGEST_REARM_ENDPOINT`, `INGEST_REARM_KEY_ROOT`, `INGEST_REARM_ORGS`, `INGEST_REARM_DRY_RUN`, `INGEST_REARM_CONCURRENCY`, `INGEST_REARM_MAX_MARKERS`, `INGEST_REARM_CREDENTIALS`, `INGEST_REARM_S3_ACCESS_KEY_ID_FILE`, `INGEST_REARM_S3_SECRET_ACCESS_KEY_FILE`; Secret `<dedicated re-arm sweeper S3 Secret>` keys `access-key-id`, `secret-access-key` |

### Profile: aws-cnpg

**AWS EKS proof stage, in-cluster CNPG HoopDb, S3 Locker via Pod Identity.** The stacks/aws/eks.ts shape with hoopdb backend cnpg (isolated proof and sandbox stages only). ECR image, S3 bucket through EKS Pod Identity, bundled OTel collector.

chart `sessions-pipeline` · values [`ci/aws-cnpg-values.yaml`](../charts/sessions-pipeline/ci/aws-cnpg-values.yaml) · dbMode `selfhosted` · boundary `global-default-revoke` · HoopDb cnpg · services image ECR

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [CloudNativePG operator installed](#req-k8s-cnpg-operator) | stack | values `hoopdb.enabled` | kubectl get crd clusters.postgresql.cnpg.io && kubectl get deploy -A -l app.kubernetes.io/name=cloudnative-pg |
| shipped | [A default StorageClass for the in-cluster HoopDb and Locker volumes](#req-k8s-storage) | stack | values `hoopdb.cluster.storage.size`, `session-object-storage.persistence.size` | kubectl get storageclass (one marked default), then kubectl get pvc -n <ns> all Bound |
| shipped | [Workload identity for the Locker bucket (EKS Pod Identity / GKE Workload Identity)](#req-k8s-workload-identity) | stack | values `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode`, `worker.serviceAccount.annotations`, `alleyoop.serviceAccount.annotations`, `worker.serviceAccount.name`, `alleyoop.serviceAccount.name`, `sessionReadApi.serviceAccountName`, `ingestEdge.serviceAccountName`, `searchIndexer.serviceAccount.name` | aws eks list-pod-identity-associations --cluster-name <c> includes every enabled workload ServiceAccount; the worker, ingest edge and search indexer reach only their required bucket/index resources |
| shipped | [External Secrets Operator and a ClusterSecretStore (only with externalSecrets.enabled)](#req-k8s-external-secrets-operator) | operator | values `sessions-pipeline-worker:externalSecrets.*`, `session-ingest-api:externalSecrets.*` | kubectl get crd externalsecrets.external-secrets.io && kubectl get clustersecretstore <name>; the ExternalSecret reports Ready |
| shipped | [Summary encryption keyring (SUMMARY_MASTER_KEYS)](#req-secret-summary-master-keys) | stack | values `worker.summaryEncryption.existingSecret`, `worker.summaryEncryption.key`, `worker.summaryEncryption.mountPath`, `worker.summaryEncryption.fileName`; env `SUMMARY_MASTER_KEYS_FILE`, `SUMMARY_MASTER_KEYS`; Secret `96bulls-runtime` keys `SUMMARY_MASTER_KEYS` | kubectl exec deploy/<release>-worker-bob-costas -- test -r /var/run/secrets/sessions-pipeline/summary-master-keys; the Secret key parses as <id>:<64 hex> |
| shipped | [HoopDb connection Secret (HOOPDB_URL)](#req-secret-hoopdb-url) | chart | values `worker.hoopdb.existingSecret`, `worker.hoopdb.key`, `worker.secretKeys.hoopdbUrl`, `alleyoop.hoopdb.existingSecret`, `alleyoop.hoopdb.key`, `alleyoop.secretKeys.hoopdbUrl`; env `HOOPDB_URL`; Secret `hoopdb-app` keys `uri` | kubectl get secret hoopdb-app -o jsonpath='{.data.uri}' is non-empty once the CNPG Cluster is ready |
| shipped | [Agent Relay org id (TENANT_ORG_ID)](#req-sessions-pipeline-tenant-org-id) | operator | values `global.tenant.orgId`, `worker.tenant.orgId`, `alleyoop.tenant.orgId`; env `TENANT_ORG_ID` | helm template renders (it fails with "tenant.orgId (or global.tenant.orgId) is required" otherwise) |
| shipped | [A RelayAuth JWKS URL reachable from alleyoop](#req-sessions-pipeline-relayauth-jwks) | operator | values `alleyoop.auth.jwksUrl`; env `RELAYAUTH_JWKS_URL` | kubectl run -it --rm curl --image=curlimages/curl -- curl -fsS <jwksUrl> returns {"keys":[...]} |
| shipped | [PostgreSQL 17 with pg_trgm and btree_gin (and vector) available](#req-db-postgres-17-extensions) | chart | values `hoopdb.cluster.imageName`, `hoopdb.cluster.initdb.postInitApplicationSQL` | psql "$HOOPDB_URL" -Atc "select name from pg_available_extensions where name in ('pg_trgm','btree_gin','vector')" lists all three; server_version_num >= 170000 |
| shipped | [A database dedicated to HoopDb](#req-db-dedicated-database) | chart | values `hoopdb.cluster.initdb.database`, `hoopdb.cluster.initdb.owner` | psql "$HOOPDB_URL" -Atc "select nspname from pg_namespace where nspname not like 'pg_%' and nspname <> 'information_schema'" shows only HoopDb schemas |
| shipped | [Supabase compatibility roles (anon, authenticated, service_role)](#req-db-compat-roles) | chart | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `worker.migrations.supabaseShim` | psql "$HOOPDB_URL" -Atc "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role')" is 3 |
| shipped | [The session directory search Worker role (session_directory_search_worker)](#req-db-search-worker-role) | chart | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `searchWorkerRole.bootstrapJob.enabled`, `searchWorkerRole.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.role` | psql "$HOOPDB_URL" -Atc "select rolcanlogin, rolconfig from pg_roles where rolname='session_directory_search_worker'" is f\|{statement_timeout=2s} |
| shipped | [The dedicated HoopDb runtime role (HOOPDB_RUNTIME_ROLE, e.g. sessions_pipeline_runtime)](#req-db-runtime-role) | chart | values `worker.migrations.runtimeRole`, `worker.migrations.runtimeRoleLogin`, `runtimeRole.bootstrapJob.enabled`, `runtimeRole.bootstrapJob.sqlPath`; env `HOOPDB_RUNTIME_ROLE`, `HOOPDB_RUNTIME_ROLE_LOGIN` | psql "$HOOPDB_URL" -Atc "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin from pg_roles where rolname='sessions_pipeline_runtime'" is f\|f\|f\|f\|f\|t; migrate refuses otherwise |
| shipped | [The durable function boundary installed before the first migrate](#req-db-function-boundary) | chart | values `functionDefaultRevoke.bootstrapJob.enabled`, `functionDefaultRevoke.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.functionDefault` | the function-default Job completes and migrate's wait-for-role logs "present: ... + owner function default" |
| shipped | [The services image digest for the privileged SQL Jobs](#req-sessions-pipeline-privileged-sql-image) | chart | values `privilegedSql.sqlImage.repository`, `privilegedSql.sqlImage.digest`, `searchWorkerRole.bootstrapJob.sqlImage.*`, `runtimeRole.bootstrapJob.sqlImage.*`, `functionDefaultRevoke.bootstrapJob.sqlImage.*` | helm template renders (it fails with "sqlImage.repository and .digest are required" otherwise); ci/sessions-pipeline-profiles/matrix.sh asserts the image |
| shipped | [migrate always runs the phase 2 role verify (HOOPDB_ROLE_VERIFY=true)](#req-sessions-pipeline-role-verify) | chart | env `HOOPDB_ROLE_VERIFY` | kubectl get job -l app.kubernetes.io/component=hoopdb-migrate -o yaml shows HOOPDB_ROLE_VERIFY "true"; workloads go ready after migrate |
| shipped | [Model API key Secret for session briefs (OPENAI_API_KEY)](#req-secret-model-api-key) | operator | values `worker.nativeBrief.openaiSecret`, `worker.nativeBrief.openaiSecret.name`, `worker.nativeBrief.openaiSecret.key`; env `OPENAI_API_KEY`; Secret `<model key Secret>` keys `OPENAI_API_KEY` | A worker Pod references the chosen Secret/key; the init container does not. Verify an actual model result separately. |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [alleyoop token verification source](#opt-alleyoop-auth-mode) | `jwksUrl`, `localJwks` | `jwksUrl` | values `alleyoop.auth.jwksUrl`, `alleyoop.auth.localJwks`, `alleyoop.auth.issuer`, `alleyoop.auth.audience`, `alleyoop.secretKeys.jwksJson`; env `RELAYAUTH_JWKS_URL`, `JWKS_JSON`, `AUTH_ISSUER`, `AUTH_AUDIENCE`; Secret `<existingSecret>` keys `JWKS_JSON` (only with auth.localJwks=true) |
| shipped | [Plain http to in-cluster Service FQDNs](#opt-sessions-pipeline-in-cluster-http) | `false`, `true` | `false` | values `alleyoop.allowInClusterHttp`, `worker.allowInClusterHttp`; env `ALLOW_IN_CLUSTER_HTTP` |
| shipped | [CA bundle for verifying the Postgres server certificate (postgresCa)](#opt-postgres-ca-bundle) | `false`, `true` | `false` | values `worker.postgresCa.*`, `alleyoop.postgresCa.*`, `relay-control:postgresCa.*`, `relaychief-control:postgresCa.*`, `relayfile-control:postgresCa.*`; env `NODE_EXTRA_CA_CERTS`, `PGSSLROOTCERT` |
| shipped | [RelayHistory origin expected by the ingest](#opt-alleyoop-history-origin) | `unset`, `origin` | `unset` | values `alleyoop.auth.historyOrigin`; env `RELAYHISTORY_ORIGIN` |
| shipped | [Interim RelayAuth bearer compatibility (local only)](#opt-alleyoop-interim-relayauth-bearer) | `false`, `true` | `false` | values `alleyoop.auth.allowInterimRelayAuthBearer`; env `ALLOW_INTERIM_RELAYAUTH_BEARER` |
| shipped | [HoopDb backend](#opt-sessions-pipeline-hoopdb-backend) | `cnpg`, `external` | `cnpg` | values `hoopdb.enabled` |
| shipped | [Migrator database mode (HOOPDB_DB_MODE)](#opt-sessions-pipeline-db-mode) | `selfhosted`, `cloudsql`, `rds`, `supabase`, `local` | `selfhosted` | values `worker.migrations.databaseMode`; env `HOOPDB_DB_MODE` |
| shipped | [Function boundary mode (HOOPDB_FUNCTION_BOUNDARY_MODE)](#opt-sessions-pipeline-function-boundary-mode) | `global-default-revoke`, `event-trigger` | `global-default-revoke` | values `worker.migrations.functionBoundaryMode`; env `HOOPDB_FUNCTION_BOUNDARY_MODE`, `HOOPDB_FUNCTION_BOUNDARY_APPROVED` |
| shipped | [Plain-Postgres role shim (HOOPDB_SUPABASE_SHIM)](#opt-sessions-pipeline-supabase-shim) | `true`, `false` | `true` | values `worker.migrations.supabaseShim`; env `HOOPDB_SUPABASE_SHIM` |
| shipped | [Migrator role bootstrap (HOOPDB_ROLE_BOOTSTRAP)](#opt-sessions-pipeline-role-bootstrap) | `true`, `false`, `unset` | (no default) | values `worker.migrations.roleBootstrap`; env `HOOPDB_ROLE_BOOTSTRAP` |
| shipped | [Runtime workload role (HOOPDB_RUNTIME_WORKLOAD_ROLE)](#opt-sessions-pipeline-runtime-workload-role) | `""`, `<role>` | `""` | values `worker.migrations.runtimeWorkloadRole`; env `HOOPDB_RUNTIME_WORKLOAD_ROLE` |
| shipped | [Blocking index build for one migrate run (HOOPDB_ALLOW_BLOCKING_INDEX_BUILD)](#opt-sessions-pipeline-allow-blocking-index-build) | `false`, `true` | `false` | values `worker.migrations.allowBlockingIndexBuild`; env `HOOPDB_ALLOW_BLOCKING_INDEX_BUILD` |
| shipped | [migrate's wait-for-role ordering](#opt-sessions-pipeline-wait-for-role) | `true`, `false` | `true` | values `worker.migrations.waitForRole.enabled`, `worker.migrations.waitForRole.functionDefault`, `worker.migrations.waitForRole.image`, `worker.migrations.waitForRole.intervalSeconds`, `worker.migrations.waitForRole.role` |
| shipped | [Separate migration-owner URL for migrate](#opt-hoopdb-migration-owner-url) | `""`, `<secret>/<key>` | `""` | values `worker.migrations.hoopdb.existingSecret`, `worker.migrations.hoopdb.key` |
| shipped | [Locker object store](#opt-sessions-pipeline-locker-backend) | `minio`, `external` | `external` | values `session-object-storage.enabled`, `worker.locker.endpoint`, `worker.locker.bucket`, `worker.locker.region`, `alleyoop.locker.endpoint`, `alleyoop.locker.bucket`, `alleyoop.locker.region`, `worker.lockerInit.enabled`; env `LOCKER_ENDPOINT`, `LOCKER_BUCKET`, `LOCKER_REGION` |
| shipped | [Locker credentials mode](#opt-sessions-pipeline-locker-credentials-mode) | `secret`, `podIdentity` | `podIdentity` | values `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode` |
| shipped | [Locker provider (S3-compatible or native GCS)](#opt-sessions-pipeline-locker-provider) | `s3`, `gcs` | `s3` | values `worker.locker.provider`, `alleyoop.locker.provider`, `worker.extraEnv`, `alleyoop.extraEnv`; env `LOCKER_PROVIDER`, `PIPELINE_RAW_PROVIDER`, `CLOUD_SQL_CONNECTION_NAME`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_AUTH_ENABLED`, `REDIS_TRANSIT_ENCRYPTION`, `REDIS_TLS_CA_PEM`, `PUBSUB_TOPIC`, `PUBSUB_SUBSCRIPTION` |
| shipped | [Services image registry](#opt-sessions-pipeline-services-image) | `ghcr`, `ecr`, `release-overlay` | `ecr` | values `worker.image.repository`, `worker.image.digest`, `worker.image.tag`, `alleyoop.image.repository`, `alleyoop.image.digest`, `alleyoop.image.tag`, `global.imageRegistry` |
| shipped | [OpenTelemetry export](#opt-sessions-pipeline-otel) | `""`, `<your OTLP endpoint>`, `http://otel-collector:4318` | `http://otel-collector:4318` | values `global.otel.endpoint`, `otel.enabled`, `otel.config.*`; env `OTEL_EXPORTER_OTLP_ENDPOINT` |
| shipped | [Workspace, deployment and environment labels](#opt-sessions-pipeline-deployment-identity) | `<any>` | `workspaceId=default`, `deployment=selfhost`, `environment=production` | values `worker.tenant.workspaceId`, `worker.deployment.name`, `worker.deployment.id`, `worker.environment`, `alleyoop.tenant.workspaceId`, `alleyoop.deployment.name`, `alleyoop.deployment.id`, `alleyoop.environment`; env `WORKSPACE_ID`, `DEPLOYMENT`, `DEPLOYMENT_ID`, `ENVIRONMENT` |
| shipped | [Stage worker health server](#opt-sessions-pipeline-worker-health) | `true`, `false` | `true` | values `worker.workerHealth.*`; env `WORKER_HEALTH_PORT`, `WORKER_UNHEALTHY_AFTER_FAILURES`, `WORKER_MAX_TICK_AGE_MS` |
| shipped | [Bob Costas summariser model (BOB_COSTAS_MODEL)](#opt-sessions-pipeline-bob-costas-model) | `off` | `off` | values `worker.components.bob-costas.env`; env `BOB_COSTAS_MODEL` |
| **planned** | [Transcript search backend (search.backend)](#opt-sessions-pipeline-search-backend) | `postgres`, `clickhouse` (**planned**) | `postgres` | values `search.backend`, `search.clickhouse.*` |
| shipped | [Native model session briefs](#opt-sessions-pipeline-session-briefs) | `false`, `true` | `false` | values `worker.components.session-brief.enabled`, `worker.components.session-brief.replicas`, `worker.nativeBrief.enabled`, `worker.nativeBrief.image.*`, `worker.nativeBrief.workspaceIds`, `worker.nativeBrief.model`, `worker.nativeBrief.baseUrl`, `worker.nativeBrief.allowInClusterHttp`, `worker.nativeBrief.keyPrefix`, `worker.nativeBrief.sweepSeconds`, `worker.nativeBrief.batch`, `worker.nativeBrief.globalDailyCap`, `worker.nativeBrief.sessionDailyCap`, `worker.nativeBrief.openaiEgress.*`, `worker.postgresCa.sha256`; env `SESSION_BRIEF_ENABLED`, `SESSION_BRIEF_CANONICAL_INPUT`, `SESSION_BRIEF_WORKSPACE_IDS`, `SESSION_BRIEF_MODEL`, `SESSION_BRIEF_SWEEP_SECONDS`, `SESSION_BRIEF_BATCH`, `SESSION_BRIEF_GLOBAL_DAILY_CAP`, `SESSION_BRIEF_SESSION_DAILY_CAP`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `OPENAI_BASE_URL` |
| shipped | [Sessions reader ruleset ceiling](#opt-sessions-pipeline-reader-max-ruleset) | (no default), `8`, `9`, `10` | (no default) | values `nativeConsumer.readerMaxRuleset`, `worker.nativeBrief.readerMaxRuleset`, `sessionReadApi.readerMaxRuleset`, `alleyoop.readerMaxRuleset`, `ingestEdge.readerMaxRuleset`; env `READER_MAX_RULESET` |
| shipped | [Shared Sessions scrub engine rollout contract](#opt-sessions-pipeline-scrub-engine) | (no default), `reader-first`, `wasm-bindgen` | (no default) | values `global.scrubEngine.engine`, `global.scrubEngine.required`, `global.scrubEngine.readerMaxRuleset`; env `SCRUB_ENGINE`, `SCRUB_ENGINE_REQUIRED`, `READER_MAX_RULESET` |
| shipped | [Native brief collector analytics adapter](#opt-sessions-pipeline-brief-collector-analytics) | `false`, `true` | `false` | values `worker.nativeBrief.analytics.*`; env `ANALYTICS_SINK`, `ANALYTICS_DEPLOYMENT_ID`, `ANALYTICS_COLLECTOR_URL`, `ANALYTICS_COLLECTOR_TOKEN`, `ANALYTICS_COLLECTOR_CA_FILE`; Secret `<Native brief component-bound analytics producer Secret>` keys `token` |
| shipped | [Default-off native session upload edge](#opt-sessions-native-ingest) | `disabled`, `enabled` | `disabled` | values `ingestEdge.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_INGEST`, `RELAYHISTORY_SELFHOST_SESSION_SELECTION`, `RELAYHISTORY_SELFHOST_HEARTBEAT_ACCEPT`, `RELAYHISTORY_INGEST_PORT`, `RELAYHISTORY_INGEST_ORIGIN`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`, `RELAYHISTORY_INGEST_DATABASE_URL`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYHISTORY_INGEST_PG_POOL_MAX`, `ALLOW_IN_CLUSTER_HTTP`, `LOCKER_PROVIDER`, `LOCKER_BUCKET`, `LOCKER_ENDPOINT`, `LOCKER_REGION`, `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`, `INGEST_KEY_ROOT`, `INGEST_MAX_PER_USER`, `INGEST_MAX_PER_ORG`; Secret `<native ingest runtime Secret>` keys `database-url`, `introspect-secret`; Secret `<native ingest object-store Secret>` keys `access-key-id`, `secret-access-key` |
| shipped | [Default-off self-host session read API container](#opt-sessions-read-api) | `disabled`, `enabled` | `disabled` | values `fullnameOverride`, `replicas`, `image.*`, `imagePullSecrets`, `port`, `probeRuntime`, `origin`, `completeSince`, `directoryWorkspaces`, `login.advertisesSync`, `turns.assumeNoLegacy`, `timing.assumeNoTurns`, `canonical.pinLaggingPointer`, `events.messageIds`, `coordinationOverlaps.enabled`, `serviceAccountCreate`, `allowInClusterHttp`, `config.*`, `postgres.*`, `postgresCa.*`, `search.*`, `auth.*`, `cors.*`, `ingress.*`, `networkPolicy.*`, `extraEnv`, `extraVolumes`, `extraVolumeMounts`, `serviceAccountName`, `nodeSelector`, `tolerations`, `affinity`, `podAnnotations`, `resources`; env `SERVICE`, `RELAYHISTORY_SELFHOST_READ_API`, `RELAYHISTORY_READ_API_PORT`, `RELAYHISTORY_READ_API_SECRET`, `READ_API_ORIGIN`, `READ_API_AUTH_MODE`, `READ_API_COMPLETE_SINCE`, `READ_API_DIRECTORY_WORKSPACES`, `READ_API_CORS_ALLOWED_ORIGINS`, `RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC`, `READ_API_TURNS_ASSUME_NO_LEGACY`, `READ_API_TIMING_ASSUME_NO_TURNS`, `READ_API_CANONICAL_PIN_LAGGING_POINTER`, `READ_API_EVENT_MESSAGE_IDS`, `READ_API_COORDINATION_OVERLAPS_ENABLED`, `READ_API_COORDINATION_OVERLAPS_BACKEND`, `READ_API_INTERNAL_SECRET`, `READ_API_INTERNAL_SECRET_PREVIOUS`, `READ_API_ACCESS_TOKEN_TTL_SECONDS`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `SEARCH_INDEX_BACKEND`, `ALLOW_IN_CLUSTER_HTTP`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYAUTH_JWKS_URL`, `RELAYAUTH_ISSUER`, `RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API configuration Secret>` keys `RELAYHISTORY_READ_API_SECRET`; Secret `<read API introspection Secret>` keys `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API internal Secret>` keys `READ_API_INTERNAL_SECRET`; Secret `<read API previous internal Secret>` keys `READ_API_INTERNAL_SECRET_PREVIOUS` |
| shipped | [Default-off self-host transcript search writer](#opt-sessions-search-indexer) | `disabled`, `enabled` | `disabled` | values `searchIndexer.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `LOCKER_BUCKET`, `LOCKER_REGION`, `LOCKER_ENDPOINT`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `WORKER_HEALTH_PORT`; Secret `<search indexer configuration Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<search indexer bootstrap Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` |
| shipped | [Self-host output facts writer and bootstrap Job](#opt-sessions-output-facts) | `disabled`, `enabled` | `disabled` | values `searchIndexer.outputFacts.enabled`, `searchIndexer.outputFacts.bootstrap.*`, `nativeConsumer.outputFacts.enabled`; env `RELAYHISTORY_SELFHOST_OUTPUT_FACTS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_DEADLINE_SECONDS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_ALLOW_PARTIAL` |
| shipped | [Session read API Output and daily digest routes](#opt-sessions-read-api-output-digest) | `disabled`, `enabled` | `disabled` | values `output.enabled`, `digest.enabled`, `digest.narrative.*`; env `READ_API_OUTPUT_ENABLED`, `READ_API_OUTPUT_BACKEND`, `READ_API_DIGEST_ENABLED`, `READ_API_DIGEST_BACKEND`, `READ_API_DIGEST_NARRATIVE_MODEL`, `READ_API_DIGEST_NARRATIVE_DB_URL`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`; Secret `<digest narrative model API key Secret, model only>` keys `OPENAI_API_KEY`; Secret `<digest narrative writer login Secret, model only>` keys `READ_API_DIGEST_NARRATIVE_DB_URL` |
| shipped | [Native ingest claim lock retry response](#opt-sessions-native-ingest-claim-lock-busy) | `true`, `false` | `true` | values `ingestEdge.claimLockBusy`; env `INGEST_CLAIM_LOCK_BUSY` |
| shipped | [Native ingest admission mode](#opt-sessions-native-ingest-admission) | `sync`, `async`, `drain` | `sync` | values `ingestEdge.admission.mode`, `ingestEdge.admission.concurrency`, `ingestEdge.admission.scanIntervalMs`, `ingestEdge.admission.maxAttempts`; env `SELFHOST_INGEST_ADMISSION`, `SELFHOST_ADMISSION_CONCURRENCY`, `SELFHOST_ADMISSION_SCAN_MS`, `SELFHOST_ADMISSION_MAX_ATTEMPTS` |
| shipped | [Default-off native canonical pointer and search consumer](#opt-sessions-native-consumer) | `disabled`, `enabled` | `disabled` | values `nativeConsumer.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `HOOPDB_DB_MODE`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_RUNTIME`, `PIPELINE_FANOUT`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `CONSUMER_RECONCILE_EVERY_MINUTES`, `PIPELINE_RECONCILE_LOOKBACK_MINUTES`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `ALLOW_IN_CLUSTER_HTTP`, `WORKER_HEALTH_PORT`, `CONSUMER_UNHEALTHY_FILE`, `LOCKER_PROVIDER`, `LOCKER_BUCKET`, `LOCKER_ENDPOINT`, `LOCKER_REGION`, `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`, `NATIVE_CONSUMER_CA_SOURCE_FILE`, `NATIVE_CONSUMER_PREFLIGHT_MODE`, `NATIVE_CONSUMER_EXPECTED_ROLE`, `NATIVE_CONSUMER_EXPECTED_DATABASE`, `NATIVE_CONSUMER_EXPECTED_HOST`, `NATIVE_CONSUMER_EXPECTED_PORT`, `NATIVE_CONSUMER_PREFLIGHT_TIMEOUT_SECONDS`; Secret `<native consumer runtime JSON Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<native consumer Job-only owner JSON Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<native consumer S3 static Secret, secret mode only>` keys `access-key-id`, `secret-access-key` |
| shipped | [Native direct upload inbox scan](#opt-history-direct-upload-consumer) | `off`, `allowlist`, `on` | `off` | values `ingestEdge.uploadDirect.*`, `ingestEdge.keyRoot`, `ingestEdge.createServiceAccount`; env `HISTORY_UPLOAD_DIRECT`, `HISTORY_UPLOAD_DIRECT_ALLOWLIST`, `SELFHOST_UPLOAD_SCAN_BATCH`, `UPLOAD_WITNESS_KEY`; Secret `<operator-chosen shared upload witness Secret>` keys `upload-witness-key` |
| shipped | [S3 upload ledger for the native ingest (decision 0005)](#opt-sessions-pipeline-s3-ledger) | `sql`, `s3` | `sql` | values `ingestEdge.ledger`; env `INGEST_LEDGER` |
| shipped | [S3 ledger re-arm sweeper CronJob](#opt-sessions-pipeline-rearm-sweeper) | `false`, `true` | `false` | values `rearmSweeper.*`; env `INGEST_REARM_SWEEPER_ENABLED`, `INGEST_REARM_BUCKET`, `INGEST_REARM_REGION`, `INGEST_REARM_ENDPOINT`, `INGEST_REARM_KEY_ROOT`, `INGEST_REARM_ORGS`, `INGEST_REARM_DRY_RUN`, `INGEST_REARM_CONCURRENCY`, `INGEST_REARM_MAX_MARKERS`, `INGEST_REARM_CREDENTIALS`, `INGEST_REARM_S3_ACCESS_KEY_ID_FILE`, `INGEST_REARM_S3_SECRET_ACCESS_KEY_FILE`; Secret `<dedicated re-arm sweeper S3 Secret>` keys `access-key-id`, `secret-access-key` |

### Profile: aws-supabase

**AWS EKS, external Supabase HoopDb, S3 Locker via Pod Identity.** The stacks/aws/eks.ts shape with hoopdb backend external. supabase mode with no function boundary set, so migrate fails closed (function_boundary_unproven) until one is selected and installed.

chart `sessions-pipeline` · values [`ci/pod-identity-values.yaml`](../charts/sessions-pipeline/ci/pod-identity-values.yaml) · dbMode `supabase` · boundary (unset) · HoopDb external · services image GHCR

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [Workload identity for the Locker bucket (EKS Pod Identity / GKE Workload Identity)](#req-k8s-workload-identity) | stack | values `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode`, `worker.serviceAccount.annotations`, `alleyoop.serviceAccount.annotations`, `worker.serviceAccount.name`, `alleyoop.serviceAccount.name`, `sessionReadApi.serviceAccountName`, `ingestEdge.serviceAccountName`, `searchIndexer.serviceAccount.name` | aws eks list-pod-identity-associations --cluster-name <c> includes every enabled workload ServiceAccount; the worker, ingest edge and search indexer reach only their required bucket/index resources |
| shipped | [External Secrets Operator and a ClusterSecretStore (only with externalSecrets.enabled)](#req-k8s-external-secrets-operator) | operator | values `sessions-pipeline-worker:externalSecrets.*`, `session-ingest-api:externalSecrets.*` | kubectl get crd externalsecrets.external-secrets.io && kubectl get clustersecretstore <name>; the ExternalSecret reports Ready |
| shipped | [Pull Secret for the private GHCR services image](#req-secret-image-pull) | operator | values `worker.imagePullSecrets`, `alleyoop.imagePullSecrets`; Secret `<pull secret>` (type kubernetes.io/dockerconfigjson with read access to ghcr.io/agentworkforce/96bulls-services) | kubectl get secret <pull secret> -o jsonpath='{.type}' is kubernetes.io/dockerconfigjson; pods are not ImagePullBackOff |
| shipped | [Summary encryption keyring (SUMMARY_MASTER_KEYS)](#req-secret-summary-master-keys) | stack | values `worker.summaryEncryption.existingSecret`, `worker.summaryEncryption.key`, `worker.summaryEncryption.mountPath`, `worker.summaryEncryption.fileName`; env `SUMMARY_MASTER_KEYS_FILE`, `SUMMARY_MASTER_KEYS`; Secret `sessions-pipeline-summary` keys `SUMMARY_MASTER_KEYS` | kubectl exec deploy/<release>-worker-bob-costas -- test -r /var/run/secrets/sessions-pipeline/summary-master-keys; the Secret key parses as <id>:<64 hex> |
| shipped | [HoopDb connection Secret (HOOPDB_URL)](#req-secret-hoopdb-url) | stack | values `worker.hoopdb.existingSecret`, `worker.hoopdb.key`, `worker.secretKeys.hoopdbUrl`, `alleyoop.hoopdb.existingSecret`, `alleyoop.hoopdb.key`, `alleyoop.secretKeys.hoopdbUrl`; env `HOOPDB_URL`; Secret `hoopdb-app` keys `uri` | kubectl get secret hoopdb-app -o jsonpath='{.data.uri}' is non-empty once the CNPG Cluster is ready |
| shipped | [Agent Relay org id (TENANT_ORG_ID)](#req-sessions-pipeline-tenant-org-id) | operator | values `global.tenant.orgId`, `worker.tenant.orgId`, `alleyoop.tenant.orgId`; env `TENANT_ORG_ID` | helm template renders (it fails with "tenant.orgId (or global.tenant.orgId) is required" otherwise) |
| shipped | [A RelayAuth JWKS URL reachable from alleyoop](#req-sessions-pipeline-relayauth-jwks) | operator | values `alleyoop.auth.jwksUrl`; env `RELAYAUTH_JWKS_URL` | kubectl run -it --rm curl --image=curlimages/curl -- curl -fsS <jwksUrl> returns {"keys":[...]} |
| shipped | [PostgreSQL 17 with pg_trgm and btree_gin (and vector) available](#req-db-postgres-17-extensions) | operator | values `hoopdb.cluster.imageName`, `hoopdb.cluster.initdb.postInitApplicationSQL` | psql "$HOOPDB_URL" -Atc "select name from pg_available_extensions where name in ('pg_trgm','btree_gin','vector')" lists all three; server_version_num >= 170000 |
| shipped | [Supabase compatibility roles (anon, authenticated, service_role)](#req-db-compat-roles) | operator | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `worker.migrations.supabaseShim` | psql "$HOOPDB_URL" -Atc "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role')" is 3 |
| shipped | [The session directory search Worker role (session_directory_search_worker)](#req-db-search-worker-role) | operator | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `searchWorkerRole.bootstrapJob.enabled`, `searchWorkerRole.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.role` | psql "$HOOPDB_URL" -Atc "select rolcanlogin, rolconfig from pg_roles where rolname='session_directory_search_worker'" is f\|{statement_timeout=2s} |
| shipped | [The dedicated HoopDb runtime role (HOOPDB_RUNTIME_ROLE, e.g. sessions_pipeline_runtime)](#req-db-runtime-role) | operator | values `worker.migrations.runtimeRole`, `worker.migrations.runtimeRoleLogin`, `runtimeRole.bootstrapJob.enabled`, `runtimeRole.bootstrapJob.sqlPath`; env `HOOPDB_RUNTIME_ROLE`, `HOOPDB_RUNTIME_ROLE_LOGIN` | psql "$HOOPDB_URL" -Atc "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin from pg_roles where rolname='sessions_pipeline_runtime'" is f\|f\|f\|f\|f\|t; migrate refuses otherwise |
| shipped | [The durable function boundary installed before the first migrate](#req-db-function-boundary) | operator | values `functionDefaultRevoke.bootstrapJob.enabled`, `functionDefaultRevoke.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.functionDefault` | no boundary is selected in this shape; migrate refuses with function_boundary_unproven until one is |
| shipped | [migrate always runs the phase 2 role verify (HOOPDB_ROLE_VERIFY=true)](#req-sessions-pipeline-role-verify) | chart | env `HOOPDB_ROLE_VERIFY` | kubectl get job -l app.kubernetes.io/component=hoopdb-migrate -o yaml shows HOOPDB_ROLE_VERIFY "true"; workloads go ready after migrate |
| shipped | [Model API key Secret for session briefs (OPENAI_API_KEY)](#req-secret-model-api-key) | operator | values `worker.nativeBrief.openaiSecret`, `worker.nativeBrief.openaiSecret.name`, `worker.nativeBrief.openaiSecret.key`; env `OPENAI_API_KEY`; Secret `<model key Secret>` keys `OPENAI_API_KEY` | A worker Pod references the chosen Secret/key; the init container does not. Verify an actual model result separately. |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [alleyoop token verification source](#opt-alleyoop-auth-mode) | `jwksUrl`, `localJwks` | `jwksUrl` | values `alleyoop.auth.jwksUrl`, `alleyoop.auth.localJwks`, `alleyoop.auth.issuer`, `alleyoop.auth.audience`, `alleyoop.secretKeys.jwksJson`; env `RELAYAUTH_JWKS_URL`, `JWKS_JSON`, `AUTH_ISSUER`, `AUTH_AUDIENCE`; Secret `<existingSecret>` keys `JWKS_JSON` (only with auth.localJwks=true) |
| shipped | [Plain http to in-cluster Service FQDNs](#opt-sessions-pipeline-in-cluster-http) | `false`, `true` | `false` | values `alleyoop.allowInClusterHttp`, `worker.allowInClusterHttp`; env `ALLOW_IN_CLUSTER_HTTP` |
| shipped | [CA bundle for verifying the Postgres server certificate (postgresCa)](#opt-postgres-ca-bundle) | `false`, `true` | `false` | values `worker.postgresCa.*`, `alleyoop.postgresCa.*`, `relay-control:postgresCa.*`, `relaychief-control:postgresCa.*`, `relayfile-control:postgresCa.*`; env `NODE_EXTRA_CA_CERTS`, `PGSSLROOTCERT` |
| shipped | [RelayHistory origin expected by the ingest](#opt-alleyoop-history-origin) | `unset`, `origin` | `unset` | values `alleyoop.auth.historyOrigin`; env `RELAYHISTORY_ORIGIN` |
| shipped | [Interim RelayAuth bearer compatibility (local only)](#opt-alleyoop-interim-relayauth-bearer) | `false`, `true` | `false` | values `alleyoop.auth.allowInterimRelayAuthBearer`; env `ALLOW_INTERIM_RELAYAUTH_BEARER` |
| shipped | [HoopDb backend](#opt-sessions-pipeline-hoopdb-backend) | `cnpg`, `external` | `external` | values `hoopdb.enabled` |
| shipped | [Migrator database mode (HOOPDB_DB_MODE)](#opt-sessions-pipeline-db-mode) | `selfhosted`, `cloudsql`, `rds`, `supabase`, `local` | `supabase` | values `worker.migrations.databaseMode`; env `HOOPDB_DB_MODE` |
| shipped | [Function boundary mode (HOOPDB_FUNCTION_BOUNDARY_MODE)](#opt-sessions-pipeline-function-boundary-mode) | `global-default-revoke`, `event-trigger` | (no default) | values `worker.migrations.functionBoundaryMode`; env `HOOPDB_FUNCTION_BOUNDARY_MODE`, `HOOPDB_FUNCTION_BOUNDARY_APPROVED` |
| shipped | [Plain-Postgres role shim (HOOPDB_SUPABASE_SHIM)](#opt-sessions-pipeline-supabase-shim) | `true`, `false` | `false` | values `worker.migrations.supabaseShim`; env `HOOPDB_SUPABASE_SHIM` |
| shipped | [Migrator role bootstrap (HOOPDB_ROLE_BOOTSTRAP)](#opt-sessions-pipeline-role-bootstrap) | `true`, `false`, `unset` | (no default) | values `worker.migrations.roleBootstrap`; env `HOOPDB_ROLE_BOOTSTRAP` |
| shipped | [Runtime workload role (HOOPDB_RUNTIME_WORKLOAD_ROLE)](#opt-sessions-pipeline-runtime-workload-role) | `""`, `<role>` | `""` | values `worker.migrations.runtimeWorkloadRole`; env `HOOPDB_RUNTIME_WORKLOAD_ROLE` |
| shipped | [Blocking index build for one migrate run (HOOPDB_ALLOW_BLOCKING_INDEX_BUILD)](#opt-sessions-pipeline-allow-blocking-index-build) | `false`, `true` | `false` | values `worker.migrations.allowBlockingIndexBuild`; env `HOOPDB_ALLOW_BLOCKING_INDEX_BUILD` |
| shipped | [migrate's wait-for-role ordering](#opt-sessions-pipeline-wait-for-role) | `true`, `false` | `false` | values `worker.migrations.waitForRole.enabled`, `worker.migrations.waitForRole.functionDefault`, `worker.migrations.waitForRole.image`, `worker.migrations.waitForRole.intervalSeconds`, `worker.migrations.waitForRole.role` |
| shipped | [Separate migration-owner URL for migrate](#opt-hoopdb-migration-owner-url) | `""`, `<secret>/<key>` | `""` | values `worker.migrations.hoopdb.existingSecret`, `worker.migrations.hoopdb.key` |
| shipped | [Locker object store](#opt-sessions-pipeline-locker-backend) | `minio`, `external` | `external` | values `session-object-storage.enabled`, `worker.locker.endpoint`, `worker.locker.bucket`, `worker.locker.region`, `alleyoop.locker.endpoint`, `alleyoop.locker.bucket`, `alleyoop.locker.region`, `worker.lockerInit.enabled`; env `LOCKER_ENDPOINT`, `LOCKER_BUCKET`, `LOCKER_REGION` |
| shipped | [Locker credentials mode](#opt-sessions-pipeline-locker-credentials-mode) | `secret`, `podIdentity` | `podIdentity` | values `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode` |
| shipped | [Locker provider (S3-compatible or native GCS)](#opt-sessions-pipeline-locker-provider) | `s3`, `gcs` | `s3` | values `worker.locker.provider`, `alleyoop.locker.provider`, `worker.extraEnv`, `alleyoop.extraEnv`; env `LOCKER_PROVIDER`, `PIPELINE_RAW_PROVIDER`, `CLOUD_SQL_CONNECTION_NAME`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_AUTH_ENABLED`, `REDIS_TRANSIT_ENCRYPTION`, `REDIS_TLS_CA_PEM`, `PUBSUB_TOPIC`, `PUBSUB_SUBSCRIPTION` |
| shipped | [Services image registry](#opt-sessions-pipeline-services-image) | `ghcr`, `ecr`, `release-overlay` | `ghcr` | values `worker.image.repository`, `worker.image.digest`, `worker.image.tag`, `alleyoop.image.repository`, `alleyoop.image.digest`, `alleyoop.image.tag`, `global.imageRegistry` |
| shipped | [OpenTelemetry export](#opt-sessions-pipeline-otel) | `""`, `<your OTLP endpoint>`, `http://otel-collector:4318` | `""` | values `global.otel.endpoint`, `otel.enabled`, `otel.config.*`; env `OTEL_EXPORTER_OTLP_ENDPOINT` |
| shipped | [Workspace, deployment and environment labels](#opt-sessions-pipeline-deployment-identity) | `<any>` | `workspaceId=default`, `deployment=selfhost`, `environment=production` | values `worker.tenant.workspaceId`, `worker.deployment.name`, `worker.deployment.id`, `worker.environment`, `alleyoop.tenant.workspaceId`, `alleyoop.deployment.name`, `alleyoop.deployment.id`, `alleyoop.environment`; env `WORKSPACE_ID`, `DEPLOYMENT`, `DEPLOYMENT_ID`, `ENVIRONMENT` |
| shipped | [Stage worker health server](#opt-sessions-pipeline-worker-health) | `true`, `false` | `true` | values `worker.workerHealth.*`; env `WORKER_HEALTH_PORT`, `WORKER_UNHEALTHY_AFTER_FAILURES`, `WORKER_MAX_TICK_AGE_MS` |
| shipped | [Bob Costas summariser model (BOB_COSTAS_MODEL)](#opt-sessions-pipeline-bob-costas-model) | `off` | `off` | values `worker.components.bob-costas.env`; env `BOB_COSTAS_MODEL` |
| **planned** | [Transcript search backend (search.backend)](#opt-sessions-pipeline-search-backend) | `postgres`, `clickhouse` (**planned**) | `postgres` | values `search.backend`, `search.clickhouse.*` |
| shipped | [Native model session briefs](#opt-sessions-pipeline-session-briefs) | `false`, `true` | `false` | values `worker.components.session-brief.enabled`, `worker.components.session-brief.replicas`, `worker.nativeBrief.enabled`, `worker.nativeBrief.image.*`, `worker.nativeBrief.workspaceIds`, `worker.nativeBrief.model`, `worker.nativeBrief.baseUrl`, `worker.nativeBrief.allowInClusterHttp`, `worker.nativeBrief.keyPrefix`, `worker.nativeBrief.sweepSeconds`, `worker.nativeBrief.batch`, `worker.nativeBrief.globalDailyCap`, `worker.nativeBrief.sessionDailyCap`, `worker.nativeBrief.openaiEgress.*`, `worker.postgresCa.sha256`; env `SESSION_BRIEF_ENABLED`, `SESSION_BRIEF_CANONICAL_INPUT`, `SESSION_BRIEF_WORKSPACE_IDS`, `SESSION_BRIEF_MODEL`, `SESSION_BRIEF_SWEEP_SECONDS`, `SESSION_BRIEF_BATCH`, `SESSION_BRIEF_GLOBAL_DAILY_CAP`, `SESSION_BRIEF_SESSION_DAILY_CAP`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `OPENAI_BASE_URL` |
| shipped | [Sessions reader ruleset ceiling](#opt-sessions-pipeline-reader-max-ruleset) | (no default), `8`, `9`, `10` | (no default) | values `nativeConsumer.readerMaxRuleset`, `worker.nativeBrief.readerMaxRuleset`, `sessionReadApi.readerMaxRuleset`, `alleyoop.readerMaxRuleset`, `ingestEdge.readerMaxRuleset`; env `READER_MAX_RULESET` |
| shipped | [Shared Sessions scrub engine rollout contract](#opt-sessions-pipeline-scrub-engine) | (no default), `reader-first`, `wasm-bindgen` | (no default) | values `global.scrubEngine.engine`, `global.scrubEngine.required`, `global.scrubEngine.readerMaxRuleset`; env `SCRUB_ENGINE`, `SCRUB_ENGINE_REQUIRED`, `READER_MAX_RULESET` |
| shipped | [Native brief collector analytics adapter](#opt-sessions-pipeline-brief-collector-analytics) | `false`, `true` | `false` | values `worker.nativeBrief.analytics.*`; env `ANALYTICS_SINK`, `ANALYTICS_DEPLOYMENT_ID`, `ANALYTICS_COLLECTOR_URL`, `ANALYTICS_COLLECTOR_TOKEN`, `ANALYTICS_COLLECTOR_CA_FILE`; Secret `<Native brief component-bound analytics producer Secret>` keys `token` |
| shipped | [Default-off native session upload edge](#opt-sessions-native-ingest) | `disabled`, `enabled` | `disabled` | values `ingestEdge.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_INGEST`, `RELAYHISTORY_SELFHOST_SESSION_SELECTION`, `RELAYHISTORY_SELFHOST_HEARTBEAT_ACCEPT`, `RELAYHISTORY_INGEST_PORT`, `RELAYHISTORY_INGEST_ORIGIN`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`, `RELAYHISTORY_INGEST_DATABASE_URL`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYHISTORY_INGEST_PG_POOL_MAX`, `ALLOW_IN_CLUSTER_HTTP`, `LOCKER_PROVIDER`, `LOCKER_BUCKET`, `LOCKER_ENDPOINT`, `LOCKER_REGION`, `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`, `INGEST_KEY_ROOT`, `INGEST_MAX_PER_USER`, `INGEST_MAX_PER_ORG`; Secret `<native ingest runtime Secret>` keys `database-url`, `introspect-secret`; Secret `<native ingest object-store Secret>` keys `access-key-id`, `secret-access-key` |
| shipped | [Default-off self-host session read API container](#opt-sessions-read-api) | `disabled`, `enabled` | `disabled` | values `fullnameOverride`, `replicas`, `image.*`, `imagePullSecrets`, `port`, `probeRuntime`, `origin`, `completeSince`, `directoryWorkspaces`, `login.advertisesSync`, `turns.assumeNoLegacy`, `timing.assumeNoTurns`, `canonical.pinLaggingPointer`, `events.messageIds`, `coordinationOverlaps.enabled`, `serviceAccountCreate`, `allowInClusterHttp`, `config.*`, `postgres.*`, `postgresCa.*`, `search.*`, `auth.*`, `cors.*`, `ingress.*`, `networkPolicy.*`, `extraEnv`, `extraVolumes`, `extraVolumeMounts`, `serviceAccountName`, `nodeSelector`, `tolerations`, `affinity`, `podAnnotations`, `resources`; env `SERVICE`, `RELAYHISTORY_SELFHOST_READ_API`, `RELAYHISTORY_READ_API_PORT`, `RELAYHISTORY_READ_API_SECRET`, `READ_API_ORIGIN`, `READ_API_AUTH_MODE`, `READ_API_COMPLETE_SINCE`, `READ_API_DIRECTORY_WORKSPACES`, `READ_API_CORS_ALLOWED_ORIGINS`, `RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC`, `READ_API_TURNS_ASSUME_NO_LEGACY`, `READ_API_TIMING_ASSUME_NO_TURNS`, `READ_API_CANONICAL_PIN_LAGGING_POINTER`, `READ_API_EVENT_MESSAGE_IDS`, `READ_API_COORDINATION_OVERLAPS_ENABLED`, `READ_API_COORDINATION_OVERLAPS_BACKEND`, `READ_API_INTERNAL_SECRET`, `READ_API_INTERNAL_SECRET_PREVIOUS`, `READ_API_ACCESS_TOKEN_TTL_SECONDS`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `SEARCH_INDEX_BACKEND`, `ALLOW_IN_CLUSTER_HTTP`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYAUTH_JWKS_URL`, `RELAYAUTH_ISSUER`, `RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API configuration Secret>` keys `RELAYHISTORY_READ_API_SECRET`; Secret `<read API introspection Secret>` keys `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API internal Secret>` keys `READ_API_INTERNAL_SECRET`; Secret `<read API previous internal Secret>` keys `READ_API_INTERNAL_SECRET_PREVIOUS` |
| shipped | [Default-off self-host transcript search writer](#opt-sessions-search-indexer) | `disabled`, `enabled` | `disabled` | values `searchIndexer.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `LOCKER_BUCKET`, `LOCKER_REGION`, `LOCKER_ENDPOINT`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `WORKER_HEALTH_PORT`; Secret `<search indexer configuration Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<search indexer bootstrap Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` |
| shipped | [Self-host output facts writer and bootstrap Job](#opt-sessions-output-facts) | `disabled`, `enabled` | `disabled` | values `searchIndexer.outputFacts.enabled`, `searchIndexer.outputFacts.bootstrap.*`, `nativeConsumer.outputFacts.enabled`; env `RELAYHISTORY_SELFHOST_OUTPUT_FACTS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_DEADLINE_SECONDS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_ALLOW_PARTIAL` |
| shipped | [Session read API Output and daily digest routes](#opt-sessions-read-api-output-digest) | `disabled`, `enabled` | `disabled` | values `output.enabled`, `digest.enabled`, `digest.narrative.*`; env `READ_API_OUTPUT_ENABLED`, `READ_API_OUTPUT_BACKEND`, `READ_API_DIGEST_ENABLED`, `READ_API_DIGEST_BACKEND`, `READ_API_DIGEST_NARRATIVE_MODEL`, `READ_API_DIGEST_NARRATIVE_DB_URL`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`; Secret `<digest narrative model API key Secret, model only>` keys `OPENAI_API_KEY`; Secret `<digest narrative writer login Secret, model only>` keys `READ_API_DIGEST_NARRATIVE_DB_URL` |
| shipped | [Native ingest claim lock retry response](#opt-sessions-native-ingest-claim-lock-busy) | `true`, `false` | `true` | values `ingestEdge.claimLockBusy`; env `INGEST_CLAIM_LOCK_BUSY` |
| shipped | [Native ingest admission mode](#opt-sessions-native-ingest-admission) | `sync`, `async`, `drain` | `sync` | values `ingestEdge.admission.mode`, `ingestEdge.admission.concurrency`, `ingestEdge.admission.scanIntervalMs`, `ingestEdge.admission.maxAttempts`; env `SELFHOST_INGEST_ADMISSION`, `SELFHOST_ADMISSION_CONCURRENCY`, `SELFHOST_ADMISSION_SCAN_MS`, `SELFHOST_ADMISSION_MAX_ATTEMPTS` |
| shipped | [Native direct upload inbox scan](#opt-history-direct-upload-consumer) | `off`, `allowlist`, `on` | `off` | values `ingestEdge.uploadDirect.*`, `ingestEdge.keyRoot`, `ingestEdge.createServiceAccount`; env `HISTORY_UPLOAD_DIRECT`, `HISTORY_UPLOAD_DIRECT_ALLOWLIST`, `SELFHOST_UPLOAD_SCAN_BATCH`, `UPLOAD_WITNESS_KEY`; Secret `<operator-chosen shared upload witness Secret>` keys `upload-witness-key` |
| shipped | [S3 upload ledger for the native ingest (decision 0005)](#opt-sessions-pipeline-s3-ledger) | `sql`, `s3` | `sql` | values `ingestEdge.ledger`; env `INGEST_LEDGER` |
| shipped | [S3 ledger re-arm sweeper CronJob](#opt-sessions-pipeline-rearm-sweeper) | `false`, `true` | `false` | values `rearmSweeper.*`; env `INGEST_REARM_SWEEPER_ENABLED`, `INGEST_REARM_BUCKET`, `INGEST_REARM_REGION`, `INGEST_REARM_ENDPOINT`, `INGEST_REARM_KEY_ROOT`, `INGEST_REARM_ORGS`, `INGEST_REARM_DRY_RUN`, `INGEST_REARM_CONCURRENCY`, `INGEST_REARM_MAX_MARKERS`, `INGEST_REARM_CREDENTIALS`, `INGEST_REARM_S3_ACCESS_KEY_ID_FILE`, `INGEST_REARM_S3_SECRET_ACCESS_KEY_FILE`; Secret `<dedicated re-arm sweeper S3 Secret>` keys `access-key-id`, `secret-access-key` |

### Profile: gcp-cloudsql

**GKE + Google Cloud SQL, GCS Locker via Workload Identity.** The stacks/gcp/config.ts shape. cloudsql mode, shim off, roleBootstrap false, a separate migration-owner URL; the operator runs the Cloud SQL bootstrap files as the migration owner.

chart `sessions-pipeline` · values [`ci/gcp-cloudsql-values.yaml`](../charts/sessions-pipeline/ci/gcp-cloudsql-values.yaml) · dbMode `cloudsql` · boundary `global-default-revoke` · HoopDb external · services image GHCR

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [Workload identity for the Locker bucket (EKS Pod Identity / GKE Workload Identity)](#req-k8s-workload-identity) | stack | values `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode`, `worker.serviceAccount.annotations`, `alleyoop.serviceAccount.annotations`, `worker.serviceAccount.name`, `alleyoop.serviceAccount.name`, `sessionReadApi.serviceAccountName`, `ingestEdge.serviceAccountName`, `searchIndexer.serviceAccount.name` | aws eks list-pod-identity-associations --cluster-name <c> includes every enabled workload ServiceAccount; the worker, ingest edge and search indexer reach only their required bucket/index resources |
| shipped | [External Secrets Operator and a ClusterSecretStore (only with externalSecrets.enabled)](#req-k8s-external-secrets-operator) | operator | values `sessions-pipeline-worker:externalSecrets.*`, `session-ingest-api:externalSecrets.*` | kubectl get crd externalsecrets.external-secrets.io && kubectl get clustersecretstore <name>; the ExternalSecret reports Ready |
| shipped | [Pull Secret for the private GHCR services image](#req-secret-image-pull) | operator | values `worker.imagePullSecrets`, `alleyoop.imagePullSecrets`; Secret `<pull secret>` (type kubernetes.io/dockerconfigjson with read access to ghcr.io/agentworkforce/96bulls-services) | kubectl get secret <pull secret> -o jsonpath='{.type}' is kubernetes.io/dockerconfigjson; pods are not ImagePullBackOff |
| shipped | [Summary encryption keyring (SUMMARY_MASTER_KEYS)](#req-secret-summary-master-keys) | stack | values `worker.summaryEncryption.existingSecret`, `worker.summaryEncryption.key`, `worker.summaryEncryption.mountPath`, `worker.summaryEncryption.fileName`; env `SUMMARY_MASTER_KEYS_FILE`, `SUMMARY_MASTER_KEYS`; Secret `96bulls-gcp` keys `SUMMARY_MASTER_KEYS` | kubectl exec deploy/<release>-worker-bob-costas -- test -r /var/run/secrets/sessions-pipeline/summary-master-keys; the Secret key parses as <id>:<64 hex> |
| shipped | [HoopDb connection Secret (HOOPDB_URL)](#req-secret-hoopdb-url) | stack | values `worker.hoopdb.existingSecret`, `worker.hoopdb.key`, `worker.secretKeys.hoopdbUrl`, `alleyoop.hoopdb.existingSecret`, `alleyoop.hoopdb.key`, `alleyoop.secretKeys.hoopdbUrl`; env `HOOPDB_URL`; Secret `96bulls-gcp` keys `HOOPDB_URL` | kubectl get secret hoopdb-app -o jsonpath='{.data.uri}' is non-empty once the CNPG Cluster is ready |
| shipped | [Separate migration-owner connection Secret (HOOPDB_MIGRATION_URL)](#req-secret-hoopdb-migration-url) | stack | values `worker.migrations.hoopdb.existingSecret`, `worker.migrations.hoopdb.key`; Secret `96bulls-gcp` keys `HOOPDB_MIGRATION_URL` | kubectl get secret 96bulls-gcp -o jsonpath='{.data.HOOPDB_MIGRATION_URL}' connects as the migration owner (select current_user) |
| shipped | [Agent Relay org id (TENANT_ORG_ID)](#req-sessions-pipeline-tenant-org-id) | operator | values `global.tenant.orgId`, `worker.tenant.orgId`, `alleyoop.tenant.orgId`; env `TENANT_ORG_ID` | helm template renders (it fails with "tenant.orgId (or global.tenant.orgId) is required" otherwise) |
| shipped | [A RelayAuth JWKS URL reachable from alleyoop](#req-sessions-pipeline-relayauth-jwks) | operator | values `alleyoop.auth.jwksUrl`; env `RELAYAUTH_JWKS_URL` | kubectl run -it --rm curl --image=curlimages/curl -- curl -fsS <jwksUrl> returns {"keys":[...]} |
| shipped | [PostgreSQL 17 with pg_trgm and btree_gin (and vector) available](#req-db-postgres-17-extensions) | stack | values `hoopdb.cluster.imageName`, `hoopdb.cluster.initdb.postInitApplicationSQL` | psql "$HOOPDB_URL" -Atc "select name from pg_available_extensions where name in ('pg_trgm','btree_gin','vector')" lists all three; server_version_num >= 170000 |
| shipped | [A database dedicated to HoopDb](#req-db-dedicated-database) | stack | values `hoopdb.cluster.initdb.database`, `hoopdb.cluster.initdb.owner` | psql "$HOOPDB_URL" -Atc "select nspname from pg_namespace where nspname not like 'pg_%' and nspname <> 'information_schema'" shows only HoopDb schemas |
| shipped | [Supabase compatibility roles (anon, authenticated, service_role)](#req-db-compat-roles) | operator | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `worker.migrations.supabaseShim` | psql "$HOOPDB_URL" -Atc "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role')" is 3 |
| shipped | [The session directory search Worker role (session_directory_search_worker)](#req-db-search-worker-role) | operator | values `hoopdb.cluster.initdb.postInitApplicationSQL`, `searchWorkerRole.bootstrapJob.enabled`, `searchWorkerRole.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.role` | run supabase/bootstrap/session_directory_search_worker.sql as the migration owner; then the same query |
| shipped | [The dedicated HoopDb runtime role (HOOPDB_RUNTIME_ROLE, e.g. sessions_pipeline_runtime)](#req-db-runtime-role) | operator | values `worker.migrations.runtimeRole`, `worker.migrations.runtimeRoleLogin`, `runtimeRole.bootstrapJob.enabled`, `runtimeRole.bootstrapJob.sqlPath`; env `HOOPDB_RUNTIME_ROLE`, `HOOPDB_RUNTIME_ROLE_LOGIN` | psql "$HOOPDB_URL" -Atc "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin from pg_roles where rolname='sessions_pipeline_runtime'" is f\|f\|f\|f\|f\|t; migrate refuses otherwise |
| shipped | [The durable function boundary installed before the first migrate](#req-db-function-boundary) | operator | values `functionDefaultRevoke.bootstrapJob.enabled`, `functionDefaultRevoke.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.functionDefault` | the function-default Job completes and migrate's wait-for-role logs "present: ... + owner function default" |
| shipped | [migrate always runs the phase 2 role verify (HOOPDB_ROLE_VERIFY=true)](#req-sessions-pipeline-role-verify) | chart | env `HOOPDB_ROLE_VERIFY` | kubectl get job -l app.kubernetes.io/component=hoopdb-migrate -o yaml shows HOOPDB_ROLE_VERIFY "true"; workloads go ready after migrate |
| shipped | [Model API key Secret for session briefs (OPENAI_API_KEY)](#req-secret-model-api-key) | operator | values `worker.nativeBrief.openaiSecret`, `worker.nativeBrief.openaiSecret.name`, `worker.nativeBrief.openaiSecret.key`; env `OPENAI_API_KEY`; Secret `<model key Secret>` keys `OPENAI_API_KEY` | A worker Pod references the chosen Secret/key; the init container does not. Verify an actual model result separately. |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [alleyoop token verification source](#opt-alleyoop-auth-mode) | `jwksUrl`, `localJwks` | `jwksUrl` | values `alleyoop.auth.jwksUrl`, `alleyoop.auth.localJwks`, `alleyoop.auth.issuer`, `alleyoop.auth.audience`, `alleyoop.secretKeys.jwksJson`; env `RELAYAUTH_JWKS_URL`, `JWKS_JSON`, `AUTH_ISSUER`, `AUTH_AUDIENCE`; Secret `<existingSecret>` keys `JWKS_JSON` (only with auth.localJwks=true) |
| shipped | [Plain http to in-cluster Service FQDNs](#opt-sessions-pipeline-in-cluster-http) | `false`, `true` | `false` | values `alleyoop.allowInClusterHttp`, `worker.allowInClusterHttp`; env `ALLOW_IN_CLUSTER_HTTP` |
| shipped | [CA bundle for verifying the Postgres server certificate (postgresCa)](#opt-postgres-ca-bundle) | `false`, `true` | `false` | values `worker.postgresCa.*`, `alleyoop.postgresCa.*`, `relay-control:postgresCa.*`, `relaychief-control:postgresCa.*`, `relayfile-control:postgresCa.*`; env `NODE_EXTRA_CA_CERTS`, `PGSSLROOTCERT` |
| shipped | [RelayHistory origin expected by the ingest](#opt-alleyoop-history-origin) | `unset`, `origin` | `unset` | values `alleyoop.auth.historyOrigin`; env `RELAYHISTORY_ORIGIN` |
| shipped | [Interim RelayAuth bearer compatibility (local only)](#opt-alleyoop-interim-relayauth-bearer) | `false`, `true` | `false` | values `alleyoop.auth.allowInterimRelayAuthBearer`; env `ALLOW_INTERIM_RELAYAUTH_BEARER` |
| shipped | [HoopDb backend](#opt-sessions-pipeline-hoopdb-backend) | `cnpg`, `external` | `external` | values `hoopdb.enabled` |
| shipped | [Migrator database mode (HOOPDB_DB_MODE)](#opt-sessions-pipeline-db-mode) | `selfhosted`, `cloudsql`, `rds`, `supabase`, `local` | `cloudsql` | values `worker.migrations.databaseMode`; env `HOOPDB_DB_MODE` |
| shipped | [Function boundary mode (HOOPDB_FUNCTION_BOUNDARY_MODE)](#opt-sessions-pipeline-function-boundary-mode) | `global-default-revoke`, `event-trigger` | `global-default-revoke` | values `worker.migrations.functionBoundaryMode`; env `HOOPDB_FUNCTION_BOUNDARY_MODE`, `HOOPDB_FUNCTION_BOUNDARY_APPROVED` |
| shipped | [Plain-Postgres role shim (HOOPDB_SUPABASE_SHIM)](#opt-sessions-pipeline-supabase-shim) | `true`, `false` | `false` | values `worker.migrations.supabaseShim`; env `HOOPDB_SUPABASE_SHIM` |
| shipped | [Migrator role bootstrap (HOOPDB_ROLE_BOOTSTRAP)](#opt-sessions-pipeline-role-bootstrap) | `true`, `false`, `unset` | `false` | values `worker.migrations.roleBootstrap`; env `HOOPDB_ROLE_BOOTSTRAP` |
| shipped | [Runtime workload role (HOOPDB_RUNTIME_WORKLOAD_ROLE)](#opt-sessions-pipeline-runtime-workload-role) | `""`, `<role>` | `""` | values `worker.migrations.runtimeWorkloadRole`; env `HOOPDB_RUNTIME_WORKLOAD_ROLE` |
| shipped | [Blocking index build for one migrate run (HOOPDB_ALLOW_BLOCKING_INDEX_BUILD)](#opt-sessions-pipeline-allow-blocking-index-build) | `false`, `true` | `false` | values `worker.migrations.allowBlockingIndexBuild`; env `HOOPDB_ALLOW_BLOCKING_INDEX_BUILD` |
| shipped | [migrate's wait-for-role ordering](#opt-sessions-pipeline-wait-for-role) | `true`, `false` | `true` | values `worker.migrations.waitForRole.enabled`, `worker.migrations.waitForRole.functionDefault`, `worker.migrations.waitForRole.image`, `worker.migrations.waitForRole.intervalSeconds`, `worker.migrations.waitForRole.role` |
| shipped | [Locker object store](#opt-sessions-pipeline-locker-backend) | `minio`, `external` | `external` | values `session-object-storage.enabled`, `worker.locker.endpoint`, `worker.locker.bucket`, `worker.locker.region`, `alleyoop.locker.endpoint`, `alleyoop.locker.bucket`, `alleyoop.locker.region`, `worker.lockerInit.enabled`; env `LOCKER_ENDPOINT`, `LOCKER_BUCKET`, `LOCKER_REGION` |
| shipped | [Locker credentials mode](#opt-sessions-pipeline-locker-credentials-mode) | `secret`, `podIdentity` | `podIdentity` | values `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode` |
| shipped | [Locker provider (S3-compatible or native GCS)](#opt-sessions-pipeline-locker-provider) | `s3`, `gcs` | `gcs` | values `worker.locker.provider`, `alleyoop.locker.provider`, `worker.extraEnv`, `alleyoop.extraEnv`; env `LOCKER_PROVIDER`, `PIPELINE_RAW_PROVIDER`, `CLOUD_SQL_CONNECTION_NAME`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_AUTH_ENABLED`, `REDIS_TRANSIT_ENCRYPTION`, `REDIS_TLS_CA_PEM`, `PUBSUB_TOPIC`, `PUBSUB_SUBSCRIPTION` |
| shipped | [Services image registry](#opt-sessions-pipeline-services-image) | `ghcr`, `ecr`, `release-overlay` | `ghcr` | values `worker.image.repository`, `worker.image.digest`, `worker.image.tag`, `alleyoop.image.repository`, `alleyoop.image.digest`, `alleyoop.image.tag`, `global.imageRegistry` |
| shipped | [OpenTelemetry export](#opt-sessions-pipeline-otel) | `""`, `<your OTLP endpoint>`, `http://otel-collector:4318` | `""` | values `global.otel.endpoint`, `otel.enabled`, `otel.config.*`; env `OTEL_EXPORTER_OTLP_ENDPOINT` |
| shipped | [Workspace, deployment and environment labels](#opt-sessions-pipeline-deployment-identity) | `<any>` | `workspaceId=default`, `deployment=selfhost`, `environment=production` | values `worker.tenant.workspaceId`, `worker.deployment.name`, `worker.deployment.id`, `worker.environment`, `alleyoop.tenant.workspaceId`, `alleyoop.deployment.name`, `alleyoop.deployment.id`, `alleyoop.environment`; env `WORKSPACE_ID`, `DEPLOYMENT`, `DEPLOYMENT_ID`, `ENVIRONMENT` |
| shipped | [Stage worker health server](#opt-sessions-pipeline-worker-health) | `true`, `false` | `true` | values `worker.workerHealth.*`; env `WORKER_HEALTH_PORT`, `WORKER_UNHEALTHY_AFTER_FAILURES`, `WORKER_MAX_TICK_AGE_MS` |
| shipped | [Bob Costas summariser model (BOB_COSTAS_MODEL)](#opt-sessions-pipeline-bob-costas-model) | `off` | `off` | values `worker.components.bob-costas.env`; env `BOB_COSTAS_MODEL` |
| **planned** | [Transcript search backend (search.backend)](#opt-sessions-pipeline-search-backend) | `postgres`, `clickhouse` (**planned**) | `postgres` | values `search.backend`, `search.clickhouse.*` |
| shipped | [Native model session briefs](#opt-sessions-pipeline-session-briefs) | `false`, `true` | `false` | values `worker.components.session-brief.enabled`, `worker.components.session-brief.replicas`, `worker.nativeBrief.enabled`, `worker.nativeBrief.image.*`, `worker.nativeBrief.workspaceIds`, `worker.nativeBrief.model`, `worker.nativeBrief.baseUrl`, `worker.nativeBrief.allowInClusterHttp`, `worker.nativeBrief.keyPrefix`, `worker.nativeBrief.sweepSeconds`, `worker.nativeBrief.batch`, `worker.nativeBrief.globalDailyCap`, `worker.nativeBrief.sessionDailyCap`, `worker.nativeBrief.openaiEgress.*`, `worker.postgresCa.sha256`; env `SESSION_BRIEF_ENABLED`, `SESSION_BRIEF_CANONICAL_INPUT`, `SESSION_BRIEF_WORKSPACE_IDS`, `SESSION_BRIEF_MODEL`, `SESSION_BRIEF_SWEEP_SECONDS`, `SESSION_BRIEF_BATCH`, `SESSION_BRIEF_GLOBAL_DAILY_CAP`, `SESSION_BRIEF_SESSION_DAILY_CAP`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `OPENAI_BASE_URL` |
| shipped | [Sessions reader ruleset ceiling](#opt-sessions-pipeline-reader-max-ruleset) | (no default), `8`, `9`, `10` | (no default) | values `nativeConsumer.readerMaxRuleset`, `worker.nativeBrief.readerMaxRuleset`, `sessionReadApi.readerMaxRuleset`, `alleyoop.readerMaxRuleset`, `ingestEdge.readerMaxRuleset`; env `READER_MAX_RULESET` |
| shipped | [Shared Sessions scrub engine rollout contract](#opt-sessions-pipeline-scrub-engine) | (no default), `reader-first`, `wasm-bindgen` | (no default) | values `global.scrubEngine.engine`, `global.scrubEngine.required`, `global.scrubEngine.readerMaxRuleset`; env `SCRUB_ENGINE`, `SCRUB_ENGINE_REQUIRED`, `READER_MAX_RULESET` |
| shipped | [Native brief collector analytics adapter](#opt-sessions-pipeline-brief-collector-analytics) | `false`, `true` | `false` | values `worker.nativeBrief.analytics.*`; env `ANALYTICS_SINK`, `ANALYTICS_DEPLOYMENT_ID`, `ANALYTICS_COLLECTOR_URL`, `ANALYTICS_COLLECTOR_TOKEN`, `ANALYTICS_COLLECTOR_CA_FILE`; Secret `<Native brief component-bound analytics producer Secret>` keys `token` |
| shipped | [Default-off native session upload edge](#opt-sessions-native-ingest) | `disabled`, `enabled` | `disabled` | values `ingestEdge.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_INGEST`, `RELAYHISTORY_SELFHOST_SESSION_SELECTION`, `RELAYHISTORY_SELFHOST_HEARTBEAT_ACCEPT`, `RELAYHISTORY_INGEST_PORT`, `RELAYHISTORY_INGEST_ORIGIN`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`, `RELAYHISTORY_INGEST_DATABASE_URL`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYHISTORY_INGEST_PG_POOL_MAX`, `ALLOW_IN_CLUSTER_HTTP`, `LOCKER_PROVIDER`, `LOCKER_BUCKET`, `LOCKER_ENDPOINT`, `LOCKER_REGION`, `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`, `INGEST_KEY_ROOT`, `INGEST_MAX_PER_USER`, `INGEST_MAX_PER_ORG`; Secret `<native ingest runtime Secret>` keys `database-url`, `introspect-secret`; Secret `<native ingest object-store Secret>` keys `access-key-id`, `secret-access-key` |
| shipped | [Default-off self-host session read API container](#opt-sessions-read-api) | `disabled`, `enabled` | `disabled` | values `fullnameOverride`, `replicas`, `image.*`, `imagePullSecrets`, `port`, `probeRuntime`, `origin`, `completeSince`, `directoryWorkspaces`, `login.advertisesSync`, `turns.assumeNoLegacy`, `timing.assumeNoTurns`, `canonical.pinLaggingPointer`, `events.messageIds`, `coordinationOverlaps.enabled`, `serviceAccountCreate`, `allowInClusterHttp`, `config.*`, `postgres.*`, `postgresCa.*`, `search.*`, `auth.*`, `cors.*`, `ingress.*`, `networkPolicy.*`, `extraEnv`, `extraVolumes`, `extraVolumeMounts`, `serviceAccountName`, `nodeSelector`, `tolerations`, `affinity`, `podAnnotations`, `resources`; env `SERVICE`, `RELAYHISTORY_SELFHOST_READ_API`, `RELAYHISTORY_READ_API_PORT`, `RELAYHISTORY_READ_API_SECRET`, `READ_API_ORIGIN`, `READ_API_AUTH_MODE`, `READ_API_COMPLETE_SINCE`, `READ_API_DIRECTORY_WORKSPACES`, `READ_API_CORS_ALLOWED_ORIGINS`, `RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC`, `READ_API_TURNS_ASSUME_NO_LEGACY`, `READ_API_TIMING_ASSUME_NO_TURNS`, `READ_API_CANONICAL_PIN_LAGGING_POINTER`, `READ_API_EVENT_MESSAGE_IDS`, `READ_API_COORDINATION_OVERLAPS_ENABLED`, `READ_API_COORDINATION_OVERLAPS_BACKEND`, `READ_API_INTERNAL_SECRET`, `READ_API_INTERNAL_SECRET_PREVIOUS`, `READ_API_ACCESS_TOKEN_TTL_SECONDS`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `SEARCH_INDEX_BACKEND`, `ALLOW_IN_CLUSTER_HTTP`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYAUTH_JWKS_URL`, `RELAYAUTH_ISSUER`, `RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API configuration Secret>` keys `RELAYHISTORY_READ_API_SECRET`; Secret `<read API introspection Secret>` keys `RELAYCONTROL_INTROSPECT_SECRET`; Secret `<read API internal Secret>` keys `READ_API_INTERNAL_SECRET`; Secret `<read API previous internal Secret>` keys `READ_API_INTERNAL_SECRET_PREVIOUS` |
| shipped | [Default-off self-host transcript search writer](#opt-sessions-search-indexer) | `disabled`, `enabled` | `disabled` | values `searchIndexer.*`; env `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `LOCKER_BUCKET`, `LOCKER_REGION`, `LOCKER_ENDPOINT`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `WORKER_HEALTH_PORT`; Secret `<search indexer configuration Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`; Secret `<search indexer bootstrap Secret>` keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` |
| shipped | [Self-host output facts writer and bootstrap Job](#opt-sessions-output-facts) | `disabled`, `enabled` | `disabled` | values `searchIndexer.outputFacts.enabled`, `searchIndexer.outputFacts.bootstrap.*`, `nativeConsumer.outputFacts.enabled`; env `RELAYHISTORY_SELFHOST_OUTPUT_FACTS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_DEADLINE_SECONDS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_ALLOW_PARTIAL` |
| shipped | [Session read API Output and daily digest routes](#opt-sessions-read-api-output-digest) | `disabled`, `enabled` | `disabled` | values `output.enabled`, `digest.enabled`, `digest.narrative.*`; env `READ_API_OUTPUT_ENABLED`, `READ_API_OUTPUT_BACKEND`, `READ_API_DIGEST_ENABLED`, `READ_API_DIGEST_BACKEND`, `READ_API_DIGEST_NARRATIVE_MODEL`, `READ_API_DIGEST_NARRATIVE_DB_URL`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`; Secret `<digest narrative model API key Secret, model only>` keys `OPENAI_API_KEY`; Secret `<digest narrative writer login Secret, model only>` keys `READ_API_DIGEST_NARRATIVE_DB_URL` |
| shipped | [Native ingest claim lock retry response](#opt-sessions-native-ingest-claim-lock-busy) | `true`, `false` | `true` | values `ingestEdge.claimLockBusy`; env `INGEST_CLAIM_LOCK_BUSY` |
| shipped | [Native ingest admission mode](#opt-sessions-native-ingest-admission) | `sync`, `async`, `drain` | `sync` | values `ingestEdge.admission.mode`, `ingestEdge.admission.concurrency`, `ingestEdge.admission.scanIntervalMs`, `ingestEdge.admission.maxAttempts`; env `SELFHOST_INGEST_ADMISSION`, `SELFHOST_ADMISSION_CONCURRENCY`, `SELFHOST_ADMISSION_SCAN_MS`, `SELFHOST_ADMISSION_MAX_ATTEMPTS` |
| shipped | [Native direct upload inbox scan](#opt-history-direct-upload-consumer) | `off`, `allowlist`, `on` | `off` | values `ingestEdge.uploadDirect.*`, `ingestEdge.keyRoot`, `ingestEdge.createServiceAccount`; env `HISTORY_UPLOAD_DIRECT`, `HISTORY_UPLOAD_DIRECT_ALLOWLIST`, `SELFHOST_UPLOAD_SCAN_BATCH`, `UPLOAD_WITNESS_KEY`; Secret `<operator-chosen shared upload witness Secret>` keys `upload-witness-key` |
| shipped | [S3 upload ledger for the native ingest (decision 0005)](#opt-sessions-pipeline-s3-ledger) | `sql`, `s3` | `sql` | values `ingestEdge.ledger`; env `INGEST_LEDGER` |
| shipped | [S3 ledger re-arm sweeper CronJob](#opt-sessions-pipeline-rearm-sweeper) | `false`, `true` | `false` | values `rearmSweeper.*`; env `INGEST_REARM_SWEEPER_ENABLED`, `INGEST_REARM_BUCKET`, `INGEST_REARM_REGION`, `INGEST_REARM_ENDPOINT`, `INGEST_REARM_KEY_ROOT`, `INGEST_REARM_ORGS`, `INGEST_REARM_DRY_RUN`, `INGEST_REARM_CONCURRENCY`, `INGEST_REARM_MAX_MARKERS`, `INGEST_REARM_CREDENTIALS`, `INGEST_REARM_S3_ACCESS_KEY_ID_FILE`, `INGEST_REARM_S3_SECRET_ACCESS_KEY_FILE`; Secret `<dedicated re-arm sweeper S3 Secret>` keys `access-key-id`, `secret-access-key` |

### Profile: relaycast

**Relaycast core (portable-single).** One replica, SQLite and local file storage on a retained PVC, Recreate upgrades. The required core of the self-hosted product.

chart `relaycast` · install: `helm install relaycast agentworkforce/relaycast --set baseUrl=https://relay.example.com --set existingSecret=relaycast-secrets`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [Relaycast secret (internal admin + workspace bootstrap)](#req-relaycast-secret) | operator | values `existingSecret`, `secretKeys.internalSecret`, `secretKeys.bootstrapSecret`, `secretKeys.credentialKeyring`, `secretKeys.relayauthToken`, `secretKeys`; env `RELAYCAST_INTERNAL_SECRET_FILE`, `RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET_FILE`, `RELAYCAST_CREDENTIAL_KEYRING_FILE`, `RELAYCAST_RELAYAUTH_TOKEN_FILE`; Secret `<existingSecret, e.g. relaycast-secrets>` keys `internal-secret`, `workspace-bootstrap-secret`, `<operator-chosen, no default>`, `<operator-chosen, no default>` | kubectl -n relaycast get secret relaycast-secrets -o jsonpath='{.data}' has internal-secret and workspace-bootstrap-secret, plus the secretKeys.credentialKeyring key when credentials.authority=self or the secretKeys.relayauthToken key when credentials.authority=relayauth; helm template fails with "existingSecret is required", or the matching credentials error, otherwise |
| shipped | [Relaycast public origin (baseUrl)](#req-relaycast-base-url) | operator | values `baseUrl` | helm template fails with "baseUrl is required" otherwise; curl <baseUrl>/health |
| shipped | [DNS and a TLS certificate for the public Relaycast host (with ingress)](#req-relaycast-dns-tls) | operator | values `ingress.enabled`, `ingress.hosts`, `ingress.tls`, `ingress.externalTls`, `ingress.className`, `ingress.annotations`, `networkPolicy.ingressFrom`; Secret `<ingress.tls[].secretName>` (kubernetes.io/tls; created by cert-manager when annotated) | dig +short <host>; curl -fsS https://<host>/health; curl -s -o /dev/null -w '%{http_code}' https://<host>/internal is 503 |
| shipped | [A ReadWriteOnce volume for the SQLite database and files](#req-relaycast-storage) | operator | values `persistence.existingClaim`, `persistence.storageClass`, `persistence.accessMode`, `persistence.size`, `replicaCount` | kubectl get pvc -n relaycast Bound; helm template refuses replicaCount != 1 |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [Install the Relaycast core](#opt-stack-relaycast) | `installed` | `installed` |  |
| shipped | [GKE BackendConfig binding for the Relaycast Service](#opt-relaycast-service-backend-config) | `empty`, `<gkeIngress.name>-cast` | `empty` | values `service.backendConfig` |
| shipped | [Relaycast ingress scheme](#opt-relaycast-exposure) | `internal`, `ingress-tls`, `ingress-external-tls` | `internal` | values `allowInsecureBaseUrl`, `privateDnsSuffixes`, `insecureBaseUrlHosts`, `ingress.enabled`, `ingress.externalTls`, `service.type`; env `RELAYCAST_ALLOW_INSECURE_BASE_URL`, `RELAYCAST_PRIVATE_DNS_SUFFIXES`, `RELAYCAST_INSECURE_BASE_URL_HOSTS` |
| shipped | [Anonymous workspace creation](#opt-relaycast-workspace-create) | `false`, `true` | `false` | values `publicWorkspaceCreate`, `bootstrapProofRequired`; env `RELAYCAST_PUBLIC_WORKSPACE_CREATE`, `RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED` |
| shipped | [Message retention and mailbox limits](#opt-relaycast-retention) | `<positive integer>`, `""` | (no default) | values `retention.messageTtlDays`, `mailbox.ttlMs`, `mailbox.depthCap`; env `RELAYCAST_MESSAGE_TTL_DAYS`, `RELAYCAST_MAILBOX_TTL_MS`, `RELAYCAST_MAILBOX_DEPTH_CAP` |
| shipped | [Scheduled SQLite and file backups](#opt-relaycast-backup) | `false`, `true` | `false` | values `backup.*` |
| shipped | [Relaycast runtime backend](#opt-relaycast-runtime-backend) | `sqlite`, `aws-ha` (**planned**), `gcp-ha` (**planned**) | `sqlite` | values `runtime.backend` |
| shipped | [Workspace credential format and authority (ar_ / model B)](#opt-relaycast-credential-authority) | `legacy`, `ar` | `legacy` | values `credentials.*`; env `RELAYCAST_CREDENTIAL_FORMAT`, `RELAYCAST_RELAYAUTH_URL` |
| shipped | [Relaycast NetworkPolicy](#opt-relaycast-network-policy) | `true`, `false` | `true` | values `networkPolicy.enabled`, `networkPolicy.ingressFrom` |
| shipped | [Image pull Secrets for the Relay charts](#opt-charts-image-pull-secrets) | `[]`, `[{name: <secret>}]` | `[]` | values `relaycast:imagePullSecrets`, `relayauth:imagePullSecrets`, `relayfile:imagePullSecrets`, `relayflows:imagePullSecrets` |

### Profile: relayauth

**RelayAuth issuer.** Single-writer SQLite issuer with externally managed signing keys and an optional JWKS-only ingress. Its JWKS URL is what alleyoop and relayfile verify against.

chart `relayauth` · install: `helm install relayauth agentworkforce/relayauth --set existingSecret=relayauth-secrets`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [RelayAuth secret and signing keys](#req-relayauth-secret) | operator | values `existingSecret`, `secretKeys`, `secretKeys.internalSecret`, `secretKeys.signingKey`, `secretKeys.bootstrapApiKey`, `secretKeys.relaycastCredentialKeyring`, `secretKeys.relaycastInternalSecret`, `secretKeys.relaycastServiceApiKey`; env `INTERNAL_SECRET_FILE`, `RELAYAUTH_SIGNING_KEY_PEM_FILE`, `RELAYAUTH_BOOTSTRAP_API_KEY_FILE`, `RELAYAUTH_RELAYCAST_CREDENTIAL_KEYRING_FILE`, `RELAYAUTH_RELAYCAST_INTERNAL_SECRET_FILE`, `RELAYAUTH_RELAYCAST_SERVICE_API_KEY_FILE`; Secret `<existingSecret, e.g. relayauth-secrets>` keys `internal-secret`, `signing-key.pem`, `bootstrap-api-key`, `<operator-chosen, no default>`, `<operator-chosen, no default>`, `<operator-chosen, no default>` | kubectl get secret relayauth-secrets -o jsonpath='{.data}' has the three required keys, plus the relaycast* keys when secretKeys.relaycastCredentialKeyring is set; helm template fails with "existingSecret is required" (or the relaycast* pairing errors) otherwise |
| shipped | [A ReadWriteOnce volume for the RelayAuth SQLite database](#req-relayauth-storage) | operator | values `persistence.existingClaim`, `persistence.storageClass`, `persistence.size`, `replicaCount` | kubectl get pvc Bound; helm template refuses replicaCount != 1 |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [Run RelayAuth in-cluster or use a hosted issuer](#opt-stack-relayauth) | `installed`, `external` | `installed` |  |
| shipped | [Image pull Secrets for the Relay charts](#opt-charts-image-pull-secrets) | `[]`, `[{name: <secret>}]` | `[]` | values `relaycast:imagePullSecrets`, `relayauth:imagePullSecrets`, `relayfile:imagePullSecrets`, `relayflows:imagePullSecrets` |
| shipped | [Signing key rotation slots](#opt-relayauth-key-rotation) | `""`, `<secret key name>` | `""` | values `secretKeys.signingKeyPublic`, `secretKeys.signingKeyNext`, `secretKeys.signingKeyPrevious`; env `RELAYAUTH_SIGNING_KEY_PEM_PUBLIC_FILE`, `RELAYAUTH_SIGNING_KEY_PEM_NEXT_FILE`, `RELAYAUTH_SIGNING_KEY_PEM_PREVIOUS_FILE` |
| shipped | [RelayAuth base URL and issuer](#opt-relayauth-issuer) | `""`, `https://<public host>` | `""` | values `baseUrl`, `issuer`; env `BASE_URL`, `RELAYAUTH_ISSUER` |
| shipped | [Public JWKS ingress](#opt-relayauth-jwks-ingress) | `false`, `true` | `false` | values `jwksIngress.*`, `networkPolicy.enabled`, `networkPolicy.ingressFrom`; Secret `<jwksIngress.tls[].secretName>` (kubernetes.io/tls for the JWKS host) |
| shipped | [CORS allowlist and RelayHistory assertion options](#opt-relayauth-cors-history) | `<any>` | `allowedOrigins=`, `allowPrivateHttpOrigin=false`, `bootstrapApiKeyOrg=org_selfhost` | values `cors.allowedOrigins`, `relayhistory.allowPrivateHttpOrigin`, `relayhistory.bootstrapApiKeyOrg`; env `ALLOWED_ORIGINS`, `RELAYAUTH_ALLOW_PRIVATE_HTTP_HISTORY_ORIGIN`, `RELAYAUTH_BOOTSTRAP_API_KEY_ORG` |
| shipped | [Push RelayAuth-issued ar_ workspace credentials into Relaycast (model B)](#opt-relayauth-relaycast-credentials) | `""`, `configured` | `""` | values `relaycast.url`; env `RELAYAUTH_RELAYCAST_URL` |
| shipped | [Retire a legacy Deployment while retaining resources](#opt-legacy-deployment-retirement) | `true`, `false` | `true` | values `deployment.enabled` |

### Profile: relay-control

**Self-host control-plane API.** Single-replica self-host API with normal migration Job and existing Secrets only; no HA claim.

chart `relay-control` · values [`ci/default-values.yaml`](../charts/relay-control/ci/default-values.yaml) · install: `helm install relay-control agentworkforce/relay-control -f values.yaml --set image.repository=<verified-repository> --set image.digest=sha256:<digest>`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [Session read API handoff and token introspection for Control](#req-relay-control-session-read) | operator | values `services.relayhistoryBackend`, `services.sessionReadApiUrl`, `services.sessionReadApiPublicUrl`, `services.sessionReadApiMcpReads`, `secretKeys.sessionReadApiSecret`, `secretKeys.introspectSecret`, `introspection.audiences`; env `RELAYHISTORY_BACKEND`, `SESSION_READ_API_URL`, `SESSION_READ_API_PUBLIC_URL`, `SESSION_READ_API_SECRET_FILE`, `SESSION_READ_API_MCP_READS`, `RELAYCONTROL_INTROSPECT_SECRET_FILE`, `SELFHOST_INTROSPECT_AUDIENCES` | helm template renders no SESSION_READ_API_* or introspection env by default, and renders each one with the secrets as mounted files when configured. |
| shipped | [Self-host control-plane existing Secret and service configuration](#req-relay-control-config) | operator | values `publicUrl`, `services.*`, `existingSecret`, `secretKeys.*`, `database.runtimeRole`, `encryption.keyId`, `ingress.tls`, `imagePullSecrets`; env `SELFHOST_ENCRYPTION_KEY_ID`, `DATABASE_URL_FILE`, `DATABASE_MIGRATIONS_URL_FILE`, `SELFHOST_RUNTIME_DATABASE_ROLE`, `RELAYAUTH_API_KEY_FILE`, `SELFHOST_BOOTSTRAP_TOKEN_FILE`, `SELFHOST_ENCRYPTION_KEY_FILE`, `SELFHOST_PUBLIC_URL`, `RELAYAUTH_URL`, `RELAYCAST_URL`, `RELAYCAST_PUBLIC_URL`, `RELAYHISTORY_URL`, `RELAYHISTORY_PUBLIC_URL`; Secret `<existingSecret>` keys `database-url`, `database-migrations-url`, `relayauth-api-key`, `selfhost-bootstrap-token`, `selfhost-encryption-key`; Secret `<ingress.tls[].secretName>` (kubernetes.io/tls, normally managed by the GKE ingress certificate path); Secret `<imagePullSecrets[].name>` (optional registry pull Secret) | helm template fails without existingSecret, encryption.keyId, immutable image digest or valid public service origins; the migration Job invokes migrate-cli.js directly and projects only database-migrations-url |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [CA bundle for verifying the Postgres server certificate (postgresCa)](#opt-postgres-ca-bundle) | `false`, `true` | `false` | values `worker.postgresCa.*`, `alleyoop.postgresCa.*`, `relay-control:postgresCa.*`, `relaychief-control:postgresCa.*`, `relayfile-control:postgresCa.*`; env `NODE_EXTRA_CA_CERTS`, `PGSSLROOTCERT` |
| shipped | [Control collector analytics adapter](#opt-relay-control-collector-analytics) | `false`, `true` | `false` | values `analytics.*`; env `SELFHOST_ANALYTICS_DESTINATION`, `SELFHOST_ANALYTICS_PROFILE`, `SELFHOST_ANALYTICS_DEPLOYMENT_ID`, `SELFHOST_ANALYTICS_COLLECTOR_URL`, `SELFHOST_ANALYTICS_COLLECTOR_TOKEN_FILE`, `SELFHOST_ANALYTICS_COLLECTOR_CA_FILE`; Secret `<Control component-bound analytics producer Secret>` keys `token` |
| shipped | [Separate Control introspection credential Secret](#opt-relay-control-external-introspection-secret) | `disabled`, `enabled` | `disabled` | values `introspection.existingSecret`, `introspection.key`; env `RELAYCONTROL_INTROSPECT_SECRET_FILE`; Secret `<Control introspection Secret>` keys `introspect-secret` |
| shipped | [Previous encryption key during a key rotation](#opt-relay-control-encryption-rotation) | `none`, `previous key` | `none` | values `encryption.previousKeyId`, `secretKeys.previousEncryptionKey`; env `SELFHOST_ENCRYPTION_PREVIOUS_KEY_ID`, `SELFHOST_ENCRYPTION_PREVIOUS_KEY_FILE`; Secret `<existingSecret>` keys `<operator-chosen, no default>` |
| shipped | [Internal service token for /internal/v1](#opt-relay-control-internal-token) | `disabled`, `enabled` | `disabled` | values `secretKeys.internalToken`; env `SELFHOST_INTERNAL_TOKEN_FILE`; Secret `<existingSecret>` keys `<operator-chosen, no default>` |
| shipped | [Dashboard URL for OAuth callbacks and flow run links](#opt-relay-control-dashboard-url) | `publicUrl + "/"`, `dashboard origin` | `publicUrl + "/"` | values `dashboardUrl`; env `SELFHOST_DASHBOARD_URL` |
| shipped | [First-boot organization, owner and default workspace](#opt-relay-control-bootstrap) | `disabled`, `enabled` | `disabled (manual bootstrap with the bootstrap token)` | values `bootstrap.*`, `secretKeys.relaycastInternalSecret`; env `SELFHOST_BOOTSTRAP_ORG_NAME`, `SELFHOST_BOOTSTRAP_ADMIN_EMAIL`, `SELFHOST_BOOTSTRAP_ADMIN_NAME`, `SELFHOST_BOOTSTRAP_WORKSPACE_NAME`, `RELAYCAST_INTERNAL_SECRET_FILE`; Secret `<existingSecret>` keys `<operator-chosen, e.g. relaycast-internal-secret>` |
| shipped | [Sign-in methods (OIDC, email links), invites and auto-join](#opt-relay-control-sign-in) | `none`, `oidc`, `microsoft`, `email links`, `oidc and email links`, `password` | `none (operator break-glass only)` | values `auth.*`, `secretKeys.oidcClientSecret`, `secretKeys.microsoftClientSecret`, `secretKeys.setupKey`; env `SELFHOST_OIDC_ISSUER`, `SELFHOST_OIDC_CLIENT_ID`, `SELFHOST_OIDC_CLIENT_SECRET_FILE`, `SELFHOST_OIDC_ALLOWED_DOMAINS`, `SELFHOST_OIDC_DISPLAY_NAME`, `SELFHOST_OIDC_SCOPES`, `SELFHOST_OIDC_REDIRECT_URL`, `SELFHOST_OIDC_ALLOW_HTTP_ISSUER`, `SELFHOST_MICROSOFT_CLIENT_ID`, `SELFHOST_MICROSOFT_CLIENT_SECRET_FILE`, `SELFHOST_MICROSOFT_TENANT`, `SELFHOST_MICROSOFT_REDIRECT_URL`, `SELFHOST_EMAIL_LOGIN`, `SELFHOST_SIGNIN_METHODS`, `SELFHOST_TRUSTED_PROXIES`, `SELFHOST_SETUP_KEY_FILE`, `SELFHOST_AUTO_JOIN_DOMAINS`, `SELFHOST_INVITE_TTL_HOURS`; Secret `<existingSecret>` keys `<operator-chosen, e.g. oidc-client-secret>`, `<operator-chosen, e.g. microsoft-client-secret>`, `<operator-generated, e.g. selfhost-setup-key>` |
| shipped | [SMTP for invite emails and sign-in links](#opt-relay-control-smtp) | `none`, `smtp` | `none (copy invite links)` | values `smtp.*`, `secretKeys.smtpPassword`; env `SELFHOST_SMTP_HOST`, `SELFHOST_SMTP_PORT`, `SELFHOST_SMTP_SECURITY`, `SELFHOST_SMTP_USERNAME`, `SELFHOST_SMTP_PASSWORD_FILE`, `SELFHOST_EMAIL_FROM`; Secret `<existingSecret>` keys `<operator-chosen, e.g. smtp-password>` |
| shipped | [Password pepper for password sign-in](#opt-relay-control-password-pepper) | `none`, `pepper` | `none (no pepper)` | values `secretKeys.passwordPepper`; env `SELFHOST_PASSWORD_PEPPER_FILE`; Secret `<existingSecret>` keys `<operator-chosen, e.g. password-pepper>` |
| shipped | [Integration OAuth apps for just-in-time connects](#opt-relay-control-integrations) | `none`, `one entry per provider with existingSecret` | `none (no integration can be connected until its app is configured)` | values `integrations`; Secret `<operator-chosen, integrations.<provider>.existingSecret>` keys `client-id`, `client-secret` |
| shipped | [Relayflows control-plane storage and worker queue](#opt-relay-control-flows) | `postgres`, `gcs` | `postgres` | values `flows.*`; env `SELFHOST_FLOWS_STORAGE`, `SELFHOST_FLOWS_GCS_BUCKET`, `SELFHOST_FLOWS_GCS_PREFIX`, `SELFHOST_FLOWS_WORKER_RELAYCAST_URL`, `SELFHOST_FLOWS_QUEUE_PING_MS` |
| shipped | [Self-host telemetry level and transport](#opt-relay-control-telemetry) | `errors`, `full`, `off` | `errors` | values `telemetry.*`, `secretKeys.telemetryInstallKey`; env `SELFHOST_TELEMETRY_LEVEL`, `SELFHOST_TELEMETRY_TRANSPORT`, `SELFHOST_TELEMETRY_ENDPOINT`, `SELFHOST_TELEMETRY_INSTALL_ID`, `SELFHOST_TELEMETRY_INSTALL_KEY_FILE`, `SELFHOST_TELEMETRY_PROBES`, `SELFHOST_TELEMETRY_DEPLOYMENT`; Secret `<existingSecret>` keys `<operator-chosen, no default>` |
| shipped | [Sign-in page logo and organization name](#opt-relay-control-login-cobrand) | `none`, `hosted logo (global.branding.logo)`, `external https URL (login.logoUrl)` | `none (no customer logo; login-config logo_url and org_name are null)` | values `login.*`, `global.branding.logo.*`; env `SELFHOST_LOGIN_LOGO_URL`, `SELFHOST_LOGIN_ORG_NAME` |
| shipped | [Control legacy RelayAuth client environment](#opt-control-legacy-relayauth) | `true`, `false` | `true` | values `services.relayauthEnabled`; env `RELAYAUTH_URL`, `RELAYAUTH_API_KEY_FILE` |
| shipped | [Explicit optional Control features](#opt-relay-control-selected-features) | (no default), `[]`, `["flows","relayfile","chief"]`, `["usage"]`, `["launch"]`, `["usage","usage_people"]` | (no default) | values `selectedFeatures`; env `SELFHOST_FEATURES` |
| shipped | [Existing caller-token native reader connection](#opt-relay-control-direct-native-reader) | `disabled`, `enabled` | `disabled` | values `services.relayhistoryReadApiUrl`, `services.relayhistoryReadApiEvents`, `services.relayhistoryHostAliases`; env `RELAYHISTORY_READ_API_URL`, `RELAYHISTORY_READ_API_EVENTS` |
| shipped | [Direct S3 upload credential issuer](#opt-history-direct-upload-issuer) | `off`, `allowlist`, `on` | `off` | values `historyUpload.*`; env `SELFHOST_HISTORY_UPLOAD_DIRECT`, `SELFHOST_HISTORY_UPLOAD_ALLOWLIST`, `SELFHOST_HISTORY_UPLOAD_BUCKET`, `SELFHOST_HISTORY_UPLOAD_REGION`, `SELFHOST_HISTORY_UPLOAD_KEY_ROOT`, `SELFHOST_HISTORY_UPLOAD_ROLE_ARN`, `SELFHOST_HISTORY_UPLOAD_KMS_KEY_ARN`, `SELFHOST_HISTORY_UPLOAD_MAX_OBJECT_BYTES`, `SELFHOST_HISTORY_UPLOAD_WITNESS_KEY_FILE`, `SELFHOST_HISTORY_UPLOAD_PUBLIC_ENDPOINT`, `SELFHOST_HISTORY_UPLOAD_INTERNAL_ENDPOINT`, `SELFHOST_HISTORY_UPLOAD_ACCESS_KEY_ID_FILE`, `SELFHOST_HISTORY_UPLOAD_SECRET_ACCESS_KEY_FILE`; Secret `<operator-chosen shared upload witness Secret>` keys `upload-witness-key`; Secret `<operator-chosen dedicated compatible-store issuer Secret>` keys `access-key-id`, `secret-access-key` |

### Profile: relay-webapp

**Self-host dashboard.** Static dashboard whose ingress sends same-origin /cloud/api to relay-control.

chart `relay-webapp` · values [`ci/default-values.yaml`](../charts/relay-webapp/ci/default-values.yaml) · install: `helm install relay-webapp agentworkforce/relay-webapp -f values.yaml --set image.digest=sha256:<digest>`

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [Dashboard ingress and same-origin API proxy](#opt-relay-webapp-ingress) | `enabled`, `disabled` | `enabled` | values `runtime.publicUrl`, `runtime.appPath`, `runtime.apiBasePath`, `runtime.loginPath`, `ingress.tls`, `imagePullSecrets`; env `DASHBOARD_PUBLIC_URL`, `DASHBOARD_APP_PATH`, `DASHBOARD_API_BASE_PATH`, `DASHBOARD_LOGIN_PATH`, `DASHBOARD_SESSION_READ_API_ENABLED`; Secret `<ingress.tls[].secretName>` (kubernetes.io/tls); Secret `<imagePullSecrets[].name>` (optional registry pull Secret) |
| shipped | [Dashboard customer profile (enterprise branding)](#opt-relay-webapp-customer-profile) | `none`, `customer profile` | `none` | values `customerProfile`; env `DASHBOARD_CUSTOMER_PROFILE` |
| shipped | [Hosted customer logo (sign-in page co-branding)](#opt-relay-webapp-branding-logo) | `none`, `inline SVG`, `existing ConfigMap (PNG)` | `none (no hosted logo)` | values `global.branding.logo.*` |
| shipped | [Dashboard collector analytics runtime selection](#opt-relay-webapp-collector-analytics) | (no default), `true`, `false` | (no default) | values `runtime.analyticsEnabled`; env `DASHBOARD_ANALYTICS_ENABLED` |
| shipped | [Dashboard coordination-overlaps view](#opt-relay-webapp-coordination-overlaps) | `false`, `true` | `false` | values `runtime.coordinationOverlapsEnabled`; env `DASHBOARD_COORDINATION_OVERLAPS_ENABLED` |

### Profile: agent-relay

**GCP messaging and Sessions suite.** Relaycast, RelayAuth, Sessions Pipeline, Relay History, control-plane API and dashboard; Relayflows is opt-in via components.relayflows, Relayfile is excluded.

chart `agent-relay` · values [`values-gcp-proof.yaml`](../charts/agent-relay/values-gcp-proof.yaml), [`values-gcp-proof-live.yaml`](../charts/agent-relay/values-gcp-proof-live.yaml), [`ci/gcp-proof-values.yaml`](../charts/agent-relay/ci/gcp-proof-values.yaml) · install: `helm install agent-relay agentworkforce/agent-relay -f values-gcp-proof.yaml -f values-gcp-proof-live.yaml --set relay-control.image.digest=sha256:<digest>`

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [CA bundle for verifying the Postgres server certificate (postgresCa)](#opt-postgres-ca-bundle) | `false`, `true` | `false` | values `worker.postgresCa.*`, `alleyoop.postgresCa.*`, `relay-control:postgresCa.*`, `relaychief-control:postgresCa.*`, `relayfile-control:postgresCa.*`; env `NODE_EXTRA_CA_CERTS`, `PGSSLROOTCERT` |
| shipped | [Control collector analytics adapter](#opt-relay-control-collector-analytics) | `false`, `true` | `false` | values `analytics.*`; env `SELFHOST_ANALYTICS_DESTINATION`, `SELFHOST_ANALYTICS_PROFILE`, `SELFHOST_ANALYTICS_DEPLOYMENT_ID`, `SELFHOST_ANALYTICS_COLLECTOR_URL`, `SELFHOST_ANALYTICS_COLLECTOR_TOKEN_FILE`, `SELFHOST_ANALYTICS_COLLECTOR_CA_FILE`; Secret `<Control component-bound analytics producer Secret>` keys `token` |
| shipped | [Separate Control introspection credential Secret](#opt-relay-control-external-introspection-secret) | `disabled`, `enabled` | `disabled` | values `introspection.existingSecret`, `introspection.key`; env `RELAYCONTROL_INTROSPECT_SECRET_FILE`; Secret `<Control introspection Secret>` keys `introspect-secret` |
| shipped | [Single-host mode for the dashboard and the control API](#opt-agent-relay-single-host) | `disabled`, `enabled` | `disabled` | values `global.singleHost.host`, `relay-control:global.singleHost.host`, `relay-control:publicUrl`, `relay-webapp:global.singleHost.host`, `relay-webapp:runtime.publicUrl`, `relay-webapp:ingress.host`; env `SELFHOST_PUBLIC_URL`, `DASHBOARD_PUBLIC_URL` |
| shipped | [Single GKE ingress for the proof hosts](#opt-agent-relay-gke-ingress) | `enabled`, `disabled` | `disabled` | values `gkeIngress.enabled`, `gkeIngress.staticIpName`, `gkeIngress.managedCertificateName`, `gkeIngress.frontendConfigName`, `gkeIngress.hosts.*`, `gkeIngress.backends.*`, `relayauth.jwksIngress.enabled` |
| shipped | [Optional Relayflows component in the suite](#opt-agent-relay-relayflows) | `enabled`, `disabled` | `disabled` | values `components.relayflows`, `relayflows.*` |
| shipped | [Control legacy RelayAuth client environment](#opt-control-legacy-relayauth) | `true`, `false` | `true` | values `services.relayauthEnabled`; env `RELAYAUTH_URL`, `RELAYAUTH_API_KEY_FILE` |
| shipped | [Native pipeline collector adapters](#opt-native-pipeline-analytics) | `false`, `true` | `false` | values `ingestEdge.analytics.*`, `nativeConsumer.analytics.*`, `session-read-api:analytics.*`; env `ANALYTICS_SINK`, `ANALYTICS_DEPLOYMENT_ID`, `ANALYTICS_COLLECTOR_URL`, `ANALYTICS_COLLECTOR_TOKEN`, `NODE_EXTRA_CA_CERTS`; Secret `<ingest component-bound analytics producer Secret>` keys `token`; Secret `<consumer component-bound analytics producer Secret>` keys `token`; Secret `<reader component-bound analytics producer Secret>` keys `token` |
| shipped | [Operator session erase fences, API, and byte deletion](#opt-operator-session-erase) | `false`, `true` | `false` | values `global.operatorSessionErase.*`, `operatorSessionErase.*`, `session-read-api:global.operatorSessionErase.*`, `relay-control:sessionErasureApi.*`; env `SESSION_ERASE_FENCE_ENFORCED`, `SESSION_ERASE_API_ENABLED`, `SESSION_ERASE_API_URL`, `SESSION_ERASE_API_SECRET`, `SESSION_ERASE_API_SECRET_PREVIOUS`, `SESSION_ERASE_BYTES_ENABLED`, `SESSION_ERASE_S3_BUCKET`, `SESSION_ERASE_S3_REGION`, `SESSION_ERASE_S3_ENDPOINT`, `SESSION_ERASE_KEY_ROOT`, `SESSION_ERASE_S3_ACCESS_KEY_ID`, `SESSION_ERASE_S3_SECRET_ACCESS_KEY`, `SESSION_ERASE_SEARCH_POSTGRES_URL`, `SESSION_ERASE_OPENSEARCH_USERNAME`, `SESSION_ERASE_OPENSEARCH_PASSWORD`; Secret `<dedicated operator session erase API Secret>` keys `SESSION_ERASE_API_SECRET`, `<operator-chosen previous API key>`; Secret `<dedicated session eraser S3 Secret>` keys `SESSION_ERASE_S3_ACCESS_KEY_ID`, `SESSION_ERASE_S3_SECRET_ACCESS_KEY`; Secret `<dedicated session erase Postgres search Secret>` keys `SESSION_ERASE_SEARCH_POSTGRES_URL`; Secret `<dedicated session erase OpenSearch Secret>` keys `SESSION_ERASE_OPENSEARCH_USERNAME`, `SESSION_ERASE_OPENSEARCH_PASSWORD` |
| shipped | [Retire a legacy Deployment while retaining resources](#opt-legacy-deployment-retirement) | `true`, `false` | `true` | values `deployment.enabled` |

### Profile: relayfile

**Relayfile server.** Go server, Postgres-backed in production. Inclusion in the self-host product is unresolved (docs/self-hosted-reference-architecture.md).

chart `relayfile` · install: `helm install relayfile agentworkforce/relayfile --set secrets.existingSecret=relayfile-secrets --set auth.jwksUrl=<jwks url>`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [Relayfile credentials Secret](#req-relayfile-secret) | operator | values `secrets.existingSecret`, `secrets.productionDsn`, `secrets.internalHmacSecret`, `secrets.jwtSecret`; env `RELAYFILE_PRODUCTION_DSN`, `RELAYFILE_INTERNAL_HMAC_SECRET`, `RELAYFILE_JWT_SECRET`; Secret `<secrets.existingSecret>` keys `RELAYFILE_PRODUCTION_DSN`, `RELAYFILE_INTERNAL_HMAC_SECRET`, `RELAYFILE_JWT_SECRET` | helm template fails with "secrets.internalHmacSecret is required" without either |
| shipped | [A Postgres database for Relayfile (production profile)](#req-relayfile-postgres) | operator | values `server.backendProfile` | psql "$RELAYFILE_PRODUCTION_DSN" -c 'select 1' |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [Image pull Secrets for the Relay charts](#opt-charts-image-pull-secrets) | `[]`, `[{name: <secret>}]` | `[]` | values `relaycast:imagePullSecrets`, `relayauth:imagePullSecrets`, `relayfile:imagePullSecrets`, `relayflows:imagePullSecrets` |
| shipped | [Relayfile storage backend profile](#opt-relayfile-backend-profile) | `production`, `memory`, `durable-local`, `custom` | `production` | values `server.backendProfile`; env `RELAYFILE_BACKEND_PROFILE` |
| shipped | [Relayfile RelayAuth JWKS](#opt-relayfile-auth) | `<jwks url>` | `""` | values `auth.jwksUrl`; env `RELAYAUTH_JWKS_URL` |
| shipped | [Relayfile Notion provider](#opt-relayfile-notion) | `""`, `<token>` | `""` | values `providers.notion.token`, `providers.notion.baseUrl`, `providers.notion.apiVersion`; env `RELAYFILE_NOTION_TOKEN`, `RELAYFILE_NOTION_BASE_URL`, `RELAYFILE_NOTION_API_VERSION`; Secret `<secrets.existingSecret>` keys `RELAYFILE_NOTION_TOKEN` |
| shipped | [Relayfile server tuning](#opt-relayfile-server-tuning) | `<any>` | `port=8080`, `envelopeWorkers=2`, `writebackWorkers=2`, `providerMaxConcurrency=4` | values `server.addr`, `server.port`, `server.envelopeWorkers`, `server.writebackWorkers`, `server.providerMaxConcurrency`, `server.rateLimitMax`, `server.rateLimitWindow`, `server.maxBodyBytes`; env `RELAYFILE_ADDR`, `RELAYFILE_ENVELOPE_WORKERS`, `RELAYFILE_WRITEBACK_WORKERS`, `RELAYFILE_PROVIDER_MAX_CONCURRENCY`, `RELAYFILE_RATE_LIMIT_MAX`, `RELAYFILE_RATE_LIMIT_WINDOW`, `RELAYFILE_MAX_BODY_BYTES` |
| shipped | [Relayfile ingress](#opt-relayfile-ingress) | `false`, `true` | `false` | values `ingress.*`; Secret `<ingress.tls[].secretName>` (kubernetes.io/tls) |

### Profile: relayflows

**Relayflows (standalone Job, or Cloud worker).** Off by default in the product. standalone runs a flow in a Kubernetes Job with no Agent Relay Cloud contact; cloudWorker enrolls a Cloud worker.

chart `relayflows` · install: `helm install relayflows agentworkforce/relayflows --set image.repository=<flow image> --set standalone.flow.path=<flow>`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [Cloud worker enrollment token (cloudWorker mode only)](#req-relayflows-enrollment-secret) | operator | values `credentials.existingSecret`, `credentials.existingSecretKey`, `credentials.enrollmentToken`; env `AGENT_RELAY_WORKER_ENROLLMENT_TOKEN`; Secret `<credentials.existingSecret>` keys `AGENT_RELAY_WORKER_ENROLLMENT_TOKEN` | the worker's startup probe (agent-relay cloud worker status) passes |
| shipped | [A ReadWriteOncePod volume for run journals or worker state](#req-relayflows-storage) | operator | values `persistence.*` | kubectl get pvc Bound; the StorageClass supports ReadWriteOncePod (CSI, Kubernetes 1.29+) |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [Image pull Secrets for the Relay charts](#opt-charts-image-pull-secrets) | `[]`, `[{name: <secret>}]` | `[]` | values `relaycast:imagePullSecrets`, `relayauth:imagePullSecrets`, `relayfile:imagePullSecrets`, `relayflows:imagePullSecrets` |
| shipped | [Relayflows mode](#opt-relayflows-mode) | `standalone`, `cloudWorker` | `standalone` | values `mode`, `worker.name`, `worker.cloudUrl`; env `AGENT_RELAY_CLOUD_URL`, `AGENT_RELAY_WORKER_NAME`, `FLOWS_CLOUD_MIRROR`, `AGENT_RELAY_TELEMETRY_DISABLED` |
| shipped | [Standalone flow source, input and resume](#opt-relayflows-flow-source) | `path`, `content`, `existingConfigMap` | (no default) | values `standalone.flow.*`, `standalone.input`, `standalone.resumeRunId`, `standalone.cron.*`; env `RELAYFLOWS_FLOW_PATH`, `RELAYFLOWS_INPUT`, `RELAYFLOWS_RUN_ID` |
| shipped | [Relayflows runtime, local agents and model credentials](#opt-relayflows-runtime) | `<any>` | `runtimeInstaller=true`, `localAgent=true`, `agentCapacity=1` | values `runtimeInstaller.*`, `standalone.localAgent`, `standalone.agentCapacity`, `standalone.dataDir`, `extraEnvFrom`; env `RELAYFLOWS_VERSION`, `AGENT_RELAY_VERSION`, `RELAYFLOWS_AGENT_CAPACITY`, `RELAYFLOWS_DATA_DIR` |

### Profile: relay-chief

**Relay Chief (scheduled coordination cycles).** Not qualified and not part of the suite yet; no image is published. Suspended by default. Runs one bounded cycle per CronJob firing against SQLite on a persistent volume, and every cycle may dispatch.

chart `relay-chief` · values [`ci/default-values.yaml`](../charts/relay-chief/ci/default-values.yaml) · install: `helm install relay-chief agentworkforce/relay-chief -f <your values>`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [Relay and control-plane origins](#req-relay-chief-origins) | operator | values `relay.baseUrl`, `controlPlane.url`; env `RELAY_BASE_URL`, `CHIEF_CONTROL_PLANE_URL` | helm template fails with "relay.baseUrl is required" when it is unset |
| shipped | [Relay Chief runtime credentials](#req-relay-chief-credentials) | operator | values `existingSecret`, `secretKeys.*`; env `RELAY_AGENT_TOKEN`, `TYPESAFE_API_KEY`, `CHIEF_CONTROL_PLANE_TOKEN`; Secret `<existingSecret>` keys `relay-agent-token`, `typesafe-api-key`, `control-plane-token` | helm template fails with "existingSecret is required" when it is unset; after setting suspend to false, a cycle's Job starts without a CreateContainerConfigError |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [Relay Chief image pull Secrets](#opt-relay-chief-image-pull-secrets) | `none`, `listed` | `none` | values `imagePullSecrets` |

### Profile: relaychief-control

**Relay Chief control add-on.** Optional add-on outside the agent-relay umbrella; not qualified. One replica, operator-managed PostgreSQL, a loopback-only admin listener and an Ingress limited to /chief/v1 by default; no HA claim.

chart `relaychief-control` · values [`ci/default-values.yaml`](../charts/relaychief-control/ci/default-values.yaml) · install: `helm install relaychief-control agentworkforce/relaychief-control -f <your values>`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [Relay Chief control origins](#req-relaychief-control-config) | operator | values `config.relaycontrolUrl`, `config.publicOrigin`; env `RELAYCONTROL_URL`, `RELAYCHIEF_CONTROL_PUBLIC_ORIGIN` | helm template fails with "config.relaycontrolUrl (RELAYCONTROL_URL) is required" or "config.publicOrigin (RELAYCHIEF_CONTROL_PUBLIC_ORIGIN) is required" when one is unset |
| shipped | [Relay Chief control database URL and service secrets](#req-relaychief-control-credentials) | operator | values `existingSecret`, `secretKeys.*`; env `DATABASE_URL`, `RELAYCONTROL_INTROSPECT_SECRET`, `RELAYCHIEF_CONTROL_ADMIN_TOKEN`; Secret `<existingSecret>` keys `DATABASE_URL`, `RELAYCONTROL_INTROSPECT_SECRET`, `RELAYCHIEF_CONTROL_ADMIN_TOKEN`, `<operator-chosen, e.g. NANGO_SECRET_KEY>`, `<operator-chosen, e.g. RELAYCHIEF_CONTROL_RELAY_SECRET>`, `<operator-chosen, e.g. RELAYCHIEF_CONTROL_ENCRYPTION_KEY_ID>`, `<operator-chosen, e.g. RELAYCHIEF_CONTROL_ENCRYPTION_KEY>` | helm template fails with "existingSecret is required" when it is unset; the pod starts without a CreateContainerConfigError and /readyz answers 200 |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [CA bundle for verifying the Postgres server certificate (postgresCa)](#opt-postgres-ca-bundle) | `false`, `true` | `false` | values `worker.postgresCa.*`, `alleyoop.postgresCa.*`, `relay-control:postgresCa.*`, `relaychief-control:postgresCa.*`, `relayfile-control:postgresCa.*`; env `NODE_EXTRA_CA_CERTS`, `PGSSLROOTCERT` |
| shipped | [Relay Chief control Nango host and browser origins](#opt-relaychief-control-nango) | `unset`, `hosted`, `self-hosted` | `unset` | values `config.nangoHost`, `config.browserOrigins`; env `NANGO_HOST`, `NANGO_SECRET_KEY`, `RELAYCHIEF_CONTROL_BROWSER_ORIGINS` |
| shipped | [Relay Chief control platform-issued Relay identities](#opt-relaychief-control-relay-identity) | `unset`, `set` | `unset` | values `secretKeys.relaySecret`, `secretKeys.encryptionKeyId`, `secretKeys.encryptionKey`; env `RELAYCHIEF_CONTROL_RELAY_SECRET`, `RELAYCHIEF_CONTROL_ENCRYPTION_KEY_ID`, `RELAYCHIEF_CONTROL_ENCRYPTION_KEY` |
| shipped | [Relay Chief control Ingress and NetworkPolicy](#opt-relaychief-control-exposure) | `disabled`, `enabled` | `disabled` | values `ingress.*`, `networkPolicy.*` |
| shipped | [Relay Chief control image pull Secrets](#opt-relaychief-control-image-pull-secrets) | `none`, `listed` | `none` | values `imagePullSecrets` |

### Profile: relayfile-control

**Relayfile control add-on (webhook ingest and Flows API).** Optional add-on outside the agent-relay umbrella; not qualified. One replica, operator-managed PostgreSQL in its own database, migrations at startup, a loopback-only admin listener. Flows and the Ingress are off by default.

chart `relayfile-control` · values [`ci/default-values.yaml`](../charts/relayfile-control/ci/default-values.yaml) · install: `helm install relayfile-control agentworkforce/relayfile-control -f <your values>`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [Relayfile control target URLs](#req-relayfile-control-config) | operator | values `config.relayfileBaseUrl`, `config.relaycontrolBaseUrl`; env `RELAYFILE_BASE_URL`, `RELAYCONTROL_BASE_URL` | helm template fails with "config.relayfileBaseUrl (RELAYFILE_BASE_URL) is required" or "config.relaycontrolBaseUrl (RELAYCONTROL_BASE_URL) is required" when one is unset |
| shipped | [Relayfile control database URL and service secrets](#req-relayfile-control-credentials) | operator | values `existingSecret`, `secretKeys.*`; env `DATABASE_URL`, `RELAYFILE_INTERNAL_HMAC_SECRET`, `RELAYFILE_CONTROL_ADMIN_TOKEN`, `RELAYCONTROL_SERVICE_TOKEN`; Secret `<existingSecret>` keys `DATABASE_URL`, `RELAYFILE_INTERNAL_HMAC_SECRET`, `RELAYFILE_CONTROL_ADMIN_TOKEN`, `RELAYCONTROL_SERVICE_TOKEN` | helm template fails with "existingSecret is required" when it is unset; the pod starts without a CreateContainerConfigError and /readyz answers 200 |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [CA bundle for verifying the Postgres server certificate (postgresCa)](#opt-postgres-ca-bundle) | `false`, `true` | `false` | values `worker.postgresCa.*`, `alleyoop.postgresCa.*`, `relay-control:postgresCa.*`, `relaychief-control:postgresCa.*`, `relayfile-control:postgresCa.*`; env `NODE_EXTRA_CA_CERTS`, `PGSSLROOTCERT` |
| shipped | [Relayfile control Flows API](#opt-relayfile-control-flows) | `false`, `true` | `false` | values `flows.enabled`, `config.publicOrigin`, `flows.*`, `secretKeys.introspectSecret`, `secretKeys.brokerSecret`, `secretKeys.encryptionKey`, `secretKeys.previousEncryptionKey`, `secretKeys.telemetrySecret`, `secretKeys.runtimeVerifySecret`; env `FLOWS_ENABLED`, `RELAYFILE_CONTROL_PUBLIC_ORIGIN`, `RELAYFILE_CONTROL_ENCRYPTION_KEY_ID`, `RELAYFILE_CONTROL_ENCRYPTION_PREVIOUS_KEY_ID`, `RELAYFILE_CONTROL_ENCRYPTION_KEY`, `RELAYFILE_CONTROL_ENCRYPTION_PREVIOUS_KEY`, `RELAYCONTROL_INTROSPECT_SECRET`, `RELAYFILE_CONTROL_BROKER_SECRET`, `RELAYFILE_CONTROL_TELEMETRY_SECRET`, `RELAYFILE_CONTROL_RUNTIME_VERIFY_SECRET`, `SELFHOST_FLOWS_WORKER_RELAYCAST_URL`, `RELAYCAST_PUBLIC_URL`, `SELFHOST_FLOWS_WORKER_RELAYFILE_URL`, `SELFHOST_DASHBOARD_URL`, `SELFHOST_FLOWS_STORAGE`, `FLOWS_PUBLIC_BASE_URL` |
| shipped | [Relayfile control provider webhook secrets](#opt-relayfile-control-webhooks) | `unset`, `set` | `unset` | values `secretKeys.githubWebhookSecret`, `secretKeys.nangoWebhookSecret`, `secretKeys.hookdeckWebhookSecret`, `secretKeys.dropboxAppSecret`, `secretKeys.slackSigningSecret`, `secretKeys.linearWebhookSecret`; env `GITHUB_WEBHOOK_SECRET`, `NANGO_WEBHOOK_SECRET`, `HOOKDECK_WEBHOOK_SECRET`, `DROPBOX_APP_SECRET`, `SLACK_SIGNING_SECRET`, `LINEAR_WEBHOOK_SECRET` |
| shipped | [Relayfile control Ingress and NetworkPolicy](#opt-relayfile-control-exposure) | `disabled`, `enabled` | `disabled` | values `ingress.enabled`, `ingress.*`, `networkPolicy.*`, `service.annotations` |
| shipped | [Relayfile control image pull Secrets](#opt-relayfile-control-image-pull-secrets) | `none`, `listed` | `none` | values `imagePullSecrets` |

### Profile: durable-actors

**TerseAI durable-actors control plane (vendored upstream chart).** GKE Sandbox (gVisor) actor hosts, one Standard GCS bucket (Rapid optional), PostgreSQL; more than one controller needs Redis. Only GKE Sandbox and Modal providers exist upstream.

chart `durable-actors` · values [`ci/gcp-values.yaml`](../charts/durable-actors/ci/gcp-values.yaml) · install: `enabled through the agent-relay umbrella (components.durableActors); upstream publishes the chart itself`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [GKE Standard with GKE Sandbox (gVisor), Workload Identity and enforced NetworkPolicy](#req-durable-actors-gke-sandbox) | operator | values `placement.zone`, `sandboxNamespace`, `nodeSelector`, `networkPolicy.dnsCidrs`, `actors.*`, `organizationLimits.*`, `alarms.*`, `resources.*`, `replicaCount`, `podDisruptionBudget.*`, `topologySpread.*`, `analytics.backend`, `usage.topic`, `postgres.maxConnections`; env `DURABLE_ACTORS_PROCESS_ROLE`, `DURABLE_ACTORS_CONTROL_PLANE_BIND`, `DURABLE_ACTORS_ALARM_POLL_INTERVAL_MS`, `DURABLE_ACTORS_POSTGRES_MAX_CONNECTIONS`, `DURABLE_ACTORS_ANALYTICS_BACKEND`, `DURABLE_ACTORS_USAGE_TOPIC`, `DURABLE_ACTORS_ORGANIZATION_LIMITS_ENABLED`, `DURABLE_ACTORS_ORGANIZATION_MAX_ACTIVE_ACTORS`, `DURABLE_ACTORS_ORGANIZATION_ACTOR_STARTS_PER_SECOND`, `DURABLE_ACTORS_ORGANIZATION_ACTOR_START_BURST`, `DURABLE_ACTORS_TYPESCRIPT_IMAGE`, `DURABLE_ACTORS_PYTHON_IMAGE`, `DURABLE_ACTORS_GKE_NAMESPACE`, `DURABLE_ACTORS_GKE_ZONE`, `DURABLE_ACTORS_SPARE_IDLE`, `DURABLE_ACTORS_HOST_IDLE_TIMEOUT_MS`, `DURABLE_ACTORS_SPARE_MAX_STARTING`, `DURABLE_ACTORS_SPARE_REFILL_INTERVAL_MS`, `DURABLE_ACTORS_SPARE_RETIRE_CONCURRENCY`, `DURABLE_ACTORS_SPARE_REAP_INTERVAL_MS`, `DURABLE_ACTORS_SPARE_POD_REAP_INTERVAL_MS`, `DURABLE_ACTORS_GKE_REAP_CONCURRENCY`, `DURABLE_ACTORS_HOST_CPU_MILLIS`, `DURABLE_ACTORS_HOST_CPU_LIMIT_MILLIS`, `DURABLE_ACTORS_HOST_MEMORY_MIB`, `DURABLE_ACTORS_HOST_MEMORY_LIMIT_MIB`, `DURABLE_ACTORS_SANDBOX_MIN_CPU_MILLIS`, `DURABLE_ACTORS_SANDBOX_MAX_CPU_MILLIS`, `DURABLE_ACTORS_SANDBOX_MIN_MEMORY_MIB`, `DURABLE_ACTORS_SANDBOX_MAX_MEMORY_MIB` | kubectl get runtimeclass gvisor; kubectl get nodes -l sandbox.gke.io/runtime=gvisor -L topology.kubernetes.io/zone shows placement.zone |
| shipped | [One Standard GCS bucket for actor state and compiled code (Rapid optional)](#req-durable-actors-bucket) | operator | values `storage.bucket`, `storage.mode`, `storage.rapid.*`; env `DURABLE_ACTORS_PERSISTENCE`, `DURABLE_ACTORS_BUCKET`, `DURABLE_ACTORS_ARTIFACT_BUCKET`, `DURABLE_ACTORS_ARCHIVE_BUCKET`, `DURABLE_ACTORS_RAPID_BUCKETS`, `DURABLE_ACTORS_RAPID_PLACEMENT` | gcloud storage buckets describe gs://<storage.bucket> --format='value(default_storage_class)' is STANDARD |
| shipped | [A GSA bound to the control-plane KSA through Workload Identity](#req-durable-actors-workload-identity) | operator | values `serviceAccount.googleServiceAccount` | gcloud iam service-accounts get-iam-policy <gsa> lists the workloadIdentityUser member |
| shipped | [durable-actors credentials Secret (postgres-url, jwt-signing-key, api-key)](#req-durable-actors-credentials) | operator | values `credentialsSecret`, `invokeApiKeySecretKey`, `redis.urlSecretKey`, `redis.caSecretKey`, `analytics.clickhouse.*`; env `DURABLE_ACTORS_POSTGRES_URL`, `DURABLE_ACTORS_JWT_SIGNING_KEY`, `DURABLE_ACTORS_SECRET`, `DURABLE_ACTORS_INVOKE_API_KEY`, `DURABLE_ACTORS_REDIS_URL`, `DURABLE_ACTORS_REDIS_CA_CERT`, `DURABLE_ACTORS_CLICKHOUSE_URL`, `DURABLE_ACTORS_CLICKHOUSE_DATABASE`, `DURABLE_ACTORS_CLICKHOUSE_USER`, `DURABLE_ACTORS_CLICKHOUSE_PASSWORD`; Secret `actors-credentials` keys `postgres-url`, `jwt-signing-key`, `api-key`, `<operator-chosen, no default>`, `<operator-chosen, no default>`, `<operator-chosen, no default>` | kubectl get secret actors-credentials -o jsonpath='{.data}' has postgres-url, jwt-signing-key and api-key; the controller starts and runs migrations |
| shipped | [The durable-actors public HTTPS origin (publicUrl) with WebSocket support](#req-durable-actors-public-url) | operator | values `publicUrl`, `ingress.enabled`, `ingress.className`, `ingress.tlsSecret`, `ingress.annotations`, `agent-relay:gkeIngress.hosts.actors`, `agent-relay:gkeIngress.actorsBackendTimeoutSec`; env `DURABLE_ACTORS_PUBLIC_URL`, `DURABLE_ACTORS_CONTROL_PLANE_URL`; Secret `<ingress.tlsSecret>` (kubernetes.io/tls, only with the chart's own ingress) | curl -fsS <publicUrl>/healthz |

### Profile: relaycast-durable-actors

**Relaycast on durable-actors (runtime.backend=durable-actors).** Stateless gateway (relaycast-actors-gateway) in front of one Workspace actor per workspace; deployer Job registers the actor bundle; files in GCS or S3. PostgreSQL installs use the full-copy upgrader; SQLite workspaces are not migrated.

chart `relaycast` · values [`ci/durable-actors-values.yaml`](../charts/relaycast/ci/durable-actors-values.yaml) · install: `helm install relaycast agentworkforce/relaycast -f values.yaml (runtime.backend=durable-actors, a durable-actors control plane, ar_ credentials)`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [Relaycast actor-mode Secrets (gateway invocation key, file signing, actor env, admin key)](#req-relaycast-durable-actors-secrets) | operator | values `secretKeys.workspaceBootstrapSecret`, `runtime.durableActors.fileSigningSecretKey`, `runtime.durableActors.invocationSecret.*`, `runtime.durableActors.adminKeySecret.*`, `runtime.durableActors.actorEnvSecrets`, `runtime.durableActors.devRuntime.secretKey`, `runtime.durableActors.deployer.*`; env `RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET`, `DURABLE_ACTORS_SECRET`, `RELAYCAST_FILE_SIGNING_SECRET`, `DURABLE_ACTORS_ARTIFACT_BUCKET`, `DURABLE_ACTORS_SECRET_REFS`, `DURABLE_ACTORS_ORGANIZATION_ID`, `DURABLE_ACTORS_ARTIFACT_STORE`, `DURABLE_ACTORS_S3_REGION`, `DURABLE_ACTORS_S3_ENDPOINT`, `DURABLE_ACTORS_S3_FORCE_PATH_STYLE`; Secret `<existingSecret>` keys `file-signing-secret`, `<operator-chosen>`, `credential-keyring`; Secret `<runtime.durableActors.invocationSecret.name>` keys `durable-actors-invoke-key`; Secret `actors-credentials` keys `api-key`; Secret `<runtime.durableActors.actorEnvSecrets[], e.g. relaycast-actor-env, in the sandbox namespace>` keys `RELAYCAST_PUBLIC_URL`, `RELAYCAST_FILE_SIGNING_SECRET`, `RELAYCAST_INTERNAL_SECRET`, `RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET`, `RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED` (label terse.ai/customer-secret=true; keys become actor env); Secret `<existingSecret, devRuntime only>` keys `durable-actors-dev-secret` | helm template fails with "invocationSecret must not be the admin key Secret" or "actorEnvSecrets is required" on miswiring; the deploy Job completes |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [Relaycast runtime backend (sqlite, durable-actors or postgres)](#opt-relaycast-durable-actors) | `sqlite`, `durable-actors`, `postgres` | `sqlite` | values `runtime.backend`, `runtime.durableActors.projectId`, `runtime.durableActors.organizationId`, `runtime.durableActors.controlPlaneUrl`, `runtime.durableActors.homeRegion`, `runtime.durableActors.socketOrigin`, `runtime.durableActors.gateway.*`, `runtime.durableActors.maxUploadBytes`, `runtime.durableActors.shutdownGraceMs`, `runtime.durableActors.logFormat`, `runtime.durableActors.fileStore.*`, `runtime.durableActors.devRuntime.*`; env `DURABLE_ACTORS_CONTROL_PLANE_URL`, `DURABLE_ACTORS_PROJECT_ID`, `DURABLE_ACTORS_HOME_REGION`, `DURABLE_ACTORS_SOCKET_ORIGIN`, `RELAYCAST_FILE_STORE`, `RELAYCAST_FILE_DIR`, `RELAYCAST_GCS_BUCKET`, `RELAYCAST_GCS_PREFIX`, `RELAYCAST_S3_BUCKET`, `RELAYCAST_S3_REGION`, `RELAYCAST_S3_ENDPOINT`, `RELAYCAST_S3_PREFIX`, `RELAYCAST_S3_FORCE_PATH_STYLE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `RELAYCAST_MAX_UPLOAD_BYTES`, `RELAYCAST_SHUTDOWN_GRACE_MS`, `RELAYCAST_LOG_FORMAT`, `DURABLE_ACTORS_PORT`, `DURABLE_ACTORS_DATA_DIR`, `RELAYCAST_PUBLIC_URL`, `RELAYCAST_INTERNAL_SECRET`; Secret `<runtime.durableActors.fileStore.s3.existingSecret>` keys `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (s3 file store only; empty uses the pod's ambient identity) |

### Profile: relaycast-postgres

**Relaycast on PostgreSQL (runtime.backend=postgres).** One replica on an external PostgreSQL database; a hash-named migration Job runs as relaycast_owner and the server waits for it as relaycast_runtime; uploaded files stay on the PVC. Default off.

chart `relaycast` · values [`ci/postgres-values.yaml`](../charts/relaycast/ci/postgres-values.yaml) · install: `helm install relaycast agentworkforce/relaycast -f values.yaml (runtime.backend=postgres, postgresCa, owner and runtime database URLs in existingSecret)`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [Relaycast PostgreSQL backend (owner and runtime URLs, CA, migration Job)](#req-relaycast-postgres) | operator | values `runtime.postgres.image.repository`, `runtime.postgres.image.digest`, `runtime.postgres.migrations.identitySalt`, `runtime.postgres.migrations.backoffLimit`, `runtime.postgres.migrations.activeDeadlineSeconds`, `secretKeys.databaseOwnerUrl`, `secretKeys.databaseRuntimeUrl`, `postgresCa.enabled`, `postgresCa.configMap`, `postgresCa.secret`, `postgresCa.key`; env `RELAYCAST_DATABASE_URL_FILE`; Secret `<existingSecret>` keys `database-owner-url`, `database-runtime-url`; Secret `<postgresCa.secret>` keys `ca.crt` (or the same key in the ConfigMap named by postgresCa.configMap) | kubectl wait --for=condition=complete job -l app.kubernetes.io/name=relaycast-migrate; curl <baseUrl>/health |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [Relaycast collector analytics adapter](#opt-relaycast-collector-analytics) | `false`, `true` | `false` | values `analytics.*`; env `RELAYCAST_TELEMETRY_DESTINATION`, `RELAYCAST_TELEMETRY_COLLECTOR_URL`, `RELAYCAST_TELEMETRY_DEPLOYMENT_ID`, `RELAYCAST_TELEMETRY_COLLECTOR_TOKEN_FILE`, `NODE_EXTRA_CA_CERTS`; Secret `<Relaycast component-bound analytics producer Secret>` keys `token` |

### Profile: relayfile-durable-actors

**Relayfile on durable-actors (runtime.backend=durable-actors).** Stateless gateway, internal session broker (the only long-running holder of the admin api-key), deploy Job; file bytes in GCS or S3.

chart `relayfile` · values [`ci/durable-actors-values.yaml`](../charts/relayfile/ci/durable-actors-values.yaml) · install: `helm install relayfile agentworkforce/relayfile -f values.yaml (runtime.backend=durable-actors, a durable-actors control plane)`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [Relayfile actor-mode Secrets (gateway Secret, durable-actors admin key)](#req-relayfile-durable-actors-secrets) | operator | values `runtime.durableActors.existingSecret`, `runtime.durableActors.secretKeys.*`, `runtime.durableActors.adminKeySecret.*`, `runtime.durableActors.devRuntime.secretKey`; env `RELAYFILE_ACTORS_BROKER_TOKEN`, `RELAYFILE_JWT_SECRET`, `RELAYFILE_INTERNAL_HMAC_SECRET`, `DURABLE_ACTORS_SECRET`; Secret `relayfile-actors` keys `RELAYFILE_JWT_SECRET`, `RELAYFILE_ACTORS_BROKER_TOKEN`, `<operator-chosen, no default>`; Secret `actors-credentials` keys `api-key`; Secret `<runtime.durableActors.existingSecret, devRuntime only>` keys `DURABLE_ACTORS_SECRET` | helm template fails with "adminKeySecret must be a different Secret" when they match; the broker's /health is ready |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [Relayfile runtime backend (go or durable-actors)](#opt-relayfile-durable-actors) | `go`, `durable-actors` | `go` | values `runtime.backend`, `runtime.durableActors.image.*`, `runtime.durableActors.projectId`, `runtime.durableActors.organizationId`, `runtime.durableActors.controlPlaneUrl`, `runtime.durableActors.gateway.*`, `runtime.durableActors.broker.*`, `runtime.durableActors.deployer.*`, `runtime.durableActors.blobStore.*`, `runtime.durableActors.devRuntime.*`; env `DURABLE_ACTORS_CONTROL_PLANE_URL`, `DURABLE_ACTORS_PROJECT_ID`, `DURABLE_ACTORS_ORGANIZATION_ID`, `DURABLE_ACTORS_ARTIFACT_BUCKET`, `RELAYFILE_ACTORS_BROKER_URL`, `RELAYFILE_ACTORS_ALLOW_ADMIN_KEY`, `RELAYFILE_BLOB_STORE`, `RELAYFILE_BLOB_BUCKET`, `RELAYFILE_BLOB_PREFIX`, `RELAYFILE_BLOB_INLINE_MAX_BYTES`, `RELAYFILE_S3_ENDPOINT`, `RELAYFILE_S3_REGION`, `RELAYFILE_S3_FORCE_PATH_STYLE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `DURABLE_ACTORS_PORT`, `DURABLE_ACTORS_DATA_DIR`, `DURABLE_ACTORS_ARTIFACT_STORE`, `DURABLE_ACTORS_S3_REGION`, `DURABLE_ACTORS_S3_ENDPOINT`, `DURABLE_ACTORS_S3_FORCE_PATH_STYLE`; Secret `<runtime.durableActors.blobStore.s3.existingSecret>` keys `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (s3 blob store only; empty uses the pod's ambient identity) |

### Profile: agent-relay-durable-actors

**GCP proof suite with the durable-actors control plane, Relaycast and Relayfile in actor mode.** components.durableActors and components.relayfile on the GKE proof cluster; actors and files hosts on the suite load balancer. All proof image digests are pinned in the overlays (no --set).

chart `agent-relay` · values [`values-gcp-proof.yaml`](../charts/agent-relay/values-gcp-proof.yaml), [`values-gcp-proof-live.yaml`](../charts/agent-relay/values-gcp-proof-live.yaml), [`values-gcp-proof-durable-actors.yaml`](../charts/agent-relay/values-gcp-proof-durable-actors.yaml), [`values-gcp-proof-relayfile.yaml`](../charts/agent-relay/values-gcp-proof-relayfile.yaml), [`ci/gcp-proof-values.yaml`](../charts/agent-relay/ci/gcp-proof-values.yaml) · install: `helm upgrade agent-relay agentworkforce/agent-relay -f values-gcp-proof.yaml -f values-gcp-proof-live.yaml -f values-gcp-proof-durable-actors.yaml -f values-gcp-proof-relayfile.yaml`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [GKE Standard with GKE Sandbox (gVisor), Workload Identity and enforced NetworkPolicy](#req-durable-actors-gke-sandbox) | operator | values `placement.zone`, `sandboxNamespace`, `nodeSelector`, `networkPolicy.dnsCidrs`, `actors.*`, `organizationLimits.*`, `alarms.*`, `resources.*`, `replicaCount`, `podDisruptionBudget.*`, `topologySpread.*`, `analytics.backend`, `usage.topic`, `postgres.maxConnections`; env `DURABLE_ACTORS_PROCESS_ROLE`, `DURABLE_ACTORS_CONTROL_PLANE_BIND`, `DURABLE_ACTORS_ALARM_POLL_INTERVAL_MS`, `DURABLE_ACTORS_POSTGRES_MAX_CONNECTIONS`, `DURABLE_ACTORS_ANALYTICS_BACKEND`, `DURABLE_ACTORS_USAGE_TOPIC`, `DURABLE_ACTORS_ORGANIZATION_LIMITS_ENABLED`, `DURABLE_ACTORS_ORGANIZATION_MAX_ACTIVE_ACTORS`, `DURABLE_ACTORS_ORGANIZATION_ACTOR_STARTS_PER_SECOND`, `DURABLE_ACTORS_ORGANIZATION_ACTOR_START_BURST`, `DURABLE_ACTORS_TYPESCRIPT_IMAGE`, `DURABLE_ACTORS_PYTHON_IMAGE`, `DURABLE_ACTORS_GKE_NAMESPACE`, `DURABLE_ACTORS_GKE_ZONE`, `DURABLE_ACTORS_SPARE_IDLE`, `DURABLE_ACTORS_HOST_IDLE_TIMEOUT_MS`, `DURABLE_ACTORS_SPARE_MAX_STARTING`, `DURABLE_ACTORS_SPARE_REFILL_INTERVAL_MS`, `DURABLE_ACTORS_SPARE_RETIRE_CONCURRENCY`, `DURABLE_ACTORS_SPARE_REAP_INTERVAL_MS`, `DURABLE_ACTORS_SPARE_POD_REAP_INTERVAL_MS`, `DURABLE_ACTORS_GKE_REAP_CONCURRENCY`, `DURABLE_ACTORS_HOST_CPU_MILLIS`, `DURABLE_ACTORS_HOST_CPU_LIMIT_MILLIS`, `DURABLE_ACTORS_HOST_MEMORY_MIB`, `DURABLE_ACTORS_HOST_MEMORY_LIMIT_MIB`, `DURABLE_ACTORS_SANDBOX_MIN_CPU_MILLIS`, `DURABLE_ACTORS_SANDBOX_MAX_CPU_MILLIS`, `DURABLE_ACTORS_SANDBOX_MIN_MEMORY_MIB`, `DURABLE_ACTORS_SANDBOX_MAX_MEMORY_MIB` | kubectl get runtimeclass gvisor; kubectl get nodes -l sandbox.gke.io/runtime=gvisor -L topology.kubernetes.io/zone shows placement.zone |
| shipped | [One Standard GCS bucket for actor state and compiled code (Rapid optional)](#req-durable-actors-bucket) | operator | values `storage.bucket`, `storage.mode`, `storage.rapid.*`; env `DURABLE_ACTORS_PERSISTENCE`, `DURABLE_ACTORS_BUCKET`, `DURABLE_ACTORS_ARTIFACT_BUCKET`, `DURABLE_ACTORS_ARCHIVE_BUCKET`, `DURABLE_ACTORS_RAPID_BUCKETS`, `DURABLE_ACTORS_RAPID_PLACEMENT` | gcloud storage buckets describe gs://<storage.bucket> --format='value(default_storage_class)' is STANDARD |
| shipped | [A GSA bound to the control-plane KSA through Workload Identity](#req-durable-actors-workload-identity) | operator | values `serviceAccount.googleServiceAccount` | gcloud iam service-accounts get-iam-policy <gsa> lists the workloadIdentityUser member |
| shipped | [durable-actors credentials Secret (postgres-url, jwt-signing-key, api-key)](#req-durable-actors-credentials) | operator | values `credentialsSecret`, `invokeApiKeySecretKey`, `redis.urlSecretKey`, `redis.caSecretKey`, `analytics.clickhouse.*`; env `DURABLE_ACTORS_POSTGRES_URL`, `DURABLE_ACTORS_JWT_SIGNING_KEY`, `DURABLE_ACTORS_SECRET`, `DURABLE_ACTORS_INVOKE_API_KEY`, `DURABLE_ACTORS_REDIS_URL`, `DURABLE_ACTORS_REDIS_CA_CERT`, `DURABLE_ACTORS_CLICKHOUSE_URL`, `DURABLE_ACTORS_CLICKHOUSE_DATABASE`, `DURABLE_ACTORS_CLICKHOUSE_USER`, `DURABLE_ACTORS_CLICKHOUSE_PASSWORD`; Secret `actors-credentials` keys `postgres-url`, `jwt-signing-key`, `api-key`, `<operator-chosen, no default>`, `<operator-chosen, no default>`, `<operator-chosen, no default>` | kubectl get secret actors-credentials -o jsonpath='{.data}' has postgres-url, jwt-signing-key and api-key; the controller starts and runs migrations |
| shipped | [The durable-actors public HTTPS origin (publicUrl) with WebSocket support](#req-durable-actors-public-url) | operator | values `publicUrl`, `ingress.enabled`, `ingress.className`, `ingress.tlsSecret`, `ingress.annotations`, `agent-relay:gkeIngress.hosts.actors`, `agent-relay:gkeIngress.actorsBackendTimeoutSec`; env `DURABLE_ACTORS_PUBLIC_URL`, `DURABLE_ACTORS_CONTROL_PLANE_URL`; Secret `<ingress.tlsSecret>` (kubernetes.io/tls, only with the chart's own ingress) | curl -fsS <publicUrl>/healthz |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [Run the durable-actors control plane and Relayfile in the suite](#opt-agent-relay-durable-actors) | `false`, `true` | `false` | values `components.durableActors`, `components.relayfile`, `durableActorsNetworkPolicy.*`, `gkeIngress.hosts.files`, `gkeIngress.backends.files.*` |
| shipped | [Relaycast runtime backend (sqlite, durable-actors or postgres)](#opt-relaycast-durable-actors) | `sqlite`, `durable-actors`, `postgres` | `sqlite` | values `runtime.backend`, `runtime.durableActors.projectId`, `runtime.durableActors.organizationId`, `runtime.durableActors.controlPlaneUrl`, `runtime.durableActors.homeRegion`, `runtime.durableActors.socketOrigin`, `runtime.durableActors.gateway.*`, `runtime.durableActors.maxUploadBytes`, `runtime.durableActors.shutdownGraceMs`, `runtime.durableActors.logFormat`, `runtime.durableActors.fileStore.*`, `runtime.durableActors.devRuntime.*`; env `DURABLE_ACTORS_CONTROL_PLANE_URL`, `DURABLE_ACTORS_PROJECT_ID`, `DURABLE_ACTORS_HOME_REGION`, `DURABLE_ACTORS_SOCKET_ORIGIN`, `RELAYCAST_FILE_STORE`, `RELAYCAST_FILE_DIR`, `RELAYCAST_GCS_BUCKET`, `RELAYCAST_GCS_PREFIX`, `RELAYCAST_S3_BUCKET`, `RELAYCAST_S3_REGION`, `RELAYCAST_S3_ENDPOINT`, `RELAYCAST_S3_PREFIX`, `RELAYCAST_S3_FORCE_PATH_STYLE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `RELAYCAST_MAX_UPLOAD_BYTES`, `RELAYCAST_SHUTDOWN_GRACE_MS`, `RELAYCAST_LOG_FORMAT`, `DURABLE_ACTORS_PORT`, `DURABLE_ACTORS_DATA_DIR`, `RELAYCAST_PUBLIC_URL`, `RELAYCAST_INTERNAL_SECRET`; Secret `<runtime.durableActors.fileStore.s3.existingSecret>` keys `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (s3 file store only; empty uses the pod's ambient identity) |
| shipped | [Relayfile runtime backend (go or durable-actors)](#opt-relayfile-durable-actors) | `go`, `durable-actors` | `go` | values `runtime.backend`, `runtime.durableActors.image.*`, `runtime.durableActors.projectId`, `runtime.durableActors.organizationId`, `runtime.durableActors.controlPlaneUrl`, `runtime.durableActors.gateway.*`, `runtime.durableActors.broker.*`, `runtime.durableActors.deployer.*`, `runtime.durableActors.blobStore.*`, `runtime.durableActors.devRuntime.*`; env `DURABLE_ACTORS_CONTROL_PLANE_URL`, `DURABLE_ACTORS_PROJECT_ID`, `DURABLE_ACTORS_ORGANIZATION_ID`, `DURABLE_ACTORS_ARTIFACT_BUCKET`, `RELAYFILE_ACTORS_BROKER_URL`, `RELAYFILE_ACTORS_ALLOW_ADMIN_KEY`, `RELAYFILE_BLOB_STORE`, `RELAYFILE_BLOB_BUCKET`, `RELAYFILE_BLOB_PREFIX`, `RELAYFILE_BLOB_INLINE_MAX_BYTES`, `RELAYFILE_S3_ENDPOINT`, `RELAYFILE_S3_REGION`, `RELAYFILE_S3_FORCE_PATH_STYLE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `DURABLE_ACTORS_PORT`, `DURABLE_ACTORS_DATA_DIR`, `DURABLE_ACTORS_ARTIFACT_STORE`, `DURABLE_ACTORS_S3_REGION`, `DURABLE_ACTORS_S3_ENDPOINT`, `DURABLE_ACTORS_S3_FORCE_PATH_STYLE`; Secret `<runtime.durableActors.blobStore.s3.existingSecret>` keys `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (s3 blob store only; empty uses the pod's ambient identity) |

### Profile: agent-relay-eks-durable-actors

**AWS EKS durable-actors profile, Relaycast and Relayfile in actor mode on S3.** standalone profile; standard-mode EKS with runc actor hosts on a tainted node group, one S3 bucket, EKS Pod Identity (or IRSA), a durable-actors control-plane image from the AgentWorkforce fork. Every other suite component off.

chart `agent-relay` · values [`values-eks-actors.yaml`](../charts/agent-relay/values-eks-actors.yaml) · install: `helm upgrade --install agent-relay agentworkforce/agent-relay -f values-eks-actors.yaml -f <your overrides> (proof in a Pippen sandbox - scripts/selfhost/eks-actors-sandbox.sh, then eks-actors-install.sh)`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [AWS EKS - one S3 bucket, a control-plane IAM role (Pod Identity or IRSA) and a tainted actor node group](#req-durable-actors-aws-s3) | operator | values `storage.provider`, `storage.s3.*`, `sandbox.*`, `serviceAccount.annotations`; env `DURABLE_ACTORS_STORAGE_PROVIDER`, `DURABLE_ACTORS_S3_REGION`, `DURABLE_ACTORS_S3_ACTOR_CREDENTIALS`, `DURABLE_ACTORS_S3_ACTOR_ROLE_ARN`, `DURABLE_ACTORS_S3_ENDPOINT`, `DURABLE_ACTORS_S3_FORCE_PATH_STYLE`, `DURABLE_ACTORS_SANDBOX_RUNTIME_CLASS`, `DURABLE_ACTORS_SANDBOX_NODE_SELECTOR`, `DURABLE_ACTORS_SANDBOX_TOLERATIONS` | aws s3api head-bucket --bucket <storage.bucket>; with EKS Pod Identity, aws eks list-pod-identity-associations --cluster-name <cluster> lists <release>-durable-actors; with IRSA, kubectl get serviceaccount <release>-durable-actors -o jsonpath='{.metadata.annotations.eks\\.amazonaws\\.com/role-arn}' shows a role whose trust policy names the cluster's OIDC provider; kubectl get nodes -l durable-actors/role=actor-host -L topology.kubernetes.io/zone shows placement.zone |
| shipped | [durable-actors credentials Secret (postgres-url, jwt-signing-key, api-key)](#req-durable-actors-credentials) | operator | values `credentialsSecret`, `invokeApiKeySecretKey`, `redis.urlSecretKey`, `redis.caSecretKey`, `analytics.clickhouse.*`; env `DURABLE_ACTORS_POSTGRES_URL`, `DURABLE_ACTORS_JWT_SIGNING_KEY`, `DURABLE_ACTORS_SECRET`, `DURABLE_ACTORS_INVOKE_API_KEY`, `DURABLE_ACTORS_REDIS_URL`, `DURABLE_ACTORS_REDIS_CA_CERT`, `DURABLE_ACTORS_CLICKHOUSE_URL`, `DURABLE_ACTORS_CLICKHOUSE_DATABASE`, `DURABLE_ACTORS_CLICKHOUSE_USER`, `DURABLE_ACTORS_CLICKHOUSE_PASSWORD`; Secret `actors-credentials` keys `postgres-url`, `jwt-signing-key`, `api-key`, `<operator-chosen, no default>`, `<operator-chosen, no default>`, `<operator-chosen, no default>` | kubectl get secret actors-credentials -o jsonpath='{.data}' has postgres-url, jwt-signing-key and api-key; the controller starts and runs migrations |
| shipped | [The durable-actors public HTTPS origin (publicUrl) with WebSocket support](#req-durable-actors-public-url) | operator | values `publicUrl`, `ingress.enabled`, `ingress.className`, `ingress.tlsSecret`, `ingress.annotations`, `agent-relay:gkeIngress.hosts.actors`, `agent-relay:gkeIngress.actorsBackendTimeoutSec`; env `DURABLE_ACTORS_PUBLIC_URL`, `DURABLE_ACTORS_CONTROL_PLANE_URL`; Secret `<ingress.tlsSecret>` (kubernetes.io/tls, only with the chart's own ingress) | curl -fsS <publicUrl>/healthz |

**Options (choose)**

| | option | choices | default here | maps to |
| --- | --- | --- | --- | --- |
| shipped | [Run the durable-actors control plane and Relayfile in the suite](#opt-agent-relay-durable-actors) | `false`, `true` | `false` | values `components.durableActors`, `components.relayfile`, `durableActorsNetworkPolicy.*`, `gkeIngress.hosts.files`, `gkeIngress.backends.files.*` |
| shipped | [Relaycast runtime backend (sqlite, durable-actors or postgres)](#opt-relaycast-durable-actors) | `sqlite`, `durable-actors`, `postgres` | `sqlite` | values `runtime.backend`, `runtime.durableActors.projectId`, `runtime.durableActors.organizationId`, `runtime.durableActors.controlPlaneUrl`, `runtime.durableActors.homeRegion`, `runtime.durableActors.socketOrigin`, `runtime.durableActors.gateway.*`, `runtime.durableActors.maxUploadBytes`, `runtime.durableActors.shutdownGraceMs`, `runtime.durableActors.logFormat`, `runtime.durableActors.fileStore.*`, `runtime.durableActors.devRuntime.*`; env `DURABLE_ACTORS_CONTROL_PLANE_URL`, `DURABLE_ACTORS_PROJECT_ID`, `DURABLE_ACTORS_HOME_REGION`, `DURABLE_ACTORS_SOCKET_ORIGIN`, `RELAYCAST_FILE_STORE`, `RELAYCAST_FILE_DIR`, `RELAYCAST_GCS_BUCKET`, `RELAYCAST_GCS_PREFIX`, `RELAYCAST_S3_BUCKET`, `RELAYCAST_S3_REGION`, `RELAYCAST_S3_ENDPOINT`, `RELAYCAST_S3_PREFIX`, `RELAYCAST_S3_FORCE_PATH_STYLE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `RELAYCAST_MAX_UPLOAD_BYTES`, `RELAYCAST_SHUTDOWN_GRACE_MS`, `RELAYCAST_LOG_FORMAT`, `DURABLE_ACTORS_PORT`, `DURABLE_ACTORS_DATA_DIR`, `RELAYCAST_PUBLIC_URL`, `RELAYCAST_INTERNAL_SECRET`; Secret `<runtime.durableActors.fileStore.s3.existingSecret>` keys `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (s3 file store only; empty uses the pod's ambient identity) |
| shipped | [Relayfile runtime backend (go or durable-actors)](#opt-relayfile-durable-actors) | `go`, `durable-actors` | `go` | values `runtime.backend`, `runtime.durableActors.image.*`, `runtime.durableActors.projectId`, `runtime.durableActors.organizationId`, `runtime.durableActors.controlPlaneUrl`, `runtime.durableActors.gateway.*`, `runtime.durableActors.broker.*`, `runtime.durableActors.deployer.*`, `runtime.durableActors.blobStore.*`, `runtime.durableActors.devRuntime.*`; env `DURABLE_ACTORS_CONTROL_PLANE_URL`, `DURABLE_ACTORS_PROJECT_ID`, `DURABLE_ACTORS_ORGANIZATION_ID`, `DURABLE_ACTORS_ARTIFACT_BUCKET`, `RELAYFILE_ACTORS_BROKER_URL`, `RELAYFILE_ACTORS_ALLOW_ADMIN_KEY`, `RELAYFILE_BLOB_STORE`, `RELAYFILE_BLOB_BUCKET`, `RELAYFILE_BLOB_PREFIX`, `RELAYFILE_BLOB_INLINE_MAX_BYTES`, `RELAYFILE_S3_ENDPOINT`, `RELAYFILE_S3_REGION`, `RELAYFILE_S3_FORCE_PATH_STYLE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `DURABLE_ACTORS_PORT`, `DURABLE_ACTORS_DATA_DIR`, `DURABLE_ACTORS_ARTIFACT_STORE`, `DURABLE_ACTORS_S3_REGION`, `DURABLE_ACTORS_S3_ENDPOINT`, `DURABLE_ACTORS_S3_FORCE_PATH_STYLE`; Secret `<runtime.durableActors.blobStore.s3.existingSecret>` keys `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (s3 blob store only; empty uses the pod's ambient identity) |

### Profile: telemetry-collector

**Self-hosted analytics file collector.** one writer, an exclusive persistent volume, internal TLS and no outbound analytics destination. Requires runtime image and lifecycle acceptance separately.

chart `telemetry-collector` · install: `helm upgrade --install telemetry agentworkforce/telemetry-collector -f <accepted images, TLS and producer Secret references>`

**Requirements (provide these)**

| | requirement | provided by | maps to | verify |
| --- | --- | --- | --- | --- |
| shipped | [Analytics collector image and bounded storage runtime](#req-telemetry-collector-runtime) | operator | values `imagePullSecrets`, `image.*`, `tlsProxy.image.*`, `persistence.*`, `limits.*`, `retention.*`, `terminationGracePeriodSeconds`, `networkPolicy.allowedFrom`, `rolloutRevision`; env `ANALYTICS_COLLECTOR_HOST`, `ANALYTICS_COLLECTOR_PORT`, `ANALYTICS_COLLECTOR_DATA_DIR`, `ANALYTICS_COLLECTOR_PRODUCERS_FILE`, `ANALYTICS_COLLECTOR_MAX_BATCH_BYTES`, `ANALYTICS_COLLECTOR_MAX_BATCH_EVENTS`, `ANALYTICS_COLLECTOR_MAX_EVENT_BYTES`, `ANALYTICS_COLLECTOR_REQUEST_TIMEOUT_MS`, `ANALYTICS_COLLECTOR_MAX_IN_FLIGHT`, `ANALYTICS_COLLECTOR_MAX_SEGMENTS`, `ANALYTICS_COLLECTOR_MAX_DISK_BYTES`, `ANALYTICS_COLLECTOR_SHUTDOWN_DEADLINE_MS`, `ANALYTICS_COLLECTOR_RETENTION`, `ANALYTICS_COLLECTOR_RETENTION_MAX_AGE_MS` | Exercise the accepted collector entrypoint, authenticated TLS intake, durable files after restart and failure-before-acknowledgement cases on the installed volume. |
| shipped | [Separate analytics producer and TLS credential Secrets](#req-telemetry-collector-secrets) | operator | values `producersSecret`, `tlsSecret` | Check distinct mounted producer credentials and TLS keys, exact certificate SAN and issuer, and a restart after rotation; never print values. |

## All entries

### Requirements

#### req.k8s.cnpg-operator

<a id="req-k8s-cnpg-operator"></a>

**CloudNativePG operator installed** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, aws-cnpg

The in-cluster HoopDb is a CloudNativePG Cluster (cnpg/cluster 0.9.0), so the
CNPG operator and its CRDs must be installed before the release. Pinned
operator values are in deps/cnpg-operator-values.yaml.

- Provided by: default: operator, aws-cnpg: stack
- Values: `hoopdb.enabled`
- Verify: kubectl get crd clusters.postgresql.cnpg.io && kubectl get deploy -A -l app.kubernetes.io/name=cloudnative-pg
- Sources: [`charts/sessions-pipeline/Chart.yaml:12`](../charts/sessions-pipeline/Chart.yaml#L12), [`charts/sessions-pipeline/values.yaml:85`](../charts/sessions-pipeline/values.yaml#L85), [`deps/pins.txt:4`](../deps/pins.txt#L4), `sessions-pipeline@7d7229b:stacks/aws/hardening.ts:375`

#### req.k8s.storage

<a id="req-k8s-storage"></a>

**A default StorageClass for the in-cluster HoopDb and Locker volumes** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, aws-cnpg

The CNPG HoopDb claims hoopdb.cluster.storage.size (10Gi) and the MinIO Locker
session-object-storage.persistence.size (20Gi) through the default StorageClass.

- Provided by: default: operator, aws-cnpg: stack
- Values: `hoopdb.cluster.storage.size`, `session-object-storage.persistence.size`
- Verify: kubectl get storageclass (one marked default), then kubectl get pvc -n <ns> all Bound
- Sources: [`charts/sessions-pipeline/values.yaml:102`](../charts/sessions-pipeline/values.yaml#L102), [`charts/sessions-pipeline/values.yaml:155`](../charts/sessions-pipeline/values.yaml#L155)

#### req.k8s.workload-identity

<a id="req-k8s-workload-identity"></a>

**Workload identity for the Locker bucket (EKS Pod Identity / GKE Workload Identity)** · shipped · chart `sessions-pipeline` · profiles aws-cnpg, aws-supabase, gcp-cloudsql, aws-rds-native

With locker.credentials.mode=podIdentity the charts omit LOCKER_ACCESS_KEY_ID and
LOCKER_SECRET_ACCESS_KEY and the SDK uses the workload identity chain. Install
the EKS Pod Identity Agent (unless EKS Auto Mode) and create the IAM
associations for every rendered ServiceAccount before the workloads start
(GKE: Workload Identity bindings via serviceAccount.annotations). The AWS
native profile uses separate worker, native-ingest, read and search-indexer
identities. The workload roles need their scoped bucket/OpenSearch access;
Terraform owns bucket creation and versioning when lockerInit is disabled.

- Provided by: stack
- Values: `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode`, `worker.serviceAccount.annotations`, `alleyoop.serviceAccount.annotations`, `worker.serviceAccount.name`, `alleyoop.serviceAccount.name`, `sessionReadApi.serviceAccountName`, `ingestEdge.serviceAccountName`, `searchIndexer.serviceAccount.name`
- Verify: aws eks list-pod-identity-associations --cluster-name <c> includes every enabled workload ServiceAccount; the worker, ingest edge and search indexer reach only their required bucket/index resources
- Sources: [`README.md:152`](../README.md#L152), [`charts/sessions-pipeline-worker/values.yaml:60`](../charts/sessions-pipeline-worker/values.yaml#L60), [`charts/sessions-pipeline-worker/templates/_env.tpl:77`](../charts/sessions-pipeline-worker/templates/_env.tpl#L77)

#### req.k8s.external-secrets-operator

<a id="req-k8s-external-secrets-operator"></a>

**External Secrets Operator and a ClusterSecretStore (only with externalSecrets.enabled)** · shipped · chart `sessions-pipeline-worker`, `session-ingest-api` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

externalSecrets.enabled renders an ExternalSecret (external-secrets.io/v1) whose
target is existingSecret. The ESO CRDs and the named secretStoreRef must exist,
and every consumed key must be mapped in externalSecrets.data.

- Provided by: operator
- Values: `sessions-pipeline-worker:externalSecrets.*`, `session-ingest-api:externalSecrets.*`
- Verify: kubectl get crd externalsecrets.external-secrets.io && kubectl get clustersecretstore <name>; the ExternalSecret reports Ready
- Sources: [`charts/sessions-pipeline-worker/values.yaml:248`](../charts/sessions-pipeline-worker/values.yaml#L248), [`charts/sessions-pipeline-worker/templates/externalsecret.yaml:20`](../charts/sessions-pipeline-worker/templates/externalsecret.yaml#L20), [`charts/session-ingest-api/templates/externalsecret.yaml:11`](../charts/session-ingest-api/templates/externalsecret.yaml#L11)

#### req.secret.image-pull

<a id="req-secret-image-pull"></a>

**Pull Secret for the private GHCR services image** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, external-supabase, aws-supabase, gcp-cloudsql

ghcr.io/agentworkforce/96bulls-services is a private package. Create a
docker-registry Secret and list it in the umbrella's shared imagePullSecrets
(worker and alleyoop; the privileged SQL Jobs reuse worker.imagePullSecrets).
The ECR path (EKS node role) needs none.

- Provided by: operator
- Values: `worker.imagePullSecrets`, `alleyoop.imagePullSecrets`
- Secret: `<pull secret>`. type kubernetes.io/dockerconfigjson with read access to ghcr.io/agentworkforce/96bulls-services
- Verify: kubectl get secret <pull secret> -o jsonpath='{.type}' is kubernetes.io/dockerconfigjson; pods are not ImagePullBackOff
- Sources: [`README.md:128`](../README.md#L128), [`charts/sessions-pipeline/values.yaml:24`](../charts/sessions-pipeline/values.yaml#L24), [`charts/sessions-pipeline/templates/_privileged-sql-job.tpl:92`](../charts/sessions-pipeline/templates/_privileged-sql-job.tpl#L92)

#### req.secret.locker-credentials

<a id="req-secret-locker-credentials"></a>

**Locker credential Secret (MinIO root / S3 static keys)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, external-supabase

In secret mode the workers and alleyoop read the Locker access key pair from
existingSecret, and the bundled MinIO reads its root credential from the same
Secret (session-object-storage.existingSecret). Not used with locker.credentials.mode=podIdentity.

- Provided by: operator
- Values: `worker.existingSecret`, `alleyoop.existingSecret`, `session-object-storage.existingSecret`, `worker.secretKeys.lockerAccessKeyId`, `worker.secretKeys.lockerSecretAccessKey`, `alleyoop.secretKeys.lockerAccessKeyId`, `alleyoop.secretKeys.lockerSecretAccessKey`
- Env: `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`
- Secret: `sessions-pipeline-locker` from `worker.existingSecret`; keys `rootUser` from `worker.secretKeys.lockerAccessKeyId`; `rootPassword` from `worker.secretKeys.lockerSecretAccessKey`
- Secret: `sessions-pipeline-locker` from `alleyoop.existingSecret`; keys `rootUser` from `alleyoop.secretKeys.lockerAccessKeyId`; `rootPassword` from `alleyoop.secretKeys.lockerSecretAccessKey`
- Secret: `sessions-pipeline-locker` from `session-object-storage.existingSecret`. the bundled upstream MinIO requires literal Secret data keys rootUser and rootPassword
- Verify: kubectl get secret sessions-pipeline-locker -o jsonpath='{.data}' has rootUser and rootPassword
- Sources: [`charts/sessions-pipeline/values.yaml:3`](../charts/sessions-pipeline/values.yaml#L3), [`charts/sessions-pipeline/values.yaml:28`](../charts/sessions-pipeline/values.yaml#L28), [`charts/sessions-pipeline-worker/templates/_env.tpl:78`](../charts/sessions-pipeline-worker/templates/_env.tpl#L78), [`charts/session-ingest-api/templates/_env.tpl:66`](../charts/session-ingest-api/templates/_env.tpl#L66)

#### req.secret.summary-master-keys

<a id="req-secret-summary-master-keys"></a>

**Summary encryption keyring (SUMMARY_MASTER_KEYS)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

Bob Costas encrypts summary objects before they reach the Locker. The keyring
("<key-id>:<64 hex>[,<key-id>:<64 hex>...]", first is current) comes only from
a Secret and is projected as a read-only file into Bob Costas only
(SUMMARY_MASTER_KEYS_FILE). summaryEncryption.existingSecret empty follows
worker.existingSecret; pod-identity installs with no shared Secret must set it.

- Provided by: default: operator, aws-cnpg: stack, aws-supabase: stack, gcp-cloudsql: stack
- Values: `worker.summaryEncryption.existingSecret`, `worker.summaryEncryption.key`, `worker.summaryEncryption.mountPath`, `worker.summaryEncryption.fileName`
- Env: `SUMMARY_MASTER_KEYS_FILE`, `SUMMARY_MASTER_KEYS`
- Secret: `sessions-pipeline-locker` (default), `96bulls-runtime` (aws-cnpg), `sessions-pipeline-summary` (aws-supabase), `96bulls-gcp` (gcp-cloudsql), `agent-relay-secrets` (aws-rds-native) from `worker.summaryEncryption.existingSecret` then `worker.existingSecret`; keys `SUMMARY_MASTER_KEYS` from `worker.summaryEncryption.key`
- Verify: kubectl exec deploy/<release>-worker-bob-costas -- test -r /var/run/secrets/sessions-pipeline/summary-master-keys; the Secret key parses as <id>:<64 hex>
- Sources: [`README.md:143`](../README.md#L143), [`charts/sessions-pipeline-worker/values.yaml:45`](../charts/sessions-pipeline-worker/values.yaml#L45), [`charts/sessions-pipeline-worker/templates/_env.tpl:102`](../charts/sessions-pipeline-worker/templates/_env.tpl#L102), [`charts/sessions-pipeline-worker/templates/_env.tpl:30`](../charts/sessions-pipeline-worker/templates/_env.tpl#L30), `sessions-pipeline@7d7229b:src/shared/keyring.ts:17`

#### req.secret.hoopdb-url

<a id="req-secret-hoopdb-url"></a>

**HoopDb connection Secret (HOOPDB_URL)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

Every workload and migrate read HOOPDB_URL from hoopdb.existingSecret/key (else
existingSecret / secretKeys.hoopdbUrl). With the in-cluster HoopDb it is the
Secret CloudNativePG generates (hoopdb-app, key uri): nothing to create. With an
external database the operator (or the stack) creates it; for supabase it is the
migration role's connection string unless migrations.hoopdb separates them.

- Provided by: default: chart, external-selfhosted: operator, external-rds: operator, aws-rds-native: operator, external-supabase: operator, aws-supabase: stack, gcp-cloudsql: stack
- Values: `worker.hoopdb.existingSecret`, `worker.hoopdb.key`, `worker.secretKeys.hoopdbUrl`, `alleyoop.hoopdb.existingSecret`, `alleyoop.hoopdb.key`, `alleyoop.secretKeys.hoopdbUrl`
- Env: `HOOPDB_URL`
- Secret: `hoopdb-app` (default), `sessions-pipeline-hoopdb` (external-selfhosted), `sessions-pipeline-hoopdb` (external-rds), `agent-relay-secrets` (aws-rds-native), `sessions-pipeline-hoopdb` (external-supabase), `96bulls-gcp` (gcp-cloudsql) from `worker.hoopdb.existingSecret` then `worker.existingSecret`; keys `uri` (default), `HOOPDB_URL` (external-selfhosted), `HOOPDB_URL` (external-rds), `HOOPDB_URL` (aws-rds-native), `HOOPDB_URL` (external-supabase), `HOOPDB_URL` (gcp-cloudsql) from `worker.hoopdb.key,worker.secretKeys.hoopdbUrl`
- Secret: `hoopdb-app` (default), `sessions-pipeline-hoopdb` (external-selfhosted), `sessions-pipeline-hoopdb` (external-rds), `agent-relay-secrets` (aws-rds-native), `sessions-pipeline-hoopdb` (external-supabase), `96bulls-gcp` (gcp-cloudsql) from `alleyoop.hoopdb.existingSecret` then `alleyoop.existingSecret`; keys `uri` (default), `HOOPDB_URL` (external-selfhosted), `HOOPDB_URL` (external-rds), `HOOPDB_URL` (aws-rds-native), `HOOPDB_URL` (external-supabase), `HOOPDB_URL` (gcp-cloudsql) from `alleyoop.hoopdb.key,alleyoop.secretKeys.hoopdbUrl`
- Verify: default: kubectl get secret hoopdb-app -o jsonpath='{.data.uri}' is non-empty once the CNPG Cluster is ready / external-selfhosted: kubectl get secret sessions-pipeline-hoopdb -o jsonpath='{.data.HOOPDB_URL}' \| base64 -d \| psql -X -c 'select 1' / external-rds: psql "$(kubectl get secret sessions-pipeline-hoopdb -o jsonpath='{.data.HOOPDB_URL}' \| base64 -d \| sed -E 's/&?uselibpqcompat=true//; s/\?&/?/')" -X -c 'select 1' / aws-rds-native: psql "$(kubectl get secret agent-relay-secrets -o jsonpath='{.data.HOOPDB_URL}' \| base64 -d \| sed -E 's/&?uselibpqcompat=true//; s/\?&/?/')" -X -c 'select 1' / external-supabase: kubectl get secret sessions-pipeline-hoopdb -o jsonpath='{.data.HOOPDB_URL}' \| base64 -d \| psql -X -c 'select current_user'
- Sources: [`charts/sessions-pipeline/values.yaml:39`](../charts/sessions-pipeline/values.yaml#L39), [`charts/sessions-pipeline/profiles/external-selfhosted.yaml:11`](../charts/sessions-pipeline/profiles/external-selfhosted.yaml#L11), [`charts/sessions-pipeline/profiles/external-supabase.yaml:24`](../charts/sessions-pipeline/profiles/external-supabase.yaml#L24), [`charts/sessions-pipeline-worker/templates/_env.tpl:162`](../charts/sessions-pipeline-worker/templates/_env.tpl#L162), [`charts/session-ingest-api/templates/_env.tpl:54`](../charts/session-ingest-api/templates/_env.tpl#L54)

#### req.secret.hoopdb-migration-url

<a id="req-secret-hoopdb-migration-url"></a>

**Separate migration-owner connection Secret (HOOPDB_MIGRATION_URL)** · shipped · chart `sessions-pipeline` · profiles gcp-cloudsql, external-rds, aws-rds-native

On Cloud SQL and RDS the services connect as the least-privilege runtime role and only
the migrate Job (and its wait-for-role) connects as the migration owner, from
migrations.hoopdb.existingSecret/key.

- Provided by: default: stack, external-rds: operator, aws-rds-native: operator
- Values: `worker.migrations.hoopdb.existingSecret`, `worker.migrations.hoopdb.key`
- Secret: `96bulls-gcp` (default), `sessions-pipeline-hoopdb` (external-rds), `agent-relay-secrets` (aws-rds-native) from `worker.migrations.hoopdb.existingSecret`; keys `HOOPDB_MIGRATION_URL` from `worker.migrations.hoopdb.key`
- Verify: default: kubectl get secret 96bulls-gcp -o jsonpath='{.data.HOOPDB_MIGRATION_URL}' connects as the migration owner (select current_user) / external-rds: psql "$(kubectl get secret sessions-pipeline-hoopdb -o jsonpath='{.data.HOOPDB_MIGRATION_URL}' \| base64 -d \| sed -E 's/&?uselibpqcompat=true//; s/\?&/?/')" -Atc 'select current_user' is the RDS master / aws-rds-native: psql "$(kubectl get secret agent-relay-secrets -o jsonpath='{.data.HOOPDB_MIGRATION_URL}' \| base64 -d \| sed -E 's/&?uselibpqcompat=true//; s/\?&/?/')" -Atc 'select current_user' is the RDS master
- Sources: [`charts/sessions-pipeline/ci/gcp-cloudsql-values.yaml:33`](../charts/sessions-pipeline/ci/gcp-cloudsql-values.yaml#L33), [`charts/sessions-pipeline-worker/values.yaml:93`](../charts/sessions-pipeline-worker/values.yaml#L93), `sessions-pipeline@7d7229b:stacks/gcp/config.ts:1002`

#### req.sessions-pipeline.tenant-org-id

<a id="req-sessions-pipeline-tenant-org-id"></a>

**Agent Relay org id (TENANT_ORG_ID)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

The org this install ingests for; every profile leaves it to the operator and the render fails without it.

- Provided by: operator
- Values: `global.tenant.orgId`, `worker.tenant.orgId`, `alleyoop.tenant.orgId`
- Env: `TENANT_ORG_ID`
- Verify: helm template renders (it fails with "tenant.orgId (or global.tenant.orgId) is required" otherwise)
- Sources: [`charts/sessions-pipeline/values.yaml:16`](../charts/sessions-pipeline/values.yaml#L16), [`charts/sessions-pipeline-worker/templates/_env.tpl:20`](../charts/sessions-pipeline-worker/templates/_env.tpl#L20)

#### req.sessions-pipeline.relayauth-jwks

<a id="req-sessions-pipeline-relayauth-jwks"></a>

**A RelayAuth JWKS URL reachable from alleyoop** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

alleyoop verifies courier tokens against RelayAuth's JWKS (RELAYAUTH_JWKS_URL).
Point it at a RelayAuth install (the relayauth profile, with its JWKS ingress or
in-cluster Service) or the hosted issuer. Every profile leaves it to the operator.

- Provided by: operator
- Values: `alleyoop.auth.jwksUrl`
- Env: `RELAYAUTH_JWKS_URL`
- Verify: kubectl run -it --rm curl --image=curlimages/curl -- curl -fsS <jwksUrl> returns {"keys":[...]}
- Sources: [`charts/sessions-pipeline/values.yaml:81`](../charts/sessions-pipeline/values.yaml#L81), [`charts/session-ingest-api/templates/deployment.yaml:46`](../charts/session-ingest-api/templates/deployment.yaml#L46), `sessions-pipeline@7d7229b:src/alleyoop/ingest.ts:118`

#### req.db.postgres-17-extensions

<a id="req-db-postgres-17-extensions"></a>

**PostgreSQL 17 with pg_trgm and btree_gin (and vector) available** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

The session directory migrations run CREATE EXTENSION IF NOT EXISTS pg_trgm and
btree_gin WITH SCHEMA public (both trusted, so the migration owner can create
them). The standard search profile (postgres, pg_trgm GIN indexes) relies on
them. The chart's in-cluster HoopDb uses the CNPG standard Postgres 17 image and
also creates vector and pg_trgm at initdb; the chart documents vector for
external databases too, though the migrations at 7d7229b do not use it.

- Provided by: default: chart, external-selfhosted: operator, external-rds: operator, aws-rds-native: operator, external-supabase: operator, aws-supabase: operator, gcp-cloudsql: stack
- Values: `hoopdb.cluster.imageName`, `hoopdb.cluster.initdb.postInitApplicationSQL`
- Verify: default: psql "$HOOPDB_URL" -Atc "select name from pg_available_extensions where name in ('pg_trgm','btree_gin','vector')" lists all three; server_version_num >= 170000 / external-rds: with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select name from pg_available_extensions where name in ('pg_trgm','btree_gin','vector')" lists all three; server_version_num >= 160000 / aws-rds-native: with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select name from pg_available_extensions where name in ('pg_trgm','btree_gin','vector')" lists all three; server_version_num >= 160000
- Sources: [`charts/sessions-pipeline/values.yaml:99`](../charts/sessions-pipeline/values.yaml#L99), [`charts/sessions-pipeline/values.yaml:119`](../charts/sessions-pipeline/values.yaml#L119), [`docs/self-hosted-reference-architecture.md:75`](../docs/self-hosted-reference-architecture.md#L75), `sessions-pipeline@7d7229b:supabase/migrations/20261030010000_session_directory.sql:9`, `sessions-pipeline@7d7229b:supabase/migrations/20261030020000_session_directory_short_summary.sql:177`

#### req.db.dedicated-database

<a id="req-db-dedicated-database"></a>

**A database dedicated to HoopDb** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, aws-cnpg, external-selfhosted, external-rds, aws-rds-native, gcp-cloudsql

global-default-revoke sets the global function default of the migration owner
and every superuser in the HoopDb database; that is safe only because the
database holds nothing else. The in-cluster HoopDb is dedicated by construction.

- Provided by: default: chart, external-selfhosted: operator, external-rds: operator, aws-rds-native: operator, gcp-cloudsql: stack
- Values: `hoopdb.cluster.initdb.database`, `hoopdb.cluster.initdb.owner`
- Verify: default: psql "$HOOPDB_URL" -Atc "select nspname from pg_namespace where nspname not like 'pg_%' and nspname <> 'information_schema'" shows only HoopDb schemas / external-rds: with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select nspname from pg_namespace where nspname not like 'pg_%' and nspname <> 'information_schema'" shows only HoopDb schemas / aws-rds-native: with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select nspname from pg_namespace where nspname not like 'pg_%' and nspname <> 'information_schema'" shows only HoopDb schemas
- Sources: [`charts/sessions-pipeline/profiles/external-selfhosted.yaml:2`](../charts/sessions-pipeline/profiles/external-selfhosted.yaml#L2), [`charts/sessions-pipeline/values.yaml:275`](../charts/sessions-pipeline/values.yaml#L275)

#### req.db.compat-roles

<a id="req-db-compat-roles"></a>

**Supabase compatibility roles (anon, authenticated, service_role)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, aws-cnpg, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-supabase, gcp-cloudsql

The migrations GRANT to the Supabase roles. CNPG initdb creates them as
superuser; on plain external Postgres the migrator's shim creates them
(HOOPDB_SUPABASE_SHIM=true); on Cloud SQL the operator's
cloudsql_migration_roles.sql does (shim off); on RDS the master's
rds_migration_roles.sql does (shim off); Supabase has them natively.

- Provided by: default: chart, external-selfhosted: migrator, external-rds: operator, aws-rds-native: operator, external-supabase: operator, aws-supabase: operator, gcp-cloudsql: operator
- Values: `hoopdb.cluster.initdb.postInitApplicationSQL`, `worker.migrations.supabaseShim`
- Verify: default: psql "$HOOPDB_URL" -Atc "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role')" is 3 / external-rds: with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role')" is 3 / aws-rds-native: with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select count(*) from pg_roles where rolname in ('anon','authenticated','service_role')" is 3
- Sources: [`charts/sessions-pipeline/values.yaml:122`](../charts/sessions-pipeline/values.yaml#L122), [`charts/sessions-pipeline/ci/gcp-cloudsql-values.yaml:5`](../charts/sessions-pipeline/ci/gcp-cloudsql-values.yaml#L5), `sessions-pipeline@7d7229b:supabase/bootstrap/cloudsql_migration_roles.sql:1`

#### req.db.search-worker-role

<a id="req-db-search-worker-role"></a>

**The session directory search Worker role (session_directory_search_worker)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, aws-cnpg, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-supabase, gcp-cloudsql

NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION,
exactly statement_timeout=2s, no memberships. The migration only verifies it
(phase 1) and migrate's wait-for-role waits for it. New CNPG clusters get it from
initdb; existing CNPG clusters from searchWorkerRole.bootstrapJob; external
databases from the operator (Supabase uses the transactional _supabase wrapper).

- Provided by: default: chart, external-selfhosted: operator, external-rds: operator, aws-rds-native: operator, external-supabase: operator, aws-supabase: operator, gcp-cloudsql: operator
- Values: `hoopdb.cluster.initdb.postInitApplicationSQL`, `searchWorkerRole.bootstrapJob.enabled`, `searchWorkerRole.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.role`
- Verify: default: psql "$HOOPDB_URL" -Atc "select rolcanlogin, rolconfig from pg_roles where rolname='session_directory_search_worker'" is f\|{statement_timeout=2s} / external-selfhosted: run supabase/bootstrap/session_directory_search_worker.sql as a superuser; then the same query / external-rds: the master runs supabase/bootstrap/rds_migration_roles.sql; then, with uselibpqcompat=true removed from the URL (psql rejects it), the same query / aws-rds-native: the master runs supabase/bootstrap/rds_migration_roles.sql; then, with uselibpqcompat=true removed from the URL (psql rejects it), the same query / external-supabase: run supabase/bootstrap/session_directory_search_worker_supabase.sql as postgres; then the same query / gcp-cloudsql: run supabase/bootstrap/session_directory_search_worker.sql as the migration owner; then the same query
- Sources: [`charts/sessions-pipeline/values.yaml:131`](../charts/sessions-pipeline/values.yaml#L131), [`charts/sessions-pipeline/values.yaml:218`](../charts/sessions-pipeline/values.yaml#L218), [`charts/sessions-pipeline/templates/search-worker-role-bootstrap.yaml:7`](../charts/sessions-pipeline/templates/search-worker-role-bootstrap.yaml#L7), [`README.md:259`](../README.md#L259), `sessions-pipeline@7d7229b:supabase/bootstrap/session_directory_search_worker.sql:1`, `sessions-pipeline@7d7229b:runbooks/session-directory-search-worker-bootstrap.md:1`

#### req.db.runtime-role

<a id="req-db-runtime-role"></a>

**The dedicated HoopDb runtime role (HOOPDB_RUNTIME_ROLE, e.g. sessions_pipeline_runtime)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, aws-cnpg, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-supabase, gcp-cloudsql

The role the services connect as: never the migration owner or the search
Worker; NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS, LOGIN as
configured, CONNECT granted, TEMPORARY revoked from PUBLIC (Supabase keeps its
PUBLIC TEMPORARY baseline). On CNPG runtimeRole.bootstrapJob creates or verifies
it; external databases pre-provision it (hoopdb_runtime_role.sql, the _rds
variant on RDS, or the _supabase wrapper with -v runtime_role=sessions_pipeline_runtime -v runtime_login=true).
Never the drifted legacy relayhistory_runtime.

- Provided by: default: chart, external-selfhosted: operator, external-rds: operator, aws-rds-native: operator, external-supabase: operator, aws-supabase: operator, gcp-cloudsql: operator
- Values: `worker.migrations.runtimeRole`, `worker.migrations.runtimeRoleLogin`, `runtimeRole.bootstrapJob.enabled`, `runtimeRole.bootstrapJob.sqlPath`
- Env: `HOOPDB_RUNTIME_ROLE`, `HOOPDB_RUNTIME_ROLE_LOGIN`
- Verify: default: psql "$HOOPDB_URL" -Atc "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin from pg_roles where rolname='sessions_pipeline_runtime'" is f\|f\|f\|f\|f\|t; migrate refuses otherwise / external-rds: with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin from pg_roles where rolname='sessions_pipeline_runtime'" is f\|f\|f\|f\|f\|t; migrate refuses otherwise / aws-rds-native: with uselibpqcompat=true removed from the URL (psql rejects it), psql "$HOOPDB_URL" -Atc "select rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin from pg_roles where rolname='sessions_pipeline_runtime'" is f\|f\|f\|f\|f\|t; migrate refuses otherwise
- Sources: [`charts/sessions-pipeline/templates/hoopdb-runtime-role-bootstrap.yaml:17`](../charts/sessions-pipeline/templates/hoopdb-runtime-role-bootstrap.yaml#L17), [`charts/sessions-pipeline/values.yaml:250`](../charts/sessions-pipeline/values.yaml#L250), [`charts/sessions-pipeline/profiles/external-supabase.yaml:29`](../charts/sessions-pipeline/profiles/external-supabase.yaml#L29), [`charts/sessions-pipeline-worker/templates/_env.tpl:202`](../charts/sessions-pipeline-worker/templates/_env.tpl#L202), `sessions-pipeline@7d7229b:supabase/bootstrap/hoopdb_runtime_role.sql:1`, `sessions-pipeline@7d7229b:src/hoopdb/migrate.ts:150`

#### req.db.function-boundary

<a id="req-db-function-boundary"></a>

**The durable function boundary installed before the first migrate** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, aws-cnpg, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-supabase, gcp-cloudsql

The migrator's function-boundary gate refuses (function_boundary_unproven)
without a catalog-proven control. global-default-revoke: on CNPG
functionDefaultRevoke.bootstrapJob runs hoopdb_function_default_revoke.sql
(-v migration_owner=hoop) and migrate waits for the exact default; external
Postgres runs the same file as a superuser; Cloud SQL runs
cloudsql_owner_function_default_revoke.sql as the migration owner; RDS runs
rds_owner_function_default_revoke.sql as the master.
event-trigger (Supabase only): hoopdb_sessions_function_boundary_supabase.sql as
postgres (-v runtime_role=sessions_pipeline_runtime), then migrate.ts --activation-check
must report event_trigger.verified true. Never run the default-revoke file on
Supabase.

- Provided by: default: chart, external-selfhosted: operator, external-rds: operator, aws-rds-native: operator, external-supabase: operator, aws-supabase: operator, gcp-cloudsql: operator
- Values: `functionDefaultRevoke.bootstrapJob.enabled`, `functionDefaultRevoke.bootstrapJob.sqlPath`, `worker.migrations.waitForRole.functionDefault`
- Verify: default: the function-default Job completes and migrate's wait-for-role logs "present: ... + owner function default" / external-rds: migrate completes; it refuses with function_boundary_unproven unless rds_owner_function_default_revoke.sql has run / aws-rds-native: migrate completes; it refuses with function_boundary_unproven unless rds_owner_function_default_revoke.sql has run / external-supabase: migrate.ts --activation-check with HOOPDB_DB_MODE=supabase HOOPDB_FUNCTION_BOUNDARY_MODE=event-trigger reports event_trigger.verified true / aws-supabase: no boundary is selected in this shape; migrate refuses with function_boundary_unproven until one is
- Sources: [`charts/sessions-pipeline/templates/hoopdb-function-default-revoke.yaml:17`](../charts/sessions-pipeline/templates/hoopdb-function-default-revoke.yaml#L17), [`charts/sessions-pipeline/values.yaml:283`](../charts/sessions-pipeline/values.yaml#L283), [`charts/sessions-pipeline/profiles/external-supabase.yaml:38`](../charts/sessions-pipeline/profiles/external-supabase.yaml#L38), [`charts/sessions-pipeline/profiles/external-selfhosted.yaml:17`](../charts/sessions-pipeline/profiles/external-selfhosted.yaml#L17), `sessions-pipeline@7d7229b:supabase/bootstrap/hoopdb_function_default_revoke.sql:1`, `sessions-pipeline@7d7229b:supabase/bootstrap/hoopdb_sessions_function_boundary_supabase.sql:1`, `sessions-pipeline@7d7229b:supabase/bootstrap/cloudsql_owner_function_default_revoke.sql:1`, `sessions-pipeline@7d7229b:runbooks/session-directory-search-worker-bootstrap.md:374`

#### req.sessions-pipeline.privileged-sql-image

<a id="req-sessions-pipeline-privileged-sql-image"></a>

**The services image digest for the privileged SQL Jobs** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, aws-cnpg

The runtime-role, function-default and search Worker Jobs copy their bootstrap
file from the services image by digest (privilegedSql.sqlImage, or a Job's own
sqlImage). There is no chart default: every enabled Job fails to render
without it. The profiles pin the same digest as the workloads.

- Provided by: chart
- Values: `privilegedSql.sqlImage.repository`, `privilegedSql.sqlImage.digest`, `searchWorkerRole.bootstrapJob.sqlImage.*`, `runtimeRole.bootstrapJob.sqlImage.*`, `functionDefaultRevoke.bootstrapJob.sqlImage.*`
- Verify: helm template renders (it fails with "sqlImage.repository and .digest are required" otherwise); ci/sessions-pipeline-profiles/matrix.sh asserts the image
- Sources: [`charts/sessions-pipeline/values.yaml:194`](../charts/sessions-pipeline/values.yaml#L194), [`charts/sessions-pipeline/templates/_privileged-sql-job.tpl:16`](../charts/sessions-pipeline/templates/_privileged-sql-job.tpl#L16)

#### req.sessions-pipeline.role-verify

<a id="req-sessions-pipeline-role-verify"></a>

**migrate always runs the phase 2 role verify (HOOPDB_ROLE_VERIFY=true)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

Readiness needs the PASS marker for the image's migration generation that only
a verifying migrate writes, so the chart always sets it and refuses an override
via extraEnv or component env.

- Provided by: chart
- Env: `HOOPDB_ROLE_VERIFY`
- Verify: kubectl get job -l app.kubernetes.io/component=hoopdb-migrate -o yaml shows HOOPDB_ROLE_VERIFY "true"; workloads go ready after migrate
- Sources: [`charts/sessions-pipeline-worker/templates/_jobspec.tpl:82`](../charts/sessions-pipeline-worker/templates/_jobspec.tpl#L82), [`charts/sessions-pipeline-worker/templates/_env.tpl:23`](../charts/sessions-pipeline-worker/templates/_env.tpl#L23)

#### req.secret.model-api-key

<a id="req-secret-model-api-key"></a>

**Model API key Secret for session briefs (OPENAI_API_KEY)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

Native briefs read the model key from an existing Secret named by
nativeBrief.openaiSecret. The key is supplied only to the main worker,
never the CA-admission init container. Missing credentials never produce
generated text. Configure the Secret through the operator credential store,
never a literal value or unmanaged env override.

- Provided by: operator
- Values: `worker.nativeBrief.openaiSecret`, `worker.nativeBrief.openaiSecret.name`, `worker.nativeBrief.openaiSecret.key`
- Env: `OPENAI_API_KEY`
- Secret: `<model key Secret>` from `worker.nativeBrief.openaiSecret.name`; keys `OPENAI_API_KEY` from `worker.nativeBrief.openaiSecret.key`
- Verify: A worker Pod references the chosen Secret/key; the init container does not. Verify an actual model result separately.
- Sources: [`charts/sessions-pipeline-worker/templates/_native-brief.tpl:75`](../charts/sessions-pipeline-worker/templates/_native-brief.tpl#L75)

#### req.relay-control.session-read

<a id="req-relay-control-session-read"></a>

**Session read API handoff and token introspection for Control** · shipped · chart `relay-control` · profiles relay-control

Default off. services.sessionReadApiUrl, services.sessionReadApiPublicUrl
and secretKeys.sessionReadApiSecret enable the Control credential handoff
to the session read API and must be set together;
services.sessionReadApiMcpReads also sends MCP session reads there. The
handoff needs Control 0.5.1. secretKeys.introspectSecret or the separate
introspection.existingSecret reference enables token introspection, and
introspection.audiences lists the accepted origins.

- Provided by: operator
- Values: `services.relayhistoryBackend`, `services.sessionReadApiUrl`, `services.sessionReadApiPublicUrl`, `services.sessionReadApiMcpReads`, `secretKeys.sessionReadApiSecret`, `secretKeys.introspectSecret`, `introspection.audiences`
- Env: `RELAYHISTORY_BACKEND`, `SESSION_READ_API_URL`, `SESSION_READ_API_PUBLIC_URL`, `SESSION_READ_API_SECRET_FILE`, `SESSION_READ_API_MCP_READS`, `RELAYCONTROL_INTROSPECT_SECRET_FILE`, `SELFHOST_INTROSPECT_AUDIENCES`
- Verify: helm template renders no SESSION_READ_API_* or introspection env by default, and renders each one with the secrets as mounted files when configured.
- Sources: [`charts/relay-control/values.yaml`](../charts/relay-control/values.yaml), [`charts/relay-control/templates/_helpers.tpl`](../charts/relay-control/templates/_helpers.tpl)

#### req.relay-control.config

<a id="req-relay-control-config"></a>

**Self-host control-plane existing Secret and service configuration** · shipped · chart `relay-control` · profiles relay-control

packages/selfhost-api reads its runtime database, RelayAuth API key,
bootstrap token and encryption key only from an existing Secret mounted
as files. encryption.keyId (SELFHOST_ENCRYPTION_KEY_ID) is the required
non-secret id stored with every encrypted value; the API refuses to start
without it. The migration owner URL is projected only into the migration
Job. Internal service origins are explicit chart values; Relaycast and
RelayHistory public origins must use public multi-label HTTPS DNS.

- Provided by: operator
- Values: `publicUrl`, `services.*`, `existingSecret`, `secretKeys.*`, `database.runtimeRole`, `encryption.keyId`, `ingress.tls`, `imagePullSecrets`
- Env: `SELFHOST_ENCRYPTION_KEY_ID`, `DATABASE_URL_FILE`, `DATABASE_MIGRATIONS_URL_FILE`, `SELFHOST_RUNTIME_DATABASE_ROLE`, `RELAYAUTH_API_KEY_FILE`, `SELFHOST_BOOTSTRAP_TOKEN_FILE`, `SELFHOST_ENCRYPTION_KEY_FILE`, `SELFHOST_PUBLIC_URL`, `RELAYAUTH_URL`, `RELAYCAST_URL`, `RELAYCAST_PUBLIC_URL`, `RELAYHISTORY_URL`, `RELAYHISTORY_PUBLIC_URL`
- Secret: `<existingSecret>` from `existingSecret`; keys `database-url` from `secretKeys.databaseUrl`; `database-migrations-url` from `secretKeys.databaseMigrationsUrl`; `relayauth-api-key` from `secretKeys.relayauthApiKey`; `selfhost-bootstrap-token` from `secretKeys.bootstrapToken`; `selfhost-encryption-key` from `secretKeys.encryptionKey`
- Secret: `<ingress.tls[].secretName>`. kubernetes.io/tls, normally managed by the GKE ingress certificate path
- Secret: `<imagePullSecrets[].name>`. optional registry pull Secret
- Verify: helm template fails without existingSecret, encryption.keyId, immutable image digest or valid public service origins; the migration Job invokes migrate-cli.js directly and projects only database-migrations-url
- Sources: [`charts/relay-control/values.yaml`](../charts/relay-control/values.yaml), [`charts/relay-control/templates/_helpers.tpl`](../charts/relay-control/templates/_helpers.tpl)

#### req.relaycast.secret

<a id="req-relaycast-secret"></a>

**Relaycast secret (internal admin + workspace bootstrap)** · shipped · chart `relaycast` · profiles relaycast

An existing Secret in the release namespace; the keys are mounted read-only
under /run/secrets/relaycast and passed as *_FILE paths. internal-secret is the
bearer (>= 32 characters) for the in-cluster /internal admin API;
workspace-bootstrap-secret derives keyed workspace-create retries and must stay
stable across upgrades. The optional credentialKeyring and relayauthToken keys
wire ar_ credentials (see opt.relaycast.credential-authority).

- Provided by: operator
- Values: `existingSecret`, `secretKeys.internalSecret`, `secretKeys.bootstrapSecret`, `secretKeys.credentialKeyring`, `secretKeys.relayauthToken`, `secretKeys`
- Env: `RELAYCAST_INTERNAL_SECRET_FILE`, `RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET_FILE`, `RELAYCAST_CREDENTIAL_KEYRING_FILE`, `RELAYCAST_RELAYAUTH_TOKEN_FILE`
- Secret: `<existingSecret, e.g. relaycast-secrets>` from `existingSecret`; keys `internal-secret` from `secretKeys.internalSecret`; `workspace-bootstrap-secret` from `secretKeys.bootstrapSecret`; `<operator-chosen, no default>` from `secretKeys.credentialKeyring` (optional: required when credentials.authority=self (the ar_ tag keyring)); `<operator-chosen, no default>` from `secretKeys.relayauthToken` (optional: required when credentials.authority=relayauth or credentials.relayauth.url is set (the RelayAuth token))
- Verify: kubectl -n relaycast get secret relaycast-secrets -o jsonpath='{.data}' has internal-secret and workspace-bootstrap-secret, plus the secretKeys.credentialKeyring key when credentials.authority=self or the secretKeys.relayauthToken key when credentials.authority=relayauth; helm template fails with "existingSecret is required", or the matching credentials error, otherwise
- Sources: [`charts/relaycast/values.yaml:47`](../charts/relaycast/values.yaml#L47), [`charts/relaycast/templates/deployment.yaml:61`](../charts/relaycast/templates/deployment.yaml#L61), [`charts/relaycast/templates/_helpers.tpl:103`](../charts/relaycast/templates/_helpers.tpl#L103), [`README.md:62`](../README.md#L62)

#### req.relaycast.base-url

<a id="req-relaycast-base-url"></a>

**Relaycast public origin (baseUrl)** · shipped · chart `relaycast` · profiles relaycast

Embedded in signed file URLs and A2A cards. An HTTPS origin with public
multi-label DNS and no path, or a cluster-internal http:// origin with
allowInsecureBaseUrl=true. Passed as --base-url.

- Provided by: operator
- Values: `baseUrl`
- Verify: helm template fails with "baseUrl is required" otherwise; curl <baseUrl>/health
- Sources: [`charts/relaycast/values.yaml:31`](../charts/relaycast/values.yaml#L31), [`charts/relaycast/templates/_helpers.tpl:80`](../charts/relaycast/templates/_helpers.tpl#L80)

#### req.relaycast.dns-tls

<a id="req-relaycast-dns-tls"></a>

**DNS and a TLS certificate for the public Relaycast host (with ingress)** · shipped · chart `relaycast` · profiles relaycast

With ingress.enabled the baseUrl host must be in ingress.hosts, resolve to the
ingress controller, and serve HTTPS: either an ingress.tls Secret (cert-manager
can create and renew it via annotations) or ingress.externalTls when a load
balancer terminates TLS. An ingress controller (ingress.className) must exist,
and with networkPolicy networkPolicy.ingressFrom must allow it.

- Provided by: operator
- Values: `ingress.enabled`, `ingress.hosts`, `ingress.tls`, `ingress.externalTls`, `ingress.className`, `ingress.annotations`, `networkPolicy.ingressFrom`
- Secret: `<ingress.tls[].secretName>`. kubernetes.io/tls; created by cert-manager when annotated
- Verify: dig +short <host>; curl -fsS https://<host>/health; curl -s -o /dev/null -w '%{http_code}' https://<host>/internal is 503
- Sources: [`charts/relaycast/values.yaml:107`](../charts/relaycast/values.yaml#L107), [`charts/relaycast/templates/_helpers.tpl:170`](../charts/relaycast/templates/_helpers.tpl#L170), [`charts/relaycast/templates/_helpers.tpl:173`](../charts/relaycast/templates/_helpers.tpl#L173)

#### req.relaycast.storage

<a id="req-relaycast-storage"></a>

**A ReadWriteOnce volume for the SQLite database and files** · shipped · chart `relaycast` · profiles relaycast

One replica, Recreate upgrades; the data PVC (10Gi, helm.sh/resource-policy keep) and, with backups, a second PVC on the same node.

- Provided by: operator
- Values: `persistence.existingClaim`, `persistence.storageClass`, `persistence.accessMode`, `persistence.size`, `replicaCount`
- Verify: kubectl get pvc -n relaycast Bound; helm template refuses replicaCount != 1
- Sources: [`charts/relaycast/values.yaml:130`](../charts/relaycast/values.yaml#L130), [`charts/relaycast/templates/_helpers.tpl:74`](../charts/relaycast/templates/_helpers.tpl#L74)

#### req.relayauth.secret

<a id="req-relayauth-secret"></a>

**RelayAuth secret and signing keys** · shipped · chart `relayauth` · profiles relayauth

A pre-created Secret; the chart never renders key material. Keys are mounted
under /run/secrets/relayauth and passed as *_FILE paths: the internal secret,
the signing key PEM, and the bootstrap API key (bound to
relayhistory.bootstrapApiKeyOrg). Each secretKeys entry must be a valid Secret
data key. The optional relaycast* keys wire RelayAuth-issued relaycast
credentials (see opt.relayauth.relaycast-credentials).

- Provided by: operator
- Values: `existingSecret`, `secretKeys`, `secretKeys.internalSecret`, `secretKeys.signingKey`, `secretKeys.bootstrapApiKey`, `secretKeys.relaycastCredentialKeyring`, `secretKeys.relaycastInternalSecret`, `secretKeys.relaycastServiceApiKey`
- Env: `INTERNAL_SECRET_FILE`, `RELAYAUTH_SIGNING_KEY_PEM_FILE`, `RELAYAUTH_BOOTSTRAP_API_KEY_FILE`, `RELAYAUTH_RELAYCAST_CREDENTIAL_KEYRING_FILE`, `RELAYAUTH_RELAYCAST_INTERNAL_SECRET_FILE`, `RELAYAUTH_RELAYCAST_SERVICE_API_KEY_FILE`
- Secret: `<existingSecret, e.g. relayauth-secrets>` from `existingSecret`; keys `internal-secret` from `secretKeys.internalSecret`; `signing-key.pem` from `secretKeys.signingKey`; `bootstrap-api-key` from `secretKeys.bootstrapApiKey`; `<operator-chosen, no default>` from `secretKeys.relaycastCredentialKeyring` (optional: set to issue relaycast ar_ credentials (requires relaycast.url and secretKeys.relaycastInternalSecret)); `<operator-chosen, no default>` from `secretKeys.relaycastInternalSecret` (optional: required with secretKeys.relaycastCredentialKeyring (Relaycast internal API bearer)); `<operator-chosen, no default>` from `secretKeys.relaycastServiceApiKey` (optional: only with secretKeys.relaycastCredentialKeyring)
- Verify: kubectl get secret relayauth-secrets -o jsonpath='{.data}' has the three required keys, plus the relaycast* keys when secretKeys.relaycastCredentialKeyring is set; helm template fails with "existingSecret is required" (or the relaycast* pairing errors) otherwise
- Sources: [`charts/relayauth/values.yaml:53`](../charts/relayauth/values.yaml#L53), [`charts/relayauth/templates/deployment.yaml:65`](../charts/relayauth/templates/deployment.yaml#L65), [`charts/relayauth/templates/_helpers.tpl:71`](../charts/relayauth/templates/_helpers.tpl#L71)

#### req.relayauth.storage

<a id="req-relayauth-storage"></a>

**A ReadWriteOnce volume for the RelayAuth SQLite database** · shipped · chart `relayauth` · profiles relayauth

One replica (single-writer SQLite), Recreate; the data PVC is kept on uninstall.

- Provided by: operator
- Values: `persistence.existingClaim`, `persistence.storageClass`, `persistence.size`, `replicaCount`
- Verify: kubectl get pvc Bound; helm template refuses replicaCount != 1
- Sources: [`charts/relayauth/values.yaml:87`](../charts/relayauth/values.yaml#L87), [`charts/relayauth/templates/_helpers.tpl:68`](../charts/relayauth/templates/_helpers.tpl#L68)

#### req.relayfile.secret

<a id="req-relayfile-secret"></a>

**Relayfile credentials Secret** · shipped · chart `relayfile` · profiles relayfile

secrets.existingSecret with keys RELAYFILE_PRODUCTION_DSN (Postgres, required
with backendProfile production), RELAYFILE_INTERNAL_HMAC_SECRET (required) and
RELAYFILE_JWT_SECRET, plus provider tokens. Without existingSecret the chart
renders a Secret from the inline secrets.* values (not recommended).

- Provided by: operator
- Values: `secrets.existingSecret`, `secrets.productionDsn`, `secrets.internalHmacSecret`, `secrets.jwtSecret`
- Env: `RELAYFILE_PRODUCTION_DSN`, `RELAYFILE_INTERNAL_HMAC_SECRET`, `RELAYFILE_JWT_SECRET`
- Secret: `<secrets.existingSecret>`; keys `RELAYFILE_PRODUCTION_DSN`; `RELAYFILE_INTERNAL_HMAC_SECRET`; `RELAYFILE_JWT_SECRET`
- Verify: helm template fails with "secrets.internalHmacSecret is required" without either
- Sources: [`charts/relayfile/values.yaml:66`](../charts/relayfile/values.yaml#L66), [`charts/relayfile/templates/server/_helpers.tpl:69`](../charts/relayfile/templates/server/_helpers.tpl#L69), [`charts/relayfile/templates/secret.yaml:12`](../charts/relayfile/templates/secret.yaml#L12)

#### req.relayfile.postgres

<a id="req-relayfile-postgres"></a>

**A Postgres database for Relayfile (production profile)** · shipped · chart `relayfile` · profiles relayfile

backendProfile production stores state in Postgres via RELAYFILE_PRODUCTION_DSN.

- Provided by: operator
- Values: `server.backendProfile`
- Verify: psql "$RELAYFILE_PRODUCTION_DSN" -c 'select 1'
- Sources: [`charts/relayfile/values.yaml:43`](../charts/relayfile/values.yaml#L43)

#### req.relayflows.enrollment-secret

<a id="req-relayflows-enrollment-secret"></a>

**Cloud worker enrollment token (cloudWorker mode only)** · shipped · chart `relayflows` · profiles relayflows

AGENT_RELAY_WORKER_ENROLLMENT_TOKEN from credentials.existingSecret (key credentials.existingSecretKey), or from credentials.enrollmentToken rendered into a chart Secret. Not used in standalone mode.

- Provided by: operator
- Values: `credentials.existingSecret`, `credentials.existingSecretKey`, `credentials.enrollmentToken`
- Env: `AGENT_RELAY_WORKER_ENROLLMENT_TOKEN`
- Secret: `<credentials.existingSecret>`; keys `AGENT_RELAY_WORKER_ENROLLMENT_TOKEN` from `credentials.existingSecretKey`
- Verify: the worker's startup probe (agent-relay cloud worker status) passes
- Sources: [`charts/relayflows/values.yaml:91`](../charts/relayflows/values.yaml#L91), [`charts/relayflows/templates/worker/deployment.yaml:117`](../charts/relayflows/templates/worker/deployment.yaml#L117)

#### req.relayflows.storage

<a id="req-relayflows-storage"></a>

**A ReadWriteOncePod volume for run journals or worker state** · shipped · chart `relayflows` · profiles relayflows

Standalone run journals (resume) or Cloud worker registration state; ReadWriteOncePod prevents an old and new Job mounting it at once.

- Provided by: operator
- Values: `persistence.*`
- Verify: kubectl get pvc Bound; the StorageClass supports ReadWriteOncePod (CSI, Kubernetes 1.29+)
- Sources: [`charts/relayflows/values.yaml:96`](../charts/relayflows/values.yaml#L96)

#### req.durable-actors.gke-sandbox

<a id="req-durable-actors-gke-sandbox"></a>

**GKE Standard with GKE Sandbox (gVisor), Workload Identity and enforced NetworkPolicy** · shipped · chart `durable-actors` · profiles durable-actors, agent-relay-durable-actors

Actor hosts are Pods the control plane creates with runtimeClassName gvisor,
nodeSelector sandbox.gke.io/runtime=gvisor and a zone affinity from
placement.zone, so a GKE Sandbox node pool must have nodes in that zone.
Controllers avoid gVisor nodes. There is no kind/MinIO/S3 provider upstream;
local proofs use the durable-actors dev runtime instead.

- Provided by: operator
- Values: `placement.zone`, `sandboxNamespace`, `nodeSelector`, `networkPolicy.dnsCidrs`, `actors.*`, `organizationLimits.*`, `alarms.*`, `resources.*`, `replicaCount`, `podDisruptionBudget.*`, `topologySpread.*`, `analytics.backend`, `usage.topic`, `postgres.maxConnections`
- Env: `DURABLE_ACTORS_PROCESS_ROLE`, `DURABLE_ACTORS_CONTROL_PLANE_BIND`, `DURABLE_ACTORS_ALARM_POLL_INTERVAL_MS`, `DURABLE_ACTORS_POSTGRES_MAX_CONNECTIONS`, `DURABLE_ACTORS_ANALYTICS_BACKEND`, `DURABLE_ACTORS_USAGE_TOPIC`, `DURABLE_ACTORS_ORGANIZATION_LIMITS_ENABLED`, `DURABLE_ACTORS_ORGANIZATION_MAX_ACTIVE_ACTORS`, `DURABLE_ACTORS_ORGANIZATION_ACTOR_STARTS_PER_SECOND`, `DURABLE_ACTORS_ORGANIZATION_ACTOR_START_BURST`, `DURABLE_ACTORS_TYPESCRIPT_IMAGE`, `DURABLE_ACTORS_PYTHON_IMAGE`, `DURABLE_ACTORS_GKE_NAMESPACE`, `DURABLE_ACTORS_GKE_ZONE`, `DURABLE_ACTORS_SPARE_IDLE`, `DURABLE_ACTORS_HOST_IDLE_TIMEOUT_MS`, `DURABLE_ACTORS_SPARE_MAX_STARTING`, `DURABLE_ACTORS_SPARE_REFILL_INTERVAL_MS`, `DURABLE_ACTORS_SPARE_RETIRE_CONCURRENCY`, `DURABLE_ACTORS_SPARE_REAP_INTERVAL_MS`, `DURABLE_ACTORS_SPARE_POD_REAP_INTERVAL_MS`, `DURABLE_ACTORS_GKE_REAP_CONCURRENCY`, `DURABLE_ACTORS_HOST_CPU_MILLIS`, `DURABLE_ACTORS_HOST_CPU_LIMIT_MILLIS`, `DURABLE_ACTORS_HOST_MEMORY_MIB`, `DURABLE_ACTORS_HOST_MEMORY_LIMIT_MIB`, `DURABLE_ACTORS_SANDBOX_MIN_CPU_MILLIS`, `DURABLE_ACTORS_SANDBOX_MAX_CPU_MILLIS`, `DURABLE_ACTORS_SANDBOX_MIN_MEMORY_MIB`, `DURABLE_ACTORS_SANDBOX_MAX_MEMORY_MIB`
- Verify: kubectl get runtimeclass gvisor; kubectl get nodes -l sandbox.gke.io/runtime=gvisor -L topology.kubernetes.io/zone shows placement.zone
- Sources: [`charts/durable-actors/templates/control-plane.yaml:101`](../charts/durable-actors/templates/control-plane.yaml#L101), [`charts/durable-actors/UPSTREAM.md:59`](../charts/durable-actors/UPSTREAM.md#L59)

#### req.durable-actors.bucket

<a id="req-durable-actors-bucket"></a>

**One Standard GCS bucket for actor state and compiled code (Rapid optional)** · shipped · chart `durable-actors` · profiles durable-actors, agent-relay-durable-actors

storage.bucket holds ownership records, immutable compiled actor code
(durable-actors/v3/artifacts/<uuid>/) and state snapshots. No lifecycle deletion.
Optional Rapid mode adds one or two RAPID buckets (hierarchical namespace) in
distinct zones. The controller GSA needs roles/storage.objectUser on each
(plus roles/storage.legacyBucketReader for Rapid).

- Provided by: operator
- Values: `storage.bucket`, `storage.mode`, `storage.rapid.*`
- Env: `DURABLE_ACTORS_PERSISTENCE`, `DURABLE_ACTORS_BUCKET`, `DURABLE_ACTORS_ARTIFACT_BUCKET`, `DURABLE_ACTORS_ARCHIVE_BUCKET`, `DURABLE_ACTORS_RAPID_BUCKETS`, `DURABLE_ACTORS_RAPID_PLACEMENT`
- Verify: gcloud storage buckets describe gs://<storage.bucket> --format='value(default_storage_class)' is STANDARD
- Sources: [`charts/durable-actors/templates/control-plane.yaml:103`](../charts/durable-actors/templates/control-plane.yaml#L103)

#### req.durable-actors.aws-s3

<a id="req-durable-actors-aws-s3"></a>

**AWS EKS - one S3 bucket, a control-plane IAM role (Pod Identity or IRSA) and a tainted actor node group** · shipped · chart `durable-actors` · profiles agent-relay-eks-durable-actors

storage.provider s3 keeps ownership records, compiled actor code and state
snapshots in storage.bucket (Standard persistence only; Rapid is GCS-only).
The control-plane role needs s3:GetObject/PutObject on <bucket>/durable-actors/*,
s3:ListBucket, and sts:AssumeRole + sts:TagSession on storage.s3.actorRoleArn,
which it narrows per actor with an inline session policy. Where STS is not
allowed, storage.s3.actorCredentials control-plane hands actor hosts the
control plane's own credentials (prefix isolation only; first-party actors).
sandbox.* schedules actor hosts (runtimeClassName, nodeSelector, tolerations;
on EKS runc on a dedicated tainted node group), and placement.zone is that
node group's availability zone. Needs a control-plane image from the
AgentWorkforce durable-actors fork (charts/durable-actors/UPSTREAM.md patch 10).

- Provided by: operator
- Values: `storage.provider`, `storage.s3.*`, `sandbox.*`, `serviceAccount.annotations`
- Env: `DURABLE_ACTORS_STORAGE_PROVIDER`, `DURABLE_ACTORS_S3_REGION`, `DURABLE_ACTORS_S3_ACTOR_CREDENTIALS`, `DURABLE_ACTORS_S3_ACTOR_ROLE_ARN`, `DURABLE_ACTORS_S3_ENDPOINT`, `DURABLE_ACTORS_S3_FORCE_PATH_STYLE`, `DURABLE_ACTORS_SANDBOX_RUNTIME_CLASS`, `DURABLE_ACTORS_SANDBOX_NODE_SELECTOR`, `DURABLE_ACTORS_SANDBOX_TOLERATIONS`
- Verify: aws s3api head-bucket --bucket <storage.bucket>; with EKS Pod Identity, aws eks list-pod-identity-associations --cluster-name <cluster> lists <release>-durable-actors; with IRSA, kubectl get serviceaccount <release>-durable-actors -o jsonpath='{.metadata.annotations.eks\\.amazonaws\\.com/role-arn}' shows a role whose trust policy names the cluster's OIDC provider; kubectl get nodes -l durable-actors/role=actor-host -L topology.kubernetes.io/zone shows placement.zone
- Sources: [`charts/durable-actors/templates/control-plane.yaml:110`](../charts/durable-actors/templates/control-plane.yaml#L110), [`charts/durable-actors/templates/control-plane.yaml:131`](../charts/durable-actors/templates/control-plane.yaml#L131), [`charts/durable-actors/UPSTREAM.md:79`](../charts/durable-actors/UPSTREAM.md#L79)

#### req.durable-actors.workload-identity

<a id="req-durable-actors-workload-identity"></a>

**A GSA bound to the control-plane KSA through Workload Identity** · shipped · chart `durable-actors` · profiles durable-actors, agent-relay-durable-actors

serviceAccount.googleServiceAccount annotates the <release>-durable-actors
KSA; bind roles/iam.workloadIdentityUser for
serviceAccount:<project>.svc.id.goog[<namespace>/<release>-durable-actors]. Actor
pods get credentials scoped to their own state from the control plane.

- Provided by: operator
- Values: `serviceAccount.googleServiceAccount`
- Verify: gcloud iam service-accounts get-iam-policy <gsa> lists the workloadIdentityUser member
- Sources: [`charts/durable-actors/templates/control-plane.yaml:7`](../charts/durable-actors/templates/control-plane.yaml#L7)

#### req.durable-actors.credentials

<a id="req-durable-actors-credentials"></a>

**durable-actors credentials Secret (postgres-url, jwt-signing-key, api-key)** · shipped · chart `durable-actors` · profiles durable-actors, agent-relay-durable-actors, agent-relay-eks-durable-actors

credentialsSecret in the release namespace. postgres-url: PostgreSQL the
controller can migrate (Cloud SQL through a proxy or private IP, TLS for remote).
jwt-signing-key: base64 Ed25519 PKCS#8 DER, stable across upgrades. api-key:
the administrative secret (registers deployments, issues sessions); only the
deploy Jobs and the Relayfile session broker may read it. Auth is off when it is
unset, so it is mandatory. redis-url (and redis-ca) when replicaCount > 1.
invoke-api-key (local chart patch invokeApiKeySecretKey): an invoke-only key
for a control-plane image with the scoped-credentials patch; gateways use it
instead of api-key.

- Provided by: operator
- Values: `credentialsSecret`, `invokeApiKeySecretKey`, `redis.urlSecretKey`, `redis.caSecretKey`, `analytics.clickhouse.*`
- Env: `DURABLE_ACTORS_POSTGRES_URL`, `DURABLE_ACTORS_JWT_SIGNING_KEY`, `DURABLE_ACTORS_SECRET`, `DURABLE_ACTORS_INVOKE_API_KEY`, `DURABLE_ACTORS_REDIS_URL`, `DURABLE_ACTORS_REDIS_CA_CERT`, `DURABLE_ACTORS_CLICKHOUSE_URL`, `DURABLE_ACTORS_CLICKHOUSE_DATABASE`, `DURABLE_ACTORS_CLICKHOUSE_USER`, `DURABLE_ACTORS_CLICKHOUSE_PASSWORD`
- Secret: `actors-credentials` from `credentialsSecret` then `durable-actors.credentialsSecret`; keys `postgres-url`; `jwt-signing-key`; `api-key`; `<operator-chosen, no default>` from `invokeApiKeySecretKey` (optional: patched control plane only (invoke-only key)); `<operator-chosen, no default>` from `redis.urlSecretKey` (optional: required when replicaCount > 1 (socket bus)); `<operator-chosen, no default>` from `redis.caSecretKey` (optional: private Redis CA, e.g. Memorystore)
- Verify: kubectl get secret actors-credentials -o jsonpath='{.data}' has postgres-url, jwt-signing-key and api-key; the controller starts and runs migrations
- Sources: [`charts/durable-actors/templates/control-plane.yaml:139`](../charts/durable-actors/templates/control-plane.yaml#L139), [`charts/durable-actors/templates/control-plane.yaml:145`](../charts/durable-actors/templates/control-plane.yaml#L145)

#### req.durable-actors.public-url

<a id="req-durable-actors-public-url"></a>

**The durable-actors public HTTPS origin (publicUrl) with WebSocket support** · shipped · chart `durable-actors`, `agent-relay` · profiles durable-actors, agent-relay-durable-actors, agent-relay-eks-durable-actors

SDK follow-up invocations and actor WebSocket URLs use publicUrl, so it must
resolve and terminate TLS: through the umbrella load balancer
(gkeIngress.hosts.actors, which routes an edge Service with a NEG and a
BackendConfig timeout for sockets) or the chart's own ingress
(ingress.className + ingress.tlsSecret).

- Provided by: operator
- Values: `publicUrl`, `ingress.enabled`, `ingress.className`, `ingress.tlsSecret`, `ingress.annotations`, `agent-relay:gkeIngress.hosts.actors`, `agent-relay:gkeIngress.actorsBackendTimeoutSec`
- Env: `DURABLE_ACTORS_PUBLIC_URL`, `DURABLE_ACTORS_CONTROL_PLANE_URL`
- Secret: `<ingress.tlsSecret>`. kubernetes.io/tls, only with the chart's own ingress
- Verify: curl -fsS <publicUrl>/healthz
- Sources: [`charts/durable-actors/templates/control-plane.yaml:97`](../charts/durable-actors/templates/control-plane.yaml#L97), [`charts/agent-relay/templates/gke-ingress.yaml:50`](../charts/agent-relay/templates/gke-ingress.yaml#L50)

#### req.relaycast.postgres

<a id="req-relaycast-postgres"></a>

**Relaycast PostgreSQL backend (owner and runtime URLs, CA, migration Job)** · shipped · chart `relaycast` · profiles relaycast-postgres

runtime.backend=postgres runs the portable image (runtime.postgres.image) on an
external PostgreSQL database that the platform prepares (relaycast_owner and
relaycast_runtime roles, schema public; see docs/self-host-postgres.md in
AgentWorkforce/relaycast). existingSecret gains two keys, each a full URL
postgres://<role>:<pw>@<host>:5432/<db>?sslmode=verify-full: the relaycast_owner URL
is projected only into the migration Job, the relaycast_runtime URL only into the
server. postgresCa names the CA bundle and is required. The Job is a plain Job named
by a hash of its pod template (args migrate, no Helm hook, exits 64 and 65 not
retried); the server's wait-for-migrations init container runs verify-db until the
database is migrated for this image. One replica; files stay on the PVC; backup.enabled
and retention.messageTtlDays are refused. Default off.

- Provided by: operator
- Values: `runtime.postgres.image.repository`, `runtime.postgres.image.digest`, `runtime.postgres.migrations.identitySalt`, `runtime.postgres.migrations.backoffLimit`, `runtime.postgres.migrations.activeDeadlineSeconds`, `secretKeys.databaseOwnerUrl`, `secretKeys.databaseRuntimeUrl`, `postgresCa.enabled`, `postgresCa.configMap`, `postgresCa.secret`, `postgresCa.key`
- Env: `RELAYCAST_DATABASE_URL_FILE`
- Secret: `<existingSecret>` from `existingSecret`; keys `database-owner-url` from `secretKeys.databaseOwnerUrl`; `database-runtime-url` from `secretKeys.databaseRuntimeUrl`
- Secret: `<postgresCa.secret>`; keys `ca.crt` from `postgresCa.key`. or the same key in the ConfigMap named by postgresCa.configMap
- Verify: kubectl wait --for=condition=complete job -l app.kubernetes.io/name=relaycast-migrate; curl <baseUrl>/health
- Sources: [`charts/relaycast/values.yaml:29`](../charts/relaycast/values.yaml#L29), [`charts/relaycast/templates/_postgres.tpl:1`](../charts/relaycast/templates/_postgres.tpl#L1), [`charts/relaycast/templates/postgres-migrate-job.yaml:1`](../charts/relaycast/templates/postgres-migrate-job.yaml#L1)

#### req.relaycast.durable-actors-secrets

<a id="req-relaycast-durable-actors-secrets"></a>

**Relaycast actor-mode Secrets (gateway invocation key, file signing, actor env, admin key)** · shipped · chart `relaycast` · profiles relaycast-durable-actors

existingSecret gains the file-signing secret (RELAYCAST_FILE_SIGNING_SECRET)
and must carry the credential keyring and internal secret. The gateway's
DURABLE_ACTORS_SECRET comes from its own invocationSecret (scope admin = a copy
of the durable-actors api-key until upstream ships an invoke-only key; never the
admin key Secret itself). The deployer alone reads adminKeySecret. Actor env
Secrets (RELAYCAST_PUBLIC_URL = baseUrl, RELAYCAST_FILE_SIGNING_SECRET,
RELAYCAST_INTERNAL_SECRET, optional engine settings) live in the durable-actors
SANDBOX namespace, labelled terse.ai/customer-secret=true, and are passed as
DURABLE_ACTORS_SECRET_REFS. devRuntime.secretKey is the dev sidecar's key.
deployer.artifactStore.driver s3 uploads bundles to S3 (DURABLE_ACTORS_ARTIFACT_STORE,
DURABLE_ACTORS_S3_*; credentials from the AWS SDK default chain, e.g. EKS Pod Identity).

- Provided by: operator
- Values: `secretKeys.workspaceBootstrapSecret`, `runtime.durableActors.fileSigningSecretKey`, `runtime.durableActors.invocationSecret.*`, `runtime.durableActors.adminKeySecret.*`, `runtime.durableActors.actorEnvSecrets`, `runtime.durableActors.devRuntime.secretKey`, `runtime.durableActors.deployer.*`
- Env: `RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET`, `DURABLE_ACTORS_SECRET`, `RELAYCAST_FILE_SIGNING_SECRET`, `DURABLE_ACTORS_ARTIFACT_BUCKET`, `DURABLE_ACTORS_SECRET_REFS`, `DURABLE_ACTORS_ORGANIZATION_ID`, `DURABLE_ACTORS_ARTIFACT_STORE`, `DURABLE_ACTORS_S3_REGION`, `DURABLE_ACTORS_S3_ENDPOINT`, `DURABLE_ACTORS_S3_FORCE_PATH_STYLE`
- Secret: `<existingSecret>` from `existingSecret` then `relaycast.existingSecret`; keys `file-signing-secret` from `runtime.durableActors.fileSigningSecretKey`; `<operator-chosen>` from `secretKeys.workspaceBootstrapSecret` (optional: keyed actor workspace creates; same bytes as the actor environment); `credential-keyring` from `secretKeys.credentialKeyring`
- Secret: `<runtime.durableActors.invocationSecret.name>`; keys `durable-actors-invoke-key` from `runtime.durableActors.invocationSecret.key`
- Secret: `actors-credentials` from `runtime.durableActors.adminKeySecret.name`; keys `api-key` from `runtime.durableActors.adminKeySecret.key`
- Secret: `<runtime.durableActors.actorEnvSecrets[], e.g. relaycast-actor-env, in the sandbox namespace>`; keys `RELAYCAST_PUBLIC_URL`; `RELAYCAST_FILE_SIGNING_SECRET`; `RELAYCAST_INTERNAL_SECRET`; `RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET` (optional: same bytes as secretKeys.workspaceBootstrapSecret); `RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED` (optional: true or false; equal to bootstrapProofRequired). label terse.ai/customer-secret=true; keys become actor env
- Secret: `<existingSecret, devRuntime only>`; keys `durable-actors-dev-secret` from `runtime.durableActors.devRuntime.secretKey`
- Verify: helm template fails with "invocationSecret must not be the admin key Secret" or "actorEnvSecrets is required" on miswiring; the deploy Job completes
- Sources: [`charts/relaycast/templates/_actors.tpl:78`](../charts/relaycast/templates/_actors.tpl#L78), [`charts/relaycast/templates/_actors.tpl:206`](../charts/relaycast/templates/_actors.tpl#L206)

#### req.relayfile.durable-actors-secrets

<a id="req-relayfile-durable-actors-secrets"></a>

**Relayfile actor-mode Secrets (gateway Secret, durable-actors admin key)** · shipped · chart `relayfile` · profiles relayfile-durable-actors

runtime.durableActors.existingSecret (gateway): RELAYFILE_JWT_SECRET (unless
auth.jwksUrl), RELAYFILE_ACTORS_BROKER_TOKEN, optional
RELAYFILE_INTERNAL_HMAC_SECRET, and for devRuntime DURABLE_ACTORS_SECRET.
adminKeySecret (the durable-actors credentialsSecret api-key) must be a
different Secret; only the session broker and the deploy Job mount it.

- Provided by: operator
- Values: `runtime.durableActors.existingSecret`, `runtime.durableActors.secretKeys.*`, `runtime.durableActors.adminKeySecret.*`, `runtime.durableActors.devRuntime.secretKey`
- Env: `RELAYFILE_ACTORS_BROKER_TOKEN`, `RELAYFILE_JWT_SECRET`, `RELAYFILE_INTERNAL_HMAC_SECRET`, `DURABLE_ACTORS_SECRET`
- Secret: `relayfile-actors` from `runtime.durableActors.existingSecret` then `relayfile.runtime.durableActors.existingSecret`; keys `RELAYFILE_JWT_SECRET` from `runtime.durableActors.secretKeys.jwtSecret`; `RELAYFILE_ACTORS_BROKER_TOKEN` from `runtime.durableActors.secretKeys.brokerToken`; `<operator-chosen, no default>` from `runtime.durableActors.secretKeys.internalHmacSecret` (optional: enables /v1/internal/webhook-envelopes)
- Secret: `actors-credentials` from `runtime.durableActors.adminKeySecret.name` then `relayfile.runtime.durableActors.adminKeySecret.name`; keys `api-key` from `runtime.durableActors.adminKeySecret.key`
- Secret: `<runtime.durableActors.existingSecret, devRuntime only>`; keys `DURABLE_ACTORS_SECRET` from `runtime.durableActors.devRuntime.secretKey`
- Verify: helm template fails with "adminKeySecret must be a different Secret" when they match; the broker's /health is ready
- Sources: [`charts/relayfile/templates/actors/_helpers.tpl:71`](../charts/relayfile/templates/actors/_helpers.tpl#L71), [`charts/relayfile/templates/actors/session-broker.yaml:64`](../charts/relayfile/templates/actors/session-broker.yaml#L64)

#### req.telemetry-collector.runtime

<a id="req-telemetry-collector-runtime"></a>

**Analytics collector image and bounded storage runtime** · shipped · chart `telemetry-collector` · profiles telemetry-collector

Internal producer-authenticated NDJSON collector. Immutable images and exact source identity are mandatory; one writer and a retained RWOP claim. TLS terminates in a sidecar; the collector binds loopback. No outbound sink or automatic producer enablement.

- Provided by: operator
- Values: `imagePullSecrets`, `image.*`, `tlsProxy.image.*`, `persistence.*`, `limits.*`, `retention.*`, `terminationGracePeriodSeconds`, `networkPolicy.allowedFrom`, `rolloutRevision`
- Env: `ANALYTICS_COLLECTOR_HOST`, `ANALYTICS_COLLECTOR_PORT`, `ANALYTICS_COLLECTOR_DATA_DIR`, `ANALYTICS_COLLECTOR_PRODUCERS_FILE`, `ANALYTICS_COLLECTOR_MAX_BATCH_BYTES`, `ANALYTICS_COLLECTOR_MAX_BATCH_EVENTS`, `ANALYTICS_COLLECTOR_MAX_EVENT_BYTES`, `ANALYTICS_COLLECTOR_REQUEST_TIMEOUT_MS`, `ANALYTICS_COLLECTOR_MAX_IN_FLIGHT`, `ANALYTICS_COLLECTOR_MAX_SEGMENTS`, `ANALYTICS_COLLECTOR_MAX_DISK_BYTES`, `ANALYTICS_COLLECTOR_SHUTDOWN_DEADLINE_MS`, `ANALYTICS_COLLECTOR_RETENTION`, `ANALYTICS_COLLECTOR_RETENTION_MAX_AGE_MS`
- Verify: Exercise the accepted collector entrypoint, authenticated TLS intake, durable files after restart and failure-before-acknowledgement cases on the installed volume.
- Sources: [`charts/telemetry-collector/templates/deployment.yaml:37`](../charts/telemetry-collector/templates/deployment.yaml#L37)

#### req.telemetry-collector.secrets

<a id="req-telemetry-collector-secrets"></a>

**Separate analytics producer and TLS credential Secrets** · shipped · chart `telemetry-collector` · profiles telemetry-collector

Operator-managed producers.json plus dedicated token files, and a separate TLS key/certificate Secret. Mounted as files; no credentials in Helm values or ConfigMaps. Rotate with a controlled restart.

- Provided by: operator
- Values: `producersSecret`, `tlsSecret`
- Verify: Check distinct mounted producer credentials and TLS keys, exact certificate SAN and issuer, and a restart after rotation; never print values.
- Sources: [`charts/telemetry-collector/templates/deployment.yaml:104`](../charts/telemetry-collector/templates/deployment.yaml#L104)

#### req.relay-chief.origins

<a id="req-relay-chief-origins"></a>

**Relay and control-plane origins** · shipped · chart `relay-chief` · profiles relay-chief

RELAY_BASE_URL and CHIEF_CONTROL_PLANE_URL, each a bare https origin (the runtime refuses plain http for non-loopback hosts). The chart refuses to render without RELAY_BASE_URL because the runtime otherwise falls back to the hosted Relay. Classification separately calls https://api.typesafe.ai, which is hardcoded and must be reachable.

- Provided by: operator
- Values: `relay.baseUrl`, `controlPlane.url`
- Env: `RELAY_BASE_URL`, `CHIEF_CONTROL_PLANE_URL`
- Verify: helm template fails with "relay.baseUrl is required" when it is unset
- Sources: [`charts/relay-chief/values.yaml:27`](../charts/relay-chief/values.yaml#L27), [`charts/relay-chief/templates/cronjob.yaml:57`](../charts/relay-chief/templates/cronjob.yaml#L57)

#### req.relay-chief.credentials

<a id="req-relay-chief-credentials"></a>

**Relay Chief runtime credentials** · shipped · chart `relay-chief` · profiles relay-chief

A pre-provisioned chief identity (not a workspace admin key), the classification API key and a scoped control-plane service credential, from one existing Secret.

- Provided by: operator
- Values: `existingSecret`, `secretKeys.*`
- Env: `RELAY_AGENT_TOKEN`, `TYPESAFE_API_KEY`, `CHIEF_CONTROL_PLANE_TOKEN`
- Secret: `<existingSecret>`; keys `relay-agent-token` from `secretKeys.relayAgentToken`; `typesafe-api-key` from `secretKeys.typesafeApiKey`; `control-plane-token` from `secretKeys.controlPlaneToken`
- Verify: helm template fails with "existingSecret is required" when it is unset; after setting suspend to false, a cycle's Job starts without a CreateContainerConfigError
- Sources: [`charts/relay-chief/values.yaml:36`](../charts/relay-chief/values.yaml#L36), [`charts/relay-chief/templates/cronjob.yaml:59`](../charts/relay-chief/templates/cronjob.yaml#L59)

#### req.relayfile-control.config

<a id="req-relayfile-control-config"></a>

**Relayfile control target URLs** · shipped · chart `relayfile-control` · profiles relayfile-control

RELAYFILE_BASE_URL (an http(s) URL) and RELAYCONTROL_BASE_URL (a bare http(s) origin). The chart always renders MIGRATE_ON_START=1.

- Provided by: operator
- Values: `config.relayfileBaseUrl`, `config.relaycontrolBaseUrl`
- Env: `RELAYFILE_BASE_URL`, `RELAYCONTROL_BASE_URL`
- Verify: helm template fails with "config.relayfileBaseUrl (RELAYFILE_BASE_URL) is required" or "config.relaycontrolBaseUrl (RELAYCONTROL_BASE_URL) is required" when one is unset
- Sources: [`charts/relayfile-control/values.yaml`](../charts/relayfile-control/values.yaml), [`charts/relayfile-control/templates/configmap.yaml`](../charts/relayfile-control/templates/configmap.yaml)

#### req.relayfile-control.credentials

<a id="req-relayfile-control-credentials"></a>

**Relayfile control database URL and service secrets** · shipped · chart `relayfile-control` · profiles relayfile-control

One existing Secret with DATABASE_URL (its own relayfile_control database), RELAYFILE_INTERNAL_HMAC_SECRET (the same value as the Relayfile server), RELAYFILE_CONTROL_ADMIN_TOKEN and RELAYCONTROL_SERVICE_TOKEN. The chart creates no Secret and takes no Secret values.

- Provided by: operator
- Values: `existingSecret`, `secretKeys.*`
- Env: `DATABASE_URL`, `RELAYFILE_INTERNAL_HMAC_SECRET`, `RELAYFILE_CONTROL_ADMIN_TOKEN`, `RELAYCONTROL_SERVICE_TOKEN`
- Secret: `<existingSecret>`; keys `DATABASE_URL` from `secretKeys.databaseUrl`; `RELAYFILE_INTERNAL_HMAC_SECRET` from `secretKeys.relayfileInternalHmacSecret`; `RELAYFILE_CONTROL_ADMIN_TOKEN` from `secretKeys.adminToken`; `RELAYCONTROL_SERVICE_TOKEN` from `secretKeys.relaycontrolServiceToken`
- Verify: helm template fails with "existingSecret is required" when it is unset; the pod starts without a CreateContainerConfigError and /readyz answers 200
- Sources: [`charts/relayfile-control/values.yaml`](../charts/relayfile-control/values.yaml), [`charts/relayfile-control/templates/_helpers.tpl`](../charts/relayfile-control/templates/_helpers.tpl)

#### req.relaychief-control.config

<a id="req-relaychief-control-config"></a>

**Relay Chief control origins** · shipped · chart `relaychief-control` · profiles relaychief-control

RELAYCONTROL_URL and RELAYCHIEF_CONTROL_PUBLIC_ORIGIN, each a bare http(s) origin. The public origin is the token audience, so it must also be among relay-control's accepted audiences.

- Provided by: operator
- Values: `config.relaycontrolUrl`, `config.publicOrigin`
- Env: `RELAYCONTROL_URL`, `RELAYCHIEF_CONTROL_PUBLIC_ORIGIN`
- Verify: helm template fails with "config.relaycontrolUrl (RELAYCONTROL_URL) is required" or "config.publicOrigin (RELAYCHIEF_CONTROL_PUBLIC_ORIGIN) is required" when one is unset
- Sources: [`charts/relaychief-control/values.yaml`](../charts/relaychief-control/values.yaml), [`charts/relaychief-control/templates/configmap.yaml`](../charts/relaychief-control/templates/configmap.yaml)

#### req.relaychief-control.credentials

<a id="req-relaychief-control-credentials"></a>

**Relay Chief control database URL and service secrets** · shipped · chart `relaychief-control` · profiles relaychief-control

One existing Secret with DATABASE_URL (also used by the migrate Job), RELAYCONTROL_INTROSPECT_SECRET and RELAYCHIEF_CONTROL_ADMIN_TOKEN (both 32 or more characters; the server refuses to start otherwise). The chart creates no Secret and takes no Secret values, so a render cannot check their presence or length.

- Provided by: operator
- Values: `existingSecret`, `secretKeys.*`
- Env: `DATABASE_URL`, `RELAYCONTROL_INTROSPECT_SECRET`, `RELAYCHIEF_CONTROL_ADMIN_TOKEN`
- Secret: `<existingSecret>`; keys `DATABASE_URL` from `secretKeys.databaseUrl`; `RELAYCONTROL_INTROSPECT_SECRET` from `secretKeys.introspectSecret`; `RELAYCHIEF_CONTROL_ADMIN_TOKEN` from `secretKeys.adminToken`; `<operator-chosen, e.g. NANGO_SECRET_KEY>` from `secretKeys.nangoSecretKey` (optional: unset leaves Nango off and creating a chief answers 503; required with config.nangoHost); `<operator-chosen, e.g. RELAYCHIEF_CONTROL_RELAY_SECRET>` from `secretKeys.relaySecret` (optional: relay identity; set with encryptionKeyId and encryptionKey or not at all); `<operator-chosen, e.g. RELAYCHIEF_CONTROL_ENCRYPTION_KEY_ID>` from `secretKeys.encryptionKeyId` (optional: relay identity; set with relaySecret and encryptionKey or not at all); `<operator-chosen, e.g. RELAYCHIEF_CONTROL_ENCRYPTION_KEY>` from `secretKeys.encryptionKey` (optional: relay identity; set with relaySecret and encryptionKeyId or not at all)
- Verify: helm template fails with "existingSecret is required" when it is unset; the pod starts without a CreateContainerConfigError and /readyz answers 200
- Sources: [`charts/relaychief-control/values.yaml`](../charts/relaychief-control/values.yaml), [`charts/relaychief-control/templates/_helpers.tpl`](../charts/relaychief-control/templates/_helpers.tpl)

### Options

#### opt.alleyoop.auth-mode

<a id="opt-alleyoop-auth-mode"></a>

**alleyoop token verification source** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

jwksUrl (RelayAuth) for every real install; localJwks reads a JWKS document from
existingSecret (secretKeys.jwksJson) for kind/local only. Exactly one is set.
issuer/audience are the expected token claims.

- Default: `jwksUrl`
- Choices: `jwksUrl`: RelayAuth JWKS URL (RELAYAUTH_JWKS_URL); `localJwks`: kind/local only: JWKS_JSON from existingSecret
- Provided by: operator
- Values: `alleyoop.auth.jwksUrl`, `alleyoop.auth.localJwks`, `alleyoop.auth.issuer`, `alleyoop.auth.audience`, `alleyoop.secretKeys.jwksJson`
- Env: `RELAYAUTH_JWKS_URL`, `JWKS_JSON`, `AUTH_ISSUER`, `AUTH_AUDIENCE`
- Secret: `<existingSecret>`; keys `JWKS_JSON` from `alleyoop.secretKeys.jwksJson`. only with auth.localJwks=true
- Verify: helm template fails with "set auth.jwksUrl OR auth.localJwks, not both" or with neither
- Sources: [`charts/session-ingest-api/values.yaml:81`](../charts/session-ingest-api/values.yaml#L81), [`charts/session-ingest-api/templates/_env.tpl:18`](../charts/session-ingest-api/templates/_env.tpl#L18), [`charts/session-ingest-api/templates/deployment.yaml:49`](../charts/session-ingest-api/templates/deployment.yaml#L49)

#### opt.sessions-pipeline.in-cluster-http

<a id="opt-sessions-pipeline-in-cluster-http"></a>

**Plain http to in-cluster Service FQDNs** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

allowInClusterHttp renders ALLOW_IN_CLUSTER_HTTP for alleyoop and every
worker component. false (default) keeps the validated destination URLs
(RelayAuth, Cloud, ingest, JWKS, history origin, model endpoint) https
(or loopback). true allows plain http only to <svc>.<ns>.svc or
<svc>.<ns>.svc.cluster.local, never public hosts, IPs or short names; for
example alleyoop.auth.jwksUrl=http://relayauth.relayauth.svc:8787/.well-known/jwks.json.
LOCKER_ENDPOINT and the OTLP endpoint are outside this policy, so the
bundled MinIO at http://session-object-storage:9000 works with the default false.

- Default: `false`
- Choices: `false`; `true`
- Provided by: operator
- Values: `alleyoop.allowInClusterHttp`, `worker.allowInClusterHttp`
- Env: `ALLOW_IN_CLUSTER_HTTP`
- Verify: helm template renders ALLOW_IN_CLUSTER_HTTP="false" by default and fails when extraEnv sets it
- Sources: [`charts/session-ingest-api/values.yaml`](../charts/session-ingest-api/values.yaml), [`charts/session-ingest-api/templates/deployment.yaml`](../charts/session-ingest-api/templates/deployment.yaml), [`charts/sessions-pipeline-worker/templates/_env.tpl`](../charts/sessions-pipeline-worker/templates/_env.tpl)

#### opt.postgres-ca-bundle

<a id="opt-postgres-ca-bundle"></a>

**CA bundle for verifying the Postgres server certificate (postgresCa)** · shipped · chart `sessions-pipeline`, `relay-control`, `relaychief-control`, `relayfile-control` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql, relay-control, agent-relay, relaychief-control, relayfile-control

node-pg verifies the server certificate for sslmode=require or verify-full, and the
service images do not carry private CAs such as Amazon RDS's. postgresCa mounts a PEM
bundle from an existing ConfigMap or Secret (exactly one, key postgresCa.key) at
/etc/postgres-ca/ca.crt and sets NODE_EXTRA_CA_CERTS there in the Deployments and the
migrate Job of each of these charts (locker-init opens no Postgres connection). Off by
default. Use sslmode=verify-full in the database URLs, and do not pair sslmode=require
with uselibpqcompat=true, which skips verification. The bundle is read at process start,
so rotating it needs a pod restart. Under the agent-relay umbrella the values are
sessions-pipeline.worker.postgresCa, sessions-pipeline.alleyoop.postgresCa,
relay-control.postgresCa. NODE_EXTRA_CA_CERTS does not reach
the read API or ingest edge, which set an explicit CA: the read API takes
SESSION_POSTGRES_TLS_PROFILE=custom-ca, SESSION_POSTGRES_CA_FILE and
SESSION_POSTGRES_CA_SHA256 through sessionReadApi.postgresCa, which mounts the file
and sets them; the ingest edge takes
ingestEdge.postgres.caConfigMap, caKey and caSha256.
When postgresCa is on, wait-for-role (psql) gets PGSSLROOTCERT. psql run by an operator
needs sslrootcert=<bundle> with verify-full.

- Default: `false` (by profile: default `false`, aws-rds-native `true`)
- Choices: `false`; `true`
- Provided by: operator
- Values: `worker.postgresCa.*`, `alleyoop.postgresCa.*`, `relay-control:postgresCa.*`, `relaychief-control:postgresCa.*`, `relayfile-control:postgresCa.*`
- Env: `NODE_EXTRA_CA_CERTS`, `PGSSLROOTCERT`
- Verify: kubectl exec deploy/<workload> -- printenv NODE_EXTRA_CA_CERTS is /etc/postgres-ca/ca.crt; the URLs use sslmode=verify-full and the migrate Job connects
- Sources: [`charts/sessions-pipeline/profiles/external-rds.yaml:19`](../charts/sessions-pipeline/profiles/external-rds.yaml#L19), [`charts/sessions-pipeline-worker/templates/_env.tpl`](../charts/sessions-pipeline-worker/templates/_env.tpl), [`charts/session-ingest-api/templates/deployment.yaml`](../charts/session-ingest-api/templates/deployment.yaml), [`charts/relay-control/templates/deployment.yaml`](../charts/relay-control/templates/deployment.yaml), [`charts/relaychief-control/templates/deployment.yaml`](../charts/relaychief-control/templates/deployment.yaml), [`charts/relayfile-control/templates/deployment.yaml`](../charts/relayfile-control/templates/deployment.yaml), `sessions-pipeline@78511e03:src/shared/db.ts:41`

#### opt.alleyoop.history-origin

<a id="opt-alleyoop-history-origin"></a>

**RelayHistory origin expected by the ingest** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

alleyoop.auth.historyOrigin renders RELAYHISTORY_ORIGIN on the ingest: the
bare origin expected as the History assertion audience. It must be
byte-equal to the courier's RELAYAUTH_HISTORY_ORIGIN. Set, it is also
what turns on verification of courier assertions with the interim bearer
off; this needs a 96bulls-services image built from sessions-pipeline
887a844 or later on both alleyoop.image.digest and worker.image.digest
(older images refuse every upload unless the interim bearer is on).
Unset, nothing is rendered and, outside environment=local, the ingest
refuses every courier upload.

- Default: `unset`
- Choices: `unset`; `origin`
- Provided by: operator
- Values: `alleyoop.auth.historyOrigin`
- Env: `RELAYHISTORY_ORIGIN`
- Verify: helm template fails when auth.historyOrigin is not a bare origin or extraEnv also sets RELAYHISTORY_ORIGIN
- Sources: [`charts/session-ingest-api/values.yaml`](../charts/session-ingest-api/values.yaml), [`charts/session-ingest-api/templates/deployment.yaml`](../charts/session-ingest-api/templates/deployment.yaml)

#### opt.alleyoop.interim-relayauth-bearer

<a id="opt-alleyoop-interim-relayauth-bearer"></a>

**Interim RelayAuth bearer compatibility (local only)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

alleyoop.auth.allowInterimRelayAuthBearer renders
ALLOW_INTERIM_RELAYAUTH_BEARER on the ingest. false (default) keeps the
ingest fail-closed: with auth.historyOrigin set, couriers present
RelayAuth assertions minted for exactly that origin (RS256 against the
configured JWKS, auth.jwksUrl or auth.localJwks, issuer auth.issuer,
the dedicated History assertion class; services image requirement under
opt.alleyoop.history-origin), and without it every bearer is refused. true accepts any RelayAuth-signed bearer, including
the legacy shared audience, and is allowed only with environment=local;
any other environment, a non-boolean value, or setting the variable
through extraEnv or ingest.env fails the render.

- Default: `false`
- Choices: `false`; `true`: environment=local only
- Provided by: operator
- Values: `alleyoop.auth.allowInterimRelayAuthBearer`
- Env: `ALLOW_INTERIM_RELAYAUTH_BEARER`
- Verify: helm template renders ALLOW_INTERIM_RELAYAUTH_BEARER="false" by default and fails for true outside environment=local or when extraEnv/ingest.env sets it
- Sources: [`charts/session-ingest-api/values.yaml`](../charts/session-ingest-api/values.yaml), [`charts/session-ingest-api/templates/_env.tpl`](../charts/session-ingest-api/templates/_env.tpl), [`charts/session-ingest-api/templates/deployment.yaml`](../charts/session-ingest-api/templates/deployment.yaml)

#### opt.sessions-pipeline.hoopdb-backend

<a id="opt-sessions-pipeline-hoopdb-backend"></a>

**HoopDb backend** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

cnpg runs HoopDb as a CloudNativePG Cluster in the release (hoopdb.enabled=true,
selfhosted mode only). external points worker.hoopdb and alleyoop.hoopdb at a
database you run (RDS/your Postgres, Cloud SQL, Supabase). The AWS stack calls
these eks.hoopdb.backend cnpg|external (cnpg is proof/sandbox stages only there).

- Default: `cnpg` (by profile: default `external`, selfhost-postgres `cnpg`, migration `cnpg`, aws-cnpg `cnpg`)
- Choices: `cnpg`: hoopdb.enabled=true; needs the CNPG operator; `external`: hoopdb.enabled=false; set worker.hoopdb/alleyoop.hoopdb
- Provided by: operator
- Values: `hoopdb.enabled`
- Verify: kubectl get cluster.postgresql.cnpg.io hoopdb exists exactly when cnpg
- Sources: [`charts/sessions-pipeline/values.yaml:90`](../charts/sessions-pipeline/values.yaml#L90), `sessions-pipeline@7d7229b:stacks/aws/hardening.ts:360`

#### opt.sessions-pipeline.db-mode

<a id="opt-sessions-pipeline-db-mode"></a>

**Migrator database mode (HOOPDB_DB_MODE)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

The migrator's database profile (sessions-pipeline migrationProfile()). No
default: the render fails without it. selfhosted for CNPG, RDS or any
operator-controlled plain Postgres; cloudsql for Google Cloud SQL; supabase for a
Supabase project; local for the dev stack only. The in-cluster HoopDb requires
selfhosted.

- Default: (no default) (by profile: default `selfhosted`, external-supabase `supabase`, aws-supabase `supabase`, gcp-cloudsql `cloudsql`, external-rds `rds`, aws-rds-native `rds`)
- Choices: `selfhosted`; `cloudsql`; `rds`: Amazon RDS for PostgreSQL 16+; `supabase`; `local`: dev stack only
- Provided by: operator
- Values: `worker.migrations.databaseMode`
- Env: `HOOPDB_DB_MODE`
- Verify: the migrate Job env has exactly one HOOPDB_DB_MODE (ci/sessions-pipeline-profiles/matrix.sh asserts the profile env)
- Sources: [`charts/sessions-pipeline-worker/values.yaml:106`](../charts/sessions-pipeline-worker/values.yaml#L106), [`charts/sessions-pipeline-worker/templates/_env.tpl:193`](../charts/sessions-pipeline-worker/templates/_env.tpl#L193), [`README.md:167`](../README.md#L167), `sessions-pipeline@7d7229b:src/hoopdb/migrate.ts:117`

#### opt.sessions-pipeline.function-boundary-mode

<a id="opt-sessions-pipeline-function-boundary-mode"></a>

**Function boundary mode (HOOPDB_FUNCTION_BOUNDARY_MODE)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

Which catalog-proven function boundary the migrator requires.
global-default-revoke (required in selfhosted and cloudsql) or event-trigger
(supabase only; refused elsewhere by the chart and the migrator). Optional in
supabase mode, where unset fails closed. The old name
HOOPDB_FUNCTION_BOUNDARY_APPROVED is refused, including via extraEnv.

- Default: (no default) (by profile: default `global-default-revoke`, external-supabase `event-trigger`, aws-supabase (no default))
- Choices: `global-default-revoke`: selfhosted and cloudsql; `event-trigger`: supabase only
- Provided by: operator
- Values: `worker.migrations.functionBoundaryMode`
- Env: `HOOPDB_FUNCTION_BOUNDARY_MODE`, `HOOPDB_FUNCTION_BOUNDARY_APPROVED`
- Verify: helm template refuses event-trigger outside supabase ("supported only in supabase mode")
- Sources: [`charts/sessions-pipeline-worker/values.yaml:125`](../charts/sessions-pipeline-worker/values.yaml#L125), [`charts/sessions-pipeline-worker/templates/_env.tpl:207`](../charts/sessions-pipeline-worker/templates/_env.tpl#L207), `sessions-pipeline@7d7229b:src/hoopdb/migrate.ts:173`

#### opt.sessions-pipeline.supabase-shim

<a id="opt-sessions-pipeline-supabase-shim"></a>

**Plain-Postgres role shim (HOOPDB_SUPABASE_SHIM)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

true makes the migrator create the Supabase compatibility roles on plain
Postgres. Required (true or false) in local, selfhosted and cloudsql (Cloud SQL:
false); in supabase mode it must be unset or false and renders "false".

- Default: (no default) (by profile: default `true`, external-supabase `false`, aws-supabase `false`, gcp-cloudsql `false`, external-rds `false`, aws-rds-native `false`)
- Choices: `true`; `false`
- Provided by: operator
- Values: `worker.migrations.supabaseShim`
- Env: `HOOPDB_SUPABASE_SHIM`
- Verify: helm template refuses supabaseShim=true in supabase and rds mode
- Sources: [`charts/sessions-pipeline-worker/values.yaml:115`](../charts/sessions-pipeline-worker/values.yaml#L115), [`charts/sessions-pipeline-worker/templates/_env.tpl:198`](../charts/sessions-pipeline-worker/templates/_env.tpl#L198), `sessions-pipeline@7d7229b:src/hoopdb/migrate.ts:131`

#### opt.sessions-pipeline.role-bootstrap

<a id="opt-sessions-pipeline-role-bootstrap"></a>

**Migrator role bootstrap (HOOPDB_ROLE_BOOTSTRAP)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

Optional; the migrator defaults it to the shim choice. Refused as true in
supabase and rds mode. Cloud SQL sets false (no customer superuser; the
operator provisions the search Worker role).

- Default: (no default) (by profile: default (no default), gcp-cloudsql `false`)
- Choices: `true`; `false`; `unset`: follows supabaseShim
- Provided by: operator
- Values: `worker.migrations.roleBootstrap`
- Env: `HOOPDB_ROLE_BOOTSTRAP`
- Verify: the migrate Job env carries HOOPDB_ROLE_BOOTSTRAP only when set
- Sources: [`charts/sessions-pipeline-worker/values.yaml:110`](../charts/sessions-pipeline-worker/values.yaml#L110), [`charts/sessions-pipeline-worker/templates/_env.tpl:233`](../charts/sessions-pipeline-worker/templates/_env.tpl#L233), `sessions-pipeline@7d7229b:src/hoopdb/migrate.ts:132`

#### opt.sessions-pipeline.runtime-workload-role

<a id="opt-sessions-pipeline-runtime-workload-role"></a>

**Runtime workload role (HOOPDB_RUNTIME_WORKLOAD_ROLE)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

The one role allowed to be a member of the runtime role (for example a pooler login role). Empty means none.

- Default: `""`
- Choices: `""`: none (the Supabase profile requires none); `<role>`
- Provided by: operator
- Values: `worker.migrations.runtimeWorkloadRole`
- Env: `HOOPDB_RUNTIME_WORKLOAD_ROLE`
- Verify: psql -Atc "select r.rolname from pg_auth_members m join pg_roles r on r.oid=m.member where m.roleid='sessions_pipeline_runtime'::regrole" lists at most that role
- Sources: [`charts/sessions-pipeline-worker/values.yaml:124`](../charts/sessions-pipeline-worker/values.yaml#L124), [`charts/sessions-pipeline-worker/templates/_env.tpl:229`](../charts/sessions-pipeline-worker/templates/_env.tpl#L229)

#### opt.sessions-pipeline.allow-blocking-index-build

<a id="opt-sessions-pipeline-allow-blocking-index-build"></a>

**Blocking index build for one migrate run (HOOPDB_ALLOW_BLOCKING_INDEX_BUILD)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

Lets the adopt-or-create index steps (20261105044020, 044040, 047000, 058000) build a missing index on a populated table with a blocking CREATE INDEX (SHARE lock - reads continue, writes to that table wait) instead of refusing with SQLSTATE 55000. Rendered into the migrate container only. The self-host upgrader sets it for one upgrade when its read-only census finds at most AGENT_RELAY_BLOCKING_INDEX_MAX_ROWS rows to index, and refuses above that; larger databases prebuild CONCURRENTLY with the packet the refusal names.

- Default: `false`
- Choices: `false`: refuse a blocking build on a populated table (the migration names the prebuild packet); `true`: one upgrade of a small database only; the next upgrade drops it
- Provided by: operator
- Values: `worker.migrations.allowBlockingIndexBuild`
- Env: `HOOPDB_ALLOW_BLOCKING_INDEX_BUILD`
- Verify: the rendered migrate Job alone carries HOOPDB_ALLOW_BLOCKING_INDEX_BUILD=true; no other workload has it
- Sources: [`charts/sessions-pipeline-worker/values.yaml:195`](../charts/sessions-pipeline-worker/values.yaml#L195), [`charts/sessions-pipeline-worker/templates/_env.tpl:312`](../charts/sessions-pipeline-worker/templates/_env.tpl#L312), [`scripts/selfhost/agent-relay-upgrade.sh`](../scripts/selfhost/agent-relay-upgrade.sh)

#### opt.sessions-pipeline.wait-for-role

<a id="opt-sessions-pipeline-wait-for-role"></a>

**migrate's wait-for-role ordering** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

An init container (by digest, the pinned CNPG Postgres image) holds migrate until
the search Worker role and, outside local mode, the runtime role exist; with
functionDefault also until the owner's function default is exact. On by default
in the umbrella; required with the in-cluster HoopDb; refused in supabase and
rds mode.

- Default: `true` (by profile: default `true`, external-supabase `false`, aws-supabase `false`, external-rds `false`, aws-rds-native `false`)
- Choices: `true`; `false`: supabase and rds mode only
- Provided by: chart
- Values: `worker.migrations.waitForRole.enabled`, `worker.migrations.waitForRole.functionDefault`, `worker.migrations.waitForRole.image`, `worker.migrations.waitForRole.intervalSeconds`, `worker.migrations.waitForRole.role`
- Verify: kubectl logs job/<migrate> -c wait-for-role ends with "present"
- Sources: [`charts/sessions-pipeline/values.yaml:73`](../charts/sessions-pipeline/values.yaml#L73), [`charts/sessions-pipeline-worker/templates/_jobspec.tpl:32`](../charts/sessions-pipeline-worker/templates/_jobspec.tpl#L32), [`charts/sessions-pipeline-worker/templates/_env.tpl:199`](../charts/sessions-pipeline-worker/templates/_env.tpl#L199)

#### opt.sessions-pipeline.supabase-activation-hold

<a id="opt-sessions-pipeline-supabase-activation-hold"></a>

**External-Supabase activation hold** · shipped · chart `sessions-pipeline` · profiles external-supabase

profiles/external-supabase.yaml sets supabaseActivation.hold=true, so that profile
does not render. Lift it only when the pinned image is confirmed as the
production-Supabase pin and the live Supabase activation steps (the event-trigger
bootstrap and --activation-check) are approved.

- Default: `false` (by profile: default `true`)
- Choices: `true`: fail-closed (render refused); `false`: after approval
- Provided by: operator
- Values: `supabaseActivation.hold`
- Verify: helm template with the profile fails with "supabaseActivation.hold" until lifted
- Sources: [`charts/sessions-pipeline/values.yaml:307`](../charts/sessions-pipeline/values.yaml#L307), [`charts/sessions-pipeline/templates/supabase-activation-hold.yaml:2`](../charts/sessions-pipeline/templates/supabase-activation-hold.yaml#L2)

#### opt.hoopdb.migration-owner-url

<a id="opt-hoopdb-migration-owner-url"></a>

**Separate migration-owner URL for migrate** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase

Optional everywhere except Cloud SQL and RDS (see req.secret.hoopdb-migration-url): when
both migrations.hoopdb.existingSecret and key are set, only migrate and its
wait-for-role read that URL, and long-running workloads keep the least-privilege
worker.hoopdb URL. Set both or neither.

- Default: `""` (by profile: default `""`, external-rds `sessions-pipeline-hoopdb/HOOPDB_MIGRATION_URL`, aws-rds-native `agent-relay-secrets/HOOPDB_MIGRATION_URL`)
- Choices: `""`: migrate uses HOOPDB_URL; `<secret>/<key>`: owner URL for migrate only
- Provided by: operator
- Values: `worker.migrations.hoopdb.existingSecret`, `worker.migrations.hoopdb.key`
- Verify: helm template refuses one without the other ("must be set together")
- Sources: [`charts/sessions-pipeline/values.yaml:56`](../charts/sessions-pipeline/values.yaml#L56), [`charts/sessions-pipeline-worker/templates/_env.tpl:18`](../charts/sessions-pipeline-worker/templates/_env.tpl#L18)

#### opt.sessions-pipeline.locker-backend

<a id="opt-sessions-pipeline-locker-backend"></a>

**Locker object store** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

minio runs the bundled MinIO (session-object-storage.enabled; Chainguard image, digest-pinned) and
the locker-init Job creates the bucket. external uses your S3-compatible bucket:
set worker.locker / alleyoop.locker (endpoint empty = native AWS S3 for region),
and set worker.lockerInit.enabled=false when the bucket already exists and is
versioned.

- Default: `minio` (by profile: default `minio`, aws-cnpg `external`, aws-supabase `external`, gcp-cloudsql `external`, aws-rds-native `external`)
- Choices: `minio`; `external`: S3 / GCS bucket
- Provided by: operator
- Values: `session-object-storage.enabled`, `worker.locker.endpoint`, `worker.locker.bucket`, `worker.locker.region`, `alleyoop.locker.endpoint`, `alleyoop.locker.bucket`, `alleyoop.locker.region`, `worker.lockerInit.enabled`
- Env: `LOCKER_ENDPOINT`, `LOCKER_BUCKET`, `LOCKER_REGION`
- Verify: the locker-init Job completes (minio) or a worker writes to the bucket (external)
- Sources: [`charts/sessions-pipeline/values.yaml:137`](../charts/sessions-pipeline/values.yaml#L137), [`charts/sessions-pipeline-worker/templates/_env.tpl:71`](../charts/sessions-pipeline-worker/templates/_env.tpl#L71)

#### opt.sessions-pipeline.locker-credentials-mode

<a id="opt-sessions-pipeline-locker-credentials-mode"></a>

**Locker credentials mode** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

secret reads the LOCKER_* keys from existingSecret; podIdentity omits both static credential env vars so the SDK uses workload identity.

- Default: `secret` (by profile: default `secret`, aws-cnpg `podIdentity`, aws-supabase `podIdentity`, gcp-cloudsql `podIdentity`, aws-rds-native `podIdentity`)
- Choices: `secret`; `podIdentity`
- Provided by: operator
- Values: `worker.locker.credentials.mode`, `alleyoop.locker.credentials.mode`
- Verify: no LOCKER_ACCESS_KEY_ID in the rendered pods with podIdentity
- Sources: [`charts/sessions-pipeline-worker/values.yaml:63`](../charts/sessions-pipeline-worker/values.yaml#L63), [`charts/sessions-pipeline-worker/templates/_env.tpl:15`](../charts/sessions-pipeline-worker/templates/_env.tpl#L15)

#### opt.sessions-pipeline.locker-provider

<a id="opt-sessions-pipeline-locker-provider"></a>

**Locker provider (S3-compatible or native GCS)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

s3 (default) leaves LOCKER_PROVIDER unset: MinIO, AWS S3 or another
S3-compatible store. gcs renders LOCKER_PROVIDER=gcs and
PIPELINE_RAW_PROVIDER=gcs so the services use their native GCS adapter with a
GKE Workload Identity token. It requires locker.credentials.mode=podIdentity,
an empty (or https://storage.googleapis.com) endpoint and
worker.lockerInit.enabled=false. The services refuse HMAC keys on GCS and the S3
client against storage.googleapis.com, so the charts refuse both. gcs also arms
the services' GCS data-path readiness check: worker.extraEnv and
alleyoop.extraEnv must carry CLOUD_SQL_CONNECTION_NAME, REDIS_HOST, REDIS_PORT,
REDIS_AUTH_ENABLED=false, REDIS_TRANSIT_ENCRYPTION=SERVER_AUTHENTICATION,
REDIS_TLS_CA_PEM (public CA bundle), PUBSUB_TOPIC and PUBSUB_SUBSCRIPTION, or the
render fails.

- Default: `s3` (by profile: default `s3`, gcp-cloudsql `gcs`)
- Choices: `s3`; `gcs`: GKE Workload Identity; Cloud SQL
- Provided by: operator
- Values: `worker.locker.provider`, `alleyoop.locker.provider`, `worker.extraEnv`, `alleyoop.extraEnv`
- Env: `LOCKER_PROVIDER`, `PIPELINE_RAW_PROVIDER`, `CLOUD_SQL_CONNECTION_NAME`, `REDIS_HOST`, `REDIS_PORT`, `REDIS_AUTH_ENABLED`, `REDIS_TRANSIT_ENCRYPTION`, `REDIS_TLS_CA_PEM`, `PUBSUB_TOPIC`, `PUBSUB_SUBSCRIPTION`
- Verify: with gcs, the worker and Alleyoop /readyz return 200 and /datapathz reports ok
- Sources: [`charts/sessions-pipeline-worker/values.yaml:64`](../charts/sessions-pipeline-worker/values.yaml#L64), [`charts/sessions-pipeline-worker/templates/_env.tpl:63`](../charts/sessions-pipeline-worker/templates/_env.tpl#L63), [`charts/sessions-pipeline-worker/templates/_env.tpl:108`](../charts/sessions-pipeline-worker/templates/_env.tpl#L108), [`charts/session-ingest-api/templates/_env.tpl:95`](../charts/session-ingest-api/templates/_env.tpl#L95)

#### opt.sessions-pipeline.services-image

<a id="opt-sessions-pipeline-services-image"></a>

**Services image registry** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

ghcr (the chart default, private: needs req.secret.image-pull), the immutable
ECR digest of the same build for hosted EKS (node role pulls, no pull Secret),
or the AWS native profile's mandatory private release overlay. That overlay
must set one approved digest on all five services workloads. Overriding a
repository or tag requires clearing or matching the digest. See the compatibility
matrix for the pinned digests.

- Default: `ghcr` (by profile: default `ghcr`, aws-cnpg `ecr`, aws-rds-native `release-overlay`)
- Choices: `ghcr`; `ecr`: AWS path only; `release-overlay`: AWS RDS native profile; one qualified digest across worker
- Provided by: chart
- Values: `worker.image.repository`, `worker.image.digest`, `worker.image.tag`, `alleyoop.image.repository`, `alleyoop.image.digest`, `alleyoop.image.tag`, `global.imageRegistry`
- Verify: ci/sessions-pipeline-profiles/matrix.sh asserts every row renders only the pinned images
- Sources: [`charts/sessions-pipeline-worker/values.yaml:22`](../charts/sessions-pipeline-worker/values.yaml#L22), [`charts/sessions-pipeline/ci/aws-cnpg-values.yaml:15`](../charts/sessions-pipeline/ci/aws-cnpg-values.yaml#L15), [`ci/sessions-pipeline-profiles/matrix.sh:70`](../ci/sessions-pipeline-profiles/matrix.sh#L70)

#### opt.sessions-pipeline.otel

<a id="opt-sessions-pipeline-otel"></a>

**OpenTelemetry export** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

Off by default. Set global.otel.endpoint to your OTLP/HTTP backend, or enable the
bundled collector (otel.enabled) with endpoint http://otel-collector:4318; its
default exporter drops telemetry.

- Default: `""` (by profile: default `""`, aws-cnpg `http://otel-collector:4318`)
- Choices: `""`: no export; `<your OTLP endpoint>`; `http://otel-collector:4318`: with otel.enabled
- Provided by: operator
- Values: `global.otel.endpoint`, `otel.enabled`, `otel.config.*`
- Env: `OTEL_EXPORTER_OTLP_ENDPOINT`
- Verify: OTEL_EXPORTER_OTLP_ENDPOINT in the pods equals global.otel.endpoint
- Sources: [`charts/sessions-pipeline/values.yaml:165`](../charts/sessions-pipeline/values.yaml#L165), [`charts/sessions-pipeline-worker/templates/_env.tpl:106`](../charts/sessions-pipeline-worker/templates/_env.tpl#L106)

#### opt.sessions-pipeline.deployment-identity

<a id="opt-sessions-pipeline-deployment-identity"></a>

**Workspace, deployment and environment labels** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

WORKSPACE_ID, DEPLOYMENT, DEPLOYMENT_ID (default <namespace>/<release>) and ENVIRONMENT stamped on every record.

- Default: `workspaceId=default`, `deployment=selfhost`, `environment=production`
- Choices: `<any>`
- Provided by: operator
- Values: `worker.tenant.workspaceId`, `worker.deployment.name`, `worker.deployment.id`, `worker.environment`, `alleyoop.tenant.workspaceId`, `alleyoop.deployment.name`, `alleyoop.deployment.id`, `alleyoop.environment`
- Env: `WORKSPACE_ID`, `DEPLOYMENT`, `DEPLOYMENT_ID`, `ENVIRONMENT`
- Verify: env of any worker pod
- Sources: [`charts/sessions-pipeline/values.yaml:49`](../charts/sessions-pipeline/values.yaml#L49), [`charts/sessions-pipeline-worker/templates/_env.tpl:95`](../charts/sessions-pipeline-worker/templates/_env.tpl#L95)

#### opt.sessions-pipeline.worker-health

<a id="opt-sessions-pipeline-worker-health"></a>

**Stage worker health server** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

/readyz and /healthz on workerHealth.port for every stage worker; a slow migration never restarts a worker.

- Default: `true`
- Choices: `true`; `false`
- Provided by: chart
- Values: `worker.workerHealth.*`
- Env: `WORKER_HEALTH_PORT`, `WORKER_UNHEALTHY_AFTER_FAILURES`, `WORKER_MAX_TICK_AGE_MS`
- Verify: kubectl get pods shows the workers Ready after migrate
- Sources: [`charts/sessions-pipeline-worker/values.yaml:180`](../charts/sessions-pipeline-worker/values.yaml#L180), [`charts/sessions-pipeline-worker/templates/deployments.yaml:44`](../charts/sessions-pipeline-worker/templates/deployments.yaml#L44)

#### opt.sessions-pipeline.bob-costas-model

<a id="opt-sessions-pipeline-bob-costas-model"></a>

**Bob Costas summariser model (BOB_COSTAS_MODEL)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

off (the extractive summariser) is the only value wired at 7d7229b; any other value fails at start.

- Default: `off`
- Choices: `off`
- Provided by: chart
- Values: `worker.components.bob-costas.env`
- Env: `BOB_COSTAS_MODEL`
- Verify: env of the bob-costas pod
- Sources: [`charts/sessions-pipeline-worker/values.yaml:223`](../charts/sessions-pipeline-worker/values.yaml#L223), `sessions-pipeline@7d7229b:src/bob-costas/summarizer.ts:104`

#### opt.sessions-pipeline.search-backend

<a id="opt-sessions-pipeline-search-backend"></a>

**Transcript search backend (search.backend)** · **planned** · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

Operator decision 2026-11-01: postgres (PostgreSQL 17 + pg_trgm, the default and
what every profile does today) or self-managed ClickHouse OSS as a derived index
for high-volume installs, with Postgres kept as the source of truth and the
single-switch rollback. No chart reads a search.* value yet; the proposed values
and Secret boundary (search.clickhouse.mode external|operator, endpoint,
database, table, user, existingSecret/secretKeys) are in the reference
architecture.

- Default: `postgres`
- Choices: `postgres`: behavior shipped (pg_trgm on HoopDb); the value itself is planned; `clickhouse` (**planned**)
- Provided by: operator
- Values: `search.backend`, `search.clickhouse.*`
- Verify: not applicable until charted
- Sources: [`docs/self-hosted-reference-architecture.md:68`](../docs/self-hosted-reference-architecture.md#L68), [`docs/self-hosted-reference-architecture.md:105`](../docs/self-hosted-reference-architecture.md#L105)

#### opt.sessions-pipeline.session-briefs

<a id="opt-sessions-pipeline-session-briefs"></a>

**Native model session briefs** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

Default-off managed SERVICE=session-brief canonical-input worker. Selecting
components.session-brief requires nativeBrief.enabled and an explicit
immutable compatible image. Sibling workers and migrations use the same
image or remain disabled. An explicit workspace allowlist, bare writer root,
model key Secret and SHA-pinned public PostgreSQL CA are required. Init
admits only verify-full with the mounted CA and seals verified bytes for
the worker; repeat init accepts only the same regular file. Batch and daily
caps are configurable (defaults 1/20/3), sweep defaults 60 seconds. Optional
egress selects only this component on TCP443; peers are operator-selected
because standard NetworkPolicy has no FQDN enforcement. No profile enables
it automatically; runtime images and native summary reads need separate
qualification. This is not Bob Costas encrypted-summary output. Optional
nativeBrief.baseUrl points the worker at an OpenAI-compatible endpoint
(OPENAI_BASE_URL): https, or http only to <svc>.<ns>.svc or
<svc>.<ns>.svc.cluster.local with nativeBrief.allowInClusterHttp or the
top-level allowInClusterHttp. nativeBrief.allowInClusterHttp renders
ALLOW_IN_CLUSTER_HTTP=true on this container only. The egress peers must
match that endpoint, and a gateway pod not listening on 443 also needs an
operator-managed egress policy.

- Default: `false`
- Choices: `false`; `true`: Requires a separately qualified backend image and model credential.
- Provided by: operator
- Values: `worker.components.session-brief.enabled`, `worker.components.session-brief.replicas`, `worker.nativeBrief.enabled`, `worker.nativeBrief.image.*`, `worker.nativeBrief.workspaceIds`, `worker.nativeBrief.model`, `worker.nativeBrief.baseUrl`, `worker.nativeBrief.allowInClusterHttp`, `worker.nativeBrief.keyPrefix`, `worker.nativeBrief.sweepSeconds`, `worker.nativeBrief.batch`, `worker.nativeBrief.globalDailyCap`, `worker.nativeBrief.sessionDailyCap`, `worker.nativeBrief.openaiEgress.*`, `worker.postgresCa.sha256`
- Env: `SESSION_BRIEF_ENABLED`, `SESSION_BRIEF_CANONICAL_INPUT`, `SESSION_BRIEF_WORKSPACE_IDS`, `SESSION_BRIEF_MODEL`, `SESSION_BRIEF_SWEEP_SECONDS`, `SESSION_BRIEF_BATCH`, `SESSION_BRIEF_GLOBAL_DAILY_CAP`, `SESSION_BRIEF_SESSION_DAILY_CAP`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `OPENAI_BASE_URL`
- Verify: Render with explicit native values; verify pinned CA init and worker health, then a recorded summary with actual model provenance. Source render is not model-call proof.
- Sources: [`charts/sessions-pipeline-worker/templates/_native-brief.tpl:1`](../charts/sessions-pipeline-worker/templates/_native-brief.tpl#L1), [`charts/sessions-pipeline-worker/templates/deployments.yaml:35`](../charts/sessions-pipeline-worker/templates/deployments.yaml#L35)

#### opt.sessions-pipeline.reader-max-ruleset

<a id="opt-sessions-pipeline-reader-max-ruleset"></a>

**Sessions reader ruleset ceiling** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

Managed READER_MAX_RULESET for the native canonical consumer, native brief
input, standalone read API, alleyoop manifest admission and native ingest-edge
engine initializer. Each value defaults to null: no env binding is emitted,
preserving legacy reads and courier admission exactly. Explicit 8, 9 or 10
opts into strict marker family/version and per-chunk metadata checks.
The unconfigured bindgen writer pin gate separately retains a ceiling of 8.
Setting an explicit policy requires an exact qualified image containing
relayhistory-pipeline #489 after compatibility fixes and exact-head review.
It does not enable a workload, Rust/WASM or writer output. Stage reader-first
compatibility and verify retained objects before writer activation; keep the
required explicit ceiling while newer objects remain during rollback.

- Default: (no default) (by profile: default (no default), aws-rds-native (no default))
- Choices: (no default): Omit the binding and preserve legacy reads; writer pin gate defaults to 8.; `8`: Opt into strict checks through version 8 with a qualified image.; `9`: Requires a qualified #489-compatible image on that reader.; `10`: Requires a qualified #489-compatible image on that reader.
- Provided by: operator
- Values: `nativeConsumer.readerMaxRuleset`, `worker.nativeBrief.readerMaxRuleset`, `sessionReadApi.readerMaxRuleset`, `alleyoop.readerMaxRuleset`, `ingestEdge.readerMaxRuleset`
- Env: `READER_MAX_RULESET`
- Verify: Default renders must omit READER_MAX_RULESET; explicit policies render exactly one binding with the requested decimal token; prove reads of representative objects before raising writer output. Rendering alone is not runtime compatibility proof.
- Sources: [`charts/sessions-pipeline/templates/_native-consumer.tpl:1`](../charts/sessions-pipeline/templates/_native-consumer.tpl#L1), [`charts/sessions-pipeline-worker/templates/_native-brief.tpl:1`](../charts/sessions-pipeline-worker/templates/_native-brief.tpl#L1), [`charts/session-read-api/templates/deployment.yaml:1`](../charts/session-read-api/templates/deployment.yaml#L1), [`charts/session-ingest-api/templates/deployment.yaml:1`](../charts/session-ingest-api/templates/deployment.yaml#L1), [`charts/sessions-pipeline/templates/ingest-edge.yaml:1`](../charts/sessions-pipeline/templates/ingest-edge.yaml#L1)

#### opt.sessions-pipeline.scrub-engine

<a id="opt-sessions-pipeline-scrub-engine"></a>

**Shared Sessions scrub engine rollout contract** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

One strict selection shared by every self-host workload and Job that runs
the services image. The default is fully omitted and preserves legacy
engine and reader behavior. Reader-first sets only READER_MAX_RULESET=10.
The explicit phase-2 overlay sets SCRUB_ENGINE=wasm-bindgen,
SCRUB_ENGINE_REQUIRED=wasm-bindgen and READER_MAX_RULESET=10. It requires
the approved alpha.5 services image and must follow a Ready reader-first
upgrade on populated databases.

- Default: (no default) (by profile: default (no default))
- Choices: (no default): Emit no bindings and preserve the legacy engine and reader ceiling.; `reader-first`: Emit only READER_MAX_RULESET=10 with the qualified image.; `wasm-bindgen`: Emit the exact required engine and ceiling triple after reader-first readiness.
- Provided by: operator
- Values: `global.scrubEngine.engine`, `global.scrubEngine.required`, `global.scrubEngine.readerMaxRuleset`
- Env: `SCRUB_ENGINE`, `SCRUB_ENGINE_REQUIRED`, `READER_MAX_RULESET`
- Verify: Render every services-image workload and bootstrap Job in both phases; prove retained-object reads before the cutover and prove phase-2 Job names change when their immutable pod template changes.
- Sources: [`charts/sessions-pipeline/templates/_scrub-engine.tpl:1`](../charts/sessions-pipeline/templates/_scrub-engine.tpl#L1), [`charts/sessions-pipeline/values.yaml:1`](../charts/sessions-pipeline/values.yaml#L1), [`charts/agent-relay/values-scrub-wasm-bindgen.yaml:1`](../charts/agent-relay/values-scrub-wasm-bindgen.yaml#L1), [`ci/sessions-pipeline-scrub-engine/test_scrub_engine.py:1`](../ci/sessions-pipeline-scrub-engine/test_scrub_engine.py#L1)

#### opt.sessions-pipeline.brief-collector-analytics

<a id="opt-sessions-pipeline-brief-collector-analytics"></a>

**Native brief collector analytics adapter** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

Send installation-scoped brief outcomes to the private collector from
a qualified native brief image. Register component session-brief with
its own producer credential and select the matching deployment ID.
The optional collector CA applies only to the HTTPS collector request.
Use explicit collector pod peers and pod port when the chart manages
egress. For operator-managed policy, permit that same connection and
admit the labeled brief pod at the collector.

- Default: `false`
- Choices: `false`; `true`: Requires an image and collector that support session_brief.tick_completed.
- Provided by: operator
- Values: `worker.nativeBrief.analytics.*`
- Env: `ANALYTICS_SINK`, `ANALYTICS_DEPLOYMENT_ID`, `ANALYTICS_COLLECTOR_URL`, `ANALYTICS_COLLECTOR_TOKEN`, `ANALYTICS_COLLECTOR_CA_FILE`
- Secret: `<Native brief component-bound analytics producer Secret>` from `sessions-pipeline-worker:nativeBrief.analytics.existingSecret`; keys `token` from `sessions-pipeline-worker:nativeBrief.analytics.tokenKey`
- Verify: Check brief-only analytics credentials, separate CA paths and restricted egress. Verify a real session_brief.tick_completed in the private collector files and an unchanged model admission limit.
- Sources: [`charts/sessions-pipeline-worker/templates/_brief-analytics.tpl`](../charts/sessions-pipeline-worker/templates/_brief-analytics.tpl), [`charts/sessions-pipeline-worker/templates/brief-analytics-networkpolicy.yaml`](../charts/sessions-pipeline-worker/templates/brief-analytics-networkpolicy.yaml)

#### opt.relay-control.collector-analytics

<a id="opt-relay-control-collector-analytics"></a>

**Control collector analytics adapter** · shipped · chart `relay-control` · profiles relay-control, agent-relay

Default-off Control business analytics to a private collector. Requires
a compatible qualified application image, existing component-bound
registration and dedicated producer Secret. Optional public CA trust is
scoped to this transport; Postgres and system roots are unchanged.
Only the API container receives the token file and Pod producer label.
No hosted PostHog configuration is accepted through this adapter.

- Default: `false`
- Choices: `false`; `true`: Requires a component-bound collector registration and verified TLS.
- Provided by: operator
- Values: `analytics.*`
- Env: `SELFHOST_ANALYTICS_DESTINATION`, `SELFHOST_ANALYTICS_PROFILE`, `SELFHOST_ANALYTICS_DEPLOYMENT_ID`, `SELFHOST_ANALYTICS_COLLECTOR_URL`, `SELFHOST_ANALYTICS_COLLECTOR_TOKEN_FILE`, `SELFHOST_ANALYTICS_COLLECTOR_CA_FILE`
- Secret: `<Control component-bound analytics producer Secret>` from `relay-control:analytics.existingSecret`; keys `token` from `relay-control:analytics.tokenKey`
- Verify: Check the rendered API-only Secret/CA mounts and unchanged migration Job identity, then verify real Control events in private committed collector files and negative authentication separately.
- Sources: [`charts/relay-control/templates/_runtime-adapters.tpl`](../charts/relay-control/templates/_runtime-adapters.tpl), [`charts/relay-control/ANALYTICS.md`](../charts/relay-control/ANALYTICS.md)

#### opt.relay-control.external-introspection-secret

<a id="opt-relay-control-external-introspection-secret"></a>

**Separate Control introspection credential Secret** · shipped · chart `relay-control` · profiles relay-control, agent-relay

Mount an existing introspection credential into the API without copying
it into the main application Secret. Mutually exclusive with
secretKeys.introspectSecret; neither migration nor init containers get
the credential. The existing internal-route ingress shield is preserved.

- Default: `disabled`
- Choices: `disabled`; `enabled`
- Provided by: operator
- Values: `introspection.existingSecret`, `introspection.key`
- Env: `RELAYCONTROL_INTROSPECT_SECRET_FILE`
- Secret: `<Control introspection Secret>` from `relay-control:introspection.existingSecret`; keys `introspect-secret` from `relay-control:introspection.key`
- Verify: Render the external reference and ensure the API alone mounts it, the migration Job identity is unchanged, and public /internal traffic reaches only the selectorless deny Service.
- Sources: [`charts/relay-control/templates/_runtime-adapters.tpl`](../charts/relay-control/templates/_runtime-adapters.tpl), [`charts/relay-control/templates/ingress.yaml`](../charts/relay-control/templates/ingress.yaml)

#### opt.relay-control.encryption-rotation

<a id="opt-relay-control-encryption-rotation"></a>

**Previous encryption key during a key rotation** · shipped · chart `relay-control` · profiles relay-control

During a rotation the API decrypts with the previous key and encrypts
with the active one. encryption.previousKeyId and
secretKeys.previousEncryptionKey are set together or not at all (the API
refuses one without the other); the id must differ from encryption.keyId.

- Default: `none`
- Choices: `none`; `previous key`
- Provided by: operator
- Values: `encryption.previousKeyId`, `secretKeys.previousEncryptionKey`
- Env: `SELFHOST_ENCRYPTION_PREVIOUS_KEY_ID`, `SELFHOST_ENCRYPTION_PREVIOUS_KEY_FILE`
- Secret: `<existingSecret>` from `existingSecret`; keys `<operator-chosen, no default>` from `secretKeys.previousEncryptionKey` (optional: only during a key rotation, with encryption.previousKeyId)
- Verify: helm template fails when only one of encryption.previousKeyId and secretKeys.previousEncryptionKey is set
- Sources: [`charts/relay-control/values.yaml`](../charts/relay-control/values.yaml), [`charts/relay-control/templates/_helpers.tpl`](../charts/relay-control/templates/_helpers.tpl)

#### opt.relay-control.internal-token

<a id="opt-relay-control-internal-token"></a>

**Internal service token for /internal/v1** · shipped · chart `relay-control` · profiles relay-control

secretKeys.internalToken mounts SELFHOST_INTERNAL_TOKEN_FILE (at least 32
bytes). It enables /internal/v1: flows reads workspace env vars and
integration tokens through it, and in-cluster agents file telemetry
issue reports with it. Unset disables /internal/v1. The agent-relay GKE
ingress denies /internal on the api host.

- Default: `disabled`
- Choices: `disabled`; `enabled`
- Provided by: operator
- Values: `secretKeys.internalToken`
- Env: `SELFHOST_INTERNAL_TOKEN_FILE`
- Secret: `<existingSecret>` from `existingSecret`; keys `<operator-chosen, no default>` from `secretKeys.internalToken` (optional: enables /internal/v1 (flows env delivery, telemetry issue reports))
- Verify: kubectl exec deploy/<release>-relay-control (or the fullnameOverride, relay-control in the agent-relay GCP profiles) -- sh -c 'test "$(tr -d "\r\n" < "$SELFHOST_INTERNAL_TOKEN_FILE" \| wc -c)" -ge 32' (expanded inside the pod; at least 32 bytes); curl https://<api host>/internal/v1/... is refused at the edge
- Sources: [`charts/relay-control/values.yaml`](../charts/relay-control/values.yaml), [`charts/relay-control/templates/_helpers.tpl`](../charts/relay-control/templates/_helpers.tpl), [`charts/agent-relay/templates/gke-ingress.yaml`](../charts/agent-relay/templates/gke-ingress.yaml)

#### opt.relay-control.dashboard-url

<a id="opt-relay-control-dashboard-url"></a>

**Dashboard URL for OAuth callbacks and flow run links** · shipped · chart `relay-control` · profiles relay-control

dashboardUrl (SELFHOST_DASHBOARD_URL) is where OAuth callback pages link
back and where mirrored flow runs build their runUrl. Unset, the API uses
publicUrl + "/", which is wrong when the dashboard has its own host (the
GKE profiles serve it on the root host).

- Default: `publicUrl + "/"`
- Choices: `publicUrl + "/"`; `dashboard origin`
- Provided by: operator
- Values: `dashboardUrl`
- Env: `SELFHOST_DASHBOARD_URL`
- Verify: helm template renders SELFHOST_DASHBOARD_URL only when dashboardUrl is set and fails on credentials, query or fragment
- Sources: [`charts/relay-control/values.yaml`](../charts/relay-control/values.yaml), [`charts/relay-control/templates/_helpers.tpl`](../charts/relay-control/templates/_helpers.tpl)

#### opt.relay-control.bootstrap

<a id="opt-relay-control-bootstrap"></a>

**First-boot organization, owner and default workspace** · shipped · chart `relay-control` · profiles relay-control

bootstrap.orgName and bootstrap.adminEmail (set together) make the API
create the installation's organization on its first start, with the
admin email as owner, and a default workspace (bootstrap.workspaceName,
default Default) bound to a new Relaycast workspace created through
Relaycast's POST /internal/workspaces with secretKeys.relaycastInternalSecret
(the same key relaycast.secretKeys.internalSecret names; on durable
actors the workspace key is ar_ws_). Idempotent: an existing
organization and workspace are kept, and a newly configured admin email
is made an owner once. Requires dashboardUrl outside single-host mode and
a selfhost-api image from relaycontrol #13 or later. Without it the
organization is created by hand with the bootstrap token.

- Default: `disabled (manual bootstrap with the bootstrap token)`
- Choices: `disabled`; `enabled`
- Provided by: operator
- Values: `bootstrap.*`, `secretKeys.relaycastInternalSecret`
- Env: `SELFHOST_BOOTSTRAP_ORG_NAME`, `SELFHOST_BOOTSTRAP_ADMIN_EMAIL`, `SELFHOST_BOOTSTRAP_ADMIN_NAME`, `SELFHOST_BOOTSTRAP_WORKSPACE_NAME`, `RELAYCAST_INTERNAL_SECRET_FILE`
- Secret: `<existingSecret>` from `existingSecret`; keys `<operator-chosen, e.g. relaycast-internal-secret>` from `secretKeys.relaycastInternalSecret` (optional: required with bootstrap.orgName; equal to Relaycast's internal secret)
- Verify: kubectl logs deploy/<release>-relay-control shows "bootstrap: organization created" and "bootstrap: default workspace created" once; GET /api/v1/organizations with the bootstrap token lists the organization and its workspace (bootstrap.workspaceName, Default when empty)
- Sources: [`charts/relay-control/values.yaml`](../charts/relay-control/values.yaml), [`charts/relay-control/templates/_helpers.tpl`](../charts/relay-control/templates/_helpers.tpl)

#### opt.relay-control.sign-in

<a id="opt-relay-control-sign-in"></a>

**Sign-in methods (OIDC, email links), invites and auto-join** · shipped · chart `relay-control` · profiles relay-control

auth.oidc (issuer, clientId, secretKeys.oidcClientSecret; optional
allowedDomains, displayName, scopes, redirectUrl) enables OpenID Connect
sign-in at <dashboard>/login (authorization code + PKCE; Google
Workspace, Okta, Microsoft Entra ID, Keycloak). Register
<dashboard origin>/login/oidc/callback with the IdP.
auth.microsoft (clientId, secretKeys.microsoftClientSecret; optional
tenant common|consumers|organizations|<tenant id>, redirectUrl) adds
"Continue with Microsoft" beside OIDC for Outlook.com, Hotmail, Live and
Entra ID accounts. Register <dashboard origin>/login/microsoft/callback
on the app registration; tenant accounts need the xms_edov optional
claim.
auth.emailLink.enabled adds single-use email sign-in links (needs smtp).
auth.password.enabled adds email and password sign-in
(SELFHOST_SIGNIN_METHODS includes password; SMTP optional, without it
only registration and emailed resets are off) and sets
SELFHOST_TRUSTED_PROXIES from auth.trustedProxies (0-99; null means 1
with password sign-in, the chart ingress as the single proxy with
direct pod/Service access restricted). secretKeys.setupKey names an
operator-generated one-time first-admin setup key
(SELFHOST_SETUP_KEY_FILE, openssl rand -hex 32, 24 h, single use; API
pod only, never the migration Job; needs auth.password.enabled and a
relay-control image from source bd1c9a03 or later); the bootstrap
bearer re-mints it with POST /api/v1/installation/setup-key.
auth.autoJoinDomains lets verified emails in those domains join as member
without an invite; auth.inviteTtlHours sets the invite link lifetime
(default 168). Owners and admins invite from Settings > Members. Without
any method only the operator break-glass (bootstrap token approving a
/login device code) works. auth.oidc.allowHttpIssuer is for tests only.

- Default: `none (operator break-glass only)`
- Choices: `none`; `oidc`; `microsoft`; `email links`; `oidc and email links`; `password`
- Provided by: operator
- Values: `auth.*`, `secretKeys.oidcClientSecret`, `secretKeys.microsoftClientSecret`, `secretKeys.setupKey`
- Env: `SELFHOST_OIDC_ISSUER`, `SELFHOST_OIDC_CLIENT_ID`, `SELFHOST_OIDC_CLIENT_SECRET_FILE`, `SELFHOST_OIDC_ALLOWED_DOMAINS`, `SELFHOST_OIDC_DISPLAY_NAME`, `SELFHOST_OIDC_SCOPES`, `SELFHOST_OIDC_REDIRECT_URL`, `SELFHOST_OIDC_ALLOW_HTTP_ISSUER`, `SELFHOST_MICROSOFT_CLIENT_ID`, `SELFHOST_MICROSOFT_CLIENT_SECRET_FILE`, `SELFHOST_MICROSOFT_TENANT`, `SELFHOST_MICROSOFT_REDIRECT_URL`, `SELFHOST_EMAIL_LOGIN`, `SELFHOST_SIGNIN_METHODS`, `SELFHOST_TRUSTED_PROXIES`, `SELFHOST_SETUP_KEY_FILE`, `SELFHOST_AUTO_JOIN_DOMAINS`, `SELFHOST_INVITE_TTL_HOURS`
- Secret: `<existingSecret>` from `existingSecret`; keys `<operator-chosen, e.g. oidc-client-secret>` from `secretKeys.oidcClientSecret` (optional: required with auth.oidc.issuer); `<operator-chosen, e.g. microsoft-client-secret>` from `secretKeys.microsoftClientSecret` (optional: required with auth.microsoft.clientId); `<operator-generated, e.g. selfhost-setup-key>` from `secretKeys.setupKey` (optional: optional with auth.password.enabled; openssl rand -hex 32, never a chart default)
- Verify: GET https://<root host>/login shows "Continue with <displayName>"; the admin email signs in and GET /cloud/api/v1/auth/whoami reports role owner
- Sources: [`charts/relay-control/values.yaml`](../charts/relay-control/values.yaml), [`charts/relay-control/templates/_helpers.tpl`](../charts/relay-control/templates/_helpers.tpl)

#### opt.relay-control.smtp

<a id="opt-relay-control-smtp"></a>

**SMTP for invite emails and sign-in links** · shipped · chart `relay-control` · profiles relay-control

smtp.host (+ port, security starttls|tls|none, from, and username with
secretKeys.smtpPassword) lets the API email invites and, with
auth.emailLink.enabled, sign-in links. Without it invites still work:
owners copy the single-use link from Settings > Members.

- Default: `none (copy invite links)`
- Choices: `none`; `smtp`
- Provided by: operator
- Values: `smtp.*`, `secretKeys.smtpPassword`
- Env: `SELFHOST_SMTP_HOST`, `SELFHOST_SMTP_PORT`, `SELFHOST_SMTP_SECURITY`, `SELFHOST_SMTP_USERNAME`, `SELFHOST_SMTP_PASSWORD_FILE`, `SELFHOST_EMAIL_FROM`
- Secret: `<existingSecret>` from `existingSecret`; keys `<operator-chosen, e.g. smtp-password>` from `secretKeys.smtpPassword` (optional: required with smtp.username)
- Verify: an invite created in Settings > Members reports "Invitation emailed to <email>" (emailDelivery sent)
- Sources: [`charts/relay-control/values.yaml`](../charts/relay-control/values.yaml), [`charts/relay-control/templates/_helpers.tpl`](../charts/relay-control/templates/_helpers.tpl)

#### opt.relay-control.password-pepper

<a id="opt-relay-control-password-pepper"></a>

**Password pepper for password sign-in** · shipped · chart `relay-control` · profiles relay-control

secretKeys.passwordPepper names a Secret key holding one
v<version>:<secret> line per pepper, each secret at least 32 bytes. An
init container copies it into a memory-backed emptyDir at mode 0600,
because the API refuses a file it does not own or that other users can
read. Without it, passwords are hashed with no pepper.

- Default: `none (no pepper)`
- Choices: `none`; `pepper`
- Provided by: operator
- Values: `secretKeys.passwordPepper`
- Env: `SELFHOST_PASSWORD_PEPPER_FILE`
- Secret: `<existingSecret>` from `existingSecret`; keys `<operator-chosen, e.g. password-pepper>` from `secretKeys.passwordPepper` (optional: required with a pepper)
- Verify: the API starts with SELFHOST_PASSWORD_PEPPER_FILE set, and /readyz answers 200
- Sources: [`charts/relay-control/values.yaml`](../charts/relay-control/values.yaml), [`charts/relay-control/templates/deployment.yaml`](../charts/relay-control/templates/deployment.yaml)

#### opt.relay-control.integrations

<a id="opt-relay-control-integrations"></a>

**Integration OAuth apps for just-in-time connects** · shipped · chart `relay-control` · profiles relay-control

integrations.<provider>.existingSecret supplies the customer's own OAuth
app for an integration (github, slack, linear, notion, ...): the client ID
(clientIdKey, default client-id) as SELFHOST_OAUTH_<PROVIDER>_CLIENT_ID and
the client secret (clientSecretKey, default client-secret) mounted as a
file (SELFHOST_OAUTH_<PROVIDER>_CLIENT_SECRET_FILE); optional scopes
override. Users connect just in time from the CLI, flow onboarding and
flow creation. Register <publicUrl>/api/v1/integrations/oauth/callback as
the callback URL in each provider app. A provider without an entry shows
users "Your administrator needs to configure the <Provider> app".
Env per provider (<PROVIDER> = id upper-cased, - as _):
SELFHOST_OAUTH_<PROVIDER>_CLIENT_ID, SELFHOST_OAUTH_<PROVIDER>_CLIENT_SECRET_FILE,
SELFHOST_OAUTH_<PROVIDER>_SCOPES. This needs a selfhost-api image with
operator OAuth apps (relaycontrol #12 or later).

- Default: `none (no integration can be connected until its app is configured)`
- Choices: `none`; `one entry per provider with existingSecret`
- Provided by: operator
- Values: `integrations`
- Secret: `<operator-chosen, integrations.<provider>.existingSecret>`; keys `client-id`; `client-secret`
- Verify: helm template renders the client ID from secretKeyRef and mounts only the client secret, and fails on a missing existingSecret, an inline clientId/clientSecret (unsupported field), equal key names, the migration credential key, or an invalid provider id
- Sources: [`charts/relay-control/values.yaml`](../charts/relay-control/values.yaml), [`charts/relay-control/templates/_helpers.tpl`](../charts/relay-control/templates/_helpers.tpl), [`charts/relay-control/templates/deployment.yaml`](../charts/relay-control/templates/deployment.yaml)

#### opt.relay-control.flows

<a id="opt-relay-control-flows"></a>

**Relayflows control-plane storage and worker queue** · shipped · chart `relay-control` · profiles relay-control

flows.storage selects where run artifacts live: postgres (inline, the
default) or gcs (flows.gcsBucket required, flows.gcsPrefix optional;
Workload Identity on the API service account, and egress to
storage.googleapis.com when allowAllEgress=false).
flows.workerRelaycastUrl is the Relaycast origin handed to workers.
flows.queuePingMs is the worker queue SSE keepalive (1000-120000 ms) and
must stay below every proxy timeout in front of the API.

- Default: `postgres`
- Choices: `postgres`; `gcs`
- Provided by: operator
- Values: `flows.*`
- Env: `SELFHOST_FLOWS_STORAGE`, `SELFHOST_FLOWS_GCS_BUCKET`, `SELFHOST_FLOWS_GCS_PREFIX`, `SELFHOST_FLOWS_WORKER_RELAYCAST_URL`, `SELFHOST_FLOWS_QUEUE_PING_MS`
- Verify: helm template fails for flows.storage=gcs without flows.gcsBucket, or flows.queuePingMs outside 1000-120000
- Sources: [`charts/relay-control/values.yaml`](../charts/relay-control/values.yaml), [`charts/relay-control/templates/_helpers.tpl`](../charts/relay-control/templates/_helpers.tpl)

#### opt.relay-control.telemetry

<a id="opt-relay-control-telemetry"></a>

**Self-host telemetry level and transport** · shipped · chart `relay-control` · profiles relay-control

telemetry.level (SELFHOST_TELEMETRY_LEVEL) is errors (the chart default:
scrubbed error metadata and health only, never content), full (adds
usage counts) or off (disabled). The level takes effect once the install
is registered: until telemetry.installId and
secretKeys.telemetryInstallKey (issued by Agent Relay) and, with
transport https, telemetry.endpoint are set, the chart renders off, so a
default install renders and sends nothing; setting only some of them
fails the render. transport file never sends
(air-gapped signed export). telemetry.probes and telemetry.deployment add
health probes and flat deployment-shape keys (scalar values only; the
chart-rendered keys cannot be overridden). A TCP 443 egress rule to
telemetry.egressTo is added only when networkPolicy.enabled=true,
allowAllEgress=false, the level is not off and the transport is https.

- Default: `errors`
- Choices: `errors`: default; scrubbed error metadata and health only, effective once the install is registered; `full`: adds usage counts; `off`: disabled
- Provided by: operator
- Values: `telemetry.*`, `secretKeys.telemetryInstallKey`
- Env: `SELFHOST_TELEMETRY_LEVEL`, `SELFHOST_TELEMETRY_TRANSPORT`, `SELFHOST_TELEMETRY_ENDPOINT`, `SELFHOST_TELEMETRY_INSTALL_ID`, `SELFHOST_TELEMETRY_INSTALL_KEY_FILE`, `SELFHOST_TELEMETRY_PROBES`, `SELFHOST_TELEMETRY_DEPLOYMENT`
- Secret: `<existingSecret>` from `existingSecret`; keys `<operator-chosen, no default>` from `secretKeys.telemetryInstallKey` (optional: required once the install is registered unless telemetry.level is off)
- Verify: the default render sets SELFHOST_TELEMETRY_LEVEL=off until installId, install key and (https) endpoint are set; helm template fails when only some of them are set; ci/agent-relay/render.sh checks both and that the egress rule renders only when telemetry is sent over https
- Sources: [`charts/relay-control/values.yaml`](../charts/relay-control/values.yaml), [`charts/relay-control/templates/_helpers.tpl`](../charts/relay-control/templates/_helpers.tpl), [`charts/relay-control/templates/networkpolicy.yaml`](../charts/relay-control/templates/networkpolicy.yaml)

#### opt.agent-relay.single-host

<a id="opt-agent-relay-single-host"></a>

**Single-host mode for the dashboard and the control API** · shipped · chart `agent-relay`, `relay-control`, `relay-webapp` · profiles agent-relay

global.singleHost.host (off when empty) puts the dashboard and the
self-host control API on one host: / to the dashboard and /cloud/api,
/login and /api to relay-control (flows workers and the integrations
OAuth callback use <publicUrl>/api/v1/...). relay-control.publicUrl
and relay-webapp.runtime.publicUrl are derived as https://<host>, and
relay-webapp.ingress.host as the bare <host>; each must be left empty
or equal its derived value. The GKE
Ingress then renders no api host and its ManagedCertificate drops it;
the api and cast BackendConfigs are unchanged. The leaf dashboard
Ingress (non-GKE edges) adds the /api route. Relaycast, Relay History,
Relayfile and durable-actors cannot run under a path prefix without app
changes, so they keep their own hosts and the chart fails when any of
their public URLs or leaf ingress hosts uses the single host. No service
on the single host needs a path rewrite, so the GCE Ingress is kept
rather than Gateway API.

- Default: `disabled`
- Choices: `disabled`: per-service hosts (gkeIngress.hosts.root/api/cast/history); `enabled`: global.singleHost.host plus gkeIngress.hosts.cast/history
- Provided by: operator
- Values: `global.singleHost.host`, `relay-control:global.singleHost.host`, `relay-control:publicUrl`, `relay-webapp:global.singleHost.host`, `relay-webapp:runtime.publicUrl`, `relay-webapp:ingress.host`
- Env: `SELFHOST_PUBLIC_URL`, `DASHBOARD_PUBLIC_URL`
- Verify: render has one rule for the single host (/cloud/api, /login, /api to relay-control, / to the dashboard), no api host, and SELFHOST_PUBLIC_URL = DASHBOARD_PUBLIC_URL = https://<host>
- Sources: [`charts/agent-relay/templates/gke-ingress.yaml`](../charts/agent-relay/templates/gke-ingress.yaml), [`charts/agent-relay/templates/_helpers.tpl`](../charts/agent-relay/templates/_helpers.tpl), [`charts/agent-relay/values-single-host-example.yaml`](../charts/agent-relay/values-single-host-example.yaml), [`charts/relay-webapp/templates/ingress.yaml`](../charts/relay-webapp/templates/ingress.yaml), [`ci/agent-relay/render.sh`](../ci/agent-relay/render.sh), [`ci/agent-relay/subdomain-golden.sh`](../ci/agent-relay/subdomain-golden.sh)

#### opt.relay-webapp.ingress

<a id="opt-relay-webapp-ingress"></a>

**Dashboard ingress and same-origin API proxy** · shipped · chart `relay-webapp` · profiles relay-webapp

The dashboard ingress routes /cloud/api to relay-control and / to the
dashboard. The GKE proof disables this leaf ingress and supplies the same
routes through its single umbrella Ingress.

- Default: `enabled`
- Choices: `enabled`; `disabled`
- Provided by: operator
- Values: `runtime.publicUrl`, `runtime.appPath`, `runtime.apiBasePath`, `runtime.loginPath`, `ingress.tls`, `imagePullSecrets`
- Env: `DASHBOARD_PUBLIC_URL`, `DASHBOARD_APP_PATH`, `DASHBOARD_API_BASE_PATH`, `DASHBOARD_LOGIN_PATH`, `DASHBOARD_SESSION_READ_API_ENABLED`
- Secret: `<ingress.tls[].secretName>`. kubernetes.io/tls
- Secret: `<imagePullSecrets[].name>`. optional registry pull Secret
- Verify: render contains the configured dashboard runtime environment and routes /cloud/api to relay-control
- Sources: [`charts/relay-webapp/templates/ingress.yaml`](../charts/relay-webapp/templates/ingress.yaml), [`ci/agent-relay/render.sh`](../ci/agent-relay/render.sh)

#### opt.relay-webapp.customer-profile

<a id="opt-relay-webapp-customer-profile"></a>

**Dashboard customer profile (enterprise branding)** · shipped · chart `relay-webapp` · profiles relay-webapp

customerProfile rebrands the dashboard without a new image: product
name and title, light and dark logos, favicon, accent and primary
button colors, a support link and the "Powered by Agent Relay" line.
The chart renders the map as JSON into DASHBOARD_CUSTOMER_PROFILE and
the image serves it in /runtime-config.js; the browser ignores invalid
fields. Empty (the default) keeps the Agent Relay look. Requires a
dashboard image built from relay-webapp #84 or later (its
/runtime-config.js has a customerProfile key); older images ignore it.

- Default: `none`
- Choices: `none`; `customer profile`
- Provided by: operator
- Values: `customerProfile`
- Env: `DASHBOARD_CUSTOMER_PROFILE`
- Verify: with customerProfile set, /runtime-config.js has customerProfile and the dashboard shows the product name and logo; without it, customerProfile is null
- Sources: [`charts/relay-webapp/templates/deployment.yaml`](../charts/relay-webapp/templates/deployment.yaml), [`charts/relay-webapp/README.md`](../charts/relay-webapp/README.md), [`charts/relay-webapp/ci/branding.profile.yaml`](../charts/relay-webapp/ci/branding.profile.yaml)

#### opt.relay-webapp.branding-logo

<a id="opt-relay-webapp-branding-logo"></a>

**Hosted customer logo (sign-in page co-branding)** · shipped · chart `relay-webapp` · profiles relay-webapp

global.branding.logo hosts one customer logo on the dashboard origin,
with no extra web server or ingress route: relay-webapp mounts it
read-only at /usr/share/nginx/html/brand and serves it at
<dashboard origin>/brand/<file>. Set svg (inline, at most 256 KiB,
served as logo.svg; script, event handlers, javascript: URLs and
foreignObject, character references and DTDs are refused) or
existingConfigMap and key (a ConfigMap the operator creates; .png only,
since its content is not checked). relay-control then sets
SELFHOST_LOGIN_LOGO_URL to that https URL (the dashboard origin is
https://<global.singleHost.host> or dashboardUrl's) unless
login.logoUrl overrides it, and login.orgName sets
SELFHOST_LOGIN_ORG_NAME (Control's default is bootstrap.orgName; it
publishes the name only while a logo is set). Images from relay-webapp
#132 serve /brand/ with a script-free sandbox CSP, nosniff and a
five-minute cache and 404 a missing file; older images serve it through
the app route (nosniff, no CSP), so the inline SVG checks matter there.
Needs a relay-control image with the co-branded sign-in page
(relaycontrol 7b57625 or later).

- Default: `none (no hosted logo)`
- Choices: `none`; `inline SVG`; `existing ConfigMap (PNG)`
- Provided by: operator
- Values: `global.branding.logo.*`
- Verify: GET <dashboard>/brand/<file> returns the logo
- Sources: [`charts/relay-webapp/templates/brand-configmap.yaml`](../charts/relay-webapp/templates/brand-configmap.yaml), [`charts/relay-webapp/templates/deployment.yaml`](../charts/relay-webapp/templates/deployment.yaml), [`scripts/ci/charts.sh`](../scripts/ci/charts.sh)

#### opt.relay-control.login-cobrand

<a id="opt-relay-control-login-cobrand"></a>

**Sign-in page logo and organization name** · shipped · chart `relay-control` · profiles relay-control

SELFHOST_LOGIN_LOGO_URL (an absolute https URL) puts a customer logo
beside the Agent Relay lockup on the sign-in pages, and
SELFHOST_LOGIN_ORG_NAME the name next to it (Control's default is
bootstrap.orgName; GET /api/v1/auth/login-config publishes the name
only while a logo is set). With global.branding.logo set (see
opt.relay-webapp.branding-logo) the chart derives the URL as
<dashboard origin>/brand/<file>; login.logoUrl overrides it with any
https URL, and login.orgName sets the name. Needs a relay-control image
from relaycontrol 7b57625 or later.

- Default: `none (no customer logo; login-config logo_url and org_name are null)`
- Choices: `none`; `hosted logo (global.branding.logo)`; `external https URL (login.logoUrl)`
- Provided by: operator
- Values: `login.*`, `global.branding.logo.*`
- Env: `SELFHOST_LOGIN_LOGO_URL`, `SELFHOST_LOGIN_ORG_NAME`
- Verify: GET /cloud/api/v1/auth/login-config returns the logo_url and org_name
- Sources: [`charts/relay-control/templates/_helpers.tpl`](../charts/relay-control/templates/_helpers.tpl), [`scripts/ci/charts.sh`](../scripts/ci/charts.sh)

#### opt.agent-relay.gke-ingress

<a id="opt-agent-relay-gke-ingress"></a>

**Single GKE ingress for the proof hosts** · shipped · chart `agent-relay` · profiles agent-relay

One GCE Ingress uses the reserved global address, one ManagedCertificate
for all four hosts and a FrontendConfig HTTPS redirect. Leaf ingresses
are disabled and all ClusterIP backends use standalone NEGs. /internal is
denied at the edge on the cast and api hosts. The api Service is bound
(cloud.google.com/backend-config) to a BackendConfig whose timeoutSec
(gkeIngress.backends.api.timeoutSec, at least 60, default 3600) keeps the
flows worker queue SSE stream open past GCE's 30s default. The
BackendConfig is named <gkeIngress.name>-api (the name truncated to 59
characters first); relay-control renders the annotation from
relay-control.service.backendConfig, which must equal that name (the
render fails with the expected name otherwise). The relaycast Service is
bound the same way to <gkeIngress.name>-cast (the name truncated to 58
characters; gkeIngress.backends.cast.timeoutSec, default 3600) through
relaycast.service.backendConfig, so Relaycast WebSockets stay open.

- Default: `disabled`
- Choices: `enabled`; `disabled`
- Provided by: chart
- Values: `gkeIngress.enabled`, `gkeIngress.staticIpName`, `gkeIngress.managedCertificateName`, `gkeIngress.frontendConfigName`, `gkeIngress.hosts.*`, `gkeIngress.backends.*`, `relayauth.jwksIngress.enabled`
- Verify: render contains exactly one Ingress, the four expected hosts, ManagedCertificate, FrontendConfig, NEG annotations, the api BackendConfig and the /internal edge-deny on the api host
- Sources: [`charts/agent-relay/templates/gke-ingress.yaml`](../charts/agent-relay/templates/gke-ingress.yaml), [`charts/agent-relay/values-gcp-proof.yaml`](../charts/agent-relay/values-gcp-proof.yaml), [`ci/agent-relay/render.sh`](../ci/agent-relay/render.sh)

#### opt.agent-relay.relayflows

<a id="opt-agent-relay-relayflows"></a>

**Optional Relayflows component in the suite** · shipped · chart `agent-relay` · profiles agent-relay

components.relayflows adds the relayflows subchart to the agent-relay
suite; relayflows.* values pass through to it unchanged. Off by default.
standalone mode runs a flow Job/CronJob entirely in-cluster today.
cloudWorker mode enrolls against worker.cloudUrl and is blocked until
the self-host API implements the /api/v1/workers/* enroll, queue and
assignment endpoints. See docs/self-hosted-relayflows.md.

- Default: `disabled`
- Choices: `enabled`; `disabled`
- Provided by: operator
- Values: `components.relayflows`, `relayflows.*`
- Verify: the proof render emits no relayflows manifest while disabled; enabling renders only relayflows resources
- Sources: [`charts/agent-relay/Chart.yaml:41`](../charts/agent-relay/Chart.yaml#L41), [`charts/agent-relay/values.yaml:11`](../charts/agent-relay/values.yaml#L11), [`ci/agent-relay/render.sh:12`](../ci/agent-relay/render.sh#L12), [`docs/self-hosted-relayflows.md`](../docs/self-hosted-relayflows.md)

#### opt.stack.relaycast

<a id="opt-stack-relaycast"></a>

**Install the Relaycast core** · shipped · chart `relaycast` · profiles relaycast

Relaycast is the required core of the self-hosted product; add-ons consume it and it never depends on them.

- Default: `installed`
- Choices: `installed`
- Provided by: operator
- Verify: helm status relaycast; curl <baseUrl>/health
- Sources: [`docs/self-hosted-reference-architecture.md:11`](../docs/self-hosted-reference-architecture.md#L11), [`README.md:71`](../README.md#L71)

#### opt.relaycast.service-backend-config

<a id="opt-relaycast-service-backend-config"></a>

**GKE BackendConfig binding for the Relaycast Service** · shipped · chart `relaycast` · profiles relaycast

service.backendConfig renders the Service annotation
cloud.google.com/backend-config ({"default": "<name>"}); empty renders
none. The name must be a DNS-1123 subdomain (at most 253 characters) and
cannot be combined with a hand-written annotation. Behind the agent-relay
GKE ingress it must equal <gkeIngress.name>-cast, the BackendConfig whose
timeoutSec (gkeIngress.backends.cast.timeoutSec, default 3600) keeps
Relaycast WebSockets open (opt.agent-relay.gke-ingress).

- Default: `empty`
- Choices: `empty`: no backend-config annotation; `<gkeIngress.name>-cast`: required behind the agent-relay GKE ingress
- Provided by: operator
- Values: `service.backendConfig`
- Verify: kubectl get svc <relaycast Service> -o jsonpath='{.metadata.annotations.cloud\.google\.com/backend-config}'
- Sources: [`charts/relaycast/templates/service.yaml:10`](../charts/relaycast/templates/service.yaml#L10), [`charts/agent-relay/templates/gke-ingress.yaml:144`](../charts/agent-relay/templates/gke-ingress.yaml#L144)

#### opt.stack.relayauth

<a id="opt-stack-relayauth"></a>

**Run RelayAuth in-cluster or use a hosted issuer** · shipped · chart `relayauth` · profiles relayauth

relayauth is the self-hosted issuer whose JWKS alleyoop and relayfile verify.
Install the relayauth chart, or point auth.jwksUrl at an issuer you already
run. The RelayAuth-to-RelayIdentity rename and control-plane packaging are
unresolved.

- Default: `installed`
- Choices: `installed`; `external`: an existing issuer's JWKS URL
- Provided by: operator
- Verify: curl <baseUrl>/.well-known/jwks.json
- Sources: [`docs/self-hosted-reference-architecture.md:18`](../docs/self-hosted-reference-architecture.md#L18), [`charts/relayauth/values.yaml:24`](../charts/relayauth/values.yaml#L24)

#### opt.relaycast.exposure

<a id="opt-relaycast-exposure"></a>

**Relaycast ingress scheme** · shipped · chart `relaycast` · profiles relaycast

internal: ClusterIP only, http:// baseUrl with allowInsecureBaseUrl (private
hosts only; extra suffixes/hosts for custom cluster domains). ingress-tls: the
chart's Ingress serves HTTPS from ingress.tls. ingress-external-tls: a load
balancer in front of the controller terminates TLS. Every ingress blocks
/internal and /v1/workspaces at the edge.

- Default: `internal`
- Choices: `internal`: allowInsecureBaseUrl=true, http://<svc>.<ns>.svc:8787; `ingress-tls`: ingress.enabled + ingress.tls; `ingress-external-tls`: ingress.enabled + ingress.externalTls
- Provided by: operator
- Values: `allowInsecureBaseUrl`, `privateDnsSuffixes`, `insecureBaseUrlHosts`, `ingress.enabled`, `ingress.externalTls`, `service.type`
- Env: `RELAYCAST_ALLOW_INSECURE_BASE_URL`, `RELAYCAST_PRIVATE_DNS_SUFFIXES`, `RELAYCAST_INSECURE_BASE_URL_HOSTS`
- Verify: helm template refuses ingress with allowInsecureBaseUrl or an http baseUrl
- Sources: [`charts/relaycast/values.yaml:36`](../charts/relaycast/values.yaml#L36), [`charts/relaycast/templates/_helpers.tpl:168`](../charts/relaycast/templates/_helpers.tpl#L168), [`charts/relaycast/templates/deployment.yaml:72`](../charts/relaycast/templates/deployment.yaml#L72)

#### opt.relaycast.workspace-create

<a id="opt-relaycast-workspace-create"></a>

**Anonymous workspace creation** · shipped · chart `relaycast` · profiles relaycast

Off by default; workspaces are created through the internal admin API. Refused with ingress. bootstrapProofRequired demands bootstrap-secret proof for anonymous keyed creates; actor mode requires secretKeys.workspaceBootstrapSecret and matching actor environment values.

- Default: `false`
- Choices: `false`; `true`: never with ingress
- Provided by: operator
- Values: `publicWorkspaceCreate`, `bootstrapProofRequired`
- Env: `RELAYCAST_PUBLIC_WORKSPACE_CREATE`, `RELAYCAST_WORKSPACE_BOOTSTRAP_PROOF_REQUIRED`
- Verify: POST /v1/workspaces without a key is refused
- Sources: [`charts/relaycast/values.yaml:85`](../charts/relaycast/values.yaml#L85), [`charts/relaycast/templates/_helpers.tpl:165`](../charts/relaycast/templates/_helpers.tpl#L165)

#### opt.relaycast.retention

<a id="opt-relaycast-retention"></a>

**Message retention and mailbox limits** · shipped · chart `relaycast` · profiles relaycast

Empty keeps messages forever and uses the engine's mailbox defaults; positive integers only.

- Default: (no default)
- Choices: `<positive integer>`; `""`: engine default / keep forever
- Provided by: operator
- Values: `retention.messageTtlDays`, `mailbox.ttlMs`, `mailbox.depthCap`
- Env: `RELAYCAST_MESSAGE_TTL_DAYS`, `RELAYCAST_MAILBOX_TTL_MS`, `RELAYCAST_MAILBOX_DEPTH_CAP`
- Verify: env of the relaycast pod
- Sources: [`charts/relaycast/values.yaml:90`](../charts/relaycast/values.yaml#L90), [`charts/relaycast/templates/deployment.yaml:84`](../charts/relaycast/templates/deployment.yaml#L84)

#### opt.relaycast.backup

<a id="opt-relaycast-backup"></a>

**Scheduled SQLite and file backups** · shipped · chart `relaycast` · profiles relaycast

Online SQLite-backup-API copies of the database and the file directory to a second RWO PVC on a schedule; restore procedure in charts/relaycast/README.md.

- Default: `false`
- Choices: `false`; `true`
- Provided by: operator
- Values: `backup.*`
- Verify: kubectl get cronjob -n relaycast; a completed backup Job
- Sources: [`charts/relaycast/values.yaml:143`](../charts/relaycast/values.yaml#L143), [`charts/relaycast/templates/backup.yaml:156`](../charts/relaycast/templates/backup.yaml#L156)

#### opt.relaycast.runtime-backend

<a id="opt-relaycast-runtime-backend"></a>

**Relaycast runtime backend** · shipped · chart `relaycast` · profiles relaycast

sqlite is the only released backend (portable-single). The aws-ha adapter set
(PostgreSQL, Redis pub/sub, SQS, S3) and then gcp-ha are planned in the engine;
the chart refuses anything but sqlite until they are released and proven.

- Default: `sqlite`
- Choices: `sqlite`; `aws-ha` (**planned**): Postgres + Redis + SQS + S3; `gcp-ha` (**planned**): Cloud SQL + Memorystore + Pub/Sub + GCS
- Provided by: operator
- Values: `runtime.backend`
- Verify: helm template refuses runtime.backend != sqlite
- Sources: [`charts/relaycast/values.yaml:21`](../charts/relaycast/values.yaml#L21), [`charts/relaycast/templates/_helpers.tpl:77`](../charts/relaycast/templates/_helpers.tpl#L77), [`docs/self-hosted-reference-architecture.md:40`](../docs/self-hosted-reference-architecture.md#L40)

#### opt.relaycast.credential-authority

<a id="opt-relaycast-credential-authority"></a>

**Workspace credential format and authority (ar_ / model B)** · shipped · chart `relaycast` · profiles relaycast

credentials.format selects the workspace credential format (legacy is the
default). format=ar requires an authority: relayauth makes RelayAuth the
ar_ credential authority (model B — RelayAuth owns the ar_ tag keyring and
pushes ar_ws_ keys into Relaycast, which verifies tags through RelayAuth's
remote CredentialTagger via credentials.relayauth.url and
secretKeys.relayauthToken); self verifies ar_ tags against the local
keyring mounted by secretKeys.credentialKeyring. A mounted keyring always
takes precedence over the remote tagger. ar_ custody requires a >=12.3.x
engine image; the pinned default (engine 12.7.0) satisfies it.

- Default: `legacy`
- Choices: `legacy`: issue and verify legacy credentials locally; `ar`: ar_ credentials; requires credentials.authority (self or relayauth)
- Provided by: operator
- Values: `credentials.*`
- Env: `RELAYCAST_CREDENTIAL_FORMAT`, `RELAYCAST_RELAYAUTH_URL`
- Verify: helm template refuses format=ar without an authority, authority=relayauth without url+token, and authority=self without secretKeys.credentialKeyring
- Sources: [`charts/relaycast/values.yaml:75`](../charts/relaycast/values.yaml#L75), [`charts/relaycast/templates/_helpers.tpl:133`](../charts/relaycast/templates/_helpers.tpl#L133), [`charts/relaycast/templates/deployment.yaml:95`](../charts/relaycast/templates/deployment.yaml#L95)

#### opt.relaycast.network-policy

<a id="opt-relaycast-network-policy"></a>

**Relaycast NetworkPolicy** · shipped · chart `relaycast` · profiles relaycast

On by default; allows callers only from the release namespace unless ingressFrom lists more (required with ingress).

- Default: `true`
- Choices: `true`; `false`
- Provided by: operator
- Values: `networkPolicy.enabled`, `networkPolicy.ingressFrom`
- Verify: kubectl get networkpolicy -n relaycast
- Sources: [`charts/relaycast/values.yaml:216`](../charts/relaycast/values.yaml#L216)

#### opt.charts.image-pull-secrets

<a id="opt-charts-image-pull-secrets"></a>

**Image pull Secrets for the Relay charts** · shipped · chart `relaycast`, `relayauth`, `relayfile`, `relayflows` · profiles relaycast, relayauth, relayfile, relayflows

Optional pull Secrets for mirrored or private registries (the default images are public GHCR packages and node).

- Default: `[]`
- Choices: `[]`; `[{name: <secret>}]`
- Provided by: operator
- Values: `relaycast:imagePullSecrets`, `relayauth:imagePullSecrets`, `relayfile:imagePullSecrets`, `relayflows:imagePullSecrets`
- Verify: pods are not ImagePullBackOff
- Sources: [`charts/relaycast/values.yaml:13`](../charts/relaycast/values.yaml#L13), [`charts/relayauth/values.yaml:15`](../charts/relayauth/values.yaml#L15)

#### opt.relayauth.key-rotation

<a id="opt-relayauth-key-rotation"></a>

**Signing key rotation slots** · shipped · chart `relayauth` · profiles relayauth

Optional Secret keys for the public, next and previous signing keys; each set key is mounted and passed as a *_FILE path.

- Default: `""`
- Choices: `""`: single key; `<secret key name>`
- Provided by: operator
- Values: `secretKeys.signingKeyPublic`, `secretKeys.signingKeyNext`, `secretKeys.signingKeyPrevious`
- Env: `RELAYAUTH_SIGNING_KEY_PEM_PUBLIC_FILE`, `RELAYAUTH_SIGNING_KEY_PEM_NEXT_FILE`, `RELAYAUTH_SIGNING_KEY_PEM_PREVIOUS_FILE`
- Verify: the JWKS lists the next/previous kids during a rotation
- Sources: [`charts/relayauth/values.yaml:57`](../charts/relayauth/values.yaml#L57), [`charts/relayauth/templates/deployment.yaml:74`](../charts/relayauth/templates/deployment.yaml#L74)

#### opt.relayauth.issuer

<a id="opt-relayauth-issuer"></a>

**RelayAuth base URL and issuer** · shipped · chart `relayauth` · profiles relayauth

baseUrl is the discovery/JWKS base (empty = the in-cluster Service URL); issuer is the iss verifiers pin (empty = baseUrl).

- Default: `""`
- Choices: `""`: http://<fullname>.<ns>.svc:8787; `https://<public host>`: required with jwksIngress
- Provided by: operator
- Values: `baseUrl`, `issuer`
- Env: `BASE_URL`, `RELAYAUTH_ISSUER`
- Verify: curl <baseUrl>/.well-known/openid-configuration issuer matches
- Sources: [`charts/relayauth/values.yaml:24`](../charts/relayauth/values.yaml#L24), [`charts/relayauth/templates/deployment.yaml:55`](../charts/relayauth/templates/deployment.yaml#L55)

#### opt.relayauth.jwks-ingress

<a id="opt-relayauth-jwks-ingress"></a>

**Public JWKS ingress** · shipped · chart `relayauth` · profiles relayauth

Exposes only the well-known discovery/JWKS paths (token and admin APIs stay
unexposed). Requires an explicit externally reachable baseUrl, at least one host
with DNS, TLS (jwksIngress.tls Secret), and with networkPolicy an explicit
ingressFrom.

- Default: `false`
- Choices: `false`; `true`
- Provided by: operator
- Values: `jwksIngress.*`, `networkPolicy.enabled`, `networkPolicy.ingressFrom`
- Secret: `<jwksIngress.tls[].secretName>`. kubernetes.io/tls for the JWKS host
- Verify: curl -fsS https://<host>/.well-known/jwks.json; other paths are not routed
- Sources: [`charts/relayauth/values.yaml:77`](../charts/relayauth/values.yaml#L77), [`charts/relayauth/templates/_helpers.tpl:103`](../charts/relayauth/templates/_helpers.tpl#L103)

#### opt.relayauth.cors-history

<a id="opt-relayauth-cors-history"></a>

**CORS allowlist and RelayHistory assertion options** · shipped · chart `relayauth` · profiles relayauth

ALLOWED_ORIGINS (CORS only, not an audience allowlist); allowPrivateHttpOrigin permits http historyOrigin values on private IPs and cluster DNS; bootstrapApiKeyOrg binds the bootstrap API key.

- Default: `allowedOrigins=`, `allowPrivateHttpOrigin=false`, `bootstrapApiKeyOrg=org_selfhost`
- Choices: `<any>`
- Provided by: operator
- Values: `cors.allowedOrigins`, `relayhistory.allowPrivateHttpOrigin`, `relayhistory.bootstrapApiKeyOrg`
- Env: `ALLOWED_ORIGINS`, `RELAYAUTH_ALLOW_PRIVATE_HTTP_HISTORY_ORIGIN`, `RELAYAUTH_BOOTSTRAP_API_KEY_ORG`
- Verify: env of the relayauth pod
- Sources: [`charts/relayauth/values.yaml:30`](../charts/relayauth/values.yaml#L30), [`charts/relayauth/templates/deployment.yaml:84`](../charts/relayauth/templates/deployment.yaml#L84)

#### opt.relayauth.relaycast-credentials

<a id="opt-relayauth-relaycast-credentials"></a>

**Push RelayAuth-issued ar_ workspace credentials into Relaycast (model B)** · shipped · chart `relayauth` · profiles relayauth

When secretKeys.relaycastCredentialKeyring and
secretKeys.relaycastInternalSecret are set together, RelayAuth owns the
ar_ credential tag keyring and pushes ar_ws_ workspace keys into
Relaycast's internal admin API at relaycast.url (RELAYAUTH_RELAYCAST_URL).
secretKeys.relaycastServiceApiKey adds an optional service API key. The
chart refuses partial wiring. The relaycast side is
credentials.authority=relayauth (opt.relaycast.credential-authority).

- Default: `""`
- Choices: `""`: off; no relaycast credential push; `configured`: keyring + internal secret keys set (see req.relayauth.secret)
- Provided by: operator
- Values: `relaycast.url`
- Env: `RELAYAUTH_RELAYCAST_URL`
- Verify: helm template fails with "secretKeys.relaycastInternalSecret is required" when only the keyring key is set, and renders RELAYAUTH_RELAYCAST_* envs when both are set
- Sources: [`charts/relayauth/values.yaml:48`](../charts/relayauth/values.yaml#L48), [`charts/relayauth/templates/deployment.yaml:87`](../charts/relayauth/templates/deployment.yaml#L87), [`charts/relayauth/templates/_helpers.tpl:84`](../charts/relayauth/templates/_helpers.tpl#L84)

#### opt.relayfile.backend-profile

<a id="opt-relayfile-backend-profile"></a>

**Relayfile storage backend profile** · shipped · chart `relayfile` · profiles relayfile

production (Postgres), memory (dev/test), durable-local (file-backed, needs a writable root), custom (bring your own DSNs).

- Default: `production`
- Choices: `production`; `memory`; `durable-local`; `custom`
- Provided by: operator
- Values: `server.backendProfile`
- Env: `RELAYFILE_BACKEND_PROFILE`
- Verify: env of the relayfile pod
- Sources: [`charts/relayfile/values.yaml:37`](../charts/relayfile/values.yaml#L37), [`charts/relayfile/templates/server/_helpers.tpl:37`](../charts/relayfile/templates/server/_helpers.tpl#L37)

#### opt.relayfile.auth

<a id="opt-relayfile-auth"></a>

**Relayfile RelayAuth JWKS** · shipped · chart `relayfile` · profiles relayfile

RELAYAUTH_JWKS_URL of the RelayAuth issuer; only its public JWKS endpoint is needed.

- Default: `""`
- Choices: `<jwks url>`
- Provided by: operator
- Values: `auth.jwksUrl`
- Env: `RELAYAUTH_JWKS_URL`
- Verify: curl -fsS <jwksUrl>
- Sources: [`charts/relayfile/values.yaml:85`](../charts/relayfile/values.yaml#L85), [`charts/relayfile/templates/server/_helpers.tpl:58`](../charts/relayfile/templates/server/_helpers.tpl#L58)

#### opt.relayfile.notion

<a id="opt-relayfile-notion"></a>

**Relayfile Notion provider** · shipped · chart `relayfile` · profiles relayfile

Optional provider credential (RELAYFILE_NOTION_TOKEN, from the Secret) and API overrides. Other providers go through extraEnv/extraEnvFrom.

- Default: `""`
- Choices: `""`: off; `<token>`
- Provided by: operator
- Values: `providers.notion.token`, `providers.notion.baseUrl`, `providers.notion.apiVersion`
- Env: `RELAYFILE_NOTION_TOKEN`, `RELAYFILE_NOTION_BASE_URL`, `RELAYFILE_NOTION_API_VERSION`
- Secret: `<secrets.existingSecret>`; keys `RELAYFILE_NOTION_TOKEN`
- Verify: env of the relayfile pod
- Sources: [`charts/relayfile/values.yaml:93`](../charts/relayfile/values.yaml#L93), [`charts/relayfile/templates/server/_helpers.tpl:86`](../charts/relayfile/templates/server/_helpers.tpl#L86)

#### opt.relayfile.server-tuning

<a id="opt-relayfile-server-tuning"></a>

**Relayfile server tuning** · shipped · chart `relayfile` · profiles relayfile

Listen address, worker counts, provider concurrency, rate limit and body size.

- Default: `port=8080`, `envelopeWorkers=2`, `writebackWorkers=2`, `providerMaxConcurrency=4`
- Choices: `<any>`
- Provided by: operator
- Values: `server.addr`, `server.port`, `server.envelopeWorkers`, `server.writebackWorkers`, `server.providerMaxConcurrency`, `server.rateLimitMax`, `server.rateLimitWindow`, `server.maxBodyBytes`
- Env: `RELAYFILE_ADDR`, `RELAYFILE_ENVELOPE_WORKERS`, `RELAYFILE_WRITEBACK_WORKERS`, `RELAYFILE_PROVIDER_MAX_CONCURRENCY`, `RELAYFILE_RATE_LIMIT_MAX`, `RELAYFILE_RATE_LIMIT_WINDOW`, `RELAYFILE_MAX_BODY_BYTES`
- Verify: env of the relayfile pod
- Sources: [`charts/relayfile/values.yaml:25`](../charts/relayfile/values.yaml#L25), [`charts/relayfile/templates/server/_helpers.tpl:35`](../charts/relayfile/templates/server/_helpers.tpl#L35)

#### opt.relayfile.ingress

<a id="opt-relayfile-ingress"></a>

**Relayfile ingress** · shipped · chart `relayfile` · profiles relayfile

Optional Ingress with your hosts and TLS Secrets.

- Default: `false`
- Choices: `false`; `true`
- Provided by: operator
- Values: `ingress.*`
- Secret: `<ingress.tls[].secretName>`. kubernetes.io/tls
- Verify: curl -fsS https://<host>/health
- Sources: [`charts/relayfile/values.yaml:113`](../charts/relayfile/values.yaml#L113)

#### opt.relayflows.mode

<a id="opt-relayflows-mode"></a>

**Relayflows mode** · shipped · chart `relayflows` · profiles relayflows

standalone runs a flow in a Kubernetes Job with no Agent Relay Cloud contact (hosted publication and telemetry forced off); cloudWorker runs an enrolled Cloud assignment worker.

- Default: `standalone`
- Choices: `standalone`; `cloudWorker`
- Provided by: operator
- Values: `mode`, `worker.name`, `worker.cloudUrl`
- Env: `AGENT_RELAY_CLOUD_URL`, `AGENT_RELAY_WORKER_NAME`, `FLOWS_CLOUD_MIRROR`, `AGENT_RELAY_TELEMETRY_DISABLED`
- Verify: helm template fails with "mode must be either standalone or cloudWorker" otherwise
- Sources: [`charts/relayflows/values.yaml:5`](../charts/relayflows/values.yaml#L5), [`charts/relayflows/templates/_helpers.tpl:33`](../charts/relayflows/templates/_helpers.tpl#L33), [`charts/relayflows/templates/standalone/_jobspec.tpl:141`](../charts/relayflows/templates/standalone/_jobspec.tpl#L141)

#### opt.relayflows.flow-source

<a id="opt-relayflows-flow-source"></a>

**Standalone flow source, input and resume** · shipped · chart `relayflows` · profiles relayflows

Exactly one of an image path, inline content (chart ConfigMap) or an existing ConfigMap, unless resumeRunId is set; input only for authored flows; optional cron schedule.

- Default: (no default)
- Choices: `path`; `content`; `existingConfigMap`
- Provided by: operator
- Values: `standalone.flow.*`, `standalone.input`, `standalone.resumeRunId`, `standalone.cron.*`
- Env: `RELAYFLOWS_FLOW_PATH`, `RELAYFLOWS_INPUT`, `RELAYFLOWS_RUN_ID`
- Verify: helm template fails unless exactly one source is set
- Sources: [`charts/relayflows/values.yaml:17`](../charts/relayflows/values.yaml#L17), [`charts/relayflows/templates/_helpers.tpl:140`](../charts/relayflows/templates/_helpers.tpl#L140)

#### opt.relayflows.runtime

<a id="opt-relayflows-runtime"></a>

**Relayflows runtime, local agents and model credentials** · shipped · chart `relayflows` · profiles relayflows

runtimeInstaller installs pinned relayflows (and agent-relay in cloudWorker
mode) at start; disable it for immutable images. localAgent attaches in-process
agent workers (agentCapacity 1-32); the image must contain each harness CLI.
Model/provider credentials (for example ANTHROPIC_API_KEY) come through
extraEnvFrom from a Secret you create.

- Default: `runtimeInstaller=true`, `localAgent=true`, `agentCapacity=1`
- Choices: `<any>`
- Provided by: operator
- Values: `runtimeInstaller.*`, `standalone.localAgent`, `standalone.agentCapacity`, `standalone.dataDir`, `extraEnvFrom`
- Env: `RELAYFLOWS_VERSION`, `AGENT_RELAY_VERSION`, `RELAYFLOWS_AGENT_CAPACITY`, `RELAYFLOWS_DATA_DIR`
- Verify: the Job's logs show the flow run
- Sources: [`charts/relayflows/values.yaml:73`](../charts/relayflows/values.yaml#L73), [`charts/relayflows/values.yaml:176`](../charts/relayflows/values.yaml#L176), [`charts/relayflows/templates/standalone/_jobspec.tpl:128`](../charts/relayflows/templates/standalone/_jobspec.tpl#L128)

#### opt.agent-relay.durable-actors

<a id="opt-agent-relay-durable-actors"></a>

**Run the durable-actors control plane and Relayfile in the suite** · shipped · chart `agent-relay` · profiles agent-relay-durable-actors, agent-relay-eks-durable-actors

components.durableActors enables the vendored control plane (needs an
actor-mode consumer); components.relayfile adds Relayfile. Consumers' admin
Secret and artifact bucket must equal durable-actors.credentialsSecret and
storage.bucket. durableActorsNetworkPolicy limits control-plane ingress to the
release namespace, the sandbox namespace and the GKE LB ranges.

- Default: `false`
- Choices: `false`; `true`: GKE Sandbox + GCS + PostgreSQL
- Provided by: operator
- Values: `components.durableActors`, `components.relayfile`, `durableActorsNetworkPolicy.*`, `gkeIngress.hosts.files`, `gkeIngress.backends.files.*`
- Verify: helm template fails with "components.durableActors=true has no consumer" or "requires components.durableActors=true" on miswiring (ci/agent-relay/render.sh)
- Sources: [`charts/agent-relay/values.yaml:15`](../charts/agent-relay/values.yaml#L15), [`charts/agent-relay/templates/_helpers.tpl:42`](../charts/agent-relay/templates/_helpers.tpl#L42)

#### opt.relaycast.durable-actors

<a id="opt-relaycast-durable-actors"></a>

**Relaycast runtime backend (sqlite, durable-actors or postgres)** · shipped · chart `relaycast` · profiles relaycast-durable-actors, agent-relay-durable-actors, agent-relay-eks-durable-actors

durable-actors (env contract v1) replaces the SQLite Deployment with the
relaycast-actors-gateway (same Service, ingress and edge-deny rules; PORT 8787,
/healthz and /readyz). Requires ar_ credentials with a keyring, an HTTPS public
baseUrl (sandbox egress blocks private ranges), and a durable-actors control
plane. More than one gateway replica needs fileStore gcs or s3 and renders
a PDB; generated topology spread is available. PostgreSQL installs use the
full-copy upgrader; SQLite workspaces are not migrated.

- Default: `sqlite`
- Choices: `sqlite`; `durable-actors`: env contract v1; images relaycast-actors-gateway and relaycast-actors-deployer by digest; `postgres`: see req.relaycast.postgres; image runtime.postgres.image by digest
- Provided by: operator
- Values: `runtime.backend`, `runtime.durableActors.projectId`, `runtime.durableActors.organizationId`, `runtime.durableActors.controlPlaneUrl`, `runtime.durableActors.homeRegion`, `runtime.durableActors.socketOrigin`, `runtime.durableActors.gateway.*`, `runtime.durableActors.maxUploadBytes`, `runtime.durableActors.shutdownGraceMs`, `runtime.durableActors.logFormat`, `runtime.durableActors.fileStore.*`, `runtime.durableActors.devRuntime.*`
- Env: `DURABLE_ACTORS_CONTROL_PLANE_URL`, `DURABLE_ACTORS_PROJECT_ID`, `DURABLE_ACTORS_HOME_REGION`, `DURABLE_ACTORS_SOCKET_ORIGIN`, `RELAYCAST_FILE_STORE`, `RELAYCAST_FILE_DIR`, `RELAYCAST_GCS_BUCKET`, `RELAYCAST_GCS_PREFIX`, `RELAYCAST_S3_BUCKET`, `RELAYCAST_S3_REGION`, `RELAYCAST_S3_ENDPOINT`, `RELAYCAST_S3_PREFIX`, `RELAYCAST_S3_FORCE_PATH_STYLE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `RELAYCAST_MAX_UPLOAD_BYTES`, `RELAYCAST_SHUTDOWN_GRACE_MS`, `RELAYCAST_LOG_FORMAT`, `DURABLE_ACTORS_PORT`, `DURABLE_ACTORS_DATA_DIR`, `RELAYCAST_PUBLIC_URL`, `RELAYCAST_INTERNAL_SECRET`
- Secret: `<runtime.durableActors.fileStore.s3.existingSecret>`; keys `AWS_ACCESS_KEY_ID`; `AWS_SECRET_ACCESS_KEY`. s3 file store only; empty uses the pod's ambient identity
- Verify: kubectl get deploy relaycast -o jsonpath='{.metadata.labels.agentworkforce\.dev/relaycast-backend}' is durable-actors; curl <baseUrl>/readyz
- Sources: [`charts/relaycast/values.yaml:29`](../charts/relaycast/values.yaml#L29), [`charts/relaycast/templates/_actors.tpl:98`](../charts/relaycast/templates/_actors.tpl#L98)

#### opt.relaycast.collector-analytics

<a id="opt-relaycast-collector-analytics"></a>

**Relaycast collector analytics adapter** · shipped · chart `relaycast` · profiles relaycast-postgres

The Node runtime can send a closed event vocabulary to the private HTTPS
collector. The operator chooses a collector-capable image, a deployment ID,
an existing producer Secret, and the CA ConfigMap. The application has
separate collector and PostgreSQL CA paths. The migration Job receives
neither the collector credential nor the collector CA.

- Default: `false`
- Choices: `false`; `true`
- Provided by: operator
- Values: `analytics.*`
- Env: `RELAYCAST_TELEMETRY_DESTINATION`, `RELAYCAST_TELEMETRY_COLLECTOR_URL`, `RELAYCAST_TELEMETRY_DEPLOYMENT_ID`, `RELAYCAST_TELEMETRY_COLLECTOR_TOKEN_FILE`, `NODE_EXTRA_CA_CERTS`
- Secret: `<Relaycast component-bound analytics producer Secret>` from `analytics.existingSecret`; keys `token` from `analytics.tokenKey`
- Verify: Verify the application-only CA and token projections, and a real dm.sent event in the private collector files.
- Sources: [`charts/relaycast/templates/_analytics.tpl`](../charts/relaycast/templates/_analytics.tpl), [`charts/relaycast/templates/deployment.yaml`](../charts/relaycast/templates/deployment.yaml)

#### opt.relayfile.durable-actors

<a id="opt-relayfile-durable-actors"></a>

**Relayfile runtime backend (go or durable-actors)** · shipped · chart `relayfile` · profiles relayfile-durable-actors, agent-relay-durable-actors, agent-relay-eks-durable-actors

durable-actors replaces the Go server with the relayfile-actors gateway (same
Service/Ingress/HPA/NetworkPolicy), adds the session broker and the deploy Job,
and stores file bytes in GCS (Workload Identity via serviceAccount.annotations)
or S3. deployer.artifactStore.driver s3 uploads bundles to S3 (DURABLE_ACTORS_ARTIFACT_STORE,
DURABLE_ACTORS_S3_*). devRuntime runs `durable-actors dev` as a sidecar for kind/CI only.

- Default: `go`
- Choices: `go`; `durable-actors`: images ghcr.io/agentworkforce/relayfile-actors (gateway, session broker) and relayfile-actors-workspace (deploy Job, dev sidecar) by digest
- Provided by: operator
- Values: `runtime.backend`, `runtime.durableActors.image.*`, `runtime.durableActors.projectId`, `runtime.durableActors.organizationId`, `runtime.durableActors.controlPlaneUrl`, `runtime.durableActors.gateway.*`, `runtime.durableActors.broker.*`, `runtime.durableActors.deployer.*`, `runtime.durableActors.blobStore.*`, `runtime.durableActors.devRuntime.*`
- Env: `DURABLE_ACTORS_CONTROL_PLANE_URL`, `DURABLE_ACTORS_PROJECT_ID`, `DURABLE_ACTORS_ORGANIZATION_ID`, `DURABLE_ACTORS_ARTIFACT_BUCKET`, `RELAYFILE_ACTORS_BROKER_URL`, `RELAYFILE_ACTORS_ALLOW_ADMIN_KEY`, `RELAYFILE_BLOB_STORE`, `RELAYFILE_BLOB_BUCKET`, `RELAYFILE_BLOB_PREFIX`, `RELAYFILE_BLOB_INLINE_MAX_BYTES`, `RELAYFILE_S3_ENDPOINT`, `RELAYFILE_S3_REGION`, `RELAYFILE_S3_FORCE_PATH_STYLE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `DURABLE_ACTORS_PORT`, `DURABLE_ACTORS_DATA_DIR`, `DURABLE_ACTORS_ARTIFACT_STORE`, `DURABLE_ACTORS_S3_REGION`, `DURABLE_ACTORS_S3_ENDPOINT`, `DURABLE_ACTORS_S3_FORCE_PATH_STYLE`
- Secret: `<runtime.durableActors.blobStore.s3.existingSecret>`; keys `AWS_ACCESS_KEY_ID`; `AWS_SECRET_ACCESS_KEY`. s3 blob store only; empty uses the pod's ambient identity
- Verify: kubectl get deploy <fullname>-server -o jsonpath='{.metadata.labels.agentworkforce\.dev/relayfile-backend}' is durable-actors; curl <url>/health
- Sources: [`charts/relayfile/values.yaml:14`](../charts/relayfile/values.yaml#L14), [`charts/relayfile/templates/actors/_helpers.tpl:90`](../charts/relayfile/templates/actors/_helpers.tpl#L90)

#### opt.sessions-native-ingest

<a id="opt-sessions-native-ingest"></a>

**Default-off native session upload edge** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql, aws-rds-native

Separate SERVICE=session-ingest Deployment and ClusterIP from merged
pipeline #363/974e6f74; does not replace internal alleyoop-ingest. Requires
a qualified immutable image, normalized public origin, introspection base
URL, runtime Secret, S3 Secret or workload identity, and a pinned PostgreSQL custom CA.
The aws-rds-native profile is the only install profile that enables it,
through a mandatory qualified release overlay. No ingress, role bootstrap,
publication, GC, product deletion or provider removal is implied.

- Default: `disabled` (by profile: default `disabled`, aws-rds-native `enabled`)
- Choices: `disabled`; `enabled`: Requires a qualified native image and explicit pilot plan.
- Provided by: operator
- Values: `ingestEdge.*`
- Env: `SERVICE`, `RELAYHISTORY_SELFHOST_INGEST`, `RELAYHISTORY_SELFHOST_SESSION_SELECTION`, `RELAYHISTORY_SELFHOST_HEARTBEAT_ACCEPT`, `RELAYHISTORY_INGEST_PORT`, `RELAYHISTORY_INGEST_ORIGIN`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`, `RELAYHISTORY_INGEST_DATABASE_URL`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYHISTORY_INGEST_PG_POOL_MAX`, `ALLOW_IN_CLUSTER_HTTP`, `LOCKER_PROVIDER`, `LOCKER_BUCKET`, `LOCKER_ENDPOINT`, `LOCKER_REGION`, `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`, `INGEST_KEY_ROOT`, `INGEST_MAX_PER_USER`, `INGEST_MAX_PER_ORG`
- Secret: `<native ingest runtime Secret>` (default), `agent-relay-ingest-edge-runtime` (aws-rds-native) from `ingestEdge.config.existingSecret`; keys `database-url` from `ingestEdge.config.databaseUrlKey`; `introspect-secret` from `ingestEdge.config.introspectSecretKey`
- Secret: `<native ingest object-store Secret>` (default), `<not used: EKS Pod Identity>` (aws-rds-native) from `ingestEdge.locker.existingSecret`; keys `access-key-id` from `ingestEdge.locker.accessKeyIdKey`; `secret-access-key` from `ingestEdge.locker.secretAccessKeyKey`
- Verify: default: Keep disabled until merged composition and exact image/generation pass native PG/TLS/MinIO upload-to-readback proof. / aws-rds-native: The qualified release overlay must pass native RDS/TLS/S3 upload-to-readback proof; Helm readiness is not an authorization, schema, object-store or migration barrier.
- Sources: [`charts/sessions-pipeline/templates/ingest-edge.yaml:1`](../charts/sessions-pipeline/templates/ingest-edge.yaml#L1), [`charts/sessions-pipeline/values.yaml:1`](../charts/sessions-pipeline/values.yaml#L1), [`docs/self-hosted-native-ingest.md:1`](../docs/self-hosted-native-ingest.md#L1)

#### opt.sessions-read-api

<a id="opt-sessions-read-api"></a>

**Default-off self-host session read API container** · shipped · chart `session-read-api` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

The standalone session-read-api chart, carried by sessions-pipeline as the
default-off sessionReadApi dependency. Requires an explicitly pinned
compatible image, read-role configuration JSON in a Secret, an explicit
coverage floor and workspace allowlist, a public token audience, an explicit
postgres.tlsProfile, and one of auth.mode=relaycontrol_only (the default,
with enabled introspection and empty legacy issuer settings), an
explicitly configured temporary issuer (legacy), or self_issued. self_issued
requires auth.selfIssued.internalSecret (at least 32 characters, checked by
the service at startup), relaycontrol.enabled=false, login.advertisesSync=false
and networkPolicy.enabled with controlFrom selecting the Control pods.
accessTokenTtlSeconds is 60 to 300. The optional ingress routes only /v1,
so /internal/* is not published; publicFrom peers share the service port
and must route only /v1. events.messageIds (default off) requires
LOCKER_BUCKET. A LOCKER_BUCKET extraEnv
entry requires a nonempty literal bucket, literal
PIPELINE_ORG_FROM_PREFIX=true and PIPELINE_KEY_PREFIX=96bulls. Missing/false
flags, org-suffixed roots and valueFrom references for these layout inputs
refuse rendering. Bucket literals reject surrounding whitespace; when both
services are enabled, the configured reader bucket must equal
ingestEdge.locker.bucket. Search is selected via SEARCH_INDEX_BACKEND
(postgres by default); search.clickhouse.enabled reads an external
ClickHouse from the read API Secret. Introspection uses its own Secret
reference. Readiness requires health JSON enabled:true; dormant HTTP 200 is
insufficient. The aws-rds-native profile is the only install profile that
enables this option, through a mandatory qualified release overlay. The old
sessions-pipeline readApi key refuses to render with a migration message.
Source configuration alone does not claim runtime availability or proof.
coordinationOverlaps.enabled is default off in the standalone leaf. The
sessions-pipeline adapter defaults it on when the dependency is enabled,
emitting READ_API_COORDINATION_OVERLAPS_ENABLED=true and the managed
READ_API_COORDINATION_OVERLAPS_BACKEND=postgres selection. It requires a
qualified fe62ed80-or-later services image and migration
20261105047000_coordination_fact_readers.
timing.assumeNoTurns and canonical.pinLaggingPointer are managed,
default-off assumptions. aws-rds-native enables both: a fresh native
store has no historical timing-turn population, and async admission may
temporarily leave session_index ahead of the canonical pointer. Other
profiles preserve the fail-closed defaults.

- Default: `disabled` (by profile: default `disabled`, aws-rds-native `enabled`)
- Choices: `disabled`; `enabled`: Requires an owner-approved compatible runtime.
- Provided by: operator
- Values: `fullnameOverride`, `replicas`, `image.*`, `imagePullSecrets`, `port`, `probeRuntime`, `origin`, `completeSince`, `directoryWorkspaces`, `login.advertisesSync`, `turns.assumeNoLegacy`, `timing.assumeNoTurns`, `canonical.pinLaggingPointer`, `events.messageIds`, `coordinationOverlaps.enabled`, `serviceAccountCreate`, `allowInClusterHttp`, `config.*`, `postgres.*`, `postgresCa.*`, `search.*`, `auth.*`, `cors.*`, `ingress.*`, `networkPolicy.*`, `extraEnv`, `extraVolumes`, `extraVolumeMounts`, `serviceAccountName`, `nodeSelector`, `tolerations`, `affinity`, `podAnnotations`, `resources`
- Env: `SERVICE`, `RELAYHISTORY_SELFHOST_READ_API`, `RELAYHISTORY_READ_API_PORT`, `RELAYHISTORY_READ_API_SECRET`, `READ_API_ORIGIN`, `READ_API_AUTH_MODE`, `READ_API_COMPLETE_SINCE`, `READ_API_DIRECTORY_WORKSPACES`, `READ_API_CORS_ALLOWED_ORIGINS`, `RELAYHISTORY_SELFHOST_LOGIN_ADVERTISES_SYNC`, `READ_API_TURNS_ASSUME_NO_LEGACY`, `READ_API_TIMING_ASSUME_NO_TURNS`, `READ_API_CANONICAL_PIN_LAGGING_POINTER`, `READ_API_EVENT_MESSAGE_IDS`, `READ_API_COORDINATION_OVERLAPS_ENABLED`, `READ_API_COORDINATION_OVERLAPS_BACKEND`, `READ_API_INTERNAL_SECRET`, `READ_API_INTERNAL_SECRET_PREVIOUS`, `READ_API_ACCESS_TOKEN_TTL_SECONDS`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `PIPELINE_KEY_PREFIX`, `SEARCH_INDEX_BACKEND`, `ALLOW_IN_CLUSTER_HTTP`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `RELAYAUTH_JWKS_URL`, `RELAYAUTH_ISSUER`, `RELAYHISTORY_ACCEPT_RELAYCONTROL_TOKENS`, `RELAYCONTROL_INTROSPECT_URL`, `RELAYCONTROL_INTROSPECT_SECRET`
- Secret: `<read API configuration Secret>` (default), `agent-relay-read-api` (aws-rds-native) from `sessionReadApi.config.existingSecret` then `session-read-api:config.existingSecret`; keys `RELAYHISTORY_READ_API_SECRET` from `session-read-api:config.key`
- Secret: `<read API introspection Secret>` (default), `<not used: self-issued auth>` (aws-rds-native) from `sessionReadApi.auth.relaycontrol.existingSecret` then `session-read-api:auth.relaycontrol.existingSecret`; keys `RELAYCONTROL_INTROSPECT_SECRET` from `session-read-api:auth.relaycontrol.key`
- Secret: `<read API internal Secret>` (default), `agent-relay-secrets` (aws-rds-native) from `sessionReadApi.auth.selfIssued.internalSecret.existingSecret` then `session-read-api:auth.selfIssued.internalSecret.existingSecret`; keys `READ_API_INTERNAL_SECRET` (default), `session-read-api-secret` (aws-rds-native) from `sessionReadApi.auth.selfIssued.internalSecret.key,session-read-api:auth.selfIssued.internalSecret.key`
- Secret: `<read API previous internal Secret>` (default), `<not configured>` (aws-rds-native) from `sessionReadApi.auth.selfIssued.previousInternalSecret.existingSecret` then `session-read-api:auth.selfIssued.previousInternalSecret.existingSecret`; keys `READ_API_INTERNAL_SECRET_PREVIOUS` from `session-read-api:auth.selfIssued.previousInternalSecret.key`
- Verify: default: Leave disabled until the image and assembly contract land; render/schema/probe tests prove plumbing only. / aws-rds-native: Prove authenticated workspace list/event reads and coordination overlaps with the exact qualified release image; render/schema/probe tests prove plumbing only.
- Sources: [`charts/session-read-api/templates/deployment.yaml:1`](../charts/session-read-api/templates/deployment.yaml#L1), [`charts/session-read-api/values.yaml:1`](../charts/session-read-api/values.yaml#L1), [`docs/self-hosted-session-read-api.md:1`](../docs/self-hosted-session-read-api.md#L1)

#### opt.sessions-search-indexer

<a id="opt-sessions-search-indexer"></a>

**Default-off self-host transcript search writer** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

Chart plumbing for the pipeline session-pipeline-consumer SERVICE, which
reads the Locker and writes the transcript search index (managed
OpenSearch by default, signed with the ServiceAccount's Pod Identity
credentials; projection state stays in Postgres). Requires an explicitly
pinned image built from a pipeline commit with the OpenSearch writer, the
same coverage floor and backend id as the read API, the runtime-role
connection JSON in a Secret, and an owner-role bootstrap (the chart's
bootstrap Job, or a run acknowledged by the operator). The ServiceAccount
must carry the search indexer Pod Identity association and the Locker
read grant. The aws-rds-native profile is the only install profile that
enables this option, through a mandatory qualified release overlay.

- Default: `disabled` (by profile: default `disabled`, aws-rds-native `enabled`)
- Choices: `disabled`; `enabled`: Requires a services image with the OpenSearch writer and the indexer role's Locker grant.
- Provided by: operator
- Values: `searchIndexer.*`
- Env: `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `LOCKER_BUCKET`, `LOCKER_REGION`, `LOCKER_ENDPOINT`, `SEARCH_INDEX_OPENSEARCH_URL`, `SEARCH_INDEX_OPENSEARCH_AUTH`, `SEARCH_INDEX_OPENSEARCH_AWS_REGION`, `SEARCH_INDEX_OPENSEARCH_INDEX_PREFIX`, `WORKER_HEALTH_PORT`
- Secret: `<search indexer configuration Secret>` (default), `search-indexer-runtime` (aws-rds-native) from `searchIndexer.config.existingSecret`; keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` from `searchIndexer.config.key`
- Secret: `<search indexer bootstrap Secret>` (default), `search-indexer-owner` (aws-rds-native) from `searchIndexer.bootstrap.existingSecret`; keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` from `searchIndexer.bootstrap.key`
- Verify: default: Leave disabled until the image and the role grants land; render tests prove plumbing only. / aws-rds-native: With the exact qualified release image, verify indexer consumer ticks and search hits through the read API; render tests prove plumbing only.
- Sources: [`charts/sessions-pipeline/templates/search-indexer.yaml:1`](../charts/sessions-pipeline/templates/search-indexer.yaml#L1), [`charts/sessions-pipeline/values.yaml:1`](../charts/sessions-pipeline/values.yaml#L1)

#### opt.sessions-output-facts

<a id="opt-sessions-output-facts"></a>

**Self-host output facts writer and bootstrap Job** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

searchIndexer.outputFacts.enabled and nativeConsumer.outputFacts.enabled
(strict booleans, default false) render RELAYHISTORY_SELFHOST_OUTPUT_FACTS=true
on the runtime consumer, so every indexing pass also writes the session's
commit, branch and file facts to Postgres (migration
20261105045040_selfhost_output_facts) in the directory-events transaction.
Those facts feed GET /v1/sessions/output, the daily digest and coordination
overlaps. The migration grants the four writer functions to
search_consumer_runtime, so no extra role or grant is needed.
searchIndexer.outputFacts.bootstrap.enabled (default false; requires
outputFacts.enabled and searchIndexer.bootstrap.existingSecret) renders a
hook-free Job, SERVICE=session-pipeline-output-facts-bootstrap, as the
schema owner. It queues sessions that owe facts for the running indexer,
waits up to deadlineSeconds, then writes the per-workspace coverage
watermark the read API needs (until then a workspace's windows answer 501
*_backfill_incomplete). It marks only workspaces that already have
sessions, so it runs after the first sessions of a workspace arrive and
again, with a new runId, for later workspaces. The Job name is a hash of its
spec and runId, so a reapply never reruns it. The aws-rds-native profile
enables the writer; the Job stays an operator step.

- Default: `disabled` (by profile: default `disabled`, aws-rds-native `enabled`)
- Choices: `disabled`; `enabled`: Requires a services image with migration 20261105045040 applied.
- Provided by: operator
- Values: `searchIndexer.outputFacts.enabled`, `searchIndexer.outputFacts.bootstrap.*`, `nativeConsumer.outputFacts.enabled`
- Env: `RELAYHISTORY_SELFHOST_OUTPUT_FACTS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_DEADLINE_SECONDS`, `RELAYHISTORY_SELFHOST_OUTPUT_FACTS_BOOTSTRAP_ALLOW_PARTIAL`
- Verify: default: Render no output facts binding by default; refuse non-booleans, the Job without the writer or the owner Secret, and invalid runId or deadlines. / aws-rds-native: With the exact qualified release image, verify the indexer writes facts and, after the bootstrap Job exits 0, that output_facts_coverage_for reports complete_since for the workspace; render tests prove plumbing only.
- Sources: [`charts/sessions-pipeline/templates/search-indexer.yaml:1`](../charts/sessions-pipeline/templates/search-indexer.yaml#L1), [`charts/sessions-pipeline/templates/_native-consumer.tpl:1`](../charts/sessions-pipeline/templates/_native-consumer.tpl#L1), [`charts/sessions-pipeline/values.yaml:1`](../charts/sessions-pipeline/values.yaml#L1), [`charts/sessions-pipeline/README.md:1`](../charts/sessions-pipeline/README.md#L1)

#### opt.sessions-read-api.output-digest

<a id="opt-sessions-read-api-output-digest"></a>

**Session read API Output and daily digest routes** · shipped · chart `session-read-api` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, aws-rds-native, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql

output.enabled and digest.enabled (strict booleans, default false) render
READ_API_OUTPUT_ENABLED=1 / READ_API_DIGEST_ENABLED=1 with the managed
READ_API_OUTPUT_BACKEND=postgres / READ_API_DIGEST_BACKEND=postgres, serving
GET /v1/sessions/output and GET /v1/digest/daily from the Postgres output
facts through the reader role. They need a facts writer (sessions-pipeline
outputFacts) and the output facts bootstrap watermark. digest.narrative.model
defaults to unset: no model call is made and no session content leaves the
cluster; a narrative cache miss is a 200 with provider_not_configured.
Setting the model requires digest.narrative.apiKey (OPENAI_API_KEY) and
digest.narrative.writerDatabaseUrl (the bulls96_digest_narrative login,
READ_API_DIGEST_NARRATIVE_DB_URL) Secret references; baseUrl sets
OPENAI_BASE_URL. All these names are reserved from extraEnv. The
aws-rds-native profile enables both routes with no model.

- Default: `disabled` (by profile: default `disabled`, aws-rds-native `enabled`)
- Choices: `disabled`; `enabled`: Requires the output facts writer and a services image with migration 20261105045040.
- Provided by: operator
- Values: `output.enabled`, `digest.enabled`, `digest.narrative.*`
- Env: `READ_API_OUTPUT_ENABLED`, `READ_API_OUTPUT_BACKEND`, `READ_API_DIGEST_ENABLED`, `READ_API_DIGEST_BACKEND`, `READ_API_DIGEST_NARRATIVE_MODEL`, `READ_API_DIGEST_NARRATIVE_DB_URL`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`
- Secret: `<digest narrative model API key Secret, model only>` from `sessionReadApi.digest.narrative.apiKey.existingSecret` then `session-read-api:digest.narrative.apiKey.existingSecret`; keys `OPENAI_API_KEY` from `session-read-api:digest.narrative.apiKey.key`
- Secret: `<digest narrative writer login Secret, model only>` from `sessionReadApi.digest.narrative.writerDatabaseUrl.existingSecret` then `session-read-api:digest.narrative.writerDatabaseUrl.existingSecret`; keys `READ_API_DIGEST_NARRATIVE_DB_URL` from `session-read-api:digest.narrative.writerDatabaseUrl.key`
- Verify: default: Render no output or digest binding by default; refuse non-booleans, a model without digest.enabled or its Secrets, and narrative Secrets without a model. / aws-rds-native: After the output facts bootstrap marks a workspace, GET /v1/sessions/output and /v1/digest/daily answer 200 for an authorized workspace token; render tests prove plumbing only.
- Sources: [`charts/session-read-api/templates/deployment.yaml:1`](../charts/session-read-api/templates/deployment.yaml#L1), [`charts/session-read-api/values.yaml:1`](../charts/session-read-api/values.yaml#L1), [`docs/self-hosted-session-read-api.md:1`](../docs/self-hosted-session-read-api.md#L1)

#### opt.control-legacy-relayauth

<a id="opt-control-legacy-relayauth"></a>

**Control legacy RelayAuth client environment** · shipped · chart `relay-control` · profiles relay-control, agent-relay

Keep services.relayauthEnabled true for the published legacy control
images. False omits RELAYAUTH_URL and RELAYAUTH_API_KEY_FILE and removes
the legacy key from the API Secret projection. It requires the approved
no-RelayAuth/caller-token control image; this changes no verifier code,
introspection logic or component enablement. Runtime flags are not changed
in the kind profiles. Introspection config uses existing extraEnv refs.

- Default: `true`
- Choices: `true`; `false`: Requires a compatible caller-token image.
- Provided by: operator
- Values: `services.relayauthEnabled`
- Env: `RELAYAUTH_URL`, `RELAYAUTH_API_KEY_FILE`
- Verify: Render the disabled legacy-client mode and confirm URL/key env and key projection are absent; runtime auth acceptance still requires compatible upstream source.
- Sources: [`charts/relay-control/templates/_helpers.tpl:1`](../charts/relay-control/templates/_helpers.tpl#L1), [`charts/relay-control/templates/deployment.yaml:1`](../charts/relay-control/templates/deployment.yaml#L1), [`docs/self-hosted-session-read-api.md:1`](../docs/self-hosted-session-read-api.md#L1)

#### opt.native-pipeline.analytics

<a id="opt-native-pipeline-analytics"></a>

**Native pipeline collector adapters** · shipped · chart `sessions-pipeline`, `session-read-api` · profiles agent-relay

Managed default-off analytics for native ingest, reader and consumer.
A qualified pipeline source71801741-or-later image sends closed business
events only to the private collector. Each service references an existing
distinct component-bound producer Secret; no token value or hosted key is
stored in Helm values. Optional public CA ConfigMaps add to OS trust.
The producer label is Pod-only; bootstrap/preflight receives no token.
Collector registrations and network admission remain operator-controlled.

- Default: `false`
- Choices: `false`; `true`: Requires per-component producer registration and verified collector TLS.
- Provided by: operator
- Values: `ingestEdge.analytics.*`, `nativeConsumer.analytics.*`, `session-read-api:analytics.*`
- Env: `ANALYTICS_SINK`, `ANALYTICS_DEPLOYMENT_ID`, `ANALYTICS_COLLECTOR_URL`, `ANALYTICS_COLLECTOR_TOKEN`, `NODE_EXTRA_CA_CERTS`
- Secret: `<ingest component-bound analytics producer Secret>` from `sessions-pipeline:ingestEdge.analytics.existingSecret`; keys `token` from `sessions-pipeline:ingestEdge.analytics.tokenKey`
- Secret: `<consumer component-bound analytics producer Secret>` from `sessions-pipeline:nativeConsumer.analytics.existingSecret`; keys `token` from `sessions-pipeline:nativeConsumer.analytics.tokenKey`
- Secret: `<reader component-bound analytics producer Secret>` from `session-read-api:analytics.existingSecret`; keys `token` from `session-read-api:analytics.tokenKey`
- Verify: Exercise real domain events from each selected service and inspect committed private collector files; verify component impersonation is refused and bootstrap/preflight contains no analytics token.
- Sources: [`charts/sessions-pipeline/templates/_analytics.tpl:1`](../charts/sessions-pipeline/templates/_analytics.tpl#L1), [`charts/session-read-api/templates/_analytics.tpl:1`](../charts/session-read-api/templates/_analytics.tpl#L1), [`charts/sessions-pipeline/ANALYTICS.md:1`](../charts/sessions-pipeline/ANALYTICS.md#L1)

#### opt.operator-session-erase

<a id="opt-operator-session-erase"></a>

**Operator session erase fences, API, and byte deletion** · shipped · chart `sessions-pipeline`, `session-read-api`, `relay-control` · profiles agent-relay

Default-off hard-delete composition for an approved 2026.11.2 Sessions
image. A shared permanent fence reaches every ingest, active consumer and
read-API replica. Byte deletion runs only in ingest and derives its S3 and
search targets from the canonical runtime configuration. The operator API
and Control handoff enable atomically and reference the same dedicated
32+ character Secret. Async/drain admission and direct upload fail closed.
No image is selected by these values and no credential is accepted inline.

- Default: `false`
- Choices: `false`; `true`: Requires an approved compatible image
- Provided by: operator
- Values: `global.operatorSessionErase.*`, `operatorSessionErase.*`, `session-read-api:global.operatorSessionErase.*`, `relay-control:sessionErasureApi.*`
- Env: `SESSION_ERASE_FENCE_ENFORCED`, `SESSION_ERASE_API_ENABLED`, `SESSION_ERASE_API_URL`, `SESSION_ERASE_API_SECRET`, `SESSION_ERASE_API_SECRET_PREVIOUS`, `SESSION_ERASE_BYTES_ENABLED`, `SESSION_ERASE_S3_BUCKET`, `SESSION_ERASE_S3_REGION`, `SESSION_ERASE_S3_ENDPOINT`, `SESSION_ERASE_KEY_ROOT`, `SESSION_ERASE_S3_ACCESS_KEY_ID`, `SESSION_ERASE_S3_SECRET_ACCESS_KEY`, `SESSION_ERASE_SEARCH_POSTGRES_URL`, `SESSION_ERASE_OPENSEARCH_USERNAME`, `SESSION_ERASE_OPENSEARCH_PASSWORD`
- Secret: `<dedicated operator session erase API Secret>` from `sessions-pipeline:operatorSessionErase.api.existingSecret` then `relay-control:sessionErasureApi.existingSecret`; keys `SESSION_ERASE_API_SECRET` from `sessions-pipeline:operatorSessionErase.api.secretKey`; `<operator-chosen previous API key>` from `sessions-pipeline:operatorSessionErase.api.previousSecretKey` (optional: true)
- Secret: `<dedicated session eraser S3 Secret>` from `sessions-pipeline:operatorSessionErase.bytes.s3Credentials.existingSecret`; keys `SESSION_ERASE_S3_ACCESS_KEY_ID` from `sessions-pipeline:operatorSessionErase.bytes.s3Credentials.accessKeyIdKey`; `SESSION_ERASE_S3_SECRET_ACCESS_KEY` from `sessions-pipeline:operatorSessionErase.bytes.s3Credentials.secretAccessKeyKey`
- Secret: `<dedicated session erase Postgres search Secret>` from `sessions-pipeline:operatorSessionErase.bytes.postgresSearch.existingSecret`; keys `SESSION_ERASE_SEARCH_POSTGRES_URL` from `sessions-pipeline:operatorSessionErase.bytes.postgresSearch.urlKey`
- Secret: `<dedicated session erase OpenSearch Secret>` from `sessions-pipeline:operatorSessionErase.bytes.opensearch.existingSecret`; keys `SESSION_ERASE_OPENSEARCH_USERNAME` from `sessions-pipeline:operatorSessionErase.bytes.opensearch.usernameKey`; `SESSION_ERASE_OPENSEARCH_PASSWORD` from `sessions-pipeline:operatorSessionErase.bytes.opensearch.passwordKey`
- Verify: Render default-off and full-on PostgreSQL/OpenSearch configurations; confirm only runtime replicas receive the fence, every credential is secretKeyRef-backed, and every fail-closed guard rejects unsafe composition.
- Sources: [`charts/sessions-pipeline/templates/_operator-session-erase.tpl:1`](../charts/sessions-pipeline/templates/_operator-session-erase.tpl#L1), [`charts/relay-control/templates/_runtime-adapters.tpl:1`](../charts/relay-control/templates/_runtime-adapters.tpl#L1), [`docs/operator-session-erase-upgrade.md:1`](../docs/operator-session-erase-upgrade.md#L1)

#### opt.relay-chief.image-pull-secrets

<a id="opt-relay-chief-image-pull-secrets"></a>

**Relay Chief image pull Secrets** · shipped · chart `relay-chief` · profiles relay-chief

Pull Secrets for a private registry or customer mirror.

- Default: `none`
- Choices: `none`; `listed`
- Provided by: operator
- Values: `imagePullSecrets`
- Verify: after setting suspend to false, the cycle's Job pulls its image without ImagePullBackOff
- Sources: [`charts/relay-chief/values.yaml:9`](../charts/relay-chief/values.yaml#L9), [`charts/relay-chief/templates/cronjob.yaml:34`](../charts/relay-chief/templates/cronjob.yaml#L34)

#### opt.relayfile-control.flows

<a id="opt-relayfile-control-flows"></a>

**Relayfile control Flows API** · shipped · chart `relayfile-control` · profiles relayfile-control

flows.enabled=true serves the Flows API. It requires config.publicOrigin (the token audience, also listed in relay-control's introspection.audiences), flows.encryptionKeyId, a Relaycast URL, and the Secret keys for the introspection secret, the broker secret and the 32-byte encryption key. The introspection and broker secrets must each be at least 32 bytes and differ; the broker secret is shared with relay-control. Telemetry and runtime-verify secrets are optional.

- Default: `false`
- Choices: `false`; `true`
- Provided by: operator
- Values: `flows.enabled`, `config.publicOrigin`, `flows.*`, `secretKeys.introspectSecret`, `secretKeys.brokerSecret`, `secretKeys.encryptionKey`, `secretKeys.previousEncryptionKey`, `secretKeys.telemetrySecret`, `secretKeys.runtimeVerifySecret`
- Env: `FLOWS_ENABLED`, `RELAYFILE_CONTROL_PUBLIC_ORIGIN`, `RELAYFILE_CONTROL_ENCRYPTION_KEY_ID`, `RELAYFILE_CONTROL_ENCRYPTION_PREVIOUS_KEY_ID`, `RELAYFILE_CONTROL_ENCRYPTION_KEY`, `RELAYFILE_CONTROL_ENCRYPTION_PREVIOUS_KEY`, `RELAYCONTROL_INTROSPECT_SECRET`, `RELAYFILE_CONTROL_BROKER_SECRET`, `RELAYFILE_CONTROL_TELEMETRY_SECRET`, `RELAYFILE_CONTROL_RUNTIME_VERIFY_SECRET`, `SELFHOST_FLOWS_WORKER_RELAYCAST_URL`, `RELAYCAST_PUBLIC_URL`, `SELFHOST_FLOWS_WORKER_RELAYFILE_URL`, `SELFHOST_DASHBOARD_URL`, `SELFHOST_FLOWS_STORAGE`, `FLOWS_PUBLIC_BASE_URL`
- Verify: helm template fails with "flows.enabled=true requires" when a Flows input is missing
- Sources: [`charts/relayfile-control/values.yaml`](../charts/relayfile-control/values.yaml), [`charts/relayfile-control/templates/configmap.yaml`](../charts/relayfile-control/templates/configmap.yaml), [`charts/relayfile-control/templates/_helpers.tpl`](../charts/relayfile-control/templates/_helpers.tpl)

#### opt.relayfile-control.webhooks

<a id="opt-relayfile-control-webhooks"></a>

**Relayfile control provider webhook secrets** · shipped · chart `relayfile-control` · profiles relayfile-control

Optional Secret keys for each provider ingress; comma lists allow rotation. An unset secret makes that ingress answer 503 ingress_not_configured.

- Default: `unset`
- Choices: `unset`; `set`
- Provided by: operator
- Values: `secretKeys.githubWebhookSecret`, `secretKeys.nangoWebhookSecret`, `secretKeys.hookdeckWebhookSecret`, `secretKeys.dropboxAppSecret`, `secretKeys.slackSigningSecret`, `secretKeys.linearWebhookSecret`
- Env: `GITHUB_WEBHOOK_SECRET`, `NANGO_WEBHOOK_SECRET`, `HOOKDECK_WEBHOOK_SECRET`, `DROPBOX_APP_SECRET`, `SLACK_SIGNING_SECRET`, `LINEAR_WEBHOOK_SECRET`
- Verify: an unset provider answers 503 ingress_not_configured; a set one verifies signatures
- Sources: [`charts/relayfile-control/values.yaml`](../charts/relayfile-control/values.yaml), [`charts/relayfile-control/templates/_helpers.tpl`](../charts/relayfile-control/templates/_helpers.tpl)

#### opt.relayfile-control.exposure

<a id="opt-relayfile-control-exposure"></a>

**Relayfile control Ingress and NetworkPolicy** · shipped · chart `relayfile-control` · profiles relayfile-control

ingress.enabled routes the Flows paths and their /cloud aliases to this Service and requires flows.enabled. On the shared EKS ALB use EKS_ALB_RELAYFILE_CONTROL=true with scripts/selfhost/eks-alb-ingress.sh instead. NetworkPolicy defaults on with restricted egress, so additionalEgress must admit the database.

- Default: `disabled`
- Choices: `disabled`; `enabled`
- Provided by: operator
- Values: `ingress.enabled`, `ingress.*`, `networkPolicy.*`, `service.annotations`
- Verify: helm template renders no Ingress by default; ingress.enabled without flows.enabled fails
- Sources: [`charts/relayfile-control/templates/ingress.yaml`](../charts/relayfile-control/templates/ingress.yaml), [`charts/relayfile-control/templates/networkpolicy.yaml`](../charts/relayfile-control/templates/networkpolicy.yaml), [`scripts/selfhost/eks-alb-ingress.sh`](../scripts/selfhost/eks-alb-ingress.sh)

#### opt.relayfile-control.image-pull-secrets

<a id="opt-relayfile-control-image-pull-secrets"></a>

**Relayfile control image pull Secrets** · shipped · chart `relayfile-control` · profiles relayfile-control

imagePullSecrets for a private registry mirror. Empty pulls the public image.

- Default: `none`
- Choices: `none`; `listed`
- Provided by: operator
- Values: `imagePullSecrets`
- Verify: helm template lists imagePullSecrets on the Deployment when set
- Sources: [`charts/relayfile-control/values.yaml`](../charts/relayfile-control/values.yaml), [`charts/relayfile-control/templates/deployment.yaml`](../charts/relayfile-control/templates/deployment.yaml)

#### opt.relaychief-control.nango

<a id="opt-relaychief-control-nango"></a>

**Relay Chief control Nango host and browser origins** · shipped · chart `relaychief-control` · profiles relaychief-control

NANGO_HOST with secretKeys.nangoSecretKey selects a self-hosted Nango; the key alone uses Nango's hosted API. NANGO_HOST without the key makes the server throw at startup, so the chart refuses to render it. RELAYCHIEF_CONTROL_BROWSER_ORIGINS is a comma-separated list of http(s) origins allowed through the CSRF check.

- Default: `unset`
- Choices: `unset`; `hosted`; `self-hosted`
- Provided by: operator
- Values: `config.nangoHost`, `config.browserOrigins`
- Env: `NANGO_HOST`, `NANGO_SECRET_KEY`, `RELAYCHIEF_CONTROL_BROWSER_ORIGINS`
- Verify: helm template fails with "requires secretKeys.nangoSecretKey" when config.nangoHost is set without the key
- Sources: [`charts/relaychief-control/values.yaml`](../charts/relaychief-control/values.yaml), [`charts/relaychief-control/templates/_helpers.tpl`](../charts/relaychief-control/templates/_helpers.tpl)

#### opt.relaychief-control.relay-identity

<a id="opt-relaychief-control-relay-identity"></a>

**Relay Chief control platform-issued Relay identities** · shipped · chart `relaychief-control` · profiles relaychief-control

With all three Secret keys set, binding a chief without relayCallerId registers it as a Relay agent through relay-control and stores its token encrypted with AES-256-GCM; unset, that bind answers 503. RELAYCHIEF_CONTROL_RELAY_SECRET (32 or more characters) must equal the value relay-control reads for chief registration, RELAYCHIEF_CONTROL_ENCRYPTION_KEY_ID is 1-64 characters of [A-Za-z0-9_-], and RELAYCHIEF_CONTROL_ENCRYPTION_KEY is 64 hex characters. The server refuses to start with only some of them, so the chart refuses to render a partial set; a render cannot check their contents. Needs an image built from relaychief-control PR 5 or later, whose migration 0003 the existing migrate Job applies.

- Default: `unset`
- Choices: `unset`; `set`
- Provided by: operator
- Values: `secretKeys.relaySecret`, `secretKeys.encryptionKeyId`, `secretKeys.encryptionKey`
- Env: `RELAYCHIEF_CONTROL_RELAY_SECRET`, `RELAYCHIEF_CONTROL_ENCRYPTION_KEY_ID`, `RELAYCHIEF_CONTROL_ENCRYPTION_KEY`
- Verify: helm template fails with "must be set together or not at all" when only some of the three are set; with all three, the Deployment (not the migrate Job) reads each from existingSecret
- Sources: [`charts/relaychief-control/values.yaml`](../charts/relaychief-control/values.yaml), [`charts/relaychief-control/templates/_helpers.tpl`](../charts/relaychief-control/templates/_helpers.tpl)

#### opt.relaychief-control.exposure

<a id="opt-relaychief-control-exposure"></a>

**Relay Chief control Ingress and NetworkPolicy** · shipped · chart `relaychief-control` · profiles relaychief-control

The Ingress is off by default and routes only /chief/v1 (Prefix) when on. ingress.extraPaths can add the tenant routes under /api/v1; a / rule is refused. networkPolicy.ingressFrom must admit the load balancer (an ALB in IP target mode connects from its subnets, as ipBlock peers), and networkPolicy.additionalEgress must admit the database unless allowAllEgress is true.

- Default: `disabled`
- Choices: `disabled`; `enabled`
- Provided by: operator
- Values: `ingress.*`, `networkPolicy.*`
- Verify: kubectl get ingress shows only the /chief/v1 path unless ingress.extraPaths adds more, and the load balancer's targets report healthy
- Sources: [`charts/relaychief-control/templates/ingress.yaml`](../charts/relaychief-control/templates/ingress.yaml), [`charts/relaychief-control/templates/networkpolicy.yaml`](../charts/relaychief-control/templates/networkpolicy.yaml)

#### opt.relaychief-control.image-pull-secrets

<a id="opt-relaychief-control-image-pull-secrets"></a>

**Relay Chief control image pull Secrets** · shipped · chart `relaychief-control` · profiles relaychief-control

Pull Secrets for a private registry or customer mirror.

- Default: `none`
- Choices: `none`; `listed`
- Provided by: operator
- Values: `imagePullSecrets`
- Verify: the Deployment and migrate Job pull their image without ImagePullBackOff
- Sources: [`charts/relaychief-control/values.yaml`](../charts/relaychief-control/values.yaml), [`charts/relaychief-control/templates/deployment.yaml`](../charts/relaychief-control/templates/deployment.yaml)

#### opt.sessions-native-ingest-claim-lock-busy

<a id="opt-sessions-native-ingest-claim-lock-busy"></a>

**Native ingest claim lock retry response** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql, aws-rds-native

Maps claim-stage lock waits to 429 delivery_busy with Retry-After 5-10s,
instead of 503. Requires a qualified services image containing pipeline
#484; older images can ignore the variable. Does not remove SQL from
synchronous uploads, enable async admission or change consumer backoff.
Statement timeouts and other database failures remain 503.

- Default: `true` (by profile: default `true`, aws-rds-native `true`)
- Choices: `true`: Emit on for a qualified native ingest image.; `false`: Omit the variable and keep the runtime default.
- Provided by: operator
- Values: `ingestEdge.claimLockBusy`
- Env: `INGEST_CLAIM_LOCK_BUSY`
- Verify: Prove claim lock contention returns 429 with an integer Retry-After in 5-10s on the qualified image; statement timeout stays 503 and async admission backoff is unchanged. Rendering alone does not prove support.
- Sources: [`charts/sessions-pipeline/values.yaml:1`](../charts/sessions-pipeline/values.yaml#L1), [`charts/sessions-pipeline/templates/ingest-edge.yaml:1`](../charts/sessions-pipeline/templates/ingest-edge.yaml#L1), [`docs/self-hosted-native-ingest.md:1`](../docs/self-hosted-native-ingest.md#L1)

#### opt.sessions-native-ingest-admission

<a id="opt-sessions-native-ingest-admission"></a>

**Native ingest admission mode** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql, aws-rds-native

Chart configuration for pipeline #398, merged at
f0860b2e785b52fefbaa37482d02ab96b013049d. A separately qualified image
containing that merge or a reviewed successor is required. Sync is
the unchanged default. Async acknowledges a durable create-only inbox
write, then admits to PostgreSQL in the background. Drain accepts new
uploads synchronously while consuming the existing inbox. Control
introspection remains per request; startup still verifies PostgreSQL.
Async/drain probes require the exact mode and healthy consumer counters;
an older image ignoring the setting fails readiness. No profile opts in.

- Default: `sync` (by profile: default `sync`, aws-rds-native `sync`)
- Choices: `sync`: Existing synchronous upload admission; emits no new mode variables.; `async`: Requires a qualified conditional-write store and native async image. Queued is not indexed.; `drain`: Keep the consumer running while new uploads use synchronous admission.
- Provided by: operator
- Values: `ingestEdge.admission.mode`, `ingestEdge.admission.concurrency`, `ingestEdge.admission.scanIntervalMs`, `ingestEdge.admission.maxAttempts`
- Env: `SELFHOST_INGEST_ADMISSION`, `SELFHOST_ADMISSION_CONCURRENCY`, `SELFHOST_ADMISSION_SCAN_MS`, `SELFHOST_ADMISSION_MAX_ATTEMPTS`
- Verify: Prove durable queued receipt during admission database failure after startup, restart/retry recovery, dead-letter visibility and eventual indexed readback with the exact image. Rendering and readiness do not establish end-to-end acceptance.
- Sources: [`charts/sessions-pipeline/templates/ingest-edge.yaml:1`](../charts/sessions-pipeline/templates/ingest-edge.yaml#L1), [`charts/sessions-pipeline/templates/_ingest-edge.tpl:1`](../charts/sessions-pipeline/templates/_ingest-edge.tpl#L1), [`charts/sessions-pipeline/values.yaml:1`](../charts/sessions-pipeline/values.yaml#L1), [`docs/self-hosted-native-ingest.md:1`](../docs/self-hosted-native-ingest.md#L1)

#### opt.sessions-native-consumer

<a id="opt-sessions-native-consumer"></a>

**Default-off native canonical pointer and search consumer** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, aws-cnpg

SERVICE=session-pipeline-consumer from merged pipeline 336. Requires a
qualified immutable composed image, a dedicated runtime JSON Secret, explicit
PostgreSQL target and pinned public custom CA, S3/MinIO static Secret or
Pod Identity, typed backend/floor/bare root, and a drained disabled old
hoopdb-indexer. Old migrator Job must be disabled after an external official
driver plus zero-step rerun. Active legacy workers/ingest must match the
immutable image and CA references and carry operator strict-URL/TLS/generation
qualification; otherwise stop them. One replica with Recreate. The bounded init contract checks
both actual pool TLS transports, database/login, source role/schema/policy
admission and exact generation/PASS. Opaque URLs must use verify-full plus
the managed CA path; helper-pool trust alone is insufficient.
Optional owner bootstrap uses a different Job-only JSON Secret and the
official SERVICE; no SQL grants are fabricated. Phase prepare renders
Job/contract only; serve is selected after completion and password setup.
No default image digest, install-profile enablement, public Service, hosted
fanout, buffered/publication/GC activation or deletion/privacy acceptance.

- Default: `disabled`
- Choices: `disabled`; `enabled`: Requires qualified image/generation and a drained canonical pilot plan.
- Provided by: operator
- Values: `nativeConsumer.*`
- Env: `SERVICE`, `RELAYHISTORY_SELFHOST_PIPELINE_CONSUMER`, `RELAYHISTORY_PIPELINE_CONSUMER_SECRET`, `HOOPDB_DB_MODE`, `SEARCH_INDEX_BACKEND`, `SEARCH_INDEX_POSTGRES_BACKEND_ID`, `READ_API_COMPLETE_SINCE`, `PIPELINE_RUNTIME`, `PIPELINE_FANOUT`, `PIPELINE_KEY_PREFIX`, `PIPELINE_ORG_FROM_PREFIX`, `CONSUMER_RECONCILE_EVERY_MINUTES`, `PIPELINE_RECONCILE_LOOKBACK_MINUTES`, `SESSION_POSTGRES_TLS_PROFILE`, `SESSION_POSTGRES_CA_FILE`, `SESSION_POSTGRES_CA_SHA256`, `ALLOW_IN_CLUSTER_HTTP`, `WORKER_HEALTH_PORT`, `CONSUMER_UNHEALTHY_FILE`, `LOCKER_PROVIDER`, `LOCKER_BUCKET`, `LOCKER_ENDPOINT`, `LOCKER_REGION`, `LOCKER_ACCESS_KEY_ID`, `LOCKER_SECRET_ACCESS_KEY`, `NATIVE_CONSUMER_CA_SOURCE_FILE`, `NATIVE_CONSUMER_PREFLIGHT_MODE`, `NATIVE_CONSUMER_EXPECTED_ROLE`, `NATIVE_CONSUMER_EXPECTED_DATABASE`, `NATIVE_CONSUMER_EXPECTED_HOST`, `NATIVE_CONSUMER_EXPECTED_PORT`, `NATIVE_CONSUMER_PREFLIGHT_TIMEOUT_SECONDS`
- Secret: `<native consumer runtime JSON Secret>` from `nativeConsumer.config.existingSecret`; keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` from `nativeConsumer.config.key`
- Secret: `<native consumer Job-only owner JSON Secret>` from `nativeConsumer.bootstrap.existingSecret`; keys `RELAYHISTORY_PIPELINE_CONSUMER_SECRET` from `nativeConsumer.bootstrap.key`
- Secret: `<native consumer S3 static Secret, secret mode only>` from `nativeConsumer.locker.existingSecret`; keys `access-key-id` from `nativeConsumer.locker.accessKeyIdKey`; `secret-access-key` from `nativeConsumer.locker.secretAccessKeyKey`
- Verify: Leave off until exact source/image/generation, official bootstrap and native PG/TLS/MinIO upload-to-pointer-to-dashboard proof pass. Render and probe tests alone are not runtime acceptance.
- Sources: [`charts/sessions-pipeline/templates/native-consumer.yaml:1`](../charts/sessions-pipeline/templates/native-consumer.yaml#L1), [`charts/sessions-pipeline/templates/native-consumer-bootstrap.yaml:1`](../charts/sessions-pipeline/templates/native-consumer-bootstrap.yaml#L1), [`charts/sessions-pipeline/templates/_native-consumer.tpl:1`](../charts/sessions-pipeline/templates/_native-consumer.tpl#L1), [`docs/self-hosted-native-consumer.md:1`](../docs/self-hosted-native-consumer.md#L1)

#### opt.relay-control.selected-features

<a id="opt-relay-control-selected-features"></a>

**Explicit optional Control features** · shipped · chart `relay-control` · profiles relay-control

selectedFeatures=null preserves the existing extraEnv/default selection.
A managed list selects only flows, relayfile, chief, usage, launch and usage_people; [] explicitly
serves core only. usage serves the owner-only Usage page (counts only).
While it is off Control keeps no active-user or search counters; session
and summary counts come from the session directory, which records
sessions either way. usage needs a Control image with the usage API and a
relay-webapp image with the Usage page. No license, customer metadata or
entitlement is used. launch serves agent launch tools on the shared-sessions
MCP endpoint (owners/admins on a person connection, onto this workspace's
own claimed nodes) and needs relay-control 0.5.14 or later.
usage_people serves the owner-only per-member Usage drill-down (member
names, emails and recorded session summaries; every view is audited) and
needs relay-control 0.5.17 or later and a relay-webapp image with the
People view (relay-webapp be85edc or later). With selectedFeatures=null and no
SELFHOST_FEATURES in extraEnv, such images select usage and usage_people
by default.
Managed selection reserves SELFHOST_FEATURES against duplicate extraEnv.

- Default: (no default)
- Choices: (no default); `[]`: Core only; `["flows","relayfile","chief"]`; `["usage"]`: Owner-only Usage page; `["launch"]`: MCP agent launch; `["usage","usage_people"]`: Usage page with the per-member drill-down
- Provided by: operator
- Values: `selectedFeatures`
- Env: `SELFHOST_FEATURES`
- Verify: Render explicit core with an empty SELFHOST_FEATURES and refuse unknown names, duplicates and duplicate extraEnv.
- Sources: [`charts/relay-control/templates/deployment.yaml`](../charts/relay-control/templates/deployment.yaml), [`charts/relay-control/templates/_helpers.tpl`](../charts/relay-control/templates/_helpers.tpl)

#### opt.relay-control.direct-native-reader

<a id="opt-relay-control-direct-native-reader"></a>

**Existing caller-token native reader connection** · shipped · chart `relay-control` · profiles relay-control

Separate compatibility mode for a Control-only reader. Off by default.
Uses the caller's existing Control bearer, exact public HTTPS origin,
managed introspection secret/audience and optional scoped IP mapping.
The independent native backend refuses this direct-reader selection.
The API-only relayhistoryHostAliases mapping also supports native mode,
where its sole hostname must match sessionReadApiPublicUrl and the
private sessionReadApiUrl issuer handoff remains unchanged.

- Default: `disabled`
- Choices: `disabled`; `enabled`
- Provided by: operator
- Values: `services.relayhistoryReadApiUrl`, `services.relayhistoryReadApiEvents`, `services.relayhistoryHostAliases`
- Env: `RELAYHISTORY_READ_API_URL`, `RELAYHISTORY_READ_API_EVENTS`
- Verify: Render no direct-reader env by default; preserve exact origin/port and reject authority mixing.
- Sources: [`charts/relay-control/templates/_history-connection.tpl`](../charts/relay-control/templates/_history-connection.tpl)

#### opt.relay-webapp.collector-analytics

<a id="opt-relay-webapp-collector-analytics"></a>

**Dashboard collector analytics runtime selection** · shipped · chart `relay-webapp` · profiles relay-webapp

Null preserves the image default. Explicit true or false controls the
compatible dashboard image's browser analytics through Control's collector
proxy. Control's adapter and private collector must be configured separately;
the dashboard receives no collector credentials or hosted exporter settings.

- Default: (no default)
- Choices: (no default); `true`; `false`
- Provided by: operator
- Values: `runtime.analyticsEnabled`
- Env: `DASHBOARD_ANALYTICS_ENABLED`
- Verify: Render no env for null and quoted true/false for explicit booleans; refuse other types and verify the compatible image uses Control's proxy.
- Sources: [`charts/relay-webapp/templates/deployment.yaml`](../charts/relay-webapp/templates/deployment.yaml), [`charts/relay-webapp/values.yaml`](../charts/relay-webapp/values.yaml)

#### opt.relay-webapp.coordination-overlaps

<a id="opt-relay-webapp-coordination-overlaps"></a>

**Dashboard coordination-overlaps view** · shipped · chart `relay-webapp` · profiles relay-webapp

Strict boolean, default false. True shows the coordination-overlaps view
in a compatible #124 dashboard image; false omits the environment binding
and the image keeps the view off. The session read API and its separately
managed Postgres coordination-overlaps backend must also be available.

- Default: `false`
- Choices: `false`; `true`
- Provided by: operator
- Values: `runtime.coordinationOverlapsEnabled`
- Env: `DASHBOARD_COORDINATION_OVERLAPS_ENABLED`
- Verify: Render no environment binding by default or for false; refuse non-booleans and true without runtime.sessionReadApiEnabled; render both quoted true bindings when selected; verify the compatible image makes no overlap request while off.
- Sources: [`charts/relay-webapp/templates/deployment.yaml`](../charts/relay-webapp/templates/deployment.yaml), [`charts/relay-webapp/values.yaml`](../charts/relay-webapp/values.yaml), [`charts/relay-webapp/README.md`](../charts/relay-webapp/README.md)

#### opt.sessions-pipeline.native-routing

<a id="opt-sessions-pipeline-native-routing"></a>

**Native History public route** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, external-selfhosted

Default-off managed Ingress selecting the native reader and ingest edge
on one exact public origin. Independent issuer mode exposes only /v1,
never /internal. Both reader modes route the exact upload token refresh
path to the ingest edge so Desktop can renew from Control. Source ownership
and compatible image qualification are needed
before local fixture preparation; no manual resource is auto-adopted.

- Default: `disabled`
- Choices: `disabled`; `enabled`
- Provided by: operator
- Values: `nativeRouting.*`
- Secret: `<existing public History TLS Secret>` from `nativeRouting.tls` then `nativeRouting.tls.existingSecret`
- Verify: Render only qualified exact paths and Service ports; reject missing TLS/origin, mixed authorities and public internal issuer exposure.
- Sources: [`charts/sessions-pipeline/templates/native-routing.yaml`](../charts/sessions-pipeline/templates/native-routing.yaml), [`charts/sessions-pipeline/templates/_native-routing.tpl`](../charts/sessions-pipeline/templates/_native-routing.tpl)

#### opt.legacy-deployment-retirement

<a id="opt-legacy-deployment-retirement"></a>

**Retire a legacy Deployment while retaining resources** · shipped · chart `relayauth`, `session-ingest-api` · profiles relayauth, agent-relay, selfhost-postgres, external-selfhosted, external-rds, aws-rds-native

Omit only the legacy auth or ingest Deployment after a verified replacement and drain. Services, PVCs and all other resources remain managed. This does not switch routing, migrate data or qualify a replacement.

- Default: `true` (by profile: default `true`, aws-rds-native `false`)
- Choices: `true`; `false`: Requires a verified replacement
- Provided by: operator
- Values: `deployment.enabled`
- Verify: Render both modes and compare all non-Deployment objects exactly. Preserve retained PVC and Service identities during the reviewed upgrade.
- Sources: [`charts/relayauth/values.yaml:7`](../charts/relayauth/values.yaml#L7), [`charts/session-ingest-api/values.yaml:78`](../charts/session-ingest-api/values.yaml#L78), [`ci/agent-relay/test_retained_workloads.py:1`](../ci/agent-relay/test_retained_workloads.py#L1)

#### opt.history-direct-upload-issuer

<a id="opt-history-direct-upload-issuer"></a>

**Direct S3 upload credential issuer** · shipped · chart `relay-control` · profiles relay-control

Default-off relay-upload-inbox-v1 credential issuance. Requires a published
Control image containing #90 for AWS or #94 for S3-compatible stores, and
a matching native upload consumer before enablement. AWS requires a scoped
upload role and customer KMS key. S3-compatible stores require a public TLS
endpoint and dedicated upload-scoped issuer credential files, with optional
KMS and a private journal-read endpoint. Never use the MinIO root user.
Witness key is a shared existing Secret, never inline or sent to Desktop.
MinIO requires the amended nullable-KMS contract and compatible Desktop.

- Default: `off`
- Choices: `off`; `allowlist`; `on`
- Provided by: operator
- Values: `historyUpload.*`
- Env: `SELFHOST_HISTORY_UPLOAD_DIRECT`, `SELFHOST_HISTORY_UPLOAD_ALLOWLIST`, `SELFHOST_HISTORY_UPLOAD_BUCKET`, `SELFHOST_HISTORY_UPLOAD_REGION`, `SELFHOST_HISTORY_UPLOAD_KEY_ROOT`, `SELFHOST_HISTORY_UPLOAD_ROLE_ARN`, `SELFHOST_HISTORY_UPLOAD_KMS_KEY_ARN`, `SELFHOST_HISTORY_UPLOAD_MAX_OBJECT_BYTES`, `SELFHOST_HISTORY_UPLOAD_WITNESS_KEY_FILE`, `SELFHOST_HISTORY_UPLOAD_PUBLIC_ENDPOINT`, `SELFHOST_HISTORY_UPLOAD_INTERNAL_ENDPOINT`, `SELFHOST_HISTORY_UPLOAD_ACCESS_KEY_ID_FILE`, `SELFHOST_HISTORY_UPLOAD_SECRET_ACCESS_KEY_FILE`
- Secret: `<operator-chosen shared upload witness Secret>` from `historyUpload.witness.existingSecret`; keys `upload-witness-key` from `historyUpload.witness.key`
- Secret: `<operator-chosen dedicated compatible-store issuer Secret>` from `historyUpload.credentials.existingSecret`; keys `access-key-id` from `historyUpload.credentials.accessKeyIdKey`; `secret-access-key` from `historyUpload.credentials.secretAccessKeyKey`
- Verify: Prove per-user write-only STS scope, durable PUT with SQL unavailable, async admission and searchable readback with exact published artifacts. Local source tests do not establish live runtime qualification.
- Sources: [`charts/relay-control/templates/_history-upload.tpl:1`](../charts/relay-control/templates/_history-upload.tpl#L1), [`docs/selfhost-direct-uploads.md:1`](../docs/selfhost-direct-uploads.md#L1)

#### opt.history-direct-upload-consumer

<a id="opt-history-direct-upload-consumer"></a>

**Native direct upload inbox scan** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql, aws-rds-native

Default-off native upload-inbox scan and status handling from pipeline #515.
Requires a compatible published image, S3-compatible store, matching issuer
witness Secret and async admission. Consumer allowlist entries are org:/ws:
segments; Control allowlists are user IDs. SQL admission is asynchronous.

- Default: `off`
- Choices: `off`; `allowlist`; `on`
- Provided by: operator
- Values: `ingestEdge.uploadDirect.*`, `ingestEdge.keyRoot`, `ingestEdge.createServiceAccount`
- Env: `HISTORY_UPLOAD_DIRECT`, `HISTORY_UPLOAD_DIRECT_ALLOWLIST`, `SELFHOST_UPLOAD_SCAN_BATCH`, `UPLOAD_WITNESS_KEY`
- Secret: `<operator-chosen shared upload witness Secret>` from `ingestEdge.uploadDirect.witness.existingSecret`; keys `upload-witness-key` from `ingestEdge.uploadDirect.witness.key`
- Verify: Prove PUT, admission polling, witness refusal, restart/retry and indexed readback. Keep the scanner running while pending uploads drain during rollback.
- Sources: [`charts/sessions-pipeline/templates/ingest-edge.yaml:1`](../charts/sessions-pipeline/templates/ingest-edge.yaml#L1), [`docs/selfhost-direct-uploads.md:1`](../docs/selfhost-direct-uploads.md#L1)

#### opt.sessions-pipeline-s3-ledger

<a id="opt-sessions-pipeline-s3-ledger"></a>

**S3 upload ledger for the native ingest (decision 0005)** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql, aws-rds-native

Default sql renders nothing. s3 renders INGEST_LEDGER=s3 on the ingest edge
only: every admission path claims and commits through the S3 ledger, and no
org is admitted until an operator writes its fence-authority marker. Render
fails, as the binary does at startup, when s3 is combined with
ingestEdge.sessionSelection or the operator session erase. The database
stays required (controls mirror deletions to SQL).

- Default: `sql`
- Choices: `sql`; `s3`: Requires a services image from pipeline 8b2430c7 or later and the README "S3 upload ledger" operator steps.
- Provided by: operator
- Values: `ingestEdge.ledger`
- Env: `INGEST_LEDGER`
- Verify: Render default sql byte-identical; render s3 and confirm INGEST_LEDGER only on the ingest edge; confirm the sessionSelection and operator erase refusals.
- Sources: [`charts/sessions-pipeline/templates/_ingest-edge.tpl:1`](../charts/sessions-pipeline/templates/_ingest-edge.tpl#L1), [`charts/sessions-pipeline/README.md:1`](../charts/sessions-pipeline/README.md#L1), [`ci/sessions-pipeline-s3-ledger/test_chart.py:1`](../ci/sessions-pipeline-s3-ledger/test_chart.py#L1)

#### opt.sessions-pipeline-rearm-sweeper

<a id="opt-sessions-pipeline-rearm-sweeper"></a>

**S3 ledger re-arm sweeper CronJob** · shipped · chart `sessions-pipeline` · profiles selfhost-postgres, migration, external-selfhosted, external-rds, external-supabase, aws-cnpg, aws-supabase, gcp-cloudsql, aws-rds-native

Default-off CronJob running one rearm-sweeper-main pass per tick
(concurrencyPolicy Forbid) with the ingest edge's image, bucket, region,
endpoint and key root. Requires ingestEdge.ledger=s3. Credentials are a
dedicated static S3 Secret mounted as files, or EKS Pod Identity
(INGEST_REARM_CREDENTIALS=podIdentity, its own serviceAccountName, no Secret;
needs a services image from pipeline 9be2ad8e or later). IRSA is refused.

- Default: `false`
- Choices: `false`; `true`: Requires ingestEdge.ledger=s3 and a dedicated sweeper credential or Pod Identity role (README "Re-arm sweeper IAM").
- Provided by: operator
- Values: `rearmSweeper.*`
- Env: `INGEST_REARM_SWEEPER_ENABLED`, `INGEST_REARM_BUCKET`, `INGEST_REARM_REGION`, `INGEST_REARM_ENDPOINT`, `INGEST_REARM_KEY_ROOT`, `INGEST_REARM_ORGS`, `INGEST_REARM_DRY_RUN`, `INGEST_REARM_CONCURRENCY`, `INGEST_REARM_MAX_MARKERS`, `INGEST_REARM_CREDENTIALS`, `INGEST_REARM_S3_ACCESS_KEY_ID_FILE`, `INGEST_REARM_S3_SECRET_ACCESS_KEY_FILE`
- Secret: `<dedicated re-arm sweeper S3 Secret>` from `rearmSweeper.credentials.existingSecret`; keys `access-key-id` from `rearmSweeper.credentials.accessKeyIdKey`; `secret-access-key` from `rearmSweeper.credentials.secretAccessKeyKey`
- Verify: Render default-off (no CronJob); render enabled and confirm the derived bucket and key root, Forbid, file-mounted keys and the refusals.
- Sources: [`charts/sessions-pipeline/templates/rearm-sweeper.yaml:1`](../charts/sessions-pipeline/templates/rearm-sweeper.yaml#L1), [`charts/sessions-pipeline/README.md:1`](../charts/sessions-pipeline/README.md#L1), [`ci/sessions-pipeline-s3-ledger/test_chart.py:1`](../ci/sessions-pipeline-s3-ledger/test_chart.py#L1)

## Pod plumbing env (not operator-facing)

Rendered by the charts but not a requirement or an option: fixed by the chart or derived from other values.

| env | chart | why |
| --- | --- | --- |
| `SEARCH_BOOTSTRAP_WAIT_FOR_RUNTIME_ROLE_LOGIN` | sessions-pipeline | Provider-profile switch that waits for the post-migration runtime LOGIN before search bootstrap; never a credential. |
| `SEARCH_BOOTSTRAP_RUNTIME_ROLE_WAIT_SECONDS` | sessions-pipeline | Bounded provider post-migration wait derived from searchIndexer.bootstrap.roleWaitSeconds; never a credential. |
| `SEARCH_BOOTSTRAP_RUNTIME_ROLE_POLL_SECONDS` | sessions-pipeline | Bounded provider post-migration poll interval derived from searchIndexer.bootstrap.rolePollSeconds; never a credential. |
| `SEARCH_BOOTSTRAP_CATALOG_RETRY_MAX_ATTEMPTS` | sessions-pipeline | Bounded same-Pod retry count derived from searchIndexer.bootstrap.catalogRetry.maxAttempts; never a credential. |
| `SEARCH_BOOTSTRAP_CATALOG_RETRY_DELAY_SECONDS` | sessions-pipeline | Bounded same-Pod retry delay derived from searchIndexer.bootstrap.catalogRetry.delaySeconds; never a credential. |
| `SSL_CERT_FILE` | sessions-pipeline-worker | Reserved and refused by native brief admission; not an operator setting or rendered credential override. |
| `SSL_CERT_DIR` | sessions-pipeline-worker | Reserved and refused by native brief admission; not an operator setting or rendered credential override. |
| `NODE_OPTIONS` | sessions-pipeline-worker | Reserved and refused by native brief admission; not an operator setting or rendered credential override. |
| `NODE_TLS_REJECT_UNAUTHORIZED` | sessions-pipeline-worker | Reserved and refused by native brief admission; not an operator setting or rendered credential override. |
| `NATIVE_BRIEF_CA_FILE` | sessions-pipeline-worker | Fixed verified CA output path for native brief init admission. |
| `NATIVE_BRIEF_CA_SOURCE` | sessions-pipeline-worker | Fixed read-only public CA source path for native brief init admission. |
| `NATIVE_BRIEF_CA_SHA256` | sessions-pipeline-worker | Derived from the explicit public CA digest; never a private key. |
| `LISTEN` | relayfile-control | derived from server.port; refused in extraEnv |
| `ADMIN_LISTEN` | relayfile-control | fixed at 127.0.0.1:3101 so the admin listener stays on loopback; refused in extraEnv |
| `MIGRATE_ON_START` | relayfile-control | fixed at 1 so the server applies migrations under its advisory lock; refused in extraEnv |
| `ADMIN_HOST` | relaychief-control | fixed at 127.0.0.1 so the admin listener stays on loopback; refused in extraEnv |
| `ADMIN_PORT` | relaychief-control | reserved from extraEnv so the admin listener stays on its documented port; no chart value offers it |
| `SERVICE` | sessions-pipeline-worker, session-ingest-api | selects the entry point of the one services image |
| `OTEL_SERVICE_NAME` | sessions-pipeline-worker, session-ingest-api | equals SERVICE |
| `TMPDIR` | sessions-pipeline-worker, session-ingest-api | the writable emptyDir under a read-only root filesystem |
| `HOME` | sessions-pipeline, sessions-pipeline-worker, relayflows | a writable home under a read-only root filesystem |
| `ROLES` | sessions-pipeline-worker | wait-for-role init container; derived from waitForRole.role and migrations.runtimeRole |
| `FUNCTION_DEFAULT` | sessions-pipeline-worker | wait-for-role init container; derived from waitForRole.functionDefault |
| `INTERVAL` | sessions-pipeline-worker | wait-for-role poll interval (waitForRole.intervalSeconds) |
| `CLUSTER` | sessions-pipeline | privileged SQL Jobs; the CNPG cluster name (bootstrapJob.cluster) |
| `DATABASE` | sessions-pipeline | privileged SQL Jobs; the HoopDb database (bootstrapJob.database) |
| `INGEST_PORT` | session-ingest-api | from ingest.port |
| `PORT` | relaycast, relayauth | from server.port |
| `RELAYCAST_DB_PATH` | relaycast | fixed /data/relaycast.db on the data PVC |
| `RELAYCAST_ENV` | relaycast | reserved name in the extraEnv guard; the environment is passed as --env (server.environment) |
| `RELAYCAST_INTERNAL_SECRET` | relaycast | reserved prefix in the extraEnv guard; the Secret is mounted as a file |
| `RELAYCAST_WORKSPACE_BOOTSTRAP_SECRET` | relaycast | reserved prefix in the extraEnv guard; the Secret is mounted as a file |
| `RELAYCAST_RELAYAUTH` | relaycast | reserved prefix in the extraEnv guard; the RelayAuth remote tagger is wired through credentials.relayauth.url and secretKeys.relayauthToken |
| `RELAYCAST_CREDENTIAL` | relaycast | reserved prefix in the extraEnv guard; the credential format and local keyring are wired through credentials.* and secretKeys.credentialKeyring |
| `RELAYCAST_TELEMETRY_` | relaycast | reserved prefix in extraEnv while the structured analytics binding is enabled |
| `MIGRATION_WAIT_SECONDS` | relaycast | postgres backend wait-for-migrations init container; from runtime.postgres.migrations.activeDeadlineSeconds |
| `RELAYCAST_DATABASE_` | relaycast | reserved prefix in the extraEnv guard on the sqlite and durable-actors backends |
| `RELAYCAST_DATABASE_URL` | relaycast | reserved name in the postgres extraEnv guard; the URL is mounted as a file |
| `RELAYCAST_DATABASE_CA_FILE` | relaycast | explicit DB CA when managed analytics uses NODE_EXTRA_CA_CERTS for the collector; otherwise the DB uses NODE_EXTRA_CA_CERTS |
| `RELAYCAST_DATABASE_SCHEMA` | relaycast | reserved name in the postgres extraEnv guard; left at the image default |
| `RELAYCAST_DATABASE_OWNER_ROLE` | relaycast | reserved name in the postgres extraEnv guard; left at the image default |
| `RELAYCAST_DATABASE_RUNTIME_ROLE` | relaycast | reserved name in the postgres extraEnv guard; left at the image default |
| `PGCLIENT_ENCODING` | relaycast | refused in the postgres extraEnv guard; the image exits 64 while it is set |
| `BACKUP_KEEP` | relaycast | backup CronJob; from backup.keep |
| `LOCK_STALE_MS` | relaycast | backup CronJob lock timeout (fixed) |
| `RELAYAUTH_DB_PATH` | relayauth | fixed path on the data PVC |
| `NPM_CONFIG_CACHE` | relayflows | runtime installer cache in an emptyDir |
| `PATH` | relayflows | puts the installed runtime CLIs first |
| `AGENT_RELAY_HOME` | relayflows | Cloud worker state on the PVC |
