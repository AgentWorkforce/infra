# Scoped Kind and q7m2k9 clean-room run

This is the Kind/q7m2k9 wipe, fresh-install, acceptance and final-wipe procedure
on Apple Silicon macOS. It is not a receipt that those steps passed.
The JHS Rehearsal app is a known co-resident and must remain untouched.

## Rebuild with retained trust

When the operator chooses to preserve the already-trusted CA and existing Kind
hosts block, use this alternative to the sudo boundaries below. Report it as a
rebuild with retained trust, not a zero-trust-state clean-room proof.

After the same scoped app/integration teardown and protected witnesses:

```sh
LOCAL_CA_REUSE=1 make local-down
```

This verifies the existing CA/key and macOS trust, saves only the two files in
private `~/.agentworkforce/kind-local-ca`, deletes the owned cluster and removes
every other `.kind/local` file. It leaves only `ca.crt`/`ca.key` there. Preserve
the external CA directory, System CA and Kind host aliases during the remaining
scoped Docker/app/data/repository cleanup. Preserve JHS exactly as below.

Clone merged main again, then run:

```sh
LOCAL_CA_REUSE=1 make local-up
make desktop-install
```

Do not run `local-trust` or the privileged `down` helper in this mode. Require the
same root fingerprint, a new leaf certificate, new cluster/tenant/credentials,
TLS without a bypass and the full real-session acceptance below. All application
data is fresh; no prior database, token, phase record or leaf key is imported.
After acceptance use retained-CA `local-down` again and finish the scoped wipe.
The final exceptions are precisely the two external CA files, the trusted public
CA and the existing hosts block; the checkout and its remaining CA copies can
then be removed. Keep that exception list with the final pass/fail sheet.

## Preconditions and boundaries

- Use merged infra main containing the local stack and Desktop installer.
  Wait for the coordinated prerequisite PRs before resetting the machine.
  Final acceptance must use the AA pack from merged #211: Control 0.5.16,
  Sessions alpha.5 and the EKS SQLite Relaycast generation, plus the merged
  Sales #50 dashboard update (`dfdf6db6`) and fresh-store read settings.
  The local recipe must derive those image references and managed
  `[usage, launch]` features from merged `charts/agent-relay/values-eks.yaml`,
  select the approved dashboard update in `ci/agent-relay/kind/local-values.yaml`,
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
- Stop only the Kind watchers through their owners, confirm release restoration,
  preserve source edits in pushed commits, and end only the Kind test agents.
- Scope is the owned Kind cluster/images/volumes/state/CA/host aliases and the
  q7m2k9 app, app data, its Keychain items and its shared Claude hook entries.
  Preserve JHS and every non-Kind resource, credential, hook and service. If
  ownership is ambiguous, stop that deletion rather than widening the reset.

Preserve provider CLI authentication and unrelated provider history. Never copy
old Desktop data, database volumes, local credentials, CA keys, selection records
or migration receipts into the fresh install. Reinject the model key from its
external source; do not back it up from the old cluster.

Export only sanitized evidence to another machine. Exclude browser storage
state, MCP session credentials, email/device links, local credentials and model
Secrets.

## First wipe: application cleanup

Before each wipe, capture protected hook witnesses on the controller, outside
the reset tree. The audit reads Claude settings and emits hashes/counts only:

```sh
umask 077
ARLAP_EVIDENCE="$HOME/relay-briefs/arlap-clean-room-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ARLAP_EVIDENCE"
ssh agentrelay@100.104.148.105 \
  '/usr/bin/python3 - snapshot --protected-marker jhs --require-protected' \
  < ci/agent-relay/kind/local_hook_audit.py > "$ARLAP_EVIDENCE/hooks-before.json"
```

Record JHS's bundle/code identity and existing core job identity too, without
contacting its site or changing its process. The hook witness includes group
matchers and all non-q7 hooks, so removing q7 from a mixed group cannot silently
change JHS behavior. Never restore a foreign hook backup to hide a mismatch.

Do integration cleanup while the old stack and its trusted TLS still work.
The installed helper must use its explicit q7m2k9 admin socket:

```sh
kind_helper="$HOME/Applications/Agent Relay Kind.app/Contents/Helpers/Agent Relay Kind Helper"
kind_socket="$HOME/.agentworkforce/desktop/core.com.agentrelay.desktop.q7m2k9.sock"
"$kind_helper" call uploader.status --socket "$kind_socket" --json
```

After ending the owned test sessions, require timestamped uploader observations
with `delivery.pending_records=0`, settled `unqueued_changes=0`, no unresolved
failure or quarantined records, and `stopped=false`. Confirm the final test
session was acknowledged. A running uploader or one successful upload is not
proof that the queue drained. Investigate sustained retries before sign-out;
never pause delivery, change sharing policy or delete queue records to force
zero. Retain sanitized status evidence for both the old-fixture cleanup and the
fresh AA acceptance.

Only after that drain check, uninstall integrations and sign out:

```sh
"$kind_helper" call tools.status --socket "$kind_socket" --json
"$kind_helper" call tools.manage --socket "$kind_socket" --params '{"tool_id":"codex","action":"uninstall"}' --json
"$kind_helper" call tools.manage --socket "$kind_socket" --params '{"tool_id":"claude","action":"uninstall"}' --json
"$kind_helper" call settings.get --socket "$kind_socket" --json
"$kind_helper" call settings.set --socket "$kind_socket" --params '{"claude_session_hook":false,"codex_stop_hook":false}' --json
"$kind_helper" call account.sign_out --socket "$kind_socket" --json
```

MCP uninstall and native session hooks are separate integrations. The two hook
preferences remove q7's Claude SessionStart/Codex stop integration and its own
generated provider rules. Compare settings before/after: only those two hook
preferences may change; every permission control and other setting must match.
Use this explicit q7 admin socket throughout and require the protected hook
witnesses to match. Do this before sign-out and quitting the core, while the
supported hook teardown is available; do not edit shared settings by hand.

These are supported integration uninstall, native hook teardown and sign-out
actions. Inspect their results: a transport success alone does not prove
integrations were removed.
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
test "$(git hash-object ci/agent-relay/kind/local_host_setup.py)" = \
  "$(git rev-parse origin/main:ci/agent-relay/kind/local_host_setup.py)"
```

The blob comparison also works when the old checkout has not tracked this helper
yet; `git diff` would report that untracked file as absent from the old index.

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

## Complete only the Kind fixture cleanup

Inventory container IDs, image IDs/references, volume mounts and development
session labels before deletion. Preserve every resource not proved Kind-owned.
In particular the co-resident rehearsal browser can share the Playwright image
with `arlap-browser-proof`: delete only our browser container and retain the
foreign container and any image it uses.

Use the explicit local socket for inspection and scoped removal:

```sh
docker_local() {
  env -u DOCKER_CONTEXT DOCKER_HOST="unix://$HOME/.docker/run/docker.sock" \
    /Applications/Docker.app/Contents/Resources/bin/docker "$@"
}
docker_local info --format '{{.Name}} {{.OperatingSystem}}'
docker_local ps -a --format '{{.ID}} {{.Names}} {{.Image}}'
docker_local image ls --digests
docker_local volume ls
```

`make local-down` removes only the checkout's UID-checked Kind cluster.
Remove the recorded `arlap-browser-proof` container only after its mounts
confirm ownership. Remove recorded Kind-only image references, old Kind recovery
images and Kind-owned volumes only when no non-Kind container references them.
Remove only development images whose session label matches this fixture's
journals. Retain shared images and unclassified resources and record them.
Do not run daemon-wide system/image/volume/builder prune commands. Clear only
scoped Kind build caches; do not select or prune another Buildx builder.
Remove only fixture Kind kubeconfig entries, preserving unrelated contexts.

Remove the q7m2k9 app and any previous copies with that exact bundle ID, its
profile-specific Application Support/Caches/HTTPStorages/Preferences/Saved
Application State, core socket/lock, relay-socket pointer and probe alias.
Confirm sign-out forgot the local app session. Remove any remaining fixture-owned
auth storage through supported cleanup; never delete unrelated Keychain items.

Preserve shared probe aliases, all JHS aliases and its app/data/Keychain items.
Do not delete `~/Library/Application Support/AgentRelay/SessionServices` as a
whole. Remove only proved Kind/q7 entries in shared storage. If hooks remain
after scoped uninstall, fix that uninstall instead of deleting whole settings.

After preserving source edits elsewhere, remove the Kind-owned
`~/Projects/AgentWorkforce/local-e2e` tree and inventoried Kind-only artifact,
temporary-project and clone paths. Do not delete `infra-worktrees` or another
shared parent wholesale; preserve non-Kind checkouts and rehearsal-verification
work. Leave no q7 backup, Kind CA/key, credentials, receipts or owned image to
seed the fresh run.

After scoped cleanup, take a second controller-side witness:

```sh
ssh agentrelay@100.104.148.105 \
  '/usr/bin/python3 - snapshot --protected-marker jhs --require-protected' \
  < ci/agent-relay/kind/local_hook_audit.py > "$ARLAP_EVIDENCE/hooks-after.json"
python3 ci/agent-relay/kind/local_hook_audit.py verify \
  "$ARLAP_EVIDENCE/hooks-before.json" "$ARLAP_EVIDENCE/hooks-after.json"
```

Require zero q7 hooks and identical protected/non-Kind hook hashes. Confirm
JHS's bundle/core identity and the retained foreign container/image identities
are unchanged. A mismatch fails the cleanup; investigate without modifying JHS.

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
services workloads. The reader also requires `READ_API_TIMING_ASSUME_NO_TURNS=true`
and `READ_API_CANONICAL_PIN_LAGGING_POINTER=true`. Check the migration/other services-image Jobs as well as
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
  After stopping the test producers, require the native uploader's pending and
  unqueued counts to reach zero with no unresolved failure/quarantine. Record
  the final acknowledgment and timestamped drain observations before wiping.
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

After success, run `make local-down` and repeat the scoped Kind Docker/q7 app/
data/Keychain/hooks/artifact/checkout cleanup, with fresh before/after witnesses
for this wipe. Verify no Kind-owned cluster/node, container, image, volume,
scoped build cache, q7 app/backup/auth/data/socket/job/hook/MCP entry, Kind clone,
artifact, saved/trusted CA or Kind hosts entry remains. JHS, its hook hashes,
the rehearsal browser/shared images, unrelated checkouts, provider CLI auth and
other non-Kind resources remain. Do not describe the whole Docker daemon or Mac
as empty.

Only after that final verification report `READY FOR KHALIQ` with the tested
commit, exact commands, actual timings and acceptance checklist.
