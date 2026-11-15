# bootstrap-sandbox

The prerequisites for `../sandbox` in the sandbox account (805532413586).
A human admin there applies this once with SSO; an agent never does.

| Resource | What |
| --- | --- |
| `aws_iam_role.bootstrap` (`layered-infra-ops-broker-tf`) | Assumable only by `arn:aws:iam::500268966557:role/layered-agent-admin-infra-ops-dev` (exact, `aws:PrincipalArn`), 1 h sessions |
| `aws_iam_role_policy.bootstrap` | Manage exactly `agent-broker-sandbox-scoped`: create, get, update, delete, tag, trust, inline policies; attach/detach only `PowerUserAccess`. Read and write state under `aws-cred-broker/` in the bucket. Nothing else. |
| `aws_s3_bucket.state` (`agent-cred-broker-tfstate-805532413586`) + versioning, SSE-S3, public access block, `BucketOwnerEnforced`, bucket policy | Broker state. TLS only, this account's principals only. |

## Apply (Khaliq, with the sandbox SSO profile)

```bash
cd agent/broker/terraform/bootstrap-sandbox
terraform init
terraform plan -var profile=m5lxqm2osk-dev -out=bootstrap.tfplan   # expect 8 to add
terraform apply bootstrap.tfplan
```

## After the first apply

Move this root's own state into the bucket it created, so it isn't only on
one laptop. Add `backend "s3" {}` to `versions.tf`, then:

```bash
terraform init -migrate-state \
  -backend-config="bucket=agent-cred-broker-tfstate-805532413586" \
  -backend-config="key=aws-cred-broker/bootstrap.tfstate" \
  -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
```

Then hand layered-infra-ops the outputs. `bootstrap_role_arn` goes into
`../sandbox/terraform.tfvars` (`sandbox_assume_role_arn`) and
`../sandbox/backend.hcl` (`assume_role`), and `state_bucket` goes into
`backend.hcl`. See `../sandbox/backend.hcl.example`.
