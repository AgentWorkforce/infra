# Local acceptance automation

`make local-acceptance` writes a signed `.kind/acceptance/acceptance.json` and
returns nonzero if a check fails. It is restricted to
`https://relay.kind.agentrelay.com`; it cannot point at a hosted/customer site.
This first increment implements **four API checks** and the report/signature
runner. The default full suite deliberately fails with `not_implemented` for
remaining qualification work. An API-only pass is not a 2026.11.1 qualification.

## Run the API foundation

Start the local stack with `make local-up`, install the Kind Desktop with
`make desktop-install`, then complete its normal browser/device sign-in.
Desktop installation, macOS trust and update clicks remain manual steps; this
runner does not change permission settings or launch jobs.

Use a real, freshly uploaded short session with a unique marker such as
`KIND_ACCEPTANCE_<random uppercase hex>`. Select only your test session for
sharing. Supply the real model key to `make -s local-llm-key` through stdin
if needed, and wait for a generated summary. Do not put a model key in config,
arguments or source control. The current runner **observes** the existing
session/summary; it does not yet generate the upload or invoke the model.

Invite a normal member to this local organization and complete that account's
normal email sign-in. Save separate Playwright storage states after owner and
member sign-in, respectively, as `.kind/acceptance/owner.private.json` and
`member.private.json`. The runner reads their cookies with domain, path and
expiry checks. Local storage tokens alone are not supported. The member must
be able to read the shared session. Never substitute a stale/unauthenticated
member cookie for the authorization refusal test.

```sh
mkdir -p .kind/acceptance
chmod 700 .kind/acceptance
cp ci/agent-relay/kind/acceptance/config.example.json .kind/acceptance/config.json
chmod 600 .kind/acceptance/*.json
# Edit config.json: current org/workspace/session IDs, unique marker, and a
# historySince timestamp from before this session, no more than 24 hours ago.
make local-acceptance ACCEPTANCE_SUITE=api
```

Python 3.9+, OpenSSH `ssh-keygen` with SSHSIG support, Git and kubectl are
required. The Make target adds checkout-local `.kind/tools` to PATH. The CA,
kubeconfig and image selection must come from this stack; config paths are
relative to the config file. Credential/config files must be regular files,
owned by the caller, with no group/other access. Everything generated lives
under ignored `.kind/`. No sudo, cluster mutation, Desktop setting change,
model-key read, upload or wipe occurs in the API suite.

Preflight checks the configured tenant against the stack's `tenant.json`, reads
the cluster UID, requires a clean tracked source tree, compares
all nine application copy/serve containers with published GHCR digest pins in
the local selection, and requires the deployments to be updated and available.
Support-store images are outside this first pin assertion. The four checks are:

1. Dashboard HTTPS 200 with the local CA, then a certificate hostname mismatch
   for `wrong.invalid` over the same endpoint. An arbitrary connection failure
   does not count as hostname refusal. No cookie is sent to the wrong host.
2. Metadata `q=id:<session>` returns exactly that session, bounded transcript
   marker search matches it, and its transcript events contain the marker.
3. Summary API returns nonempty `ready` output with a model and generation time
   within this fixture's window. Literal marker repetition in the summary is
   not required.
4. Owner Usage `days=7` returns positive user/upload/search counts; member session
   access succeeds, then member Usage returns exactly 403 `forbidden`.

No HTTP redirect is followed with credentials. API bodies, transcript/summary
text, markers, cookies, URLs with credentials and exception/subprocess text are
not copied into reports. Reports contain statuses, counts, digests, fixture
IDs, source/application pins and elapsed monotonic timings. Every API check is
attempted even after another API failure. A preflight failure yields failed
API checks and a signed report. A report/signing failure exits 2 rather than
leaving a claimed successful result. Before a new run starts, any previous
report is moved to a private `history/acceptance-*.json` beside the output.
If signing fails, the current report path stays absent; the older pass remains
available only in history with its original signed run identity and timestamps.

## Signature and trust

The first run creates `.kind/acceptance/signing_key`, an unencrypted local
Ed25519 development key with mode 0600. Keep it out of Git and artifact uploads.
`acceptance.json` embeds an SSHSIG signature over canonical JSON `payload`,
the public key and its SHA-256 fingerprint. Both pass and fail reports are
signed. This proves integrity under that key, **not external attestation or
the truth of the observations**. Independently retain the expected public key
before using a receipt as a gate; trusting the key embedded in the receipt is
insufficient.

```sh
python3 ci/agent-relay/kind/acceptance/run.py verify \
  .kind/acceptance/acceptance.json \
  --trusted-key .kind/acceptance/signing_key.pub
```

Verification confirms integrity only; inspect `payload.status`, `suite`,
`qualificationComplete`, pins and run identity separately. In this increment
`qualificationComplete` is always false. Default `make local-acceptance` also
lists each pending check as failed and exits 1, preventing an incomplete suite
from becoming a green release gate.

## Release-gate runner provisioning

The release workflow uses the organization runner group
`infra-acceptance-arlap` with labels `self-hosted`, `arlap` and `kind`. This
group is a protected release resource, not a general CI pool. Its organization
settings must have all of the following before registering the runner:

- repository access set to **Selected repositories**, with only
  `AgentWorkforce/infra` selected;
- workflow access set to **Selected workflows**, with only
  `AgentWorkforce/infra/.github/workflows/local-acceptance.yml@refs/heads/main`
  selected; and
- no runner with these labels attached to a less restrictive group.

Pinning the allowed workflow to `refs/heads/main` is mandatory. A
`pull_request` can carry a branch-edited workflow; same-repository and
candidate-file checks inside the job do not protect the runner until after the
job has started. Do not enable the group for a branch workflow, wildcard path
or all workflows.

Set the infra repository variable `ARLAP_ACCEPTANCE_CONFIG` to the provisioned
absolute config path on that runner. The path must be a regular, non-symlink
file. Keep its referenced credentials and kubeconfig outside the checkout with
the ownership and mode requirements above. Until the protected runner group,
this variable and every full-suite adapter are provisioned, release candidates
must remain blocked; an API-only pass never satisfies `qualification`.

The main-defined release workflow receives the open candidate PR number,
version and exact head through `repository_dispatch` (or explicit manual
dispatch). It checks out `main` as the trusted verifier and the candidate head
in a separate directory as data. It publishes a custom `acceptance` check on
that exact candidate commit; the tag gate accepts only that check and verifies
that its backing Actions run used the main-defined workflow. A PR-ref workflow
must never be admitted to the protected runner group. Concurrency slots include
the requested immutable head because GitHub retains only one pending run per
group. A delayed request for an older head therefore cannot replace or cancel a
pending or active current-head qualification; it fails its immutable-head check
in its own scheduler group.

Candidate automation merges the current `main` into the release branch before
requesting acceptance, and qualification refuses a head that does not contain
the PR's current base commit. After merge, the tag gate compares the complete
Git trees of the accepted head and merge commit. Any base advance, merge-time
edit or release-input drift therefore requires a new candidate head and a new
acceptance run rather than publishing unqualified files.

The release check requires the candidate ledger to contain Control, Webapp and
Sessions Pipeline pins. `values.yaml` must byte-for-byte equal the trusted
UTF-8/LF render of that ledger. The signed receipt records the trusted observer
checkout as `sourceRevision`, while its observed runtime images must match all
three candidate `repository@sha256` values. The custom check binds those
observations to the candidate head. Provisioning must therefore roll the
candidate onto the local fixture before rerunning qualification; a pass from
an older ar-lap deployment cannot qualify a newer release candidate.

## Remaining qualification increments

Port the retained-trust clean-room receipts into tracked adapters: real upload
with planted fake-secret/WASM profile and queue drain; Playwright UI assertions;
persisted telemetry including a generated brief; owner MCP spawn, refusal and
release; two-way messaging; quiesced catalog plan/apply, real named-agent filter
and writer restoration; measured frontend/backend edits with source/workload
restoration. Desktop installation/sign-in and macOS clicks get explicit manual
evidence. Cold-install/scoped-cleanup proof must identify its fixture and protect
co-resident profiles. No prior generation's cleanup manifest may be reused.

Run offline TLS/auth/report regressions with `make local-acceptance-test`.
They use a local HTTPS fixture and real Ed25519 signing, not a Kind cluster.
