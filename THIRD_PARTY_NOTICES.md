# Third-party notices and redistribution status

This file records source and license evidence for software bundled as chart dependencies
or referenced by this Helm chart repository. AgentWorkforce-authored material
in this repository, including first-party Helm chart code, is licensed under
Apache License 2.0 by the root [`LICENSE`](LICENSE). Third-party components
retain their own licenses and notices; this file does not relicense them and
is not legal advice.

Evidence was checked on 2026-11-02 (refreshed 2026-11-03) against the dependency chart archives that
`helm dependency build` produced from the committed `Chart.lock` files, and
against the linked upstream repositories. Those archives are not committed
(`*.tgz` is ignored) and the customer handoff does not ship them: they are
fetched at build or release time, pinned by name, version, and the
`Chart.lock` digest. The archives do not contain `LICENSE`, `NOTICE`,
`COPYING`, or `COPYRIGHT` files.

## License scope

The `artifacthub.io/license: Apache-2.0` annotation in each first-party
`Chart.yaml` identifies the license of the AgentWorkforce-authored chart
content. It does not apply Apache-2.0 to bundled chart dependencies, referenced
container images, or application source code maintained in other repositories.
Those materials remain subject to their respective license terms and the
redistribution limits recorded below.

## Third-party Helm chart dependencies

The SHA-256 values are those of the archives fetched on 2026-11-02 and
re-fetched unchanged on 2026-11-03, recorded so a rebuilt archive can be
compared; they are not files in this repository. `charts/sessions-pipeline/Chart.lock`
(digest
`sha256:9206b7d2ee78aa5068934641d643fa4397fb14362fb2ac8fe31e46854593787f`)
pins the versions.

| Component | Dependency archive (produced by `helm dependency build charts/sessions-pipeline`) | Upstream source | Upstream license evidence |
| --- | --- | --- | --- |
| CloudNativePG cluster chart 0.9.0 | `charts/sessions-pipeline/charts/cluster-0.9.0.tgz` (SHA-256 `95b23ee4b7e2b24d7aec03a9b6a7b751ce42c7447f1299a34460764a43a8f030`) | [`cloudnative-pg/charts`, tag `cluster-v0.9.0`, commit `60fda2534060d41f3c9065adfbea0ede282f3920`](https://github.com/cloudnative-pg/charts/tree/cluster-v0.9.0/charts/cluster) | [Apache License 2.0 at that tag](https://github.com/cloudnative-pg/charts/blob/cluster-v0.9.0/LICENSE); local copy: [`docs/licenses/Apache-2.0.txt`](docs/licenses/Apache-2.0.txt) |
| MinIO chart 5.4.0 | `charts/sessions-pipeline/charts/minio-5.4.0.tgz` (SHA-256 `25fa2740480d1ebc9e64340854a6c42d3a7bc39c2a77378da91b21f144faa9af`) | [`minio/minio`, commit `43a74029685512ce9b1b76c053d48b43fc8d64fc`](https://github.com/minio/minio/tree/43a74029685512ce9b1b76c053d48b43fc8d64fc/helm/minio) (`helm/minio/Chart.yaml` is version 5.4.0) | [GNU Affero General Public License v3.0](https://github.com/minio/minio/blob/43a74029685512ce9b1b76c053d48b43fc8d64fc/LICENSE); local copy: [`docs/licenses/AGPL-3.0-only.txt`](docs/licenses/AGPL-3.0-only.txt); upstream notice reproduced below |
| OpenTelemetry Collector chart 0.178.0 | `charts/sessions-pipeline/charts/opentelemetry-collector-0.178.0.tgz` (SHA-256 `9886a0cd6c5894bec18b628540428fda8bd32619715a64383348ebd662496024`) | [`open-telemetry/opentelemetry-helm-charts`, tag `opentelemetry-collector-0.178.0`, commit `7f0a8aa074b841451a32e4127b159685e8905959`](https://github.com/open-telemetry/opentelemetry-helm-charts/tree/opentelemetry-collector-0.178.0/charts/opentelemetry-collector) | [Apache License 2.0 at that tag](https://github.com/open-telemetry/opentelemetry-helm-charts/blob/opentelemetry-collector-0.178.0/LICENSE); local copy: [`docs/licenses/Apache-2.0.txt`](docs/licenses/Apache-2.0.txt) |

`helm dependency build charts/agent-relay` packages the same third-party chart
contents inside `charts/agent-relay/charts/sessions-pipeline-0.6.0.tgz`, whose bytes
depend on that local build (the 2026-11-03 build had SHA-256
`b9dedec3ad35dec5b3ad824780a51d700481afdad1dde086fcaa26fd6a95a9d3`); it is not
committed or shipped in the handoff. That archive also contains no license or
notice file.

### Vendored chart: durable-actors

`charts/durable-actors` is the TerseAI durable-actors release chart 0.14.6,
committed to this repository (not fetched) with the local patches listed in
[`charts/durable-actors/UPSTREAM.md`](charts/durable-actors/UPSTREAM.md), and
packaged into `agent-relay` as `charts/durable-actors-0.14.6.tgz` by
`helm dependency build charts/agent-relay`. This repository never publishes it
on its own.

| Component | Source | Upstream license evidence |
| --- | --- | --- |
| durable-actors chart 0.14.6 | [`TerseAI/durable-actors`, tag `v0.14.6`, commit `5f0a2d62ed08e3060befd9b009333e1f0c3c6cd8`](https://github.com/TerseAI/durable-actors/tree/v0.14.6/charts/durable-actors); release asset `durable-actors-0.14.6.tgz` (SHA-256 `a489cd15c5b4319b2607114701db711f79b4ae5faddd4dd25beb0ac6cab15bee`) | [MIT License at that tag](https://github.com/TerseAI/durable-actors/blob/v0.14.6/LICENSE.md) ("Copyright (c) 2026 Terse"); copied into the chart as [`charts/durable-actors/LICENSE.md`](charts/durable-actors/LICENSE.md), so the packaged chart carries the notice the MIT License requires |

The images it references (`us-central1-docker.pkg.dev/fluid-analogy-473415-c2/public/durable-actors`
control-plane, TypeScript and Python runtimes, pinned by digest in the chart)
are referenced, not copied.

The CloudNativePG operator chart 0.29.1 is an install prerequisite fetched by
CI/release workflows, not a chart dependency of any chart here. Its source is
[`cloudnative-pg/charts` tag `cloudnative-pg-v0.29.1`, commit
`effa01d9a7d6fa390712a83bbadad1784940f2f4`](https://github.com/cloudnative-pg/charts/tree/cloudnative-pg-v0.29.1/charts/cloudnative-pg)
and that source repository identifies the chart under Apache License 2.0.

### MinIO upstream notice

The following text is reproduced from
[`minio/minio` `NOTICE` at the chart source commit](https://github.com/minio/minio/blob/43a74029685512ce9b1b76c053d48b43fc8d64fc/NOTICE):

> MinIO Project, (C) 2015-2023 MinIO, Inc.
>
> This product includes software developed at MinIO, Inc.
> (https://min.io/).
>
> The MinIO project contains unmodified/modified subcomponents too with
> separate copyright notices and license terms. Your use of the source
> code for these subcomponents is subject to the terms and conditions
> of GNU Affero General Public License 3.0.

## AgentWorkforce suite components

Licenses found in an application source repository are recorded as source
evidence only. The root `LICENSE` independently covers the first-party Helm
chart code in this repository; it does not prove that a particular image was
built from the identified application source, license that separate source, or
cover an image's transitive packages.

| Component | Source identified by chart metadata | License evidence found |
| --- | --- | --- |
| Relaycast | [`AgentWorkforce/relaycast`](https://github.com/AgentWorkforce/relaycast) | Repository contains an [Apache-2.0 `LICENSE`](https://github.com/AgentWorkforce/relaycast/blob/main/LICENSE). |
| RelayAuth | [`AgentWorkforce/relayauth`](https://github.com/AgentWorkforce/relayauth) | Repository contains an [Apache-2.0 `LICENSE`](https://github.com/AgentWorkforce/relayauth/blob/main/LICENSE). |
| Relay Dashboard | [`AgentWorkforce/relay-webapp`](https://github.com/AgentWorkforce/relay-webapp) | Repository contains an [Apache-2.0 `LICENSE`](https://github.com/AgentWorkforce/relay-webapp/blob/main/LICENSE). |
| Relayflows | [`AgentWorkforce/flows`](https://github.com/AgentWorkforce/flows) | Repository contains an [Apache-2.0 `LICENSE`](https://github.com/AgentWorkforce/flows/blob/main/LICENSE). |
| Relayfile | [`AgentWorkforce/relayfile`](https://github.com/AgentWorkforce/relayfile) | Repository contains an [Apache-2.0 `LICENSE`](https://github.com/AgentWorkforce/relayfile/blob/main/LICENSE). |
| Sessions Pipeline worker and AlleyOop | Chart metadata names the private `AgentWorkforce/sessions-pipeline` repository (formerly `AgentWorkforce/96BullSessions`) | No license or notice file was found in the inspected repository. License not established. |
| Relaycontrol API | [`AgentWorkforce/relay-control`](https://github.com/AgentWorkforce/relay-control) (canonical source now used by the API chart) | The previous inspection covered the deprecated `AgentWorkforce/cloud` port source, not this repository. License/redistribution status for the current application image is not established by that historical inspection. |

## Referenced runtime images

Helm chart archives contain image references, not copies of these images.
Current direct references include:

- `ghcr.io/cloudnative-pg/postgresql:17-standard-trixie@sha256:ed6923f9ba2399cf9070379a353c710c29ced8a294be73986a2c3dae7e599ce3`
- `cgr.dev/chainguard/minio:latest@sha256:e70b2b1e74d79457f808710483bd726ff364529ca30736eaa15a6ab547d3a5a7`
- `otel/opentelemetry-collector-contrib:0.163.2`
- `docker.io/alpine/k8s:1.34.1@sha256:ec714df3813b5405292860f8a1c55c5727bf8c33c88992f1e981efad8065547f`
- `node:22.23.3-bookworm-slim`
- AgentWorkforce application images named in chart values and deployment
  profiles.

If any release bundle copies these images rather than only referencing their
registries, its packaging inputs need image-specific SBOMs, license files,
notices, source/provenance records, and any required source-delivery material.
Those records are not present in this repository, so image redistribution is
not cleared by this notice.

## Remaining redistribution limits

1. **Unlicensed suite sources.** No redistribution license was found for
   `AgentWorkforce/sessions-pipeline`, `AgentWorkforce/relayhistory-cloud`, or
   `AgentWorkforce/cloud`. Any package that copies their application code or
   images remains blocked until the copyright holder supplies applicable
   license terms and required notices. This does not change the Apache-2.0
   license of the Helm chart code in this repository.
2. **Legal files are absent from the Helm packages.** The checked dependency
   third-party archives and the generated `agent-relay`/`sessions-pipeline` archives
   contain no license or notice files. Root documentation is not automatically
   included by `helm package`. A release process must deliberately place the
   applicable legal material in each distributed artifact or otherwise define
   and verify the release bundle that accompanies it.
3. **Container redistribution evidence is incomplete.** The chart-only case
   references remote images, but an offline installer or other bundle that
   copies them is blocked pending the image-specific records listed above.

Do not treat the root Apache-2.0 license, chart annotations, or Apache-2.0 files
found in some application repositories as relicensing bundled dependencies,
separate application sources, or container images.
