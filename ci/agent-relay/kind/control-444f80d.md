# Native control candidate: 444f80d

This is an isolated local-build qualification, not an installed-cluster or MCP
OAuth end-to-end proof. The running ar-lap fixture remains pinned to the verified
`1f08cb6` artifact described in its existing receipts. No cluster was changed by
this qualification and no image was published.

## Source and scope

Merged relaycontrol source `444f80d68878d9ae7efdd1ebb160123c4045c5b3` is four
commits ahead of the previous optional local-build pin. The complete source diff
adds only `src/mcp/oauth/protocol.ts`, its tests and its design documentation.
There are no changed server routes, migrations or environment requirements in
that diff. The [upstream design](https://github.com/AgentWorkforce/relay-control/blob/444f80d68878d9ae7efdd1ebb160123c4045c5b3/docs/mcp-oauth-protocol.md)
explicitly separates the pure protocol/resource catalog from later mounted
authorization/token handlers, grants, consent, admission and signing.

## Executed qualification

The official Dockerfile built successfully for native Linux ARM64 using the
existing pinned Node base and source labels. The existing archive inspector
verified manifest/config hashes, native architecture and exact source revision.
The [build receipt](control-444f80d-build.json) records the resulting artifact.
Five control image-admission tests passed for the new pin.

The upstream `test/mcp-oauth-protocol.test.ts` was copied unchanged, retaining its
original relative import. Its imported JavaScript module was extracted from the
built runtime image to that corresponding test path. The same built image ran
the tests using Node type stripping, `--network none`, a read-only filesystem and
a read-only test mount. **15 tests passed; none failed.** The
[qualification receipt](control-444f80d-protocol.json) records the test-source and
compiled-module hashes. No tokens were minted and no HTTP server was started.

This tests the new pure module, not OAuth registration, user consent, token
issuance or an installed MCP transport. The prior 57/0/3 ar-lap receipt is not
re-attributed to this new control pin. A candidate cluster setup/protocol run is
still pending before any replacement of the proven running artifact.

## Operator boundary

The candidate was built in its own worktree, without a cluster ownership receipt.
It cannot adopt a running cluster by name. A reviewed source update in an owning
fixture, valid native artifact selection, setup and a fresh protocol proof are
required to qualify a later runtime update. Existing ownership, TLS, exact ACL
and auth gates remain in place. There is no registry publication in this path.
