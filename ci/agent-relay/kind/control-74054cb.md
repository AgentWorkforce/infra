# Separate control read-API candidate: 74054cb

This is preparation of an unmerged source candidate, not an ar-lap update.
Control [#27](https://github.com/AgentWorkforce/relay-control/pull/27) was checked
open and non-draft at `74054cb22584178ddb70697c059af1e64809e51c`. It includes
merged #20 but is separate from the merged-main `bae78a5` candidate in infra
#91. It does not replace the exact control-only QA package already proposed
from that merged source.

The official Dockerfile built for native ARM64, with the existing immutable Node
base and exact source label. The archive inspector verified manifest/config
bytes and hashes, architecture and revision. Five image-admission tests passed.
The [build receipt](control-74054cb-build.json) records manifest
`sha256:0097ff037cd5b477ca9bd1352b0aea8154df3d73f004de13f2aefd4a05f13653`.
It is a local artifact selected with `pullPolicy: Never`, not a published image.

## Focused compiled-module qualification

The actual runtime image's complete compiled modules were extracted and bound
read-only over the official build stage's source directory. The unchanged
upstream config, introspection, session and pure MCP test files used that build
stage's locked test dependencies. Tests ran with no external network, synthetic
HTTP/PGlite fixtures, a read-only filesystem, bounded `/tmp` and a 2 GiB test
container limit. Production image permissions were not changed.

The first attempt could not read private-mode build-stage fixture files as
`node`; separate copies of the same non-secret tests/configuration/migrations
were made readable for the harness. A subsequent shared run passed 43 cases but
its introspection worker received SIGKILL; that invocation was not green.
Config (8), sessions (10) and pure MCP protocol (15) completed successfully.
All 17 introspection cases then passed in five bounded batches under the same
resource limit. Thus 50 unique focused cases have successful coverage, with the
original shared-run failure explicitly retained. This is not a claim that the
entire upstream suite or that shared invocation passed.

The [qualification receipt](control-74054cb-qualification.json) identifies the
actual runtime/config/manifest and dependency image IDs, unchanged test hashes,
compiled-module tree hash, batch selections and the prior failure. Full logs
remain in the isolated build worktree's ignored `.kind/core` directory.

## Compatibility boundary

Tests cover retaining legacy RelayAuth assertion behavior when the URL/key pair
is configured, control-token introspection, reader login/read behavior and
read-only sync refusal. They use synthetic upstreams; real History upload/read
compatibility still needs the actual fixture proof. A read-only backend must not
silently replace the existing sync-capable History route.

No auth variables were removed or added, no reader or feature flag was enabled,
and no History URL was changed. No image was loaded into ar-lap or published,
and no source, deployment, migration, trust or data was changed there. The
courier-to-app integration, signed entitlement, local Desktop push admission
and full shared-Postgres target remain separately pending. A fresh authorized
runtime QA run must identify the exact chosen source and image; this candidate
does not alter the earlier approval request's pin.
