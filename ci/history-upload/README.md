# Direct-upload render and contract tests

Run `python3 ci/history-upload/test_chart.py -v` after building the
sessions-pipeline chart dependencies. No cloud credentials are used.

Vectors are copied byte-for-byte from AgentWorkforce/relayhistory-pipeline
`docs/contracts/relay-upload-inbox-v1.vectors.json` at
`a4ace85eb0cf250ee3ba83e133dc9302c0aab3a3` (#508). The source is first-party
Apache-2.0 code. All identities/keys in the fixture are synthetic test data.
The Python checksum assertion prevents accidental drift, and the object-storage
Terraform test checks that the IAM namespace contains the frozen object key.
