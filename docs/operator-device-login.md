# Operator device approval and first-admin recovery

Use this procedure only as an authorized operator of the installation. Normal
team sign-in uses the configured SSO provider or email login; normal Desktop
approval uses the signed-in user's browser. Kubernetes access and a bootstrap
bearer are not required for everyday user sign-in.

The reusable helper is
[`operator-device-login.mjs`](../scripts/selfhost/operator-device-login.mjs).
It executes **inside the Control API pod**, reads its mounted bootstrap bearer,
and calls the existing Control API over pod loopback. It never exports the
bearer, creates a user, grants a role or edits the database. Choose an existing
member and workspace explicitly; it does not assume that the first owner is
the person requesting access.

## Prerequisites

- The exact approved Kubernetes context, namespace and Control Deployment.
- Operator RBAC permitting `pods/exec` into that deployment; no new cluster-wide
  access is required by this guide.
- A compatible Control image exposing the organization, membership, workspace
  and device-approval APIs. The helper reads `SELFHOST_BOOTSTRAP_TOKEN_FILE`
  (or the chart's default mounted token path) and `PORT` (default 3000).
- Node 22+ inside the API image and this helper from the reviewed release.
- A real pending code from the intended person's browser/Desktop on this
  installation. Never approve a code supplied by an unknown requester.

Set non-secret tool context values from the installation handoff:

```sh
KUBE_CONTEXT='YOUR-VERIFIED-CONTEXT'
NAMESPACE='YOUR-INSTALL-NAMESPACE'
CONTROL_DEPLOYMENT='YOUR-CONTROL-DEPLOYMENT'
OPERATOR_TOOL='scripts/selfhost/operator-device-login.mjs'
```

Do not use `kubectl get secret`, paste a bearer into a shell argument, enable
shell tracing, or send credentials through a ticket or chat. This script does
not disable TLS: its HTTP request stays on `127.0.0.1` inside the API pod.
Browser/Desktop connections must still use normal verified public/private TLS.

## 1. Identify the existing member and workspace

```sh
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  exec -i "deployment/$CONTROL_DEPLOYMENT" -- \
  node --input-type=module - inventory < "$OPERATOR_TOOL"
```

Expected output contains one installation organization and selected member/
workspace metadata, with IDs, names, roles and member emails. It contains no
application tokens or runtime configuration. Keep this personnel information
private. If there is no unique installation organization, the helper refuses;
resolve bootstrap state instead of guessing one.

For first-admin recovery select the configured customer's owner email/ID. For
another explicitly authorized recovery select that existing member. Record:

```sh
LOGIN_ORG_ID='VERIFIED-ORGANIZATION-UUID'
LOGIN_WORKSPACE_ID='VERIFIED-WORKSPACE-UUID'
LOGIN_USER_ID='VERIFIED-MEMBER-UUID'
```

These are placeholders, not real identifiers. Do not create or promote someone
merely to approve a code. The API performs the final membership check.

## 2. Inspect the person's current request

The person opens this installation's `/login` Operator sign-in section or
starts Desktop sign-in. They keep the originating browser tab/Desktop open.
Copy their own currently displayed code:

```sh
LOGIN_USER_CODE='ABCD-EFGH' # replace with the real, current code
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  exec -i "deployment/$CONTROL_DEPLOYMENT" -- \
  node --input-type=module - lookup "$LOGIN_USER_CODE" < "$OPERATOR_TOOL"
```

Verify the returned client, computer name (when present), pending status and
expiry with that person. The client/computer labels are caller-provided display
information, not attestation of a trusted machine or its owner. Confirm the
request through the authorized customer process as well as comparing labels.
An expired, consumed, already approved or denied request must not be approved.

Set the exact verified display strings from this lookup; use a literal `-` for
a JSON `null`, not for an unknown or mismatched value:

```sh
LOGIN_CLIENT='EXACT-VERIFIED-CLIENT-NAME'
LOGIN_HOST='EXACT-VERIFIED-COMPUTER-NAME'
```

## 3. Approve or deny

After verifying the person, code, client, organization, member and workspace:

```sh
kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  exec -i "deployment/$CONTROL_DEPLOYMENT" -- \
  node --input-type=module - approve "$LOGIN_USER_CODE" \
    "$LOGIN_ORG_ID" "$LOGIN_WORKSPACE_ID" "$LOGIN_USER_ID" \
    "$LOGIN_CLIENT" "$LOGIN_HOST" < "$OPERATOR_TOOL"
```

Expected result is `status: approved` plus the three verified IDs. The helper
rechecks the organization/member/workspace and freshly looks up the pending
request immediately before asking the server for an atomic decision. An
approval is not retried automatically after a connection failure: inspect
the current state before deciding what to do next.

To reject that inspected request, use the same command with `deny` instead of
`approve`. Expected result is `status: denied`. Do not use approval as a
diagnostic test on another person's code.

## 4. Complete sign-in

Return to the original browser tab or Desktop. Confirm the signed-in person,
organization and workspace. First-admin recovery must be followed by testing
the configured normal sign-in method and access restrictions before broad
user onboarding.

Browser operator sign-in establishes a browser session; it does not install or
sign Desktop in. Desktop sign-in has its own request and must be verified
separately. Never create repeated codes while a valid request is pending.

## Refusals and recovery

| Result | Action |
| --- | --- |
| `installation_organization_ambiguous` / `installation_organization_mismatch` | Reconcile the installation and intended organization. |
| `workspace_mismatch` / `user_not_member` | Confirm the handoff IDs and existing membership. Do not grant a new role as a workaround. |
| `client_mismatch` / `host_mismatch` | Stop and verify the intended request with the person. |
| `request_expired` / `request_not_pending` | Inspect the current state; start a new request only when the old one is finished/expired. |
| `bootstrap_credential_unavailable` | Check the approved file mount and API image configuration inside the deployment; do not extract the credential. |
| `control_http_401` / `control_http_403` | Correct the installation's credential/configuration or operator access. |
| `control_http_404` / `invalid_control_response` | Check image/API compatibility, code and installation before retrying. |
| `control_request_failed` / unexpected HTTP outcome | Inspect the current lookup state; do not blindly repeat an approval. |

The API can reject a code that expires or is decided after the helper's final
lookup. Its response is authoritative. This tool checks request state and
identity selection; it does not independently attest a device, establish SSO,
or prove upload/readback. Complete the real-user acceptance flow separately.
