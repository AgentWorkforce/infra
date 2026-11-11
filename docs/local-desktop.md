# Kind-profile Desktop on Apple Silicon macOS

After the local dashboard is serving trusted HTTPS at
`https://relay.kind.agentrelay.com`, run:

```sh
make desktop-install
```

Requires authenticated GitHub CLI access to the relay-desktop Actions artifacts.
The script discovers the newest successful `desktop-release.yml` dispatch whose
version job records both `PROFILE_ID: q7m2k9` and `PREPARE_ONLY: true`, then runs
`gh run download <run> -n dmg-arm64`. Override the run with `DESKTOP_RUN=<id>`.

Before copying to `~/Applications`, it verifies the shipped SHA-256 sidecar,
strict deep codesigning, the Agent Workforce signing team, bundle identifier,
compiled local site and URL scheme. It refuses to overwrite an existing app.
The app launches normally; use its browser device flow and the local admin to
sign in. No trust or Agent Relay permission settings are changed by this script.

For a target Mac without GitHub CLI credentials, download on an authenticated
machine, transfer the complete artifact directory, and run on the target:

```sh
gh run download 42916872484 --repo AgentWorkforce/relay-desktop -n dmg-arm64 -D kind-desktop
# Transfer kind-desktop to the target Mac, then:
make desktop-install DESKTOP_ARTIFACT_DIR=/path/to/kind-desktop
```

Run `42916872484` was the latest successful q7m2k9 prepare-only build inspected
on 2026-11-11. Its arm64 DMG SHA-256 is
`f0190643099e9c6691d813a464ec83da86ae61d6fda60da9474a6d5ff1d8e158`.
The app is signed by `QUJ7SA6X8X` and carries a stapled notarization ticket.
These artifact checks do not establish local sign-in, session upload or dashboard
acceptance; those require the running local stack.
