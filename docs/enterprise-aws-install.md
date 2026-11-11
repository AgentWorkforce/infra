# Enterprise AWS installation and first-user guide

Use this guide with the customer's platform administrator, identity administrator
and pilot users. `AgentWorkforce/infra` is the installation source of truth;
customer names, account details and credentials belong in a private handoff.

**Status: the complete AWS installation is not ready for customer handoff.**
Terraform, the application charts, and the managed-RDS bootstrap exist, but the
current target still needs a release-approved Sessions Pipeline image and a
complete application acceptance run. Finish the release checks below before
scheduling an installation. The historical EKS and local kind demonstrations
are useful development evidence, not this release.

## Before you start

The release owner supplies one tested release packet:

| Required item | What must be ready |
| --- | --- |
| Infrastructure and application versions | An immutable infra commit, chart package and image inventory, including CPU architectures and customer ECR locations. |
| RDS setup | A supported RDS bootstrap/LOGIN procedure, separate service databases, owner/runtime roles, verified TLS and completed migrations. |
| Application wiring | Control sign-in, native ingest/read routes, authoritative PostgreSQL messaging, S3 and the selected OpenSearch/Lambda path tested together. The Sessions artifact includes schema generation `046010`, fresh-install `search_index` read grants, the session-query path and the coordination-overlaps endpoint. |
| Desktop | Signed customer-profile installers, a working download location and the correct server, URL scheme and update feed. |
| Operator controls | Capture policy, pre-upload scrubbing, authorized deletion and disabled add-ons verified in the actual client and app. Do not claim client-side scrubbing until the selected Desktop build contains the release-qualified R9 scrubber. |
| Recovery | A successful isolated restore and a reviewed upgrade/recovery procedure for this exact release. |

Open work is tracked in the [application proof](terraform-helm-application-proof.md),
[database contract](shared-postgres-storage-contract.md) and
[customer controls checklist](enterprise-customer-controls.md). A missing item
blocks the corresponding installation step; do not substitute an older profile.

The customer provides:

- AWS account, region, existing EKS cluster/network, namespace, storage and
  approved administrator/workload identities.
- Private app, API, Relaycast and History origins, DNS, trusted TLS certificates
  and laptop VPN/ZTNA access. A supported shared app/API host is optional;
  Relaycast and History still need their own origins.
- ECR/artifact import access, the secret delivery system, allowed egress and the
  customer's telemetry destination.
- SSO issuer/client configuration, first owner email, organization and pilot
  workspace. Register `<app origin>/login/oidc/callback` with the IdP.
- Supported Desktop operating systems, approved branding, retention and recovery
  requirements. Keep all credentials in the approved secret system.

## 1. Check the administrative environment

**Who:** customer platform administrator.

Use the approved admin runner. Import the pinned source bundle if that runner
cannot reach GitHub. With a normal repository checkout:

```sh
git clone https://github.com/AgentWorkforce/infra.git
cd infra
git checkout --detach "$INFRA_REF"
git rev-parse HEAD
aws sts get-caller-identity
kubectl config current-context
```

`INFRA_REF` comes from the release packet. Compare the commit, AWS account,
region and Kubernetes context with the private handoff before continuing.
Install the release's supported Terraform, Helm, kubectl, Node and Python tools.

For an existing EKS cluster, inventory its private networking, load-balancer
controller, storage, Pod Identity and required access. Follow the
[foundation instructions](../terraform/examples/aws-foundation/README.md) for
missing prerequisites; do not create or adopt a second cluster accidentally.

**Checkpoint:** the admin runner and a pilot laptop can reach the intended
network, and the deployment identity can manage only the approved resources.

## 2. Provision or bind the AWS data services

**Who:** customer platform administrator.

Use the [AWS environment instructions](../terraform/examples/aws-environments/README.md)
and the matching `profiles/*.example` files. Fill in the customer's existing
resource IDs and approved sizing. Keep the private variables and backend files
outside the checkout, with restricted permissions. Foundation, data and
application state have separate keys.

```sh
python3 terraform/scripts/aws-environment.py plan \
  --variables /approved/private/customer.tfvars.json \
  --backend /approved/private/customer.backend.json
python3 terraform/scripts/aws-environment.py show \
  --variables /approved/private/customer.tfvars.json \
  --backend /approved/private/customer.backend.json
```

Review the saved plan: account, region, existing versus new resources, cost,
networking, backups and retention. After approval of that exact plan, use its
recorded digest:

```sh
python3 terraform/scripts/aws-environment.py apply \
  --variables /approved/private/customer.tfvars.json \
  --backend /approved/private/customer.backend.json \
  --approve-plan "$PLAN_SHA256"
python3 terraform/scripts/aws-environment.py output \
  --variables /approved/private/customer.tfvars.json \
  --backend /approved/private/customer.backend.json
```

Retain the plan/apply receipt and non-secret `verification.json`. Reconcile a
failed apply before preparing another plan. Preserve state and backup storage.

**Checkpoint:** actual RDS, S3 and selected search/function resources match the
reviewed inventory and are privately reachable from the intended workloads.

## 3. Bootstrap the service databases

**Who:** the named database provisioning operator, then each service's migration owner.

The AWS target is **one RDS instance with separate logical databases**:

| Service | Database | Schema | Migration owner | Runtime role |
| --- | --- | --- | --- | --- |
| Control | `relaycontrol` | `public` | `control_owner` | `control_api_runtime` |
| Pipeline / HoopDb | `hoopdb` | `sessions` | `hoop` | `sessions_pipeline_runtime` |
| Relaycast | `relaycast` | `public` | `relaycast_owner` | `relaycast_runtime` |
| Relayfile, if selected | `relayfile` | `public` | `relayfile_owner` | `relayfile_runtime` |

Use the accepted [database bootstrap contract](shared-postgres-storage-contract.md).
Terraform creates only the initial RDS database; its binding outputs do not
create the other databases, users or grants. Use the tracked
[`rds-setup.sh`](../scripts/selfhost/rds-setup.sh) procedure with the approved,
digest-pinned Sessions Pipeline services image. Do not use the CNPG superuser
bootstrap as an RDS substitute.

Before Helm, export the non-secret Terraform outputs and the Secrets Manager
ARN from the reviewed environment, then run `pre`:

```sh
export AWS_REGION=<approved-region>
export RDS_HOST="$(terraform output -raw database_host)"
export RDS_ADMIN_SECRET_ARN="$(terraform output -raw database_admin_secret_arn)"
export SERVICES_IMAGE='<customer-registry>/sessions-pipeline@sha256:<approved-digest>'
export NAMESPACE=agent-relay
export KUBE_CONTEXT=<approved-kube-context>
export STATE_DIR=/approved/private/agent-relay-install
scripts/selfhost/rds-setup.sh pre
```

The command creates the `rds-ca` ConfigMap and mode-restricted Secret input
files under `$STATE_DIR/secret-files`. It prints neither database passwords nor
connection strings. Merge those files with the non-database secrets in the
private release packet and create the referenced Kubernetes Secrets; never put
their contents in values or the source checkout.

For each service, create the dedicated database, install its owner/runtime
identities and required extensions, then run its pinned migrations as the
owner. Use real runtime LOGINs over verified TLS to prove allowed operations,
denial of other service databases, and denial of DDL/owner access. Preserve an
existing installation's actual database names until a reviewed migration changes them.

History is a pipeline capability in the target. Keep legacy History/Auth stores
where the selected profile still requires them until their reviewed cutover.
After the HoopDb migration Job succeeds, run `rds-setup.sh post` and restart the
read API, ingest edge, and search indexer. The post phase refuses to activate
those logins before migration evidence exists and verifies each login over TLS.

**Checkpoint:** all required migrations and runtime-role checks pass on managed
RDS. `application_sql_ready=false` or a pending generation means stop here.

## 4. Configure the application and install it

**Who:** platform and identity administrators.

Use the release packet's complete RDS values overlay. The historical
`values-eks.yaml` proof is not a substitute. Current umbrella names are
`relay-control` and `relay-webapp`; older installations must follow the
[naming upgrade guide](control-webapp-chart-rename.md).

1. Deliver credentials through the approved secret system. Values contain
   existing Secret references, never passwords, signing keys or bootstrap tokens.
2. Set `relay-control.bootstrap.orgName` and `relay-control.bootstrap.adminEmail`, the selected
   workspace, Relaycast internal-secret reference and app origin. Configure
   `relay-control.auth.oidc` with the IdP callback from the handoff. See the
   [Control chart](../charts/relay-control/README.md#sign-in-bootstrap-and-invites).
3. Configure the approved [Webapp profile](../charts/relay-webapp/README.md),
   all service origins, private DNS/TLS and permitted egress. Select the
   qualified [native ingest](self-hosted-native-ingest.md) and
   [session reader](self-hosted-session-read-api.md) profile from the packet.
   Do not enable a slot without its supported image, role and authentication contract.
   For the AWS RDS native profile, keep `READ_API_SESSION_QUERY=true` and verify
   a fresh database can list sessions and read events before accepting the
   services digest. Verify `GET /v1/coordination/overlaps` with an authorized
   workspace token too. A 501 from session list, 503 from events, or 404 from
   overlaps blocks release.
4. For a core pilot, set `components.relayflows: false`; leave Relayfile and
   Chief uninstalled unless selected. Verify the matching server and UI
   capability behavior in the [controls checklist](enterprise-customer-controls.md).
5. Import the full pinned image inventory into customer ECR through the approved
   credential-helper/import procedure. Verify destination digests and use those
   references in the overlay. Include migration and supporting images. See the
   [image supply-chain guide](self-hosted-image-supply-chain.md).
6. Render and lint the selected chart with that overlay. Check every namespace,
   origin, Secret reference, image and network setting before installation.

Set `RELEASE`, `CHART_PACKAGE`, `KUBE_CONTEXT` and `NAMESPACE` from the handoff.
Run `helm list --all` in that exact context/namespace. Only confirmed absence
permits this **first-install** command:

```sh
helm install "$RELEASE" "$CHART_PACKAGE" \
  --kube-context "$KUBE_CONTEXT" --namespace "$NAMESPACE" \
  --create-namespace --values /approved/private/customer.values.yaml \
  --no-hooks --timeout 20m
```

Do not add `--wait` to this first command. The read API, ingest edge and search
indexer cannot become ready until their RDS logins are activated, while login
activation must wait for the HoopDb migration Job. Complete that barrier in
order:

```sh
MIGRATION_JOB="$(
  helm get manifest "$RELEASE" --kube-context "$KUBE_CONTEXT" \
    --namespace "$NAMESPACE" |
    yq -r 'select(.kind == "Job" and .metadata.labels."app.kubernetes.io/component" == "hoopdb-migrate") | .metadata.name'
)"
[[ -n "$MIGRATION_JOB" && "$MIGRATION_JOB" != *$'\n'* ]] || {
  echo "expected exactly one current HoopDb migrate Job" >&2
  exit 1
}
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" wait \
  --for=condition=complete "job/$MIGRATION_JOB" --timeout=20m &&
KUBE_CONTEXT="$KUBE_CONTEXT" RELEASE="$RELEASE" MIGRATION_JOB="$MIGRATION_JOB" \
  scripts/selfhost/rds-setup.sh post
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" rollout restart \
  deployment/$RELEASE-read-api deployment/$RELEASE-ingest-edge \
  deployment/$RELEASE-search-indexer
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" rollout status deployment \
  --selector "app.kubernetes.io/instance=$RELEASE" --timeout=20m
```

Inspect every Job before running `post`; a failed or missing current migration
blocks activation. Run the packet's ordered pre-install SQL/Jobs before the
Helm command where required.
For an existing release, follow the [pre-upgrade gate](../scripts/selfhost/README.md#pre-upgrade-gate)
and use `helm upgrade` with its reviewed package and values. Do not add `--install`
to an upgrade, or `--atomic` to a database-changing installation. If the
upgrade rotates or creates RDS logins, use the same migrate-then-post ordering
rather than waiting on Deployments first.

**Checkpoint:** required Jobs complete and workloads become ready. Inspect a
failed Job or missing image/profile instead of bypassing a verifier.

### Upgrades

Use the release's pull-based upgrader instead of assembling a chart or image
set by hand. It is plan-only unless `--apply` is present. The plan downloads
`release-manifest.json`, `release-images.values.yaml`, and `SHA256SUMS` from
the requested GitHub release, verifies their checksums and GitHub build
attestations, checks out the recorded infra commit, mirrors the manifest's
exact image digests, and prints the chart/image change against the live
release.

```sh
scripts/selfhost/agent-relay-upgrade.sh \
  --version "$AGENT_RELAY_VERSION" \
  --registry "$ECR_REGISTRY" \
  --values /approved/private/customer.values.yaml \
  --context "$KUBE_CONTEXT" \
  --namespace "$NAMESPACE" \
  --release "$RELEASE"
```

Review that plan and its exact release identifiers. After approval, repeat the
same command with `--apply --db-instance "$RDS_INSTANCE_ID"`. Apply takes and
waits for an RDS snapshot before Helm, passes the verified release image
overlay last, waits for migrations and rollouts, and stops with the prior Helm
revision and snapshot ID if a step fails. AWS, Kubernetes, and GitHub
credentials come only from the administrator's normal environment or stdin;
never add credentials to command arguments or values files.

## 5. Verify ingress, TLS and services

**Who:** platform administrator, with a pilot laptop on the customer network.

Use the exact health URLs for the selected images, not a guessed common path:

```sh
scripts/selfhost/verify-agent-relay.sh \
  --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" --release "$RELEASE" \
  --health-url "$APP_HEALTH_URL" --health-url "$API_HEALTH_URL" \
  --health-url "$CAST_HEALTH_URL" --health-url "$HISTORY_HEALTH_URL"
```

For TLS terminated at the load balancer with no Ingress `spec.tls`, also repeat
`--external-tls-host <hostname>` for each selected ingress host. The verifier
checks the real certificate chain, hostname and expiry. Do not disable TLS
verification or count a SPA HTML fallback as an API health response.

**Checkpoint:** the script passes and a pilot laptop resolves and reaches all
client-facing origins through VPN/ZTNA, including selected upload endpoints.

## 6. Provision and promote the private Desktop feed

**Who:** platform administrator and Desktop release owner, from a macOS admin
runner after Relay Control is healthy.

Relay Control must start with the private feed enabled before this step:

- `SELFHOST_DESKTOP_FEED_SIGNER=awskms` and
  `SELFHOST_DESKTOP_FEED_STORAGE=s3`;
- `SELFHOST_DESKTOP_FEED_KMS_KEY_ALIASES` maps the exact profile ID from the
  private handoff to its AWS KMS alias. The referenced key must use key spec
  `ECC_NIST_EDWARDS25519` and key usage `SIGN_VERIFY`;
- the Control workload role can call `kms:Sign` and `kms:GetPublicKey` on that
  key and can put, get and delete feed objects in the approved S3 prefix; and
- `SELFHOST_DESKTOP_FEED_S3_BUCKET`, `SELFHOST_DESKTOP_FEED_S3_REGION` and
  `SELFHOST_DESKTOP_FEED_S3_PREFIX` match the reviewed application overlay.
  Keep the bucket private.

Confirm the Control migration Job completed before continuing. The admin
runner needs `bash`, `curl`, `jq`, an authenticated GitHub CLI with permission
to manage the Desktop repository's environment secrets and dispatch its
workflows, and `hdiutil` to inspect the macOS candidate. Inject
`RELAY_ADMIN_TOKEN` from the approved secret system as an environment variable;
never put it in an argument, command transcript or handoff. It must be a Control
bootstrap token or an organization owner/admin bearer for the selected site.

Set every non-secret input from the current private handoff. In particular,
`DESKTOP_CANDIDATE_RUN` and `DESKTOP_VERSION` must name the qualified Desktop
candidate recorded in that handoff. Candidate identifiers from an older packet
are superseded; never carry them forward or substitute an unreviewed run.

```bash
export DESKTOP_REPO="AgentWorkforce/relay-desktop"
export DESKTOP_SITE_URL="https://api.<customer-domain>"
export DESKTOP_ORG_ID="<organization-id>"
export DESKTOP_PROFILE_ID="<profile-id>"
export DESKTOP_WORKSPACE_ID="<workspace-id>"
export DESKTOP_ASSET_PREFIX="<approved-asset-prefix>"
export DESKTOP_CANDIDATE_RUN="<approved-candidate-run-id>"
export DESKTOP_VERSION="<approved-desktop-version>"
export DESKTOP_ENVIRONMENT="desktop-${DESKTOP_PROFILE_ID}"
: "${RELAY_ADMIN_TOKEN:?inject RELAY_ADMIN_TOKEN from the approved secret system}"
gh auth status -h github.com
```

Run the provisioner without `--apply` first. This plan reads the existing
profile and downloads the candidate for its embedded-key check, but does not
register or bind a profile, mint a token, change a GitHub secret or dispatch a
workflow.

```bash
scripts/selfhost/desktop-feed-provision.sh \
  --site "$DESKTOP_SITE_URL" \
  --org "$DESKTOP_ORG_ID" \
  --profile "$DESKTOP_PROFILE_ID" \
  --workspace "$DESKTOP_WORKSPACE_ID" \
  --asset-prefix "$DESKTOP_ASSET_PREFIX" \
  --candidate-run "$DESKTOP_CANDIDATE_RUN" \
  --version "$DESKTOP_VERSION"
```

Require the plan to identify the intended site, profile and
`desktop-<profile>` GitHub environment. For an existing profile it must report
that `$DESKTOP_CANDIDATE_RUN` embeds the site's public feed key. A first-time
plan cannot perform that key check because the profile and KMS public key do
not exist in Control yet; it reports `would register profile` instead.

After explicit approval of these exact inputs and the external mutations, run
the same command once with `--apply`:

```bash
scripts/selfhost/desktop-feed-provision.sh \
  --site "$DESKTOP_SITE_URL" \
  --org "$DESKTOP_ORG_ID" \
  --profile "$DESKTOP_PROFILE_ID" \
  --workspace "$DESKTOP_WORKSPACE_ID" \
  --asset-prefix "$DESKTOP_ASSET_PREFIX" \
  --candidate-run "$DESKTOP_CANDIDATE_RUN" \
  --version "$DESKTOP_VERSION" \
  --apply
```

The apply registers or reuses the profile, binds the workspace, sets the
public key in `DESKTOP_FEED_PUBLIC_KEY`, mints the publisher token directly
into `DESKTOP_FEED_PUBLISHER_TOKEN` in `$DESKTOP_ENVIRONMENT`, and dispatches
`desktop-promote.yml` only after the candidate's embedded key matches. The
publisher token is never printed or written to disk.

This operation is not transactional. A missing or mismatched candidate key
fails apply before workspace binding, GitHub secret updates, token minting or
Promote, although a newly registered profile can remain. A later failure can
leave earlier completed mutations in place. Do not retry blindly: the profile
retains at most two active tokens and a third mint revokes the oldest. Inspect
the recorded state and reconcile a failed step before another apply.

Verify secret names without reading their values, then require the dispatched
Promote run and the profile feed acceptance to pass:

```bash
gh secret list -R "$DESKTOP_REPO" --env "$DESKTOP_ENVIRONMENT"
gh run list -R "$DESKTOP_REPO" --workflow desktop-promote.yml --limit 5
```

**Checkpoint:** the intended workspace is bound, the GitHub environment lists
both feed secret names, the Promote run for `$DESKTOP_CANDIDATE_RUN` and
`$DESKTOP_VERSION` succeeds, and a bound Desktop accepts the signed profile
feed. A dispatch alone is not publication or client-acceptance proof.

## 7. Onboard the first owner and pilot users

**Who:** the configured customer owner, then each invited user.

1. Open the approved app's `/login` page and sign in through customer SSO.
   Confirm the organization/workspace, then invite pilot users in Members.
   Verify an uninvited account is refused.
   Microsoft Entra issuers that omit `email_verified` need the narrowly scoped
   `SELFHOST_OIDC_TRUST_MISSING_EMAIL_VERIFIED_ISSUER` setting for that exact
   issuer in `relay-control.extraEnv`; never use it as a generic trust bypass.
   Until the release packet records a successful real-IdP SSO acceptance run,
   use the qualified password/email-link flow for day-one onboarding.
2. If no sign-in method is configured, have the identity administrator finish
   OIDC/SMTP. For first-owner recovery, the customer's authorized Kubernetes
   operator uses the [device approval runbook](operator-device-login.md).
   The bootstrap bearer stays inside Control; employees do not send it or
   their approval codes to our engineers.
3. Open the release packet's customer download page (the intended route is
   `/downloads`). Install the signed package for the selected OS/CPU. A missing
   or wrong-profile package blocks onboarding; do not substitute a hosted build.
4. Open Desktop and sign in to the customer site. Compare the computer,
   workspace and code in the normal signed-in browser, approve only that
   request, and verify Desktop connects to the same customer workspace.
5. Confirm the effective administrator capture policy and pre-upload scrubber.
   Browser sign-in alone does not prove Desktop is connected. A server-side
   scrub result also does not prove client-side pre-upload scrubbing; verify the
   selected Desktop build carries the release-qualified R9 scrubber first.

**Checkpoint:** a real pilot user can complete SSO, install the correct Desktop
profile and approve their own device without Kubernetes or bootstrap access.

## 8. Prove the workflow and hand it over

**Who:** pilot user, customer administrator and release owner.

- Capture a short real agent session with a harmless unique marker and the
  release's synthetic secret-test value. Verify removal **before upload**,
  then find the same session in app list, transcript and search.
- After first sign-in, copy the real workspace ID into the umbrella release
  overlay's `sessions-pipeline.worker.nativeBrief.workspaceIds`, apply that
  corrected overlay through the reviewed upgrade procedure, and only then
  enable descriptions. This is an explicit bounded list; never use `"*"`, and
  add later workspaces deliberately.
- Retry the supported delivery once and verify one logical result. Restart the
  relevant workloads and confirm durable readback and PostgreSQL messaging.
- Use a second workspace/user to verify cross-tenant denial. Check that each
  runtime role is denied other service databases and privileged operations.
- Change capture policy as an authorized admin and verify client enforcement.
  A normal member must be refused. Delete the test session through the
  authorized operator flow and verify read denial, cleanup and no resurrection.
- Verify disabled Flows/Chief navigation, direct routes and background work;
  check that telemetry goes only to the approved customer collector.
- Validate agreed usage/cost views against known reported activity. Complete
  the [backup and isolated restore drill](selfhost-backup-restore.md), then the
  approved upgrade check and a second Terraform plan with no unexpected drift.

Give the customer the app/download URLs, two named administrators, pinned
release identifiers, policy/add-on selection, recovery procedure, test results
and support contact. List remaining failures with owners. Call the installation
complete only when this exact release passes the agreed workflow.
