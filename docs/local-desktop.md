# Kind-profile Desktop on Apple Silicon macOS

After the local dashboard is serving trusted HTTPS at
`https://relay.kind.agentrelay.com`, run:

```sh
make desktop-install
```

Requires authenticated GitHub CLI access to the
[relay-app](https://github.com/AgentWorkforce/relay-app) Actions artifacts (the
desktop app's open-source repository; it replaces the private relay-desktop).
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
gh run download <run> --repo AgentWorkforce/relay-app -n dmg-arm64 -D kind-desktop
# Transfer kind-desktop to the target Mac, then:
make desktop-install DESKTOP_ARTIFACT_DIR=/path/to/kind-desktop
```

Use the newest successful relay-app `desktop-release.yml` dispatch with
`profile=q7m2k9` and `prepare-only=true`. The app is signed by `QUJ7SA6X8X` and
carries a stapled notarization ticket. Builds made before the move live in
AgentWorkforce/relay-desktop (for example run `42916872484`); install one of those
with `DESKTOP_ARTIFACT_DIR` after downloading it from that repository.
These artifact checks do not establish local sign-in, session upload or dashboard
acceptance; those require the running local stack.
