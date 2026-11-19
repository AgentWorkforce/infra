# Redacted support bundles

For database login, Relaycast role/ownership/grant and failed-install checks,
run the [read-only installation diagnostic](diagnose-install.md). It supports
separate cluster and database VPN runs and produces a shareable JSON report.

`scripts/support/collect-support-bundle.py` creates a read-only support archive
for one Helm release. It does not mutate the cluster and does not collect raw
manifests, pod logs, response bodies, certificate bodies, Kubernetes Secrets,
database credentials, or database rows.

One exception to "no Secrets read": with Helm's default storage driver
(`HELM_DRIVER` unset, `secret`, or `secrets`), `helm status`, `helm get values`,
and `helm history` load the release record from its `sh.helm.release.v1`
Secret, which holds the rendered manifest and values. The collector never
requests a Secret itself and keeps only curated fields and a redacted
fingerprint, but the Secret is read. The bundle's `manifest.json` says so:
`secretResourcesRead: true`, `secretResourcesReadBy: ["helm-release-storage"]`,
and `helmStorageDriver`. The collector's identity therefore needs `list` on Secrets in the release
namespace: these commands read the latest release through Helm's release query,
which lists the release's Secrets by label, and the collector never asks for a
specific revision, so `get` on Secrets is not needed. Without `list` the Helm
sections are recorded in `collection-errors.json`. Grant that only to identities trusted
with the release's values.

## Usage

```sh
python3 scripts/support/collect-support-bundle.py \
  --namespace agent-relay \
  --release agent-relay \
  --output-dir ./support-output
```

Useful options:

- `--context NAME` selects a kubeconfig context.
- `--selector LABELS` overrides the default
  `app.kubernetes.io/instance=RELEASE` selector.
- `--health-url https://relay.example.com/health` adds an explicit backend
  health endpoint. It may be repeated. User information, queries, and
  fragments are rejected.
- `--skip-network` omits DNS, TLS, and HTTP checks.
- `--release-evidence FILE` adds a small allowlisted summary and SHA-256 of a
  release-evidence JSON file. The source file is never copied.
- `--max-backup-age-hours HOURS` controls the current/stale classification.

The command prints the archive and checksum paths. Verify a bundle with:

```sh
sha256sum --check support-bundle-RELEASE-TIMESTAMP.tar.gz.sha256
```

## Contents

The archive contains curated JSON documents:

- chart, application, image, and Helm release versions;
- a SHA-256 fingerprint of Helm values after sensitive fields are removed;
- deployment, stateful set, daemon set, and pod status;
- migration Job status as a Kubernetes-only ledger (no database connection);
- pod requests/limits, optional metrics, and namespace quota pressure;
- latest successful backup Job age;
- ingress backend, DNS, TLS, and HTTP health;
- correlation IDs from an allowlist of health-response headers; and
- redacted Helm history and optional release-evidence metadata.

Collection failures are recorded by category in `collection-errors.json`.
Partial evidence is therefore still useful when metrics-server, ingress, or
some RBAC permissions are unavailable.

## Safety controls

Every external command goes through one policy gate. It permits only the
specific read operations needed by the collector. Mutating kubectl and Helm
commands are rejected, and direct `Secret`/`secrets` resource reads are
rejected regardless of resource spelling. Helm's own read of its
release-storage Secret (above) is the only Secret access, and it is reported
in `manifest.json`. Commands never use a shell.

Password-bearing URLs are rejected both at argument validation and command
execution. Explicit health URLs also reject query strings and fragments, where
credentials are commonly embedded.

Helm values are held in memory only. Keys associated with passwords, Secrets,
tokens, API keys, credentials, private keys, cookies, DSNs, connection
strings, and URLs are removed before the remaining configuration is
fingerprinted. Raw values are not written.

Immediately before archive creation, every staged file is scanned for
password-bearing URLs, credential assignments, private-key markers, bearer
tokens, and common provider token formats. Any finding aborts archive
creation. Findings identify only category, file, and line; the suspected value
is never printed.

Archive entries have deterministic modes, timestamps, and normalized
`root:root` (`0:0`) ownership. The archive itself remains owned by the invoking
user and is created mode `0600`. A SHA-256 sidecar is generated only after the
archive is complete.

## Tests

The tests mock all cluster and Helm interactions:

```sh
python3 -m unittest discover \
  -s scripts/support/tests \
  -p 'test_*.py'
```

They cover the read-only command gate, Secret and password-URL blocking,
configuration redaction, pre-archive credential scanning, mocked collection,
normalized archive metadata, and checksum generation.
