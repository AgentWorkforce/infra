# Vendored upstream chart: durable-actors

This directory is the TerseAI/durable-actors release chart, unpacked from the
release asset, plus the local patches listed under "Patches to upstream
files". Do not edit `Chart.yaml`, `values.yaml`, `values.schema.json`,
`README.md`, `.helmignore` or `templates/` except to add or update one of
those patches (and record it there). Report problems upstream and re-vendor.

| Field | Value |
| --- | --- |
| Upstream | https://github.com/TerseAI/durable-actors (MIT) |
| Tag | `v0.14.6` |
| Tag commit | `5f0a2d62ed08e3060befd9b009333e1f0c3c6cd8` |
| Release asset | `durable-actors-0.14.6.tgz` |
| Asset sha256 | `a489cd15c5b4319b2607114701db711f79b4ae5faddd4dd25beb0ac6cab15bee` |
| Also published at | `oci://ghcr.io/terseai/charts/durable-actors --version 0.14.6` |

Image digests pinned by the release chart (`images.*` in `values.yaml`), all in
`us-central1-docker.pkg.dev/fluid-analogy-473415-c2/public/durable-actors`
(multi-arch, linux/amd64 and linux/arm64):

| Image | Digest |
| --- | --- |
| controlPlane | `sha256:a83d21bc05a471dfe1727dd297a98d0bd1588b037a67e03e00637dd8d593e8ef` |
| typescript (actor host runtime) | `sha256:d5ad5fe0ade42e97670446666fa86f1c1dfcaaf1ef31246781642b7372ef5925` |
| python (actor host runtime) | `sha256:86d3861336940d92ee2b05604fb9dda4f5ef83ebd552807ef9a6ac03421413ca` |

## Local additions (not upstream)

- `UPSTREAM.md` (this file).
- `LICENSE.md`: upstream's MIT license (`LICENSE.md` at the tag), so the
  packaged chart carries the notice the license requires.
- `ci/*-values.yaml`: placeholder fixtures so `scripts/ci/charts.sh static`
  can lint and render the chart; they are not shipped values.

Patches to upstream files (report upstream; drop when fixed there):

1. `values.schema.json`: allow a root `global` object. The upstream schema sets
   `additionalProperties: false` at the root, and Helm injects `global` into
   every subchart's values, so the chart cannot be used as a dependency of an
   umbrella that defines globals (agent-relay sets `global.tenant`). Error
   without it: `durable-actors: at '': additional properties 'global' not
   allowed`. One added property; nothing else changes.
2. `invokeApiKeySecretKey` (`values.yaml`, `values.schema.json`,
   `templates/control-plane.yaml`): when set, the control plane gets
   `DURABLE_ACTORS_INVOKE_API_KEY` from that `credentialsSecret` key. Only a
   control-plane image with the invoke-only key patch (durable-actors
   `selfhost/scoped-credentials`, 7a7e9349) reads it; upstream 0.14.6 ignores
   the variable. Default empty: renders are byte-identical to upstream. The
   schema restricts it to Secret key characters (`[-._a-zA-Z0-9]`). Drop when
   upstream ships an invocation-scoped key.
3. `actors.hostIdleTimeoutMs` (`values.yaml`, `values.schema.json`,
   `templates/control-plane.yaml`): when set, the control plane gets
   `DURABLE_ACTORS_HOST_IDLE_TIMEOUT_MS` (how long an idle actor host stays
   up; upstream default 10000, max 86400000). Upstream reads the variable but
   the chart does not expose it. Default null: renders are byte-identical to
   upstream. Report upstream as a missing chart value.
4. `templates/_helpers.tpl` (`actors.poolManagerName`) and
   `templates/control-plane.yaml`: the pool manager is named
   `<actors.name truncated to 50>-pool-manager`, so its Deployment name and
   `app.kubernetes.io/name` label stay within 63 characters (upstream appends
   the suffix to the already 63-character name, which fails for release names
   of 36+ characters). Unchanged for shorter names. The umbrella's
   `durable-actors-networkpolicy.yaml` computes the same name.
5. `templates/control-plane.yaml`: `actors.bounds.*` render when non-null
   instead of when truthy, so an explicit `0` (allowed by the schema) reaches
   the control plane. Unchanged for null and non-zero values.
6. `templates/ingress.yaml`: the host from `publicUrl` is lowercased (the
   schema allows uppercase; Kubernetes rejects it in Ingress hosts).
7. `values.schema.json`: `networkPolicy.dnsCidrs` items must be IPv4 or IPv6
   CIDRs (a bare IP passed the schema and failed at apply time).
8. `templates/control-plane.yaml`: the pod `securityContext` adds
   `seccompProfile: {type: RuntimeDefault}`, like the other charts here.
9. `README.md`: links to upstream docs that are not vendored
   (`docs/self-hosting.md`, `docs/reference/configuration.md`) point at the
   upstream tag, and the per-actor CPU default reads 250 millicores (the
   rendered `actors.cpuMillis` default; upstream says 500).

10. AWS: S3 storage, AWS zones and sandbox scheduling (`values.yaml`,
    `values.schema.json`, `templates/control-plane.yaml`, `templates/_helpers.tpl`,
    `ci/eks-values.yaml`). New values `storage.provider` (`gcs` | `s3`),
    `storage.s3.{region,actorCredentials,actorRoleArn,endpoint,forcePathStyle}`
    (`actorCredentials: control-plane` hands actor hosts the control plane's own
    credentials, for accounts that forbid STS; weaker isolation, first-party code only),
    `serviceAccount.annotations` (IRSA `eks.amazonaws.com/role-arn`, or none
    with EKS Pod Identity) and `sandbox.{runtimeClassName,nodeSelector,tolerations}`.
    `placement.zone` accepts AWS availability zones (`us-west-2a`). The GKE
    Workload Identity annotation is rendered only for GCS or when set. They need a
    control-plane image built from durable-actors `selfhost/aws-s3`
    (`DURABLE_ACTORS_STORAGE_PROVIDER`, `DURABLE_ACTORS_S3_*`,
    `DURABLE_ACTORS_SANDBOX_*`); upstream 0.14.6 ignores them. `storage.provider=s3`
    requires `storage.s3.region` and, with the default `actorCredentials: assume-role`,
    `storage.s3.actorRoleArn`; GCS keeps upstream's rules (no new required value).
    Defaults render byte-identical to upstream apart from the `helm.sh/chart`
    label (patch 11). Upstream proposal: TerseAI/durable-actors PRs (see
    relay-briefs actors-aws.md).
11. `Chart.yaml`: `version` is `0.14.6-awf.1` (upstream `0.14.6`), so a packaged
    chart carrying patch 10 can never be mistaken for the upstream release.
    `appVersion` stays `0.14.6`. Reset the suffix when re-vendoring a release
    that contains these patches.

## Re-vendoring

```sh
VERSION=0.14.6
gh release download "v${VERSION}" -R TerseAI/durable-actors -p "durable-actors-${VERSION}.tgz"
shasum -a 256 "durable-actors-${VERSION}.tgz"   # record it above
rm -rf charts/durable-actors/{Chart.yaml,values.yaml,values.schema.json,README.md,.helmignore,templates}
tar xzf "durable-actors-${VERSION}.tgz" -C charts/
# Re-apply the patches listed above unless upstream fixed them.
```

Then bump the umbrella's `durable-actors` dependency version, run
`helm dependency update charts/agent-relay`, and update the tag, commit,
sha256 and digests above.

## Notes for this repo

- Sandbox pods are created by the control plane, not by this chart. Upstream
  sets `runtimeClassName: gvisor`, `nodeSelector: sandbox.gke.io/runtime: gvisor`
  and a zone affinity from `placement.zone` (`src/sandbox/gke/kubernetes.rs`);
  GKE's `gvisor` RuntimeClass adds the toleration for the sandbox node taint.
  Controllers carry a required anti-affinity for gVisor nodes. No patch needed.
- `replicaCount > 1` requires `redis.urlSecretKey` (socket bus).
- The sandbox NetworkPolicy denies RFC1918 egress from actor pods. Actors
  therefore cannot call cluster-internal services; they may only reach the
  control plane (7100), DNS and public addresses.
- Only GKE Sandbox and Modal providers exist upstream (patch 10 adds S3
  storage and non-gVisor scheduling for our fork image). There is no
  kind/MinIO provider: local proofs use `durable-actors dev` instead (see
  docs/self-hosted-durable-actors.md).
- The sandbox Namespace has no `helm.sh/resource-policy: keep` (upstream).
  `helm uninstall` deletes it together with operator-created Secrets in it,
  such as `relaycast-actor-env`; recreate them after a reinstall.
