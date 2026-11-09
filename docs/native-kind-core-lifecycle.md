# Explicit native kind core lifecycle

The native core installer is separate from legacy `kind-up`. Selecting native
workloads in the legacy command still refuses before Docker, readiness or SQL
changes. The native entry point uses the independent session reader and Control's
native backend; it needs no RelayAuth server, standalone History server, OpenAI
key or license. Optional products remain off.

This source has offline phase/refusal and real Helm composition tests. A successful
render is not fresh-cluster, repeat-up, Desktop upload or dashboard acceptance.
Qualify those against the exact selected source/image packet before releasing an
installation recipe. The current Cast transport uses its released SQLite runtime;
the reserved separate PostgreSQL database is not a PostgreSQL backend acceptance
claim. Add-on execution remains refused until its own effective capability,
workload, API and UI proof adapter exists.

## Inputs and planning

Use `ci/agent-relay/kind/native_core_cli.py`. Its default prints a static plan and
does not instantiate a runtime Stack. Supply a version-1 JSON document containing
exactly `selection`, `operator`, `inputs` and `values`, in addition to `version`.
The typed contracts live in `native_recipe.selection` and
`native_control.control_contract`. They contain resource names, file hashes,
source/image identities and the administrator's email/display name, organization
name and `Default` workspace name. They never contain a password, bearer,
connection URL or private key. `values` contains the selected values file's
`path` and `sha256`.
The selected values must explicitly pin `relay-webapp.image.repository` and
`digest` to the qualified frontend using Control's capabilities API. The
historical frontend in the old core profile is never inherited implicitly.

`inputs` names the qualified pipeline source archive/manifest, native OCI archive,
artifact receipt and immutable build metadata, plus the Control OCI archive,
artifact receipt and source/dist/migration manifests. The frontend inputs are
`webappPacket`, `webappPacketSha256`, `webappArchive` and `webappBuildMetadata`.
They preserve the original qualification/build/base-chain/bundle/smoke receipts,
verify the native archive and actual compiled files, and distinguish Docker
index, native manifest and config digests before import. Public pipeline receipts
and the older nested receipt format are read without rewriting their historical
evidence. Actual source bytes, all copied image modules, architecture, native
manifest/config and official schema generation are independently checked.

```sh
python3 ci/agent-relay/kind/native_core_cli.py \
  --config native-core.json --reviewed-config-sha256 <config-sha256>
```

For a new owned local TEST fixture, explicitly put `generate-local-test-ca` in
`selection.postgresCa.sha256` and add both `--execute` and
`--generate-local-test-ca`. The private keys remain in memory until creation of
owned immutable Kubernetes Secrets. The resulting **public** CA hash is bound
into a create-only execution plan and native binding. This does not install OS
trust, grant Desktop trust, relax TLS or qualify a public release. A partial
attempt is left for review; it is never adopted, deleted or silently restarted.

For repeat-up, omit the CA-generation flag, select the actual prior public CA
hash and pin `bindingReceipt` plus `bindingReceiptSha256`. Repeat-up requires the
original cluster UID, resource UIDs, exact selection, operator contract, real
tenant and database role identities. It never regenerates credentials or TLS,
reinstalls Control, requeues consumer bootstrap or applies pending migrations.
The original native binding and legacy readiness anchors remain unchanged.

## Ordered execution

1. Verify selected sources, actual image bytes, render and fresh/owned-repeat
   identity before any infrastructure operation.
2. On fresh only, create one TLS-only PostgreSQL server with separate `hoopdb`,
   `relaycontrol`, `relayfile` and `relaycast` databases, and the preserved
   single-writer object store. TLS is enabled from the first server start.
3. Create distinct owner/runtime/service Secrets, then claim only the new
   passwordless Control roles with generated SCRAM verifiers. Run Control's
   official migration CLI and runtime grant function using the owner Secret.
4. Start only Control and Cast. Control's official first-boot provisioner creates
   the explicitly named installation, first administrator and Default workspace.
   Read the real organization/workspace IDs through supported authenticated
   APIs. A render-only non-UUID planning token can never enable the native reader.
5. Use the qualified official pipeline role files, physical-ledger-bound
   migration driver, zero-step rerun, consumer bootstrap and post-schema grants.
   Revoke temporary owner authority before generating the three new runtime
   credentials. No marker SQL, alias rewrite, ownership transfer or existing
   password reset is substituted for those APIs.
6. Enable the native ingest, consumer, independent reader and dashboard with
   the observed workspace allowlist. Control's independent-reader secret and
   ingest introspection secret are distinct. The public route exposes `/v1`,
   never the reader's internal issuer. Runtime Helm has no owner Jobs/Secrets,
   no automatic rollback, no storage adoption and no legacy writer activation.
7. Verify actual deployment/Pod ownership, probes, role/TLS credentials,
   Control tenant, public TLS routes and a single Recreate consumer; save a
   create-only scoped native binding. A separate supported real upload/browser
   proof is still required for product acceptance.

An existing legacy fixture is not a fresh target. A changed generation or pending
schema on repeat requires an explicit reviewed operator upgrade; this command
does not infer upgrade or data-adoption authority from matching resource names.
