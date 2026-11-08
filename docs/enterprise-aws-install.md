# Enterprise AWS installation and first-user guide

This guide is for the customer's platform administrator, identity administrator,
and pilot users. Record the approved change window in the private operator handoff.

**Release preparation, not an installation-complete claim.** The local development
stack works, but the requested single-database AWS stack, customer Desktop
distribution, and all operator controls do not yet have complete acceptance
evidence. Complete the [release checklist](#before-the-installation-meeting)
before asking a customer to follow the installation steps. Do not substitute
the kind/SQLite demonstration for this release.

## What people will use

The platform administrator provides one private application address, reachable
through the customer's network access system. In this guide, replace
`https://relay.customer.example` with that address everywhere.

| Address | Who uses it | Purpose |
| --- | --- | --- |
| `https://relay.customer.example/login` | Everyone | Sign in with the customer's identity provider. |
| `https://relay.customer.example/downloads` | Pilot users and IT | Download the customer-branded Desktop installer. **This page and its signed artifact delivery are release requirements; this guide does not claim they exist today.** |
| The sign-in approval link opened by Desktop | The person signing in | Check the requesting computer and workspace, then approve that device. |
| Settings → Members | Customer owners/admins | Invite people and manage access. |
| Customer operator controls | Authorized customer administrators | Manage capture policy and deletion. Exact released navigation and implementation evidence must be supplied in the release packet. |

Customers do not need an Agent Relay hosted account to approve devices in their
own installation. They do not send a code or bootstrap secret to our engineers.

## Before the installation meeting

Our release owner supplies a **customer release packet** containing:

- A pinned infra commit, chart package/version/digest, and image digests mirrored
  into the customer's ECR. Include the supported CPU architectures.
- One tested AWS foundation/data/application composition, a non-secret customer
  values file, ordered migration/bootstrap instructions, and named rollback and
  restore procedures. A Terraform module output alone is not this packet.
- A completed acceptance report for that exact composition, including managed
  RDS activation, real Desktop upload and application readback, cross-tenant
  refusal, restart, upgrade and isolated restore. Preserve failed attempts.
- Customer Desktop packages, verified hashes/signatures, the compiled site and
  URL scheme, branding, update/feed ownership, and install/uninstall instructions
  for each selected OS. A generic hosted installer is not a substitute.
- A working customer `/downloads` page and first-admin recovery procedure.
- An implemented/tested capture-policy and operator-deletion surface, and the
  disabled-Flows behavior described below.
- A named support contact and a non-secret evidence directory. Do not include
  credentials, session contents, raw rendered Secrets, or Terraform state in a
  support bundle.

The current remaining work is tracked in
[the application proof contract](terraform-helm-application-proof.md),
[the shared database contract](shared-postgres-storage-contract.md), and
[the customer controls acceptance checklist](enterprise-customer-controls.md).
Missing evidence means **not yet ready**, not permission to skip that step.

The customer supplies these inputs before the meeting:

| Input | Customer owner | Record in the handoff |
| --- | --- | --- |
| AWS account, region, environment and permitted resource boundaries | Platform | Exact identifiers; distinguish existing resources from newly managed ones. |
| Existing EKS/network or approval to provision the selected foundation | Platform | Private subnets, endpoint access, worker capacity, storage and IAM authority. |
| Private app DNS name, trusted TLS certificate/CA, ZTNA/VPN access | Network/security | Confirm a pilot laptop can resolve and reach the app. |
| Customer ECR and approved artifact import path | Platform/security | No dependency on public registries at runtime. |
| SSO issuer, client ID, approved domain/group policy and client Secret reference | Identity | Register `<app origin>/login/oidc/callback` with the IdP. |
| First owner email, organization name and pilot workspace | Customer owner | Use a customer-controlled work email; this person receives first-admin access. |
| Approved secret delivery system | Security/platform | Kubernetes Secret references only in the non-secret values file. |
| Backup retention, recovery targets, audit export and allowed egress | Platform/security | Self-host analytics goes to the customer's collector, never hosted PostHog. |
| Approved company name, logo, Desktop names and supported OSes | Customer/IT | Record the approved display name and artwork in the private handoff. |

## 1. Provision the AWS environment

**Who:** the customer platform administrator, using the approved customer AWS
identity and change process.

1. Check the account, region, Kubernetes context and resource inventory against
   the release packet. Do not use an engineer's proof sandbox or credentials.
2. Create or select the reviewed foundation first: private networking, EKS,
   workload identities, storage prerequisites and administrative access. Use
   the [foundation instructions](../terraform/examples/aws-foundation/README.md)
   from the pinned release. If an existing EKS installation is supplied, document
   its prerequisites rather than creating a second cluster.
3. Prepare the private data variables and backend files using
   [AWS environments](../terraform/examples/aws-environments/README.md).
   Keep foundation, data and application state separate. State/backup storage
   must survive application teardown.
4. Generate and inspect the data plan:

   ```sh
   python3 terraform/scripts/aws-environment.py plan \
     --variables /approved/private/customer.tfvars.json \
     --backend /approved/private/customer.backend.json
   python3 terraform/scripts/aws-environment.py show \
     --variables /approved/private/customer.tfvars.json \
     --backend /approved/private/customer.backend.json
   ```

5. After the customer approves that exact saved plan, apply it with the same
   input paths and the reviewed plan digest. Set `PLAN_SHA256` to the exact
   saved-plan digest from the reviewed receipt:

   ```sh
   python3 terraform/scripts/aws-environment.py apply \
     --variables /approved/private/customer.tfvars.json \
     --backend /approved/private/customer.backend.json \
     --approve-plan "$PLAN_SHA256"
   ```

   Retain the apply receipt; reconcile a failed apply before preparing another plan.
   Do not delete state to make a retry succeed.
6. Export the wrapper's non-secret verification outputs. Confirm actual private
   endpoints, resource IDs, backups and workload identities against the receipt.

**Expected result:** the selected Terraform-owned AWS foundation and data
resources exist and are reachable from the approved administrative runner and
workloads. No application has been qualified merely by reaching this point.

The required relational store is **one RDS instance and one application
database**, with distinct service schemas and owner/runtime roles. The default
application database name is `relaycontrol`. Control uses schema `relaycontrol`,
pipeline uses `sessions`, Relaycast uses `relaycast`, History uses `relayhistory`,
and optional Relayfile uses `relayfile`. Follow the exact role table and SQL
readiness gate in the shared database contract. Do not point existing
dedicated-database migrators at this database without their reviewed shared
schema implementation. Runtime roles must not own schemas or run DDL.

## 2. Configure the customer profile and administrator

**Who:** platform and identity administrators together.

1. Deliver credentials through the approved secret system. The customer overlay
   names existing Secrets; it contains no database passwords, bootstrap bearer,
   SSO client secret, signing keys or application tokens.
2. Configure the API's `bootstrap.orgName` and `bootstrap.adminEmail`; set the
   optional administrator display name and workspace name. Set the matching
   Relaycast internal-secret reference and dashboard origin. These are existing
   [control chart inputs](../charts/relay-cloud-api/README.md#sign-in-bootstrap-and-invites).
3. Configure `auth.oidc` for the customer's IdP and mount its client secret from
   the selected Secret key. The callback is exactly
   `https://relay.customer.example/login/oidc/callback`. Enable only the required
   private network/IdP connectivity; do not enable unrestricted egress.
4. Set the approved [dashboard customer profile](../charts/relay-dashboard/README.md)
   and the matching Desktop profile. The Desktop site, deep-link scheme,
   application identity, signing trust and update source must belong to this
   customer profile. Never point its updater at a hosted Agent Relay build.
5. Select the customer's core profile: `components.relayflows: false`. This
   prevents Flows worker installation, but **does not by itself hide the current
   dashboard sidebar or disable the API**. Require the corresponding released
   server entitlement/capability and UI gating from the controls checklist.
   Relayfile is also outside a core-only profile unless separately
   selected. Keep add-ons available for other entitled deployments.

**Expected result:** the reviewed values describe one customer installation,
one first owner and one pilot workspace, with SSO and the selected add-ons
explicitly configured.

## 3. Install the pinned Helm release

**Who:** the customer platform administrator.

1. Import the exact release images into ECR and verify their digests. Distribute
   customer Desktop installers through the approved artifact path as well.
2. Render/lint the selected package with the supplied non-secret values. Check
   the release packet's public/private origins, namespace, Secret references,
   image digests and network restrictions before installation.
3. Run the release packet's ordered SQL/bootstrap and migration procedure using
   separate owner credentials. Wait for each required Job and the application
   readiness barrier; never bypass a verifier or mark a pending generation PASS.
4. Install/upgrade the exact chart package with the packet's values, context,
   namespace and release name. Use its specified migration order. There is no
   universal complete-stack one-liner qualified by this document. Do not add
   `--atomic`: Helm cannot undo database or object-data changes.
   Once the packet's required pre-install Jobs have completed, the Helm command
   has this shape (set each variable from that packet first):

   ```sh
   helm upgrade --install "$RELEASE" "$CHART_PACKAGE" \
     --kube-context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
     --create-namespace --values /approved/private/customer.values.yaml \
     --wait --wait-for-jobs --timeout 20m
   ```

5. Run `scripts/selfhost/verify-agent-relay.sh` with that exact context, namespace
   and release. This checks infrastructure/workload readiness; it does not
   replace the user tests below.

   ```sh
   scripts/selfhost/verify-agent-relay.sh \
     --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" --release "$RELEASE"
   ```

**Expected result:** required Jobs completed, services ready, private ingress
reachable, and normal TLS verification succeeds from the pilot laptop.

## 4. Sign in as the first administrator

**Who:** the customer employee whose email was configured as the first owner.

1. Connect to the customer's VPN/ZTNA network.
2. Open `https://relay.customer.example/login`.
3. Choose the customer's SSO provider and sign in with the configured work email.
4. Confirm the customer organization and pilot workspace are correct.
5. Open Settings → Members, invite the pilot users, and assign only the intended
   roles. Verify an uninvited/non-member account is refused.

First boot creates the organization/owner and default Relaycast workspace
idempotently; the API may still be retrying workspace creation while serving
HTTP. An HTTP 200 login page does not establish that bootstrap completed.

### If the page says “No sign-in method is configured”

This means OIDC/email sign-in was not configured successfully. The normal fix
is for the customer's identity/platform administrator to finish Step 2. It is
not a request for our team to approve every employee manually.

For first-admin recovery, the **customer's authorized Kubernetes operator** may
use the bootstrap bearer already mounted in the API pod:

1. The intended customer owner opens Operator sign-in and keeps that same
   browser tab open. Record its current code.
2. Inspect that exact code through `POST /api/v1/auth/device/approve` with
   `{ "action": "lookup", "user_code": "OWN-CODE" }`. Authenticate from inside
   the API pod with the mounted bootstrap bearer; never print/copy it into a
   terminal argument, ticket, chat or browser.
3. Check the returned client, computer (when present), pending status and
   expiry with the person requesting access. Separately verify the intended
   existing customer owner ID and workspace ID. Do not select the first row
   blindly, create a replacement user, or approve an unknown request.
4. Submit `{ "action": "approve", "user_code": "OWN-CODE", "user_id":
   "VERIFIED-OWNER-ID", "workspace_id": "VERIFIED-WORKSPACE-ID" }` to the same
   authenticated endpoint. The API enforces membership. The released operator
   tool/procedure must keep the bearer inside the pod and redact responses.
5. Return to the original browser tab. Confirm the correct organization and
   owner, then configure/test SSO before inviting other users.

The API contract is implemented in
[Control's device approval tests](https://github.com/AgentWorkforce/relay-control/blob/92cd27d58df395be050809431f21707016557899/test/device-approval.test.ts).
**The packaged, tested customer operator command is still a release deliverable.**
Do not hand customers the ignored `.kind/.../approve-login.mjs` fixture helper
as a supported enterprise tool. Codes expire; inspect a newly generated code
after expiry instead of retrying an old approval.

## 5. Download and sign in to Desktop

**Who:** each pilot user, with IT help for installation/trust if required.

1. While signed in to the customer app, open **Download Desktop** at
   `https://relay.customer.example/downloads`.
2. Select the approved installer for the computer's OS and CPU architecture.
   The page must show the approved customer brand, version, supported OS,
   publisher/signature, checksum and the connected server address. It must
   serve the entitled customer artifact, not redirect to a generic hosted app.
3. Follow that package's IT-approved installation instructions. Public or
   customer CA trust must work normally; do not bypass certificate validation,
   Gatekeeper, signing or enterprise endpoint policy.
4. Open the installed customer Desktop app and choose Sign in. It opens the
   customer site in the browser. Sign in through SSO if requested.
5. Check the computer, customer workspace and code on the approval page against
   Desktop. Approve only your own request. Desktop should report the same
   customer workspace and connected state.
6. Confirm that capture settings show the administrator's policy. Managed
   settings must be labelled and not silently overridden by the user.

Normal Desktop approval is performed in the authenticated customer browser.
It requires neither Kubernetes access nor disclosure of the bootstrap bearer.
Browser login and Desktop device approval are separate steps; a signed-in
browser is not proof that Desktop is installed or connected.

## 6. Prove the real pilot workflow

**Who:** one pilot user and one customer administrator, recording non-secret
results with the release owner.

1. Start a short real coding-agent session in the selected workspace. Include
   a unique harmless marker and a synthetic secret-test value supplied by the
   release test. Never use a real secret as the test marker.
2. Confirm client-side scrubber evidence shows the synthetic secret was removed
   **before upload**. Server-side scrubbing alone does not satisfy this check.
3. Confirm that the marked session appears in the normal customer application
   list, opens with the expected transcript, and is searchable. Check the real
   owner/workspace and processing status. A row in a pipeline table alone fails
   this test.
4. Deliver the same session event again through the supported client retry path.
   Confirm one logical result and durable readback after the selected service
   restart.
5. Register two agents, exchange a message and a reply, and verify both sides
   read the same conversation using the customer's authoritative Postgres store.
6. Use a second workspace/user to verify that lists, transcript, search, direct
   APIs and database runtime roles cannot read the first workspace's data.
7. As the customer operator, change a managed capture setting and verify the
   enrolled client enforces it. As a normal member, verify the same policy
   mutation and operator-deletion API are refused.
8. Delete the marked session through the authorized operator UI, confirm the
   target and complete the explicit destructive confirmation. Check completion
   across object storage, database/search projections and supported reads;
   replay/retry must not resurrect it. Explain retained backup disposition.
9. For a Flows-disabled profile, confirm there is no Flows sidebar item. A direct Flows URL
   and API call must also be refused, with no Flows workloads/schedules running.
10. Check that product analytics reaches only the approved local collector, and
    that blocked hosted egress cannot fall back to `i.agentrelay.com`. Verify
    agreed audit/operational telemetry in the customer's monitoring system.
11. Verify the selected cost/usage views against known reported usage. Treat
    usage attribution as distinct from an external provider invoice or enforced
    budget limit. Include the customer's agreed team/project effectiveness
    question in the POC handoff.

**Expected result:** every selected requirement passes on the exact customer
release. Record FAIL or PENDING honestly. The existing local receipt is
57 PASS / 0 FAIL / 3 PENDING, not full acceptance of this workflow.

## Troubleshooting and handoff

| What the person sees | What to do |
| --- | --- |
| Site cannot be reached | Check customer VPN/ZTNA, private DNS, ingress and network routes. |
| TLS/certificate error | Correct the certificate chain/hostname or distribute the approved public CA through IT. Never disable verification. |
| No sign-in method | Complete OIDC/SMTP configuration; use customer operator recovery only for the first owner/emergency. |
| Code expired/denied | Start a fresh request in Desktop/browser and inspect that request. Never approve another person's pending code. |
| Desktop connects to the hosted site or wrong scheme | Stop the pilot flow and install the correct customer-profile artifact. Changing an environment variable is not a replacement for a compiled profile. |
| Download missing or wrong platform | Release owner imports the signed customer asset; do not substitute a hosted build. |
| Upload succeeds but session is absent | Trace the same session through canonical storage, pipeline, approved reader and application route. Do not copy rows or bypass ACLs. |
| A managed setting can be bypassed | Fail the policy acceptance case and report the exact version; a disabled UI alone is insufficient. |
| Deletion still pending | Inspect the supported deletion job/status and read denials. Do not claim completion after hiding a list item. |

Before ending the installation meeting, give the customer the app/download
URLs, two named administrators, the selected policy and add-ons, release
identifiers, verified backup/restore instructions, test results, remaining
issues with owners, and a support contact. Do not describe the install as
complete until the agreed acceptance cases actually pass.
