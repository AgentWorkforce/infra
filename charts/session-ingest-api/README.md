# Session ingest API

This chart runs the legacy courier ingest Deployment. Secret inputs use
existing Kubernetes Secrets; the chart does not accept credential values.

`readerMaxRuleset` manages `READER_MAX_RULESET` for ingest manifest admission.
It defaults to `null` and omits the binding. Explicit `8`, `9`, or `10` opts
into strict marker and chunk checks; `extraEnv` and
`ingest.env` cannot override it. Raising the ceiling requires a qualified image
containing the reviewed #489 compatibility and binding fixes.
This is a reader ceiling only and does not change writer output.

Under the sessions-pipeline umbrella, prefer the shared
`global.scrubEngine` contract. Its reader ceiling applies to every Services
workload, and its strict phase-2 selection manages `SCRUB_ENGINE` and
`SCRUB_ENGINE_REQUIRED`. If both the legacy leaf value and shared ceiling are
set, they must be equal.

## Retaining resources after replacing the workload

`deployment.enabled` defaults to `true`. Set it to `false` only after the
replacement ingest path has been verified and the old Deployment drained.
This omits only the Deployment, retaining its Service and other chart
resources. Existing input validation still applies. Routing and stored data
are unchanged.

For an existing release, compare the full proposed render against the actual
running configuration before upgrading. Deleting a Deployment by hand while
Helm still renders it can recreate it on a later upgrade. Disabling an entire
dependency may also remove resources that should be retained.
