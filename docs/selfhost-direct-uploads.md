# Self-host direct session uploads

Desktop scrubs locally, stores a frozen batch in its adjacent SQLite delivery
queue, obtains short-lived credentials from Control, and PUTs the compressed
batch directly to object storage. The native ingest-edge scan promotes the
upload into asynchronous admission. SQL admission, indexing and summaries run
after the PUT. Ingest-edge still serves privacy controls and admission status.
The self-host scanner is authoritative; SQS is not required.

## Compatibility and contract

This wiring implements `relay-upload-inbox-v1` at relayhistory-pipeline
`5186ff1edd0b624f63b73adb2fd5d267f5e43f85` (#525, additive amendment to #508). The exact vectors are vendored
in `ci/history-upload/relay-upload-inbox-v1.vectors.json`, SHA-256
`54438c939e85b11d255e25f80c0257994c54d5de5f8cf73adf9450aba94723c3`.

Use published immutable images containing relay-control #90 (merged at
`28664c46`) and relayhistory-pipeline #515's self-host upload scanner/status
implementation (merged at `70d97a72ad2ac9123cc2235beffb2ee13a9920fe`; the
consumer image must contain that commit or a later reviewed descendant).
Do not enable the feature on an older image: it may ignore the new flags.
The chart's default image pins are unchanged; these templates alone do not
qualify or deploy a direct-upload runtime. Desktop must also implement both
credential variants and admission polling. Confirm these exact artifacts in
the deployment PR before changing either flag from `off`.

## AWS S3

In `terraform/examples/aws-environments`, opt into infrastructure:

```hcl
kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000"
history_upload = {
  control_service_account  = "relay-control"
  consumer_service_account = "agent-relay-ingest-edge"
}
```

The consumer ServiceAccount must exactly match
`sessions-pipeline.ingestEdge.serviceAccountName`. Use a separate identity from
legacy worker/alleyoop/session-ingest-api accounts. The native consumer reads
uploads; readers and legacy writers are explicitly denied raw upload reads,
including object versions and deletes, even if an older IAM grant spans `96bulls/*`.
The ingest-edge process owns both the scanner and status routes, so both use
this native consumer identity. Disable overlapping legacy ingest writers in
the native profile.

Control has one Pod Identity association. When `desktop_feed` is configured,
its role is reused and the ServiceAccount names must match. Otherwise a
Control issuer role is created. Desktop never receives that role's credentials:
Control assumes a separate one-hour upload role with a narrower per-user session
policy and `SourceIdentity`. Target trust and issuer permissions allow
`sts:TagSession` for the transitive tags supplied by EKS Pod Identity
([AWS session-tag behavior](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-abac.html)).
That role can only create encrypted inbox objects;
it cannot list, read, delete or overwrite objects. PUT requires `If-None-Match`.
Control may read privacy journals and list bucket keys (needed to distinguish a
missing journal's 404 from an authorization 403), but cannot read uploads or
canonical transcripts through this policy. Do not attach broad transcript
permissions to Control separately.

The customer-managed KMS key must have a key policy that permits this account's
IAM roles to use IAM policies, or explicitly delegates the corresponding
permissions to the issuer, upload and consumer roles. This module attaches
role policies; it does not replace an externally owned key policy. The upload
role needs `GenerateDataKey`, Control needs `Decrypt` for privacy journals, and
the consumer needs both. S3 Bucket Keys are disabled for new objects in an
upload-enabled bucket: the current credential session policy restricts KMS
operations by **object ARN**, whereas Bucket Keys use **bucket ARN** as their
encryption context. Existing objects are not rewritten.

Provision one random 32-byte witness key encoded as unpadded base64url in an
existing Kubernetes Secret through your secret manager. Share the same value
only with Control and ingest-edge. Never put the key into Terraform, committed
values, Desktop configuration or logs. Test-vector keys are not deployable keys.

After the artifacts and IAM/KMS policies are verified, use a reviewed deployment
PR with an initial user/tenant allowlist:

```yaml
relay-control:
  serviceAccount:
    name: relay-control
  historyUpload:
    mode: allowlist
    allowlist: [test_user_id] # Control user IDs
    bucket: customer-sessions
    region: us-west-2
    keyRoot: 96bulls
    roleArn: arn:aws:iam::111111111111:role/customer-desktop-upload
    kmsKeyArn: arn:aws:kms:us-west-2:111111111111:key/00000000-0000-4000-8000-000000000000
    witness: {existingSecret: history-upload-witness, key: upload-witness-key}
sessions-pipeline:
  ingestEdge:
    createServiceAccount: true
    serviceAccountName: agent-relay-ingest-edge
    admission: {mode: async}
    keyRoot: 96bulls
    uploadDirect:
      mode: allowlist
      allowlist: ["org:test_org_id"] # Consumer uses org:/ws:, not user IDs
      scanBatch: 16
      witness: {existingSecret: history-upload-witness, key: upload-witness-key}
    locker:
      provider: s3
      bucket: customer-sessions
      region: us-west-2
      endpoint: ""
      existingSecret: ""
      credentials: {mode: podIdentity}
```

Set all artifact, native database/TLS, auth and service configuration required
by the native profile separately. The values above are an overlay, not a full
installation. Keep Control, ingest, reader and pipeline storage roots identical
if overriding `96bulls`. Permit Control egress to STS, S3, KMS and the EKS Pod
Identity credential endpoint in restricted network policies. The consumer needs
S3, its database and Control; Desktop needs the public S3 endpoint and Control.
There are no static S3 credentials embedded in the app.

## Bundled MinIO

Use **presigned-only uploads** for bundled MinIO. Control #94 at
`473ce224ab9da42a67d2970a269e969109e64ae7` defines the scoped credential-file
interface used by this chart. It requires a published image containing that
change plus the amended `relay-upload-inbox-v1` nullable-KMS contract (#525) and
compatible Desktop support. Keep the feature off until those exact artifacts
are qualified; changing Helm values does not publish or qualify them.

Control signs a create-only PUT for the caller's tenant prefix. Desktop receives
only short-lived presigned URLs, never the MinIO issuer keys or root password.
Control reads privacy journals through the private endpoint. These dedicated
credential files do not change `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` or the
process-wide AWS credential chain used by Desktop feed signing/storage.

A dedicated MinIO user must already exist, with an operator-provisioned Secret
containing its access and secret keys. It should have only `s3:PutObject` on
`<bucket>/<keyRoot>/.upload-inbox/*`, `s3:GetObject` on
`<bucket>/<keyRoot>/.admission-inbox/*/v1/ws=*/m=srv_*/privacy-journal.json`,
and bucket listing needed to distinguish a missing privacy journal from an
authorization failure. It has no transcript read/delete or MinIO admin access.
Do not reuse the root/admin Secret. Provision users/policies through your
MinIO administration and secret-management workflow; Helm projects references
and never provisions or stores credential values in source.

The upload issuer always signs `If-None-Match: *`, the SHA-256 checksum,
`content-encoding: zstd` and the witness metadata. Verify that your deployed
MinIO version enforces conditional writes and the signed checksum. Keep the
bucket private; exposing the authenticated S3 API does not require anonymous
bucket access.

```yaml
relay-control:
  historyUpload:
    mode: allowlist
    allowlist: [test_user_id]
    bucket: customer-sessions
    region: us-east-1
    keyRoot: 96bulls
    publicEndpoint: https://objects.customer.example
    internalEndpoint: http://session-object-storage.agent-relay.svc.cluster.local:9000
    roleArn: "" # compatible stores do not use AWS STS
    kmsKeyArn: "" # no KES: response kmsKeyId is null; no SSE-KMS headers
    credentials:
      existingSecret: minio-upload-issuer
      accessKeyIdKey: access-key-id
      secretAccessKeyKey: secret-access-key
    witness: {existingSecret: history-upload-witness, key: upload-witness-key}
sessions-pipeline:
  session-object-storage:
    enabled: true
    fullnameOverride: session-object-storage
    ingress:
      enabled: true
      ingressClassName: nginx # use your installed ingress controller
      annotations:
        nginx.ingress.kubernetes.io/proxy-body-size: 2m
      path: /
      hosts: [objects.customer.example]
      tls:
        - secretName: minio-public-tls
          hosts: [objects.customer.example]
    consoleIngress: {enabled: false}
```

This is an overlay; retain the native ingest/consumer/reader database, TLS,
credentials and routing configuration from the installation profile. Configure
`ingestEdge.admission.mode: async`, enable its `uploadDirect` allowlist and
reference the same witness Secret as Control. Its S3-compatible Locker endpoint
and bucket must name the same private store and bucket. The scanner needs inbox
read/delete and admission/status CAS-write permissions; existing native scanner
credentials remain separate from the limited Control issuer user.

Public upload endpoints must be bare HTTPS DNS origins with no path prefix,
credentials, query or fragment. Use a dedicated S3 API ingress with no rewrite,
authentication middleware, request decompression or redirect of signed PUTs;
preserve Host and the signed headers. Provide a trusted TLS certificate and
allow a 2 MiB body. The console remains private. The upstream pinned MinIO chart
already renders this API ingress; the tested example is
`ci/history-upload/fixtures/minio-storage-values.yaml`.

The opt-in `ci/history-upload/probe_minio.py` transport test passed using the
pinned MinIO image and Control source `473ce224`: first PUT 200, repeat 412,
checksum rejection 400, missing signed conditional header 400, preserved zstd
encoding/witness, no KMS headers, and STS issuance refused. It uses only an
isolated temporary fixture container and does not replace published-image,
Desktop, TLS-ingress or asynchronous-admission acceptance.

The private endpoint may use HTTP only with explicit Kubernetes Service DNS
(`service.namespace.svc` or `.svc.cluster.local`); otherwise use HTTPS. Empty
`internalEndpoint` uses the public endpoint. Network policies must admit the
ingress controller to the S3 API and Control/scanner traffic to the private
Service. This chart's public-origin rule is stricter than Control's general URL
parser and the amended shared contract: this ingress profile deliberately uses
a dedicated hostname instead of a path-prefixed reverse proxy.

For a compatible store with KES, `kmsKeyArn` may be an opaque key ID (up to
2048 characters); Control signs the SSE-KMS headers. Empty means no SSE-KMS
headers and does not configure storage encryption on its own. AWS mode still
requires an AWS KMS key ARN and an upload role; its Terraform policies are
unchanged by the MinIO branch.

## Acceptance and rollback

Verify scoped credentials cannot read/list/delete, cannot write another user or
canonical prefix, and cannot overwrite an existing inbox object. Run a real
scrubbed Desktop batch through PUT -> pending -> admitted -> content search ->
summary. Retry the identical PUT (412 means already queued), restart Desktop
and the scanner, test a stale privacy witness, and verify pending/terminal
receipts survive. Confirm SQL can be unavailable during durable PUT acceptance;
admission retries and finishes after SQL recovers. Check private collector
events without recording credentials, witnesses or payloads.

Rollback the issuer flag to `off` first so new clients use the HTTP fallback.
Keep `admission.mode=async` and the scanner enabled until inbox work drains;
turning scanning off with pending objects would strand uploads. Preserve the
witness key, object storage, local SQLite queue and admission receipts. Remove
IAM resources only in a separate reviewed change after the backlog is empty.
