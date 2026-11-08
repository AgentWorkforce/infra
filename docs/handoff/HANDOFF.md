# Agent Relay self-hosted GCP handoff

Start with [STATUS.md](STATUS.md): what this release proves, what is preview,
and what is planned. Release notes: [RELEASE_NOTES.md](RELEASE_NOTES.md).

## Architecture

- [Architecture overview](../diagrams/agent-relay-architecture.png)
  ([SVG](../diagrams/agent-relay-architecture.svg), [source](../diagrams/agent-relay-architecture.mmd)):
  what the `agent-relay` umbrella deploys on GKE. Dashed borders mark preview
  components and the optional telemetry egress; Relayflows is opt-in and
  labelled so.
- [Request flow](../diagrams/agent-relay-request-flow.png)
  ([SVG](../diagrams/agent-relay-request-flow.svg), [source](../diagrams/agent-relay-request-flow.mmd)):
  Desktop sign-in and device approval, session upload, Dashboard read, and
  agent messaging.
- [Reference architecture](../self-hosted-reference-architecture.md) and the
  [detailed GKE shape](../diagrams/self-hosted-architecture.md).

## Deliverables

`scripts/package-customer-handoff.sh build` produces three files for one source
revision (`<rev12>` is the first 12 characters of the commit SHA):

- `agent-relay-customer-handoff-<rev12>.tar.gz`
- `agent-relay-customer-handoff-<rev12>.zip`: the same content as the tarball
- `SHA256SUMS`: checksums of the two archives

A build made with `--mode preview` is named
`agent-relay-customer-handoff-<rev12>-DEVELOPMENT-PREVIEW.*` and is not for
production or customer installation. An archive that also carries
`-INCOMPLETE` is missing required inputs and must not be used.

Both archives unpack to one `agent-relay-customer-handoff/` directory:

| Path | Contents |
| --- | --- |
| `charts/agent-relay/` | Umbrella chart source, with `values.yaml` and the structural `values-gcp.yaml` example |
| `charts/relaycast/`, `charts/relayauth/`, `charts/sessions-pipeline/`, `charts/sessions-pipeline-worker/`, `charts/session-ingest-api/`, `charts/relayhistory/`, `charts/relay-cloud-api/`, `charts/relay-dashboard/`, `charts/relayflows/`, `charts/durable-actors/`, `charts/relayfile/` | Leaf chart sources the umbrella depends on (Relayflows opt-in; durable-actors and Relayfile preview) |
| `.agents/skills/setting-up-self-hosted-agent-relay-gcp/` | Setup, safety, preflight, deployment, Desktop, pre-upgrade, and public-verification skill |
| `docs/` | Reference architecture, architecture and request-flow diagrams (`docs/diagrams/`), image supply chain, backup/restore runbook, conformance contract, and licenses |
| `scripts/selfhost/`, `scripts/release/`, `scripts/conformance/` | Read-only verification, pre-upgrade gate, release validator, conformance tests, and the end-to-end harness (`e2e-gcp-proof.sh`) |
| `docs/handoff/evidence/` | Sanitized summaries of the GKE end-to-end, upgrade and backup/restore runs, and the durable-actors preview proof |
| `docs/operations/`, `docs/support/`, `scripts/support/` | Operations contract (SLOs, capacity and load-test gates), support runbook, and the read-only support-bundle collector (`collect-support-bundle.py`) with its tests |
| `self-hosted/` | Customer image manifest and release evidence |
| `deps/`, `LICENSE`, `THIRD_PARTY_NOTICES.md` | Dependency pins and license notices |
| `RELEASE-MANIFEST.json` | Source revision, tree, release mode, production-gate status, and per-file SHA-256 |
| `SHA256SUMS` | Checksums of every file in the archive plus the manifest |

The charts ship as source, not as a packaged `.tgz`. Vendored dependency
archives are not included: run `helm dependency build` at install time (see
[`HUMAN_QUICKSTART.md`](HUMAN_QUICKSTART.md)).

## Verify

```bash
sha256sum -c SHA256SUMS            # macOS: shasum -a 256 -c SHA256SUMS
tar -xzf agent-relay-customer-handoff-<rev12>.tar.gz
cd agent-relay-customer-handoff
sha256sum -c SHA256SUMS
jq '{releaseMode, productionGate, source, incomplete}' RELEASE-MANIFEST.json
```

Require `releaseMode` to be `release`, `productionGate.status` to be `passed`,
and `incomplete` to be `false`. Anyone with a checkout of the source repository
can also run `scripts/package-customer-handoff.sh verify <directory>
--expect-revision <rev>` against the downloaded files.

## Verified behavior

An internal GCP proof environment, which is not part of this handoff,
demonstrated:

- all four workloads and both migration Jobs ready;
- idempotent Helm upgrade completed;
- two Relaycast agents exchanged a ping and reply;
- a 24-record native delivery batch received a durable receipt;
- an identical retry returned the same receipt;
- Dashboard API search returned three sessions and replay returned four events;
- all sessions and events remained readable after a RelayHistory restart.

## Customer use

Treat `charts/agent-relay/values-gcp.yaml` as a structural example, not
customer configuration. Follow the bundled skill to create a non-secret
customer overlay and replace every example domain, project, bucket, registry,
Secret reference, database role, and image digest.

This is a `portable-single` deployment, not an HA claim. The RelayHistory image
is an experimental build, and images in the internal proof registry are not a
customer distribution channel. Publish approved images to the customer's
authorized registry before installation.
