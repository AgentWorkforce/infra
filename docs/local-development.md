# A fresh local core on Apple Silicon macOS

With Git, Python 3.9+ and a running Docker Desktop:

```sh
git clone https://github.com/AgentWorkforce/infra
cd infra
make local-up
```

The command downloads checksum-pinned Kind and Helm into this checkout, creates
`agent-relay-local`, and installs PostgreSQL, MinIO, official migrations,
Control, the dashboard, Relaycast, native ingest/consumer/reader, the brief worker,
and the internal telemetry collector. It uses published immutable release images;
no source build, old data, operator packet or admission file is required.

Default Control, dashboard, Sessions, Relaycast and managed features come from
the merged release profile, `charts/agent-relay/values-eks.yaml`. Default Kind
bring-up follows that authority as new release pins land; the separate
downloads-card experiment never repins the default or customer install pack.
Only those release references/features are imported;
the local fixture generates its own identity, endpoints, credentials and storage.
The qualified `values-scrub-wasm-bindgen.yaml` overlay selects
`SCRUB_ENGINE=wasm-bindgen`, `SCRUB_ENGINE_REQUIRED=wasm-bindgen` and
`READER_MAX_RULESET=10` for this fresh database. The same contract reaches local
services-image Jobs. Session query, canonical-pointer pinning and the fresh-store
timing assumption are enabled, matching Sales #50. The reader uses managed
values when its chart supplies them. `ci/agent-relay/kind/local-values.yaml`
also contains the local collector/proxy overrides.

To try the **opt-in Kind downloads-card experiment** in a separate fresh
fixture, run:

```sh
LOCAL_DESKTOP_RELEASES=1 make local-up
```

Keep this opt-in on subsequent local commands, including `local-dev-setup`.
Switching image generations in place is refused; do not use this experiment
for customer-release qualification. `desktop-releases-values.yaml` selects
Control 0.5.19 (`d1ef0495`, source `ad74a1a3`) and dashboard `3171edd0`
(source `994ed422`). Its official selected-image migrator runs before Control,
including new migrations 0046 and 0047 on a fresh store.

With this opt-in, Settings > Workspace lists the Kind Desktop release from the public
`AgentWorkforce/relay-desktop-kind-releases` repository, labelled **GitHub
releases**, with download URLs and checksum links. Local Control sets
`SELFHOST_DESKTOP_RELEASES_REPO` for that repository. Its own API pods get a
public-IPv4 TCP443 egress exception so they can fetch GitHub release metadata;
RFC1918 and link-local ranges are excluded. This standard NetworkPolicy is
not a DNS hostname allowlist. Other pods retain their existing egress policies.
Both dashboard copy and serving containers use the same local image pin.
The default has neither that repository env setting nor the GitHub egress
exception, and uses the release Control/dashboard images instead.

On the Mac, complete this **one-time administrator step** for DNS and trust:

```sh
make local-trust
```

For a rebuild on a Mac that already trusts this fixture's CA, opt into retained
trust instead of removing and reinstalling it:

```sh
LOCAL_CA_REUSE=1 make local-down
# A fresh checkout may be cloned after the scoped cleanup.
LOCAL_CA_REUSE=1 make local-up
```

This mode retains only `ca.crt` and `ca.key` in `.kind/local` during down and in
the private `~/.agentworkforce/kind-local-ca` directory for a subsequent clone.
`LOCAL_CA_REUSE_DIR` can select another private directory outside the checkout.
Up imports only that pair, verifies its key, validity and existing macOS trust,
and mints a fresh leaf when rebuilding. Missing, mismatched, expiring or untrusted
roots fail; this mode never rotates the trusted root or edits `/etc/hosts`.
All cluster credentials, databases, tokens and phase records are regenerated.
Record the retained CA/hosts exception explicitly when reporting this rebuild;
it is not a proof from a machine with no prior trust. The default command above
still generates a new CA and requires the ordinary one-time trust step.

macOS requires sudo to update `/etc/hosts` and trust this disposable fixture's CA
in the System keychain. The script changes only the four `*.kind.agentrelay.com`
aliases, removes duplicate/IPv6 entries for those aliases, preserves unrelated
hosts, and prints the CA fingerprint. It is intended for the disposable local
test Mac. This step changes no Agent Relay permission settings.

Open `https://relay.kind.agentrelay.com`. The local administrator is
`owner@kind.example`. A single-use email sign-in link is generated through the
normal Control sign-in flow and kept in `.kind/local/admin-login.txt` (0600).
Use `make local-login` to generate another, then open the URL from that file.
Control's normal sign-in rate limits apply. Repeat-up reuses a recent link.
All generated database/service credentials stay in `.kind/local/credentials.json`
(0600); never commit `.kind`.

The local reader sets `turns.assumeNoLegacy=true`: this fresh Postgres/MinIO
store has no Neon history whose coverage needs checking. Without that existing
reader setting, the canonical transcript renders but `/turns` returns
`501 turns_unknown` and the dashboard shows `Retry loading history`. The
assumption is confined to this local recipe; custom and retained-data profiles
must establish their own coverage.

The owner-only Usage page is at
`https://relay.kind.agentrelay.com/#/settings/usage`. The local profile enables
the `usage` and `launch` features through the chart's managed `selectedFeatures`
value. Control applies its official migrations, including 0040 and 0041, during
bootstrap. Upload counts come from session
directory activity; active-user and search counts start when usage is enabled.
If the reader does not provide summary counts, they display as `n/a`. A member's
request to `/cloud/api/v1/organizations/<org-id>/usage?days=30` returns 403.

MCP launch tools are served at `/cloud/api/v1/mcp/shared-sessions`. Use a normal
owner/admin person connection and keep its `Mcp-Session-Id` for target discovery,
spawn, status and release. The Desktop must sign in to this site and enroll its
node before it appears as an allowed target. Launch permission follows the
Desktop's existing settings; these helpers do not change them.

`make local-up` reuses only this checkout's matching cluster UID and Docker
endpoint. An occupied local port or an existing foreign cluster refuses clearly;
the command never deletes a foreign listener. A pipeline-only pin change stops
its runtimes, applies the new image's official migrations and no-op check,
reapplies its official runtime grants, then restores the services. The selected
generation is recorded after readiness succeeds. Migrations wait for all four
old workloads' Pods, including terminating Pods, to exit; a timeout preserves
state and stops before schema changes. Relaycast and both collector images are
included in the saved selection. Other image generation changes
require recreating this disposable stack. A failed immutable bootstrap Job
also requires inspecting the error and recreating the fixture rather than
silently rerunning it.

The telemetry collector has one Recreate writer protected by its filesystem
lock on this single Kind node's RWO local-path claim. This local storage choice
does not change the production chart's CSI/RWOP default. No hosted analytics
destination is configured.

Configure the brief worker by piping the key to `make local-llm-key` after
bring-up. For example, with an authenticated 1Password CLI on the source Mac
and `OPENAI_KEY_REF` naming the appropriate `op://vault/item/field` reference:

```sh
op read "$OPENAI_KEY_REF" | ssh -T agentrelay@100.104.148.105 \
  'cd ~/Projects/AgentWorkforce/local-e2e/infra && make -s local-llm-key'
```

The key travels on standard input and is installed only into the owned local
cluster's model Secret; it is not placed in command arguments, logged, or saved
in a source file. The helper updates the model egress policy and waits for the
brief worker rollout. Interactive input, empty input and multiline values are
refused. Model egress selects only the brief worker and allows public IPv4 HTTPS
on TCP 443, excluding RFC1918 and link-local networks. The local profile caps brief attempts at 64 globally per day and three
per session; existing attempt records are retained. Installing a key preserves
those caps and does not prove a summary
was generated. Alternatively, set `OPENAI_API_KEY` before `make local-up`.
An absent key on first install leaves the worker healthy with
`model_not_configured` and no model calls. A key is required for summary acceptance.

## Source loop

```sh
make dev
```

On its first use against this local cluster, `make dev` clones matching release
sources next to infra and creates a private config. The source revisions come
from the deployed immutable images' complete OCI revision labels. Existing
source checkouts and edits are preserved. The pipeline checkout is named
`sessions-pipeline` and clones `AgentWorkforce/relayhistory-pipeline`.
Source development needs GitHub read access to the private pipeline repository;
the helper uses existing HTTPS credentials or an existing SSH agent. The release
stack itself needs neither GitHub credentials nor private source access.

The dashboard uses Vite HMR over the same HTTPS origin. Backends use watched
cached Docker builds, Kind imports and readiness checks. No host Node, Bun,
Rust or Go installation is required. The initial dependency build is cold;
measure edit latency after it completes. Stop the loop with Ctrl-C to restore
the original release Deployments. See `docs/kind-development.md` for the runtime
guards, custom existing targets, protected files and recovery behavior.

## Desktop and cleanup

Use `make desktop-install` and the browser device flow after trusting the local
CA; see `docs/local-desktop.md` for the q7m2k9 candidate and artifact checks.

`make local-down` removes only this checkout's owned local cluster, its volumes,
and its generated local credentials. If the CA is trusted, removing that exact
CA and its hostname aliases requires sudo before deleting its public certificate.
Renewed public CA certificates remain in `.kind/local/ca-history` until trust
cleanup completes, so older trusted certificates can be removed precisely.
On leaf renewal, PostgreSQL and the collector reopen their certificate only
after the mounted Secret contains the new leaf. Teardown removes the default
development config only when its cluster UID, context and Docker endpoint match
the deleted local cluster; the next `make dev` can configure its replacement.
This command retains source checkouts, tools and Docker build caches for normal
development; it is not the complete clean-room machine wipe.
Use the [clean-room runbook](local-clean-room.md) for the dedicated Mac's
wipe/repeat/wipe sequence and exact operator sudo boundaries.

## Prior acceptance observations and pending AA proof

The observations below used the earlier Control 0.5.14/query-capable services
generation. They are a baseline, not acceptance of the AA images now selected.
The AA clean-room must repeat the full checklist, including an actual WASM
processing witness and redaction of a planted, entirely fake credential.

On ar-lap, the fresh native workloads and strict TLS dashboard request passed;
repeat-up took 2.954 seconds after the query-capable pipeline upgrade. `make dev` built and ran all eight
application roles. A Control source edit executed its unique marker and reached
Ready in 14.200 seconds; its shared collector reached Ready in 21.356 seconds.
An authenticated Chromium fixture with normal CA/NSS trust observed a React
edit through a Vite HMR update in 2.290 seconds, including the screenshot receipt.
The measurement uses one host's monotonic clock; HTTPS errors were not ignored.
Both source trees were restored and the dashboard's `npm run check` passed.

The q7m2k9 candidate passed its checksum, signature and compiled-profile checks
and was copied to `~/Applications`. Native macOS trust and the running Desktop's
local administrator binding were observed working. A real `codex exec` session
was uploaded by Desktop. On the query-capable pinned image, a fresh session has
a pointer, three indexed marker events, and a real `gpt-5.6-luna` brief (483 input,
70 output tokens). Authenticated Chromium with normal TLS trust finds the marker
through session-list search, opens the transcript, and displays the generated
summary in Details. Two real Codex sessions also completed a local native-socket
message and reply. The Desktop backlog retained uploads through the migration
outage and drained to zero afterward. A wrong-host request fails for hostname
mismatch with the local CA trusted.

On the deployed Control 0.5.14, a normal owner browser MCP connection reported
launch capability and the local Desktop node as allowed and owned. A Codex
launch reached `ready`, an identical replay returned the same spawn ID, and
release removed it from the roster. Another MCP session was refused access to
that launch. These API results are recorded separately from Desktop screen
evidence: native screenshot capture failed with `could not create image from
display`.

That earlier self-issued reader returned unsupported responses for optional
turns, timing and output metrics; its canonical event transcript and summary
rendered. The AA run must record its actual supported behavior.
Clean-room wipe/repeat/wipe remains pending. These observations do not establish
that final reproducibility proof.

Local ingest uses asynchronous admission. Control, ingest, consumer, reader,
brief and the AA Relaycast use separate private collector credentials.
Dashboard has no matching managed adapter in this profile. Brief/Cast wiring is
covered by the rendered chart; live event proof remains part of the AA run.
Collector readiness alone does not qualify event delivery.
An existing local model Secret survives repeated `make local-up` without an
environment override; explicitly supplying an empty `OPENAI_API_KEY` disables it.
