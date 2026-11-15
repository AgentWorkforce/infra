# Agent Relay 2026.11.5

Chart agent-relay 0.7.10. Builds on 2026.11.3 (read its notes and the 2026.11.2
notes first). Install it with the GKE guide (`docs/gcp-install`) or upgrade the
usual way for your platform.

## What changes

- **Sessions image from relayhistory-pipeline `f8ac49b3`**
  (`sha256:ba02f149…`): databases migrated by 2026.11.1 now upgrade. 2026.11.2
  and 2026.11.3 stopped at the worker migrate preflight with `ledger_gap`,
  because migration `20261105047030_frozen_copy_progress` sorts before steps
  2026.11.1 had already applied. A reviewed late-insertion allowance lets the
  migrator apply it in its normal position. Fresh installs were not affected.
  Do not apply that migration by hand. It also carries everything in the
  2026.11.3 Sessions image (`601d6a65`): the desktop direct-upload fix and the
  GCS `storage_provider` fix.
- **Co-brand "for" line**: with a customer logo set (`global.branding.logo`),
  the sign-in pages show "for <logo> <name>" under the Agent Relay lockup.
  relay-control from `c276e638` (#133), relay-webapp from relay-web `0090a040`
  (#139). Without a logo nothing changes.
- **Chart 0.7.10** has the same content as 0.7.9 (published by 2026.11.4); the
  new version only lets this release publish its chart.

On GKE, `SERVICES_IMAGE` (guide step 7) is the Sessions digest above.
