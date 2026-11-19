# Prepare edge and Desktop feed configuration

This is an operator guide. For the customer-facing sequence, use
[GCP customer setup](README.md); the operator prepares these overlays from the
confirmed inputs.

`scripts/selfhost/prepare-gcp-edge.py` prepares consistent public origins,
Desktop links and signed-feed inputs for the external GKE install. It writes
local JSON files accepted by Helm. It performs no cloud calls, deployment,
credential provisioning, build dispatch or publication.

Use this with [the GCP install guide](0-START-HERE.md) and
[edge hardening](3-EDGE-HARDENING.md). The release and namespace are both
`agent-relay`; the generated resource names follow that guide. Internal load
balancers and single-host deployments need their own configuration.

## Inputs

Copy [edge-site.example.json](edge-site.example.json) outside the checkout and
replace every placeholder. Supply the four final DNS names, the Desktop
identity, the feed bucket and the signer's Ed25519 public key (canonical
base64 of 32 bytes). Keep private keys, publisher credentials and origin
header values in the approved secret-management system.

For Cloudflare with corporate VPN access, use the
[VPN + Cloudflare profile](CLOUDFLARE-VPN.md) and its
[input template](edge-site-cloudflare-vpn.example.json).

The `edge` options are:

| Setting | Default | Behavior |
| --- | --- | --- |
| `mode` | `google-managed` | Google-managed certificate, with two trusted Google proxy entries; `cloudflare` selects Origin CA TLS, Cloud Armor and a staged third trusted proxy |
| `require_single_level_zone` | `false` | Set `true` to require four sibling names under one zone, suitable for Cloudflare Universal SSL; otherwise nested names are accepted |
| `gate_only` | `false` | Set `true` to emit relaygate History URL, host, audience and CORS overrides |

For example, the usual guide shape is `relay.<zone>`, `api.relay.<zone>`,
`cast.relay.<zone>` and `history.relay.<zone>`. A single-level shape uses
`relay.<zone>`, `relay-api.<zone>`, `relay-cast.<zone>` and
`relay-history.<zone>`. Select certificate coverage that matches the names.

From the infra checkout:

```sh
python3 scripts/selfhost/prepare-gcp-edge.py \
  --config /path/to/site.json --output-dir /path/to/prepared
```

The command validates inputs before writing and refuses to overwrite its
output files. It produces three files, plus a fourth in Cloudflare mode:

| File | Purpose |
| --- | --- |
| `edge.values.json` | Consistent service origins, History CORS and Desktop links; feed storage held back until its signer is ready |
| `desktop-feed.values.json` | GCS storage and the existing signing Secret, enabled together |
| `desktop-build.json` | Matching Desktop identity, site, public key and prepare-only workflow metadata |
| `origin-locked.values.json` | Cloudflare only: trust three proxy entries after direct-origin denial has been proven |

The preparer uses the fixed `agent-relay` resource names. Keep
`name = "agent-relay"` in the VPN and platform Terraform roots for this profile,
and confirm `gkeIngress.staticIpName` equals `vpn_network.ingress.name` or the
manually reserved name. Custom resource names require separately reviewed Helm
overrides after the generated files, including the Ingress IP and edge policies.

Generate the ordinary `values.yaml` with organization, resource, network and
Secret references from the install guide. Retain approved branding before
the generated overlay: Helm deep-merges logo and colour maps while this
overlay updates only Desktop links. If gate-only mode is selected, retain
its enablement, approved policy and matching Secret references in the base.
The generator updates its public origins; it does not invent policy groups
or enrollment credentials.

## Render and inspect

Use chart 0.7.59 or newer from the same qualified commit as Terraform. Check
the final release's compatibility and migration requirements. Preserve this
values order for lint, render, diff and subsequent upgrades:

```sh
helm template agent-relay "$CHART" --namespace agent-relay --no-hooks \
  -f "$CHART/values-gcp.yaml" -f "$CHART/values-gcp-native.yaml" \
  -f managed-values.json -f values.yaml -f branding.values.yaml \
  -f prepared/edge.values.json -f control-env.values.yaml \
  -f release-images.values.yaml > rendered.yaml
```

`edge.values.json` deliberately sets `relay-control.extraEnv: []` to hold
back feed storage until the signer is ready. Helm replaces that whole list,
including unrelated entries from `values.yaml`. If the base has approved
non-feed settings, copy those entries into `relay-control.extraEnv` in an
operator-owned `control-env.values.yaml` applied **after** `edge.values.json`,
as shown above. Preserve Secret references rather than copying secret values.
Keep `SELFHOST_DESKTOP_FEED_*` entries out of this initial list. Repeating
entries only in a base file before `edge.values.json` does not preserve them.

Omit the branding and Control environment files when unused. Run
`helm lint --strict` with the same files and preserve this order for upgrades.
Inspect without Secret payloads:

- All four Ingress hosts and every service URL match the input.
- Google-managed mode has its ManagedCertificate. Cloudflare mode instead
  uses `agent-relay-origin-tls`, `agent-relay-tls` and `agent-relay-edge`, which
  must already exist through the approved certificate and Terraform setup.
- Cloudflare mode attaches Cloud Armor to every backend, including the
  dashboard. Google-managed mode preserves optional policy settings from the
  base; retain its matching dashboard BackendConfig annotation when using one.
- Public Services are ClusterIP and leaf ingresses remain disabled.
- Images use the qualified release's immutable digests, mirrored into the
  target registry. No Secret manifests or inline credentials are rendered.

The initial configuration trusts two proxy entries. In Cloudflare mode,
verify that direct-origin requests to all four hosts return 403, both with
and without the correct secret header. Then append
`-f prepared/origin-locked.values.json` to the reviewed upgrade and every
later upgrade. That file trusts Cloudflare plus Google's two proxy entries.
The [edge guide](3-EDGE-HARDENING.md) describes the origin checks and controls.

## Feed and builds

The operator provisions the signer inside the approved secret-management
environment. The existing Kubernetes Secret named in the input must contain
`<profile>.pem` (PKCS#8 PEM). Confirm its public key matches the build metadata
without reading or printing private material. Workload Identity needs the
Terraform-managed access to the private feed bucket.

Append `-f prepared/desktop-feed.values.json` to the same render, diff and
reviewed upgrade to enable storage and signer together. Helm replaces
`extraEnv` lists: combine unrelated approved entries from the initial Control
environment overlay with the four generated feed entries in the final feed
overlay. Applying the generated feed file alone after `control-env.values.yaml`
would replace that earlier list again. Do not enable feed storage alone.

For a VPN-restricted site, provide an approved operator or runner network
path for feed listing and publication. Preserve the access policy when
configuring CI.

The desktop maintainer uses `desktop-build.json` for the profile environment
in [relay-app](https://github.com/AgentWorkforce/relay-app). Its
`environment_secrets` are public configuration metadata locally, but belong
in GitHub **secrets** so customer metadata is masked in workflow logs. Retain
branding, signing and notarization configuration. Provision the publisher
credential directly into that environment. A cloud feed leaves
`RELEASES_REPOSITORY` unset. `desktop-feed-provision.sh` uses `relay-app` by
default; set `DESKTOP_REPO` only for an approved alternative repository.

Prepare from an exact source commit with successful Desktop CI, matching
`expected-source-sha` and `ci-run-id`, the selected profile and channel, and
`prepare-only=true`. Keep customer builds on the approved crate pins. Record
the candidate run, version and artifact hashes. Verify signing, notarization,
supported platform artifacts, and the embedded site, profile and feed key.
The maintainer then promotes the same bytes with `desktop-promote.yml` after
the required release approval and application proof.

Before handover, verify signed feed version/hashes, entitled downloads,
cross-profile denial, and app sign-in, session upload and update behavior.
Confirm hosted MCP discovery and OAuth metadata before changing connector
URLs. For an existing-site migration, decide profile/key continuity,
coexistence and delivery through the old feed before changing a profile's
environment.
