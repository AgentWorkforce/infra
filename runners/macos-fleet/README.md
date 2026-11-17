# macOS fleet runners

Ephemeral, per-job GitHub Actions runners on the company's Apple-silicon Macs,
for the macOS CI lanes of `relay-app` and `relay` that queue for hours behind
the hosted macOS concurrency cap. Each Mac runs one or more *slots*; a slot is
an unprivileged user plus a root LaunchDaemon that, for every job, mints a
single-use just-in-time (JIT) runner config from a small Cloudflare Worker,
runs a fresh copy of the pinned `actions/runner` as that user, then wipes the
user's state. No long-lived GitHub credential ever reaches a Mac.

```
Mac (root LaunchDaemon)                 Cloudflare Worker (fleet-runner-jit)         GitHub
fleet-runner-supervisor.sh <slot>       POST /mint  (Bearer <this Mac's key>)        App: fleet-runner-jit
  xcode-parity.sh  ok? ─────────────►   sha256(key) -> {repo, installation, name}    Administration: RW on
  mint ◄──────── encoded JIT config ──  App JWT -> installation token (one repo)      relay-app, relay only
  fresh runner as ghrunner-<slot>       -> generate-jitconfig(labels, group 1)
  ./run.sh --jitconfig  (one job)
  kill leftovers, wipe caches, repeat
```

Files in this directory:

| file | installed as | role |
| --- | --- | --- |
| `setup-mac.sh` | run once per slot, as root | creates the user, installs everything below, loads the daemon |
| `fleet-runner-supervisor.sh` | `/usr/local/libexec/fleet-runner/` | the loop: parity, mint, run, clean |
| `xcode-parity.sh` + `parity.env` | `/usr/local/libexec/fleet-runner/` | refuses jobs unless the Mac matches the hosted image's toolchain |
| `com.agentworkforce.fleet-runner.plist.template` | `/Library/LaunchDaemons/com.agentworkforce.fleet-runner.<slot>.plist` | launchd supervisor (KeepAlive) |
| `broker/worker.js`, `broker/wrangler.toml` | Cloudflare Worker `fleet-runner-jit` | mints JIT configs; the only place the GitHub App key lives |

## Security model

- **Per-repo, not org-wide.** Runners register in one repository each (the
  Free plan has no runner groups, so repo scoping is the boundary). A slot
  serves exactly one repo; a Mac that should serve both repos gets two slots.
- **Ephemeral.** Every JIT config is single-use; the runner process exits
  after one job and the next job gets a new runner extracted from the pinned,
  sha256-checked tarball. The job's user is killed and its home, caches,
  DerivedData, npm/swiftpm caches and temp dirs are wiped between jobs.
- **Unprivileged.** Jobs run as `ghrunner-<slot>`: a hidden standard user
  with a discarded random password, no sudo, in `_developer` only so
  `xcodebuild` works. Root holds only the Mac's broker key (`/etc/fleet-runner/<slot>.auth`, 0400).
- **The GitHub App key never leaves the Worker.** A Mac's key is worth one
  thing: JIT configs for its own repo, with the fleet label. Rotating it is
  one `wrangler secret put` and one file on the Mac.
- **Fork PRs never reach the fleet.** Both repos keep the default "require
  approval for fork PR workflows"; the fleet label is only used by the lanes
  listed under Routing.
- **Audit.** The Worker logs `{t, key id, repo, runner, ok}` per mint
  (Workers observability); the Mac keeps each runner's `_diag` under
  `/var/log/fleet-runner/<slot>/diag-<stamp>/` for 7 days.

## What Khaliq creates once (GitHub App, not a PAT)

A GitHub App is the right credential: it is org-owned, scoped to two repos,
carries only the `Administration` permission the JIT API needs, and rotates
without touching anyone's account. A fine-grained PAT would be tied to one
person and expire.

1. Org settings → Developer settings → GitHub Apps → **New GitHub App**:
   name `fleet-runner-jit`, any homepage URL, **webhook: off**, Repository
   permissions: **Administration: Read and write** (Metadata: Read is added
   automatically), *Where can this app be installed: Only on this account*.
   Note the **App ID** shown after creation.
2. Same page → *Private keys* → **Generate a private key** (downloads a
   `.pem`). Convert it to PKCS#8 (WebCrypto needs that form):
   `openssl pkcs8 -topk8 -nocrypt -in fleet-runner-jit.*.pem -out fleet-runner-jit.pkcs8.pem`
3. *Install App* → the org → **Only select repositories**: `relay-app` and
   `relay`. The **Installation ID** is the number at the end of the resulting
   URL (`…/settings/installations/<id>`).
4. Put the PKCS#8 key in AWS Secrets Manager in the infra-ops agent's account
   (the agent has no other way to receive a secret; nothing crosses Relay):
   `aws secretsmanager create-secret --name layered-infra-ops/github-app/fleet-runner-jit --secret-string file://fleet-runner-jit.pkcs8.pem`
   then `rm -P` both local PEM files.
5. DM layered-infra-ops: `fleet app ready: app id <N>, installation id <N>`.
   Neither number is secret.

From there the agent: generates a 32-byte key per Mac (stored at
`layered-infra-ops/fleet-runner/mac-keys/<mac>` in the same Secrets Manager),
shows `wrangler deploy --dry-run`, deploys the Worker, loads the three secrets
with `wrangler secret put` straight from Secrets Manager, and sends the Mac
admin the Worker URL plus the secret name to pull each Mac's key from.

## Per-Mac admin steps

Do these on the Mac as an admin user; nothing here needs Khaliq's GitHub account.

1. Install Xcode 16.4 at `/Applications/Xcode_16.4.app` (the hosted
   `macos-15` image's default, build 16F6) and run
   `sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch`.
   Check: `./xcode-parity.sh` prints only `ok` lines. Other Xcodes may stay
   installed; parity only pins `DEVELOPER_DIR`. Override per Mac in
   `/etc/fleet-runner/parity.env` if this Mac deliberately tracks another image.
2. Pull this Mac's key from Secrets Manager into a file only you can read:
   `aws secretsmanager get-secret-value --secret-id layered-infra-ops/fleet-runner/mac-keys/<mac> --query SecretString --output text > /tmp/fleet.key && chmod 600 /tmp/fleet.key`
3. From a checkout of this repo:
   `cd runners/macos-fleet && sudo ./setup-mac.sh --slot a --broker-url https://<worker-url> --key-file /tmp/fleet.key [--quota-gb 120]`
   Slot `a` = relay-app; add `--slot b` with the `relay` key for the second
   repo. `--quota-gb` puts the runner user's home on its own APFS volume with
   a quota so a runaway job cannot fill the disk.
4. Follow the printed post-steps: `rm -P /tmp/fleet.key`, keep Remote
   Login/Screen Sharing restricted to admins, `pmset` so the Mac stays up,
   and watch `/var/log/fleet-runner/a.launchd.log` for
   `runner <name> waiting for a job`.
5. Confirm in the repo: Settings → Actions → Runners shows the runner (idle,
   labels `self-hosted, macOS, ARM64, fleet-macos-arm64`) while it waits.

Opt-out is the default: a Mac that nobody runs `setup-mac.sh` on is not in the
fleet. Remove a slot with `sudo ./setup-mac.sh --slot a --uninstall`.

## Rollout

1. **Canary**: two Macs, slot `a` (relay-app) only. Route one lane,
   `macos-core-tests`, by setting the repo variable `CI_MACOS_ARM64_RUNNER`
   to `fleet-macos-arm64` (desktop-ci reads it; unset or any other value =
   hosted/Blacksmith, so rollback is the variable). Watch a day of runs: queue
   time, pass rate against the known flaky suites, cache wipe cost.
2. **Route step** (phase 2, owned by layered-relay-app): the `changes` job
   checks fleet health (`GET /repos/{repo}/actions/runners`, any online runner
   with the label, plus queue age) and emits the matrix with the fleet label
   or the hosted label per job, so a dead fleet falls back to hosted
   automatically. Then `macos-swift-tests`, then `macos-package`.
3. Add slot `b` (relay) on the same Macs for the `relay` test/swift lanes.

### Never route to the fleet

- `relay-app` `desktop-release.yml` build (signing certificate and notarization keys).
- `relay-app` `ios-testflight.yml` upload (App Store Connect keys).
- `relay` `publish.yml` build and sign.
- `relay-app` `mobile-ci.yml` simulator job until a Mac is at Xcode 26 parity.

Those lanes hold signing secrets; they stay on hosted runners with the
secrets-bearing environment. Nothing in this directory can claim them because
their `runs-on` never mentions the fleet label.

## Operations

- Status: `cat /var/run/fleet-runner/<slot>.state`; logs in
  `/var/log/fleet-runner/<slot>.launchd.log` (supervisor), `<slot>/runner.log`
  (runner), `<slot>/curl.err` (mint failures), `<slot>/diag-*/` (per-job).
- Restart a slot: `sudo launchctl kickstart -k system/com.agentworkforce.fleet-runner.<slot>`.
- Parity failed (Xcode updated, macOS upgraded): fix the Mac or update
  `parity.env` here (and the hosted image assumption) in one PR.
- New runner version: bump `RUNNER_VERSION` / `RUNNER_SHA256` in
  `setup-mac.sh` (sha256 from the `actions/runner` release page) and rerun
  setup on each Mac; the next job uses it.
- Rotate a Mac's key: new key in Secrets Manager, `MACHINE_KEYS` secret
  updated on the Worker (agent), new `/etc/fleet-runner/<slot>.auth` on the
  Mac, kickstart. Revoke by removing its entry from `MACHINE_KEYS`.
- A Mac that dies mid-wait leaves an offline runner behind in the repo;
  GitHub removes ephemeral runners that stay offline for a day.
