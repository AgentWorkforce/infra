# Local application development

Run `./dev.sh` from infra. It starts the native local Kind stack, builds backend
services from sibling source, runs the Next site and Vite dashboard, and builds
and launches Agent Relay Dev against `http://localhost:3100`.

## Required sibling checkouts

```text
agentworkforce/
  infra/
  agentrelay.com/
  relay-webapp/
  relay-desktop/
  relay-control/
  relaycast/
  relayhistory-pipeline/
```

Missing repositories and incomplete checkouts fail with their exact paths.
Relaycast is a TypeScript repository. Desktop includes Rust and Swift projects.
The launcher uses each checkout's current source, including local edits.
Updating those checkouts from Git is a separate, deliberate step.

Install Docker Desktop, kubectl, Git, OpenSSL, Python 3.9+, Node 22.12+, npm,
Rust and a usable Swift/macOS SDK. The local stack bootstrap prepares pinned
kind and Helm tools under `.kind/tools`, so preflight does not require them
before the first run; `--reuse-containers` skips that preparation and does
require them. Docker Desktop starts automatically
when selected and stopped. Other Docker runtimes must already be running.
With Command Line Tools selected, the launcher uses an installed macOS 26.5 SDK
when SDKROOT is unset or names the generic macOS SDK alias. Explicit versioned
SDKROOT and full Xcode selections take precedence.

## Google login and local HTTPS

```sh
mkdir -p .kind/dev
cp scripts/dev/config.example.json .kind/dev/config.json
chmod 600 .kind/dev/config.json
```

Set `adminEmail` to your Google account and `googleEnvFile` to a private local
file, such as `~/.config/agent-relay/dev.env`. Set that file's permissions to
600 and its directory's permissions to 700. It needs these two values.

```dotenv
GOOGLE_CLIENT_ID=your-development-client-id
GOOGLE_CLIENT_SECRET=your-development-client-secret
```

The launcher parses those named values without executing the file. Relative
paths resolve against the config file. Credentials go into a local Kubernetes
Secret. Keep the private file outside version control.

Register `http://localhost:3100/login/oidc/callback` on the Google OAuth web
client. Keep the legacy `/cloud/api/auth/callback/google` registration while
using legacy Cloud. Changing the public port requires its corresponding exact
callback registration. Use `localhost` for the browser and Desktop site origin.

The gateway routes Google login to Control. Control owns state, PKCE, token
exchange, membership, cookies and Desktop approval. The configured adminEmail
receives local owner access through normal Control bootstrap. Other accounts
need invitations or a configured autoJoinDomains entry.

After the cluster has created `.kind/local/ca.crt`, run this once interactively,
and only on an operator-designated disposable fixture host. A general
workstation must not run it.

```sh
make local-trust
```

The CA it trusts has no name constraints and its private key is stored in this
checkout, so anyone holding that key could impersonate any HTTPS site on the
machine. `local_host_setup.py` checks only for macOS, root and the CA file; this
restriction is not enforced in code. See the fixture CA restriction in the
[repository guide](repository-guide.md) and the CA notes in
[local stack setup](local-development.md).

This requires sudo to install the checkout's development CA in the System
keychain and map relay, cast, history and files under `kind.agentrelay.com` to
127.0.0.1. Desktop uses those HTTPS service endpoints after signing in through
localhost. The launcher itself leaves host DNS and system trust setup to this
explicit command. See [local stack setup](local-development.md) for CA renewal
and cleanup.

Google mode permits Control pods to reach public IPv4 HTTPS for discovery,
token exchange and signing keys. Other pods retain their stack network policy.

The native stack's own Google sign-in (`make local-google-oidc`, for the
`relay.kind.agentrelay.com` origin) is separate. While dev.sh runs, its patch
replaces Control's OIDC settings with this config's, including removing the
native allowed-domains list; the next native reconcile restores them.

## Run and iterate

```sh
./dev.sh --check
./dev.sh
./dev.sh --reuse-containers
./dev.sh --no-desktop
./dev.sh --no-service-watch
```

`--reuse-containers` reuses the ready owned `agent-relay-local` cluster and still
builds and watches sibling backend source. `--no-service-watch` uses the stack's
existing images for diagnostic runs. `--auth operator` selects operator-only
login when deliberately testing without Google.

The dashboard is at `http://localhost:3100/cloud/dashboard/`. Internal ports
3102, 3103 and 33100 serve Next, Vite and the Control tunnel. Occupied ports and
another running Dev UI fail preflight. Logs are under `.kind/dev` and may
contain private data.

### Reload behavior

- Next and the dashboard use HMR.
- Desktop Swift, Rust and resource edits rebuild and relaunch the Dev UI and
  restart its Dev background service.
- Control, telemetry collector, Relaycast and pipeline services use cached
  Docker builds, Kind image imports and Kubernetes rollout readiness checks.
- PostgreSQL, MinIO and infrastructure dependencies keep their running state.

Backend watching uses infra's existing source-loop implementation with explicit
sibling paths. Initial builds can take several minutes. Ordinary source edits
trigger redeployment. SQL, dependency manifests and locks, Dockerfiles,
entrypoints and scrubber authority changes stop the watcher for review and a
fresh setup. Follow [source-loop recovery](kind-development.md) for those
changes. The watcher preserves the last working image after a completed edit
build fails and retries on the next edit.

Desktop builds use the dev site origin and `com.agentrelay.desktop.dev`.
Launch validation checks the bundle identity, backend origin and absence of an
AgentRelayProduct takeover marker. Close other Dev UI instances before startup.

Ctrl-C stops this invocation's web servers, tunnels and Desktop UI. The backend
watcher finishes any in-flight build and restores its original deployments,
which can take several minutes. The launcher then pauses the cluster by stopping
its kind node container and clearing that container's restart policy, so an
idle cluster uses no CPU and Docker does not bring it back on its own; data, local OIDC
settings and the launchd-managed Dev core are retained, and the next `./dev.sh`
starts the node again and waits for its API server. Pass `--keep-running` to
leave the cluster up on exit, and run `./dev.sh --stop` to pause one that was
left running. Any exit after a launcher takes this checkout's lock pauses the
cluster unless that invocation passed `--keep-running` or its backend
restoration is unfinished. That includes an early failure of a later
`./dev.sh` while a cluster left up with `--keep-running` is running.
Deliberate native-cluster removal uses `make local-down`.

Pause and resume act only on the node this launcher recorded after the stack
verified the checkout's ownership receipt, on the same Docker endpoint. A
same-named node from another checkout is never stopped or started; a stopped
node the launcher did not record fails startup with a `docker start` hint.
Restoration counts as done only when the watcher logs `restore_complete` in this
run; its exit status alone does not decide, because it restores and then reports
whatever stopped it. A watcher refused before its first build (an expired or
changed plan, for example) changed nothing and does not block. If it is still running when the launcher gives up waiting,
the cluster is left running and a new `./dev.sh` or `./dev.sh --stop` refuses to
proceed until that watcher exits. If it failed, the cluster is left running and
`./dev.sh` refuses to start until you follow
[source-loop recovery](kind-development.md) and delete `.kind/dev/restoring.json`. `--stop` exits nonzero when a pause fails.

## E2E verification

The native stack includes Control, Relaycast, native ingest, consumer, reader,
brief worker, telemetry collector, PostgreSQL, MinIO and ingress. Verify a real
Google login, Desktop workspace approval, session upload and authenticated
transcript readback to establish application E2E behavior. Healthy processes
alone establish readiness.

Run `make local-acceptance` using the actor configuration in
[the acceptance guide](local-acceptance.md) for recorded evidence. Its API checks
are implemented, while the full qualification suite still includes incomplete
checks and returns a failure for them. The legacy
`./dev.sh --proof` option points to that workflow. Generated summaries also
require the brief worker's model credential, configured through the native
stack's `make local-llm-key` workflow. Optional Flows and Relayfile services
have their own deployment requirements.

Launcher regression checks run with the following commands.

```sh
python3 -B -m unittest discover -s scripts/dev -p 'test_*.py'
node --test scripts/dev/gateway.test.mjs
```
