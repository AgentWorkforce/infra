# Disposable Mac clean-room run

This is the wipe, fresh-install, acceptance and final-wipe procedure for a
dedicated Apple Silicon test Mac. It is not a receipt that those steps passed.

## Preconditions and boundaries

- Use merged infra main containing the local stack and Desktop installer.
  Wait for the coordinated prerequisite PRs before resetting the machine.
  Final acceptance must use the AA pack from merged #211: Control 0.5.16,
  Sessions alpha.5, the EKS SQLite Relaycast generation and the pack's webapp.
  The local recipe must derive those image references and managed
  `[usage, launch]` features from merged `charts/agent-relay/values-eks.yaml`,
  and select the merged `values-scrub-wasm-bindgen.yaml` overlay. Do not copy
  digest literals from a message or substitute a previous trial's pins.
- Retain Git, Python 3.9+, Docker Desktop with its local Linux engine, and the
  authenticated Codex/Claude executables. Docker and kubectl must be on PATH;
  their standard directory is `/Applications/Docker.app/Contents/Resources/bin`.
  Keep at least 20 GiB free on Docker's backing filesystem.
- Desktop installation needs GitHub CLI with Actions read access, or a freshly
  downloaded `dmg-arm64` artifact directory. Dev also needs private pipeline
  repository access. No old app state is an installation input.
- A human must be available at the three sudo boundaries below. Never transmit
  a sudo password or change sudoers.
- Stop watchers through their owning sessions, confirm release restoration,
  preserve source edits in pushed commits, and end test agents.
- **Stop if another Desktop profile, customer installation, active agent work
  or unclassified shared Relay data is present.** Its owner must remove or
  relocate it independently before a whole-machine reset. Never delete another
  profile's hooks, data, account, credentials or services.

Preserve provider CLI authentication and unrelated provider history. Never copy
old Desktop data, database volumes, local credentials, CA keys, selection records
or migration receipts into the fresh install. Reinject the model key from its
external source; do not back it up from the old cluster.

Export only sanitized evidence to another machine. Exclude browser storage
state, MCP session credentials, email/device links, local credentials and model
Secrets.

## First wipe: application cleanup

Do integration cleanup while the old stack and its trusted TLS still work.
The installed helper must use its explicit q7m2k9 admin socket:

```sh
kind_helper="$HOME/Applications/Agent Relay Kind.app/Contents/Helpers/Agent Relay Kind Helper"
kind_socket="$HOME/.agentworkforce/desktop/core.com.agentrelay.desktop.q7m2k9.sock"
"$kind_helper" call tools.status --socket "$kind_socket" --json
"$kind_helper" call tools.manage --socket "$kind_socket" --params '{"tool_id":"codex","action":"uninstall"}' --json
"$kind_helper" call tools.manage --socket "$kind_socket" --params '{"tool_id":"claude","action":"uninstall"}' --json
"$kind_helper" call account.sign_out --socket "$kind_socket" --json
```

These are supported integration uninstall and sign-out actions. Inspect their
results: a transport success alone does not prove integrations were removed.
Remove any other installed local provider through its supported uninstall.
Do not change spawn, sharing, trust or permission settings to make tests pass.

Quit Agent Relay Kind normally, then unload its remaining user core job:

```sh
launchctl bootout "gui/$(id -u)/com.agentrelay.desktop.q7m2k9.core.session"
```

An already absent job is acceptable; investigate other failures. Verify no test
UI, core, watcher or worker remains. Verify provider configuration has no
q7m2k9-managed hook/MCP connection. Preserve all other configuration and CLI auth;
never delete entire Codex or Claude configuration directories.

## Operator sudo boundary 1: remove old trust before deleting state

Keep the old checkout and its public CA/history until removal succeeds. For an
old trial checkout, the builder first stages only the merged cleanup helper at
its canonical path and verifies it:

```sh
cd "$HOME/Projects/AgentWorkforce/local-e2e/infra"
git fetch origin main
git show origin/main:ci/agent-relay/kind/local_host_setup.py > ci/agent-relay/kind/local_host_setup.py
git diff --exit-code origin/main -- ci/agent-relay/kind/local_host_setup.py
```

Khaliq runs this exact command in an interactive terminal **on ar-lap**:

```sh
cd "$HOME/Projects/AgentWorkforce/local-e2e/infra"
sudo /usr/bin/python3 ci/agent-relay/kind/local_host_setup.py down
```

Expected: `Local DNS and CA removed; CA SHA-256 ...`. The helper removes the exact
saved current/retained previous CA certificates and only the relay, cast, history
and files Kind host aliases. Unrelated hosts/trust are preserved. On failure,
retain the CA files and state for retry; do not proceed with deletion.

The builder then removes the owned cluster with `make local-down`.

## Complete the disposable fixture cleanup

These commands erase **all resources in the local Docker daemon**. Run them only
after the dedicated-machine checks pass. The explicit Unix socket prevents an
inherited remote context from selecting another server:

```sh
docker_local() {
  env -u DOCKER_CONTEXT DOCKER_HOST="unix://$HOME/.docker/run/docker.sock" \
    /Applications/Docker.app/Contents/Resources/bin/docker "$@"
}
docker_local info --format '{{.Name}} {{.OperatingSystem}}'
for container_id in $(docker_local ps -aq); do
  docker_local rm -f "$container_id"
done
docker_local builder prune --all --force
for image_id in $(docker_local image ls -q | sort -u); do
  docker_local image rm -f "$image_id"
done
for volume_name in $(docker_local volume ls -q); do
  docker_local volume rm "$volume_name"
done
docker_local system prune --all --volumes --force
```

Verify empty container/image/volume lists and zero build-cache usage. This
includes the browser-proof container and old `local/*-recovery` images.
Container-based BuildKit caches disappear with their containers and volumes;
do not select or prune a separately configured remote Buildx builder. Remove
only the fixture's stale Kind entries from the user kubeconfig, preserving
unrelated contexts and credentials.

Remove the q7m2k9 app and any previous copies with that exact bundle ID, its
profile-specific Application Support/Caches/HTTPStorages/Preferences/Saved
Application State, core socket/lock, relay-socket pointer and probe alias.
Confirm sign-out forgot the local app session. Remove any remaining fixture-owned
auth storage through supported cleanup; never delete unrelated Keychain items.

Shared probe aliases and
`~/Library/Application Support/AgentRelay/SessionServices` require an ownership
check. Remove shared Relay residue only after all other installations and
unclassified data have been cleared by their owners. If managed hooks remain
after supported uninstall, fix the scoped uninstall instead of deleting whole
provider settings.

After preserving reviewed source edits elsewhere, remove the disposable roots
`~/Projects/AgentWorkforce/local-e2e` and
`~/Projects/AgentWorkforce/infra-worktrees`, downloaded artifacts, temporary test
projects and any other inventoried fixture clone. Leave no app backup, CA/key,
credentials, retained receipts or cached image to seed the fresh run.

## Fresh install from main

On ar-lap, from an empty fixture directory:

```sh
mkdir -p "$HOME/Projects/AgentWorkforce/local-e2e"
cd "$HOME/Projects/AgentWorkforce/local-e2e"
git clone https://github.com/AgentWorkforce/infra
cd infra
git rev-parse HEAD
make local-up
```

Record the commit and cold bring-up duration. Require fresh 0600 credentials, a
new CA, Kind, official migrations and all core roles ready on the published
immutable AA source pins. Do not load recovery images or supply an operator
packet. Record each resolved image reference alongside the merged main commit.
Require `SCRUB_ENGINE=wasm-bindgen`, `SCRUB_ENGINE_REQUIRED=wasm-bindgen`,
`READER_MAX_RULESET=10`, and `READ_API_SESSION_QUERY=true` at the applicable
services workloads. Check the migration/other services-image Jobs as well as
Deployments. For this empty-database install, the qualified WASM overlay can be
selected initially; this is not an in-place cutover of retained data.

### Operator sudo boundary 2: trust the new fixture

After fresh `local-up` completes, Khaliq runs on ar-lap:

```sh
cd "$HOME/Projects/AgentWorkforce/local-e2e/infra"
make local-trust PYTHON=/usr/bin/python3
```

This invokes `sudo /usr/bin/python3 ci/agent-relay/kind/local_host_setup.py up`.
It is once per new CA, not a permanent sudo permission. Require
`curl https://relay.kind.agentrelay.com/` to succeed without `-k`.

Open the single-use URL in `.kind/local/admin-login.txt` locally and sign in as
`owner@kind.example`. Never paste that URL into a PR or Relay message.

```sh
make desktop-install
make dev
```

Complete Desktop's normal browser device approval for the local owner. Preserve
its default sharing policy; use the per-session include/upload action for new
test sessions. Dev clones matching adjacent sources. After its cold build,
measure a visible HMR edit and a backend edit-to-Ready, restore the source edits,
and stop dev normally.

For summary acceptance, pipe a key from the external vault into
`make -s local-llm-key` over SSH as shown in
[local development](local-development.md). Never put it in arguments or restore
it from the deleted fixture.

## Acceptance before final wipe

- All core roles ready; both dashboard containers use the selected digest;
  normal TLS verifies and a wrong-host request fails.
- A new unique marker from a real `codex exec` reaches Desktop upload,
  pointer/manifest storage, ready directory, transcript index, session-list
  search and dashboard transcript. Use fresh IDs, not old provider history.
- Prove WASM scrubbing on that real upload. Generate a syntactically valid but
  entirely invented credential fixture that is never used for authentication.
  Include it beside the unique marker in the new Codex session, retain the local
  input witness privately, and verify the raw fixture is absent and its expected
  redaction is present in stored/transcript output. Keep the fixture out of git
  and exported logs. Record actual WASM engine initialization/processing evidence,
  required-engine/no-fallback behavior, ruleset and image identity. Environment
  selection alone is not processing proof; never substitute a synthetic upload
  or manually seed a manifest, transcript or summary.
- A real generated brief for that session appears in the dashboard. Record
  model/token metadata without credentials.
- Private collector events arrive from supported producers, including brief.
  Collector readiness alone is insufficient.
- Owner Usage has real upload/search/user counts; `days=7` returns 200. A normally
  invited member has no Usage nav, sees the owner-only page refusal and gets
  API 403. Summary counts may be unavailable.
- Native send/reply works. Owner MCP finds the enrolled/owned/allowed Desktop
  target; spawn, same-key replay, ready, release and roster removal pass.
  Another MCP session is refused. Release every test worker.
- Record fresh bring-up, HMR and backend timings. Earlier measurements in the
  development guide are prior observations, not the clean-room result.

Do not claim optional turns/timing/output enrichment is supported by the current
self-issued reader. Fix unmet required acceptance in source and rerun it.

## Final wipe and operator sudo boundary 3

Export sanitized evidence, stop dev/test agents, uninstall integrations, sign
out, quit Desktop and unload its core exactly as above. While the fresh checkout
and public CA still exist, Khaliq runs:

```sh
cd "$HOME/Projects/AgentWorkforce/local-e2e/infra"
sudo /usr/bin/python3 ci/agent-relay/kind/local_host_setup.py down
```

After success, run `make local-down` and repeat the complete Docker/app/data/
hooks/artifact/checkout cleanup. Verify there is no test cluster/node, container,
image, volume, build cache, app/backup, auth session, profile data, socket, launch
job, managed hook/MCP entry, fixture clone, artifact, saved/trusted CA or Kind
hosts entry. Docker Desktop, Git, Python, provider CLIs/auth and unrelated provider
history remain.

Only after that final verification report `READY FOR KHALIQ` with the tested
commit, exact commands, actual timings and acceptance checklist.
