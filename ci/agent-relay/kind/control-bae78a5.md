# Native control candidate: bae78a5

This candidate is a local artifact qualification, not an ar-lap update or a
replacement upload/read proof. It builds merged relaycontrol main at
`bae78a524fbce4fb3ab231372417bc2dfac04cad` (#20, optional RelayAuth and
introspection). The unmerged #27 read-API branch is not included.
The existing ar-lap fixture and its historical 57/0/3 receipt are unchanged.

## Build and qualification

The official Dockerfile built for native Linux ARM64 in a separate Paris
worktree. The archive inspector verified manifest/config bytes and hashes,
native architecture, and the exact source label. See the
[build receipt](control-bae78a5-build.json).

Five existing image-admission tests passed. In addition, 23 unchanged upstream
tests (`config.test.ts` and `mcp-oauth-protocol.test.ts`) passed using the actual
compiled modules extracted from the built image, running with that same image's
Node runtime. The test container had no network, a read-only filesystem and test
mount, and a bounded ephemeral `/tmp` for its synthetic configuration fixtures.
There were no failed or skipped tests. The
[qualification receipt](control-bae78a5-qualification.json) records source-test
and compiled-module hashes, immutable Docker identity and artifact digests.

These tests include the optional RelayAuth pair's both-or-neither validation,
introspection configuration, and the pure MCP protocol module. They do not prove
real token introspection, migrations, mounted OAuth handlers, or compatibility
with the installed legacy History upload/read service.

## Candidate values and operator boundary

Build only from this candidate checkout:

```sh
make kind-build-control PROFILE=core
```

The builder writes this image selection into its own private state:

```yaml
relay-cloud-api:
  image:
    repository: agent-relay-kind/selfhost-api
    digest: sha256:c8870203c31d73d6c5f489e86a410485aaa4f34862bc22e3ff85de4147aecef9
    pullPolicy: Never
```

This is a local archive/CRI reference, not a published registry artifact. The
builder verifies and resolves its native local tag before kind import; the
digest cannot be treated as a remotely pullable GHCR image.

No RelayAuth variables were removed, no introspection secret or audience was
introduced, and no History URL was rerouted. Existing legacy URL/key wiring must
remain enabled for the proposed QA update until a replacement upload/read path
is independently qualified. No credentials are included in these receipts.

The build worktree has no ownership receipt for the running ar-lap cluster.
No image was loaded there, no migration or deployment was run, and no image was
published. A later authorized QA update needs an owning fixture, verified native
artifact transport, migration/readiness checks and a fresh protocol proof.
This draft does not change the supported milestone or approve runtime enablement.
