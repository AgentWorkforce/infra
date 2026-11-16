# aws-neon-exit-runner

One short-lived EC2 runner for copying the legacy sessions schema out of Neon
into its Supabase target. Nothing here is product infrastructure: apply it for
the copy, terminate it with `terraform destroy` after the seal.

What it creates, in one account and region:

- a private subnet in an existing VPC, a NAT gateway (plus EIP) in an existing
  public subnet, and a route table for egress;
- a security group with **no ingress**; egress only on 443, 5432, 6543 and DNS;
- an empty Secrets Manager secret for the target database owner credential.
  Its value is written out of band (`aws secretsmanager put-secret-value`) by
  whoever holds it, never through this configuration or a chat channel;
- an empty Secrets Manager secret for the Cloud copy connection URLs
  (`neon-exit/cloud/copy-urls`), also written out of band. The runner fetches
  it on the box, so no connection URL appears in SSM command history;
- an instance role with `AmazonSSMManagedInstanceCore` and read of those two
  secrets only, and the instance profile;
- one `m6id.4xlarge` (16 vCPU, 64 GB, 950 GB NVMe) on Amazon Linux 2023,
  IMDSv2 only, encrypted root, with the NVMe mounted at `/scratch` and
  `postgresql17` client, `zstd`, `git`, `jq` and `nodejs22` installed.

Access is Session Manager only: `aws ssm start-session --target <instance_id>`
from a principal with `ssm:StartSession` on the instance. On the runner,
`target-secret` prints the secret to the shell (it needs the instance role).

```sh
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
# ... copy ...
terraform destroy -var-file=terraform.tfvars
```

Approximate on-demand cost in us-east-1: the instance about $0.95 per hour,
the NAT gateway about $0.045 per hour plus $0.045 per GB processed.
