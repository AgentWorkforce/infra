# Self-host direct session uploads

Desktop scrubs locally, stores a frozen batch in its adjacent SQLite delivery
queue, obtains short-lived credentials from Control, and PUTs the compressed
batch directly to object storage. The native ingest-edge scan promotes the
upload into asynchronous admission. SQL admission, indexing and summaries run
after the PUT. Ingest-edge still serves privacy controls and admission status.
The self-host scanner is authoritative; SQS is not required.

## Compatibility and contract

This wiring implements `relay-upload-inbox-v1` at relayhistory-pipeline
`a4ace85eb0cf250ee3ba83e133dc9302c0aab3a3` (#508). The exact vectors are vendored
in `ci/history-upload/relay-upload-inbox-v1.vectors.json`, SHA-256
`0753bf6f4111c03233d8defcb553e5d0783e101b04a402b079398d28a6bd901a`.

Use published immutable images containing relay-control #90 (merged at
`28664c46`) and relayhistory-pipeline #515's self-host upload scanner/status
implementation. #515 was still under review when this wiring was written.
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

Use **presigned-only uploads** for bundled MinIO: clients should not receive a
MinIO user/root credential. The issuer must sign a PUT against a dedicated
public TLS S3 API origin without a path rewrite, while retaining a private
in-cluster endpoint for privacy-journal reads. Do not expose the console or use
the root credential as the issuer. Restrict a dedicated issuer user policy to
upload-inbox PUTs and privacy-journal reads, plus the necessary journal existence
check. Native scanning, witness verification and async SQL admission stay the
same.

This path needs a compatible Control/contract update: current #90 hardcodes AWS
STS, AWS URLs and SSE-KMS, and the frozen desktop response parser requires a
nonempty `kmsKeyId`. MinIO without KES cannot meet that contract. Merely setting
`endpoint` or enabling the upstream MinIO ingress would advertise a broken path.
The Control owner has been asked to implement S3-compatible presigned issuance,
separate public/internal endpoints and optional encryption metadata. Keep
`historyUpload.mode=off` for bundled MinIO until that shared contract and the
Desktop parser are updated and tested. No public MinIO ingress is installed by
this AWS wiring.

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
