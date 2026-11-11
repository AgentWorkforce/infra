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

The profile pins are in `ci/agent-relay/kind/local-values.yaml`. The services
pin is the existing published native image from the main branch's native CI
profile, and Control/dashboard use the main branch's GCP profile pins. The
scrubber uses that services image's defaults. No WASM-required or reader-ceiling
override is selected before the replacement services image is published.

On the Mac, complete this **one-time administrator step** for DNS and trust:

```sh
make local-trust
```

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

`make local-up` reuses only this checkout's matching cluster UID and Docker
endpoint. An occupied local port or an existing foreign cluster refuses clearly;
the command never deletes a foreign listener. An image generation change
requires recreating this disposable stack. A failed immutable bootstrap Job
also requires inspecting the error and recreating the fixture rather than
silently rerunning it.

The telemetry collector has one Recreate writer protected by its filesystem
lock on this single Kind node's RWO local-path claim. This local storage choice
does not change the production chart's CSI/RWOP default. No hosted analytics
destination is configured.

Set `OPENAI_API_KEY` in the environment before `make local-up` to configure the
brief worker. An absent key creates an empty local model Secret: the worker is
healthy and reports `model_not_configured`, and makes no model calls. A key is
required for summary acceptance. It is never written to Git or printed.

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
This command retains source checkouts, tools and Docker build caches for normal
development; it is not the complete clean-room machine wipe.

## Acceptance status

On ar-lap, the fresh native workloads and strict TLS dashboard request passed;
repeat-up took 2.24 seconds in one measured run. `make dev` built and ran all eight
application roles. A Control source edit executed its unique marker and reached
Ready in 14.200 seconds; its shared collector reached Ready in 21.356 seconds.
An authenticated Chromium fixture with normal CA/NSS trust observed a React
edit through a Vite HMR update in 2.290 seconds, including the screenshot receipt.
The measurement uses one host's monotonic clock; HTTPS errors were not ignored.
Both source trees were restored and the dashboard's `npm run check` passed.

The q7m2k9 candidate passed its checksum, signature and compiled-profile checks
and was copied to `~/Applications`. Native macOS trust and the running Desktop's
local administrator binding were observed working. A real `codex exec` session
was uploaded by Desktop: the pointer, manifest reference, two chunks and directory
entry were verified. The normal authenticated dashboard list API includes it.
Marker search currently fails with HTTP 501 because the pinned reader rejects
the `q` filter. Model summaries, local messaging, independent device-flow
qualification and wipe/repeat/wipe remain pending.

Local ingest uses asynchronous admission. Control, ingest, consumer and reader
use separate private collector credentials. The currently pinned Relaycast image
lacks collector support; Dashboard and brief have no matching managed adapter
in this profile. Collector readiness alone does not qualify event delivery.
An existing local model Secret survives repeated `make local-up` without an
environment override; explicitly supplying an empty `OPENAI_API_KEY` disables it.
