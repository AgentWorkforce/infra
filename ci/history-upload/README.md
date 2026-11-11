# Direct-upload render and contract tests

Run `python3 ci/history-upload/test_chart.py -v` after building the
sessions-pipeline chart dependencies. No cloud credentials are used.

Vectors are copied byte-for-byte from AgentWorkforce/relayhistory-pipeline
`docs/contracts/relay-upload-inbox-v1.vectors.json` at
`5186ff1edd0b624f63b73adb2fd5d267f5e43f85` (#525, additive amendment to #508).
The new `credentials.presignedSelfhost` vector is added; all existing vectors
are JSON-identical to #508. The source is first-party
Apache-2.0 code. All identities/keys in the fixture are synthetic test data.
The Python checksum assertion prevents accidental drift, and the object-storage
Terraform test checks that the IAM namespace contains the frozen object key.

## Opt-in real MinIO transport probe

`probe_minio.py` checks Control's exact source at
`473ce224ab9da42a67d2970a269e969109e64ae7` against the MinIO image pinned in the
sessions-pipeline chart. It needs gh read access, Bun, PyYAML, and an already
running **local** Docker daemon with at most 4 GiB RAM. Pull that pinned MinIO
image first, then run:

```sh
~/.local/bin/aw-heavy -- python3 ci/history-upload/probe_minio.py
```

It fetches only three first-party TypeScript files at that immutable source
commit, creates an isolated temporary container with synthetic credentials and
a memory-backed data directory, and always removes its own container. It does
not create/resize a VM, stop the shared test database, use the user's AWS keys,
mount real credentials, or touch ar-lap. Temporary source/files remain under
this checkout's ignored `.kind` directory; no npm packages are required.

The source-generated presigned PUT is tested for 200 then repeat 412, checksum
rejection, signed conditional-header enforcement, metadata/encoding retention,
no KMS headers and a 501 response to STS issuance. Only statuses/booleans and
source/image identities are printed. No signed URLs, witnesses or credential
values are logged. This is a transport proof; it does not qualify a published
Control image, Desktop parser, public TLS ingress or database admission.
