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

The mounted-route/store/admission work belongs to **hosted-mcp-port**, not the
owner of the pure protocol slice. Its [design PR #25](https://github.com/AgentWorkforce/relay-control/pull/25)
was checked open/draft at `23332b73509e2e3154e90a7d6df9857fc7bcc8d1`.
The owner reports the design is accepted as a target and implementation is
already assigned in its lane; it is dependency-gated, not awaiting a new broad
implementation go-ahead. The reported implementation areas are `src/mcp/oauth/**`,
`src/mcp/events/**` and reserved migrations `0015`–`0017`; no mounted implementation
is supplied by this candidate. Control #20 has since merged as
`bae78a524fbce4fb3ab231372417bc2dfac04cad`. The next dependency, control
[#28](https://github.com/AgentWorkforce/relay-control/pull/28), remains open/draft
at `a0d96af87d6e1acdbf1107cf2d60808d877219b3` when checked. The owner must then
compose main, recheck combined interfaces, and implement/review the mounted slice.
Code-complete, compatible-artifact and actual OAuth proof dates remain
**NOT COMMITTED**; no calendar range was supplied.

The owner-reported design requires tenant-bound sessions, live organization
membership and stored issue-time scopes, denying trusted pending handoff/artifact
authority. OAuth, Events and pump have independent default-off controls; signing
key/kid/subject-salt custody and canonical origin/resources need explicit operator
configuration. Mounted endpoints, consent, tokens, refresh/revoke and admission
need frozen-head integration tests and exact-source/image receipts. History
delegation remains a separately unaccepted contract; no History credential or
date is implied by the pure protocol slice. Runtime enablement and real-client
rehearsal still require their own operator authorization and approved test inputs.

Draft infra #91 records a newer merged-main local candidate at `bae78a5`; its
build/config qualification also does not mount or qualify this OAuth slice.
The existing basic MCP transport/CLI-auth result remains separate; this future
OAuth work is not silently counted as a new passed or required core check.

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
