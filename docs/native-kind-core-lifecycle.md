# Explicit native kind core lifecycle

The native core installer and `make local-up` are the only kind install paths.
The legacy single-phase `make kind-up` (and `kind-render`, `kind-proof`,
`kind-reconcile-names`) ran the standalone RelayHistory server, which was
removed; those targets now refuse before any state, Docker or cluster access.
`make kind-down` still deletes an owned legacy cluster. The native entry point
uses the independent session reader and Control's native backend; it needs no
RelayAuth server, standalone History server, OpenAI key or license. Optional
products remain off.

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

A platform-only native archive can omit the original build index. Cache
admission keeps the unchanged build-index proof separate from the verified
archive-native transport: an original index descriptor must match the recorded
build index, while an imported native descriptor must match the archive's exact
native manifest and media type. Both check source, architecture, config identity,
every archived runtime configuration field and the complete rootfs layer list.
A matching tag name, an unknown descriptor or mixed index/native/config digests
cannot qualify an image. The archive's full SHA-256 is verified before deriving
its in-memory transport record; no historical receipt is rewritten.

Control also accepts the unchanged qualified RawV2 packet. Select that packet as
`controlReceipt`, its raw `source-manifest.json`, `source-runtime-equality.json`
and `migration-source-comparison.json` as the three manifest inputs, and supply
the original tracked source tar as `controlSourceArchive`. Keep all hash-bound
child receipts beside the qualification packet. The parser verifies every child,
the source tar, SQL/dist maps, native archive/config and separate build index,
then derives coordinates only in memory. It does not manufacture a flat receipt
or attribute the packet's disposable database proof to a new fixture. The
read-only ledger verifier follows the exact bounded ledger identifier in that
qualified migration source, preserving the old flat receipt's ledger contract.
The frozen RawV2 build driver writes hash-verified source bytes into a new build
context and explicitly applies each manifest mode. Its Git source tar uses
`0664` for tracked `0644` files. The parser accepts only that fixed normalization
or exact mode equality and records the normalized count; it never extracts the
tar, infers executability or applies a general permission mask.

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
The resource binding includes the immutable Postgres administrator, database
server TLS and ingress TLS Secrets. Recreating any of them with identical data
still changes its UID and refuses repeat admission.
The final binding also records the owned Traefik Service UID, complete Service
spec hash, ClusterIP and literal Control public hostname. Service443 must target
the gateway's verified websecure Pod port8443. This supplies Control's public
self-route without exposing the reader's internal handoff. A changed gateway
identity or transport refuses repeat before chart writes; failed verification
does not admit a replacement on the next attempt.
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
   password reset is substituted for those APIs. Each owned diagnostic operator
   Job has a 20-minute deadline and retains terminal diagnostics for one hour
   before Kubernetes TTL cleanup removes its Job and Pod. Phase results are read
   before cleanup; repeat creates a new operator and never requeues an old one.
6. Enable the native ingest, consumer, independent reader and dashboard with
   the observed workspace allowlist. Control's independent-reader secret and
   ingest introspection secret are distinct. The public route exposes `/v1`,
   never the reader's internal issuer. Runtime Helm has no owner Jobs/Secrets,
   no automatic rollback, no storage adoption and no legacy writer activation.
7. Verify actual deployment/Pod ownership, probes, role/TLS credentials,
   Control tenant, public TLS routes and a single Recreate consumer; save a
   create-only scoped native binding. A separate supported real upload/browser
   proof is still required for product acceptance.

### Fresh object-storage initialization

Fresh installation uses the same digest-pinned CGR MinIO server as the parent
sessions-pipeline chart. The upstream dependency's floating/release image defaults
are not inherited: a changed parent pin refuses until the explicit bootstrap pin
is reviewed with it. All chart inputs that create `mc` post-install hooks stay
empty, so native bootstrap requires no separate MinIO client image.

The already-qualified pipeline image is imported and attested through the normal
native archive transport before a fresh-only Job runs its official
`src/locker/init.ts`. That initializer creates the bucket and enables versioning.
The Job has backoff zero, a three-minute deadline, no service-account token, a
read-only root filesystem and locker Secret references only; it receives no
PostgreSQL or database-owner credentials. Completion requires its exact Job and
Pod ownership, immutable image identity and exit zero. A failed attempt is left
for review rather than silently requeued. Repeat-up does not run this initializer
or change the existing bucket/versioning.

The existing namespace-only egress policy remains unchanged. It permits this
Job to reach the object store within the application namespace; it is not an
S3-only network isolation claim. A successful render or source test still does
not establish registry availability, bucket creation or fresh-cluster acceptance.

An existing legacy fixture is not a fresh target. A changed generation or pending
schema on repeat requires an explicit reviewed operator upgrade; this command
does not infer upgrade or data-adoption authority from matching resource names.

### Isolated core instances through the Python transport

A retained `agent-relay-core` must not be adopted, reset, or renamed to obtain a
fresh proof. The optional `NativeInstanceTarget` Python input selects a separate
`agent-relay-core-native-…` cluster and matching `.kind/native-instances/…` state
before directory access. Its HTTP and History ports must be distinct from the
legacy 8080/8443 ports; the site stays on 443 and refuses an occupied port. A
reviewed example is HTTP 18080, site HTTPS 443, and History HTTPS 18443.

The existing `native_core_cli.run` Python entry point accepts `instance_target`
and `reviewed_target_sha256`. An execute call uses the exact real native Stack
factory; arbitrary factory overrides are refused before construction. The target,
factory source, recipe and actual cluster UID are bound in fresh and repeat
receipts. The ordinary command-line entry point and legacy profile defaults are
unchanged; an isolated Python invocation is not evidence for the default command.
Legacy `Stack.up` and the reusable cluster primitive cannot run this target.

This source support does not install host DNS or certificate trust. Strict API
checks retain loopback routing, the selected DNS SNI and explicit pinned public
CA verification. A freshly generated local CA is not implicitly trusted by an
existing browser or Desktop. A separate owned Linux browser fixture may import
that public CA into its own normal OS/NSS trust stores, with no certificate-error
bypass ([Chromium Linux trust-store documentation](https://chromium.googlesource.com/chromium/src.git/+/refs/heads/main/docs/linux/cert_management.md)); this does not qualify a host-installed macOS Desktop.

An ordinary first-admin browser login is a separate proof from operator bootstrap
or device approval. Existing managed `relay-control.auth.emailLink.enabled` and
`smtp` values can select a synthetic, in-memory SMTP fixture and the real
email-link/confirmation/cookie flow without `extraEnv`. Authenticated customer
SMTP/OIDC secret provisioning still needs its separately supported authority
contract. No ordinary login, external mail delivery, upload, or add-on acceptance
is inferred from a native lifecycle receipt.
