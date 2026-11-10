# Session ingest API

This chart runs the legacy courier ingest Deployment. Secret inputs use
existing Kubernetes Secrets; the chart does not accept credential values.

`readerMaxRuleset` manages `READER_MAX_RULESET` for ingest manifest admission.
It defaults to `8` and accepts only `8`, `9`, or `10`; `extraEnv` and
`ingest.env` cannot override it. Raising the ceiling requires a qualified image
containing relayhistory-pipeline #489 at `0ad0813c` or a reviewed successor.
This is a reader ceiling only and does not change writer output.

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
