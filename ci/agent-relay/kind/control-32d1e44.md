# Local Control #27 artifact from merged main

Control [#27](https://github.com/AgentWorkforce/relay-control/pull/27) merged at
`32d1e4477f0203611e756e5df45fc5d74798bff3` on 2026-11-08 at 05:06:05 UTC.
This separate candidate pins that merged revision and builds its official
Dockerfile for native Linux ARM64. It does not replace the earlier `bae78a5`
ar-lap approval package at infra branch commit `1d14ac0`.

The [build receipt](control-32d1e44-build.json) records the source, immutable Node
base, hash-verified OCI manifest/config, native architecture and local transport:

| Item | Value |
| --- | --- |
| Manifest | `sha256:fafb248b8f6d0d30facde49ee3bf4c3ca4ce49e36eb37508862a533b9e904e6c` |
| Config | `sha256:d98e60882a565b8356ad307899d79e5a10d4d181f22237ec05ad9553b5bd5dea` |
| Archive SHA-256 | `ad4bb39df8669284113ce3c7483ad233809d1d000de2988b0269042652679f80` |
| Archive size | 92,574,720 bytes |

The archive remains local at `.kind/core/control-32d1e44-arm64.tar` in the
isolated `control-32d1e44` worktree. The branch's build command is
`make kind-build-control PROFILE=core`; it selects this local candidate with
`pullPolicy: Never`. It does not install it. Five image-admission tests passed,
including refusal of mismatched architecture, source and metadata hashes.

## Focused actual-image checks

The [qualification receipt](control-32d1e44-qualification.json) records 50 unique
passing cases in eight sequential batches: config 8, sessions 10, pure MCP
protocol 15 and introspection 17. These are fresh runs against this image's
compiled modules, with the official build stage's locked test dependencies and
unchanged upstream tests. Each container used no external network, a read-only
filesystem, a bounded temporary filesystem, two CPUs and a 2 GiB memory limit.
Tests use synthetic HTTP and PGlite fixtures; they are not a live History or
pipeline proof, a mounted MCP OAuth proof, or the entire upstream suite.

The merge has the same source tree as the earlier `74054cb` candidate, and the
compiled module hash matches that artifact. Its earlier failed shared test run
remains attributed to that candidate; this candidate's eight batches all passed.
Only separate copies of non-secret upstream fixtures were made readable for the
test harness. Production image permissions were unchanged. Full batch logs and
the qualification harness remain in this worktree's ignored `.kind` directory.

## Runtime boundary

The source migration tree is `5522ef7dd32dd1999b131f9ca2ca39c3f0eedba1`, matching
the running `1f08cb6` source. This is a source comparison, not a migration run.
The tests cover the configured legacy RelayAuth pair, token introspection,
session reads and read-only sync refusal. A read-only backend must not silently
replace the existing sync-capable History route.

No image was loaded into ar-lap, no deployment restarted, and no auth setting,
History URL, reader opt-in, migration, trust setting or user data changed there.
No image was published. The historical ar-lap `1c203f59` receipt remains
57 PASS / 0 FAIL / 3 PENDING. Courier-to-app visibility still needs a qualified
combined reader/writer image and ACL generation; Desktop, signed entitlement
and the full shared-Postgres target remain separate work.
