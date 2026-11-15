# bootstrap-sandbox

The prerequisites for `../sandbox` in the sandbox account (805532413586).
A human admin there applies this once with SSO; an agent never does.

| Resource | What |
| --- | --- |
| `aws_iam_role.bootstrap` (`layered-infra-ops-broker-tf`) | Assumable only by `arn:aws:iam::500268966557:role/layered-agent-admin-infra-ops-dev` (exact, `aws:PrincipalArn`), 1 h sessions |
| `aws_iam_role_policy.bootstrap` | Manage exactly `agent-broker-sandbox-scoped`: create, get, update, delete, tag, trust, inline policies; attach/detach only `PowerUserAccess`. Read and write exactly `aws-cred-broker/sandbox.tfstate` and its `.tflock` in the bucket, never this root's own `bootstrap.tfstate`. Nothing else. |
| `aws_s3_bucket.state` (`agent-cred-broker-tfstate-805532413586`) + versioning, SSE-S3, public access block, `BucketOwnerEnforced`, bucket policy | Broker state. TLS only, this account's principals only. |

## Status

Applied 2026-11-15 with Khaliq's sandbox SSO (8 added). Its state is in the
bucket it created, at `aws-cred-broker/bootstrap.tfstate`. The `../sandbox`
roles were applied the same day: 5 added, state at
`aws-cred-broker/sandbox.tfstate`.

## Changing it (a human sandbox admin, with SSO)

```bash
cd agent/broker/terraform/bootstrap-sandbox
cp backend.hcl.example backend.hcl        # set profile
terraform init -backend-config=backend.hcl
terraform plan -var profile=<sandbox SSO profile> -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
```

The outputs feed `../sandbox`: `bootstrap_role_arn` goes in
`terraform.tfvars` (`sandbox_assume_role_arn`) and `backend.hcl`
(`assume_role`), and `state_bucket` goes in `backend.hcl`. See
`../sandbox/backend.hcl.example`.
